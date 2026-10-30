import Foundation
import GlintCore
import SwiftUI
@preconcurrency import Translation

@MainActor
protocol SystemTranslationSessionDriving: AnyObject {
    func prepareTranslation() async throws
    func translate(_ text: String) async throws -> String
}

@MainActor
private final class TranslationSessionDriver:
    SystemTranslationSessionDriving
{
    private let session: TranslationSession

    init(session: TranslationSession) {
        self.session = session
    }

    func prepareTranslation() async throws {
        try await session.prepareTranslation()
    }

    func translate(_ text: String) async throws -> String {
        let response = try await session.translate(text)
        return response.targetText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
    }
}

@MainActor
public final class SystemTranslationCoordinator: ObservableObject {
    private struct PendingRequest {
        let id: UUID
        let text: String
        let continuation: CheckedContinuation<String, any Error>
    }

    private static let maximumPendingRequests = 9
    private static let defaultDriverReadyTimeout: Duration = .seconds(2)
    private static let sourceLanguage = Locale.Language(
        identifier: "zh-Hans"
    )
    private static let targetLanguage = Locale.Language(
        identifier: "en"
    )

    @Published public private(set) var availability: SystemTranslationAvailability?
    @Published public private(set) var configuration: TranslationSession.Configuration?
    @Published public private(set) var isPreparing = false

    private let availabilityProvider: @MainActor () async -> SystemTranslationAvailability
    private let driverReadyTimeout: Duration
    private var driver: (any SystemTranslationSessionDriving)?
    private var driverWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var pendingRequests: [PendingRequest] = []
    private var currentRequest: PendingRequest?
    private var cancelledRequestIDs: Set<UUID> = []
    private var idleContinuation: CheckedContinuation<Void, Never>?
    private var shouldStop = false

    public convenience init() {
        self.init(
            availabilityProvider: {
                await Self.queryAvailability()
            }
        )
    }

    init(
        availabilityProvider:
            @escaping @MainActor () async ->
            SystemTranslationAvailability,
        driverReadyTimeout: Duration =
            SystemTranslationCoordinator.defaultDriverReadyTimeout
    ) {
        self.availabilityProvider = availabilityProvider
        self.driverReadyTimeout = driverReadyTimeout
    }

    public func refreshAvailability() async {
        guard !isPreparing else { return }
        availability = await availabilityProvider()
    }

    public func prepareLanguagePack() async throws {
        guard !isPreparing else { return }
        isPreparing = true
        defer { isPreparing = false }

        let current = await availabilityProvider()
        availability = current
        guard current != .unsupported else {
            availability = .unsupported
            throw SystemTranslationError.unsupported
        }

        availability = .installing
        do {
            try await startConfiguration()
            try await driver?.prepareTranslation()
            let updated = await availabilityProvider()
            availability = updated
            guard updated.canSelect else {
                throw SystemTranslationError.languagePackUnavailable
            }
        } catch {
            if Self.isCancellation(error) {
                availability = current
                throw CancellationError()
            }
            availability = .failed(error.localizedDescription)
            throw error
        }
    }

    @discardableResult
    public func prepareInstalledSessionIfAvailable() async -> Bool {
        let current = await availabilityProvider()
        availability = current
        guard current.canSelect else { return false }
        do {
            try await startConfiguration()
            try await driver?.prepareTranslation()
            return true
        } catch SystemTranslationError.sessionUnavailable {
            return false
        } catch {
            availability = .failed(error.localizedDescription)
            return false
        }
    }

    public func translate(_ text: String) async throws -> String {
        try Task.checkCancellation()
        guard driver != nil else {
            throw SystemTranslationError.sessionUnavailable
        }
        let requestID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let activeCount = currentRequest == nil ? 0 : 1
                guard
                    pendingRequests.count + activeCount
                        < Self.maximumPendingRequests
                else {
                    continuation.resume(
                        throwing:
                            SystemTranslationError
                            .tooManyPendingRequests
                    )
                    return
                }
                pendingRequests.append(
                    PendingRequest(
                        id: requestID,
                        text: text,
                        continuation: continuation
                    )
                )
                signalIdleLoop()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel(requestID: requestID)
            }
        }
    }

    public func shutdown() {
        shouldStop = true
        configuration = nil
        signalIdleLoop()
        failDriverWaiters()
        failPendingRequests(
            CancellationError()
        )
    }

    func run(session: TranslationSession) async {
        await run(driver: TranslationSessionDriver(session: session))
    }

    func run(driver: any SystemTranslationSessionDriving) async {
        self.driver = driver
        shouldStop = false
        resumeDriverWaiters()
        while !shouldStop, !Task.isCancelled {
            if let request = takeNextRequest() {
                await execute(request, using: driver)
            } else {
                await waitForWork()
            }
        }
        self.driver = nil
        failDriverWaiters()
        failPendingRequests(
            SystemTranslationError.sessionUnavailable
        )
    }

    private func startConfiguration() async throws {
        if driver == nil {
            configuration = nil
            await Task.yield()
            configuration = TranslationSession.Configuration(
                source: Self.sourceLanguage,
                target: Self.targetLanguage
            )
            guard await waitForDriver() else {
                throw SystemTranslationError.sessionUnavailable
            }
        } else if configuration == nil {
            configuration = TranslationSession.Configuration(
                source: Self.sourceLanguage,
                target: Self.targetLanguage
            )
        }
    }

    private func waitForDriver() async -> Bool {
        guard driver == nil else { return true }
        guard !shouldStop else { return false }

        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard driver == nil else {
                    continuation.resume(returning: true)
                    return
                }
                guard !shouldStop else {
                    continuation.resume(returning: false)
                    return
                }
                driverWaiters[waiterID] = continuation
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        try await Task.sleep(for: driverReadyTimeout)
                    } catch {
                        return
                    }
                    resolveDriverWaiter(
                        id: waiterID,
                        isReady: false
                    )
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resolveDriverWaiter(
                    id: waiterID,
                    isReady: false
                )
            }
        }
    }

    private func resumeDriverWaiters() {
        let waiters = driverWaiters
        driverWaiters.removeAll()
        for (_, continuation) in waiters {
            continuation.resume(returning: true)
        }
    }

    private func failDriverWaiters() {
        let waiters = driverWaiters
        driverWaiters.removeAll()
        for (_, continuation) in waiters {
            continuation.resume(returning: false)
        }
    }

    private func resolveDriverWaiter(id: UUID, isReady: Bool) {
        guard let continuation = driverWaiters.removeValue(forKey: id) else {
            return
        }
        continuation.resume(returning: isReady)
    }

    private func takeNextRequest() -> PendingRequest? {
        guard !pendingRequests.isEmpty else { return nil }
        let request = pendingRequests.removeFirst()
        if pendingRequests.isEmpty {
            cancelledRequestIDs.removeAll(keepingCapacity: true)
        }
        currentRequest = request
        return request
    }

    private func execute(
        _ request: PendingRequest,
        using driver: any SystemTranslationSessionDriving
    ) async {
        defer {
            currentRequest = nil
            cancelledRequestIDs.remove(request.id)
        }
        guard !cancelledRequestIDs.contains(request.id) else {
            request.continuation.resume(
                throwing: CancellationError()
            )
            return
        }
        do {
            let output = try await driver.translate(request.text)
            if cancelledRequestIDs.contains(request.id) {
                request.continuation.resume(
                    throwing: CancellationError()
                )
            } else if output.isEmpty {
                request.continuation.resume(
                    throwing: SystemTranslationError.emptyTranslation
                )
            } else {
                request.continuation.resume(returning: output)
            }
        } catch {
            request.continuation.resume(throwing: error)
        }
    }

    private func cancel(requestID: UUID) {
        if let index = pendingRequests.firstIndex(where: {
            $0.id == requestID
        }) {
            let request = pendingRequests.remove(at: index)
            request.continuation.resume(
                throwing: CancellationError()
            )
            return
        }
        if currentRequest?.id == requestID {
            cancelledRequestIDs.insert(requestID)
        }
    }

    private func waitForWork() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled || shouldStop {
                    continuation.resume()
                } else {
                    idleContinuation = continuation
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.signalIdleLoop()
            }
        }
    }

    private func signalIdleLoop() {
        guard let continuation = idleContinuation else { return }
        idleContinuation = nil
        continuation.resume()
    }

    private func failPendingRequests(_ error: any Error) {
        let requests = pendingRequests
        pendingRequests.removeAll()
        for request in requests {
            request.continuation.resume(throwing: error)
        }
        if let currentRequest {
            cancelledRequestIDs.insert(currentRequest.id)
        }
    }

    private static func queryAvailability() async
        -> SystemTranslationAvailability
    {
        let status = await LanguageAvailability().status(
            from: sourceLanguage,
            to: targetLanguage
        )
        switch status {
        case .installed:
            return .installed
        case .supported:
            return .available
        case .unsupported:
            return .unsupported
        @unknown default:
            return .unsupported
        }
    }

    private static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError || Task.isCancelled {
            return true
        }
        if #available(macOS 26.0, *),
            TranslationError.alreadyCancelled ~= error
        {
            return true
        }
        return false
    }
}

public enum SystemTranslationError:
    LocalizedError,
    Equatable,
    Sendable
{
    case unsupported
    case languagePackUnavailable
    case sessionUnavailable
    case tooManyPendingRequests
    case emptyTranslation

    public var errorDescription: String? {
        switch self {
        case .unsupported:
            "当前 Mac 不支持简体中文到英文翻译"
        case .languagePackUnavailable:
            "系统翻译语言包尚未安装"
        case .sessionUnavailable:
            "系统翻译会话不可用"
        case .tooManyPendingRequests:
            "系统翻译请求过多"
        case .emptyTranslation:
            "系统翻译未返回结果"
        }
    }
}
