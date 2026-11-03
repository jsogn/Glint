import Foundation
import GlintCore
import OSLog
import SwiftUI
@preconcurrency import Translation

private let systemTranslationLogger = Logger(
    subsystem: "com.local.glint",
    category: "SystemTranslation"
)

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
    private static let defaultDriverReadyTimeout: Duration = .seconds(5)
    private static let availabilityMonitorDuration: Duration = .seconds(30 * 60)
    private static let maximumAvailabilityPollInterval = 15

    @Published public private(set) var availability: SystemTranslationAvailability? {
        didSet {
            guard availability != oldValue,
                let availability
            else {
                return
            }
            onAvailabilityChange?(currentDirection, availability)
        }
    }
    @Published public private(set) var configuration: TranslationSession.Configuration?
    @Published public private(set) var isPreparing = false
    public var onAvailabilityChange:
        (@MainActor (
            TranslationDirection,
            SystemTranslationAvailability
        ) -> Void)?
    var currentSessionGeneration: UInt64 { sessionGeneration }
    public private(set) var currentDirection: TranslationDirection

    private let availabilityProvider:
        @MainActor (TranslationDirection) async ->
            SystemTranslationAvailability
    private let driverReadyTimeout: Duration
    private var driver: (any SystemTranslationSessionDriving)?
    private var driverWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var sessionGeneration: UInt64 = 0
    private var directionGeneration: UInt64 = 0
    private var preparationGeneration: UInt64 = 0
    private var preparingDirection: TranslationDirection?
    private var preparingDirectionGeneration: UInt64 = 0
    private var pendingRequests: [PendingRequest] = []
    private var currentRequest: PendingRequest?
    private var cancelledRequestIDs: Set<UUID> = []
    private var idleContinuation: CheckedContinuation<Void, Never>?
    private var availabilityMonitorTask: Task<Void, Never>?
    private var shouldStop = false

    public convenience init(
        direction: TranslationDirection
    ) {
        self.init(
            direction: direction,
            availabilityProvider: { direction in
                await Self.queryAvailability(for: direction)
            }
        )
    }

    init(
        direction: TranslationDirection =
            .simplifiedChineseToEnglish,
        availabilityProvider:
            @escaping @MainActor (TranslationDirection) async ->
            SystemTranslationAvailability,
        driverReadyTimeout: Duration =
            SystemTranslationCoordinator.defaultDriverReadyTimeout
    ) {
        self.currentDirection = direction
        self.availabilityProvider = availabilityProvider
        self.driverReadyTimeout = driverReadyTimeout
    }

    public func setDirection(
        _ direction: TranslationDirection
    ) async {
        guard currentDirection != direction else { return }
        systemTranslationLogger.notice(
            "session direction from=\(self.currentDirection.target.rawValue, privacy: .public) to=\(direction.target.rawValue, privacy: .public)"
        )
        currentDirection = direction
        directionGeneration &+= 1
        sessionGeneration &+= 1
        driver = nil
        if var nextConfiguration = configuration {
            nextConfiguration.invalidate()
            configuration = nextConfiguration
        }
        availability = nil
        signalIdleLoop()
        failDriverWaiters()
        failPendingRequests(
            SystemTranslationError.sessionUnavailable
        )
        stopAvailabilityMonitoring()
    }

    public func refreshAvailability(
        for direction: TranslationDirection
    ) async {
        if currentDirection != direction {
            await setDirection(direction)
        }
        guard !isPreparing else { return }
        let operationGeneration = directionGeneration
        let current = await availabilityProvider(direction)
        guard isCurrentDirection(
            direction,
            generation: operationGeneration
        ), !isPreparing else {
            return
        }
        availability = current
        if current != .available {
            stopAvailabilityMonitoring()
        }
    }

    public func prepareLanguagePack(
        for direction: TranslationDirection
    ) async throws {
        if currentDirection != direction {
            await setDirection(direction)
        }
        let operationGeneration = directionGeneration
        if isPreparing,
            preparingDirection == direction,
            preparingDirectionGeneration == operationGeneration
        {
            return
        }
        preparationGeneration &+= 1
        let operation = preparationGeneration
        stopAvailabilityMonitoring()
        isPreparing = true
        preparingDirection = direction
        preparingDirectionGeneration = operationGeneration
        defer {
            if operation == preparationGeneration {
                isPreparing = false
                preparingDirection = nil
                preparingDirectionGeneration = 0
            }
        }

        let current = await availabilityProvider(direction)
        guard isCurrentDirection(
            direction,
            generation: operationGeneration
        ) else {
            return
        }
        systemTranslationLogger.notice(
            "language pack prepare target=\(direction.target.rawValue, privacy: .public) status=\(String(describing: current), privacy: .public)"
        )
        availability = current
        guard current != .unsupported else {
            availability = .unsupported
            throw SystemTranslationError.unsupported
        }

        availability = .installing
        do {
            try await startConfiguration(forceNewSession: true)
            guard isCurrentDirection(
                direction,
                generation: operationGeneration
            ) else {
                return
            }
            guard let driver else {
                throw SystemTranslationError.sessionUnavailable
            }
            try await driver.prepareTranslation()
            guard isCurrentDirection(
                direction,
                generation: operationGeneration
            ) else {
                return
            }
            let updated = await availabilityProvider(direction)
            guard isCurrentDirection(
                direction,
                generation: operationGeneration
            ) else {
                return
            }
            availability = updated
            switch updated {
            case .installed:
                break
            case .available, .installing:
                startAvailabilityMonitoring()
            case .unsupported:
                throw SystemTranslationError.unsupported
            case .failed:
                throw SystemTranslationError.languagePackUnavailable
            }
        } catch SystemTranslationError.sessionUnavailable {
            guard isCurrentDirection(
                direction,
                generation: operationGeneration
            ) else {
                return
            }
            availability = .failed(
                SystemTranslationError.sessionUnavailable.localizedDescription
            )
            throw SystemTranslationError.sessionUnavailable
        } catch {
            let updated = await availabilityProvider(direction)
            guard isCurrentDirection(
                direction,
                generation: operationGeneration
            ) else {
                return
            }
            availability = updated
            switch updated {
            case .installed:
                return
            case .available, .installing:
                startAvailabilityMonitoring()
                return
            case .unsupported:
                throw SystemTranslationError.unsupported
            case .failed:
                break
            }
            availability = .failed(error.localizedDescription)
            throw error
        }
    }

    private func isCurrentDirection(
        _ direction: TranslationDirection,
        generation: UInt64
    ) -> Bool {
        currentDirection == direction
            && directionGeneration == generation
    }

    @discardableResult
    public func prepareInstalledSessionIfAvailable(
        for direction: TranslationDirection
    ) async -> Bool {
        if currentDirection != direction {
            await setDirection(direction)
        }
        let operationGeneration = directionGeneration
        let current = await availabilityProvider(direction)
        guard isCurrentDirection(
            direction,
            generation: operationGeneration
        ) else {
            return false
        }
        availability = current
        systemTranslationLogger.notice(
            "installed session prepare target=\(direction.target.rawValue, privacy: .public) status=\(String(describing: current), privacy: .public)"
        )
        guard current.canSelect else { return false }
        do {
            try await startConfiguration(forceNewSession: true)
            guard isCurrentDirection(
                direction,
                generation: operationGeneration
            ) else {
                return false
            }
            try await driver?.prepareTranslation()
            guard isCurrentDirection(
                direction,
                generation: operationGeneration
            ) else {
                return false
            }
            return true
        } catch SystemTranslationError.sessionUnavailable {
            return false
        } catch {
            guard isCurrentDirection(
                direction,
                generation: operationGeneration
            ) else {
                return false
            }
            availability = .failed(error.localizedDescription)
            return false
        }
    }

    public func translate(
        _ text: String,
        direction: TranslationDirection
    ) async throws -> String {
        try Task.checkCancellation()
        guard currentDirection == direction,
            driver != nil
        else {
            systemTranslationLogger.error(
                "translate rejected target=\(direction.target.rawValue, privacy: .public) session_target=\(self.currentDirection.target.rawValue, privacy: .public) driver=\(String(self.driver != nil), privacy: .public)"
            )
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
        sessionGeneration &+= 1
        stopAvailabilityMonitoring()
        configuration = nil
        signalIdleLoop()
        failDriverWaiters()
        failPendingRequests(
            CancellationError()
        )
    }

    func run(
        session: TranslationSession,
        generation: UInt64
    ) async {
        guard generation == sessionGeneration else { return }
        await run(
            driver: TranslationSessionDriver(session: session),
            generation: generation
        )
    }

    func run(driver: any SystemTranslationSessionDriving) async {
        await run(
            driver: driver,
            generation: sessionGeneration
        )
    }

    private func run(
        driver: any SystemTranslationSessionDriving,
        generation: UInt64
    ) async {
        guard generation == sessionGeneration else { return }
        self.driver = driver
        shouldStop = false
        resumeDriverWaiters()
        while !shouldStop,
            !Task.isCancelled,
            generation == sessionGeneration
        {
            if let request = takeNextRequest() {
                await execute(request, using: driver)
            } else {
                await waitForWork()
            }
        }
        if generation == sessionGeneration {
            self.driver = nil
            failDriverWaiters()
            failPendingRequests(
                SystemTranslationError.sessionUnavailable
            )
        }
    }

    private func startConfiguration(
        forceNewSession: Bool = false
    ) async throws {
        if forceNewSession, configuration != nil {
            try await restartConfiguration()
            return
        }
        if driver == nil {
            configuration = nil
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(20))
            makeConfiguration()
            guard await waitForDriver() else {
                throw SystemTranslationError.sessionUnavailable
            }
        } else if configuration == nil {
            makeConfiguration()
        }
    }

    private func restartConfiguration() async throws {
        sessionGeneration &+= 1
        driver = nil
        signalIdleLoop()
        failDriverWaiters()
        failPendingRequests(
            SystemTranslationError.sessionUnavailable
        )
        if var nextConfiguration = configuration {
            nextConfiguration.invalidate()
            configuration = nextConfiguration
        } else {
            makeConfiguration()
        }
        await Task.yield()
        guard await waitForDriver() else {
            throw SystemTranslationError.sessionUnavailable
        }
    }

    private func makeConfiguration() {
        let direction = currentDirection
        configuration = TranslationSession.Configuration(
            source: Locale.Language(
                identifier: direction.source.rawValue
            ),
            target: Locale.Language(
                identifier: direction.target.rawValue
            )
        )
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

    private func startAvailabilityMonitoring() {
        guard availabilityMonitorTask == nil else { return }
        availabilityMonitorTask = Task { [weak self] in
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(
                by: Self.availabilityMonitorDuration
            )
            var pollCount = 0
            while !Task.isCancelled {
                guard clock.now < deadline else {
                    self?.availabilityMonitorTask = nil
                    return
                }
                let seconds = min(
                    1 << min(pollCount, 4),
                    Self.maximumAvailabilityPollInterval
                )
                pollCount += 1
                do {
                    try await Task.sleep(
                        for: .seconds(Int64(seconds))
                    )
                } catch {
                    return
                }
                guard let self else { return }
                guard !self.isPreparing else { continue }
                let current = await availabilityProvider(
                    currentDirection
                )
                guard !Task.isCancelled, !self.isPreparing else {
                    return
                }
                availability = current
                switch current {
                case .available, .installing:
                    continue
                case .installed, .unsupported, .failed:
                    availabilityMonitorTask = nil
                    return
                }
            }
        }
    }

    private func stopAvailabilityMonitoring() {
        availabilityMonitorTask?.cancel()
        availabilityMonitorTask = nil
    }

    private static func queryAvailability(
        for direction: TranslationDirection
    ) async
        -> SystemTranslationAvailability
    {
        let status = await LanguageAvailability().status(
            from: Locale.Language(
                identifier: direction.source.rawValue
            ),
            to: Locale.Language(
                identifier: direction.target.rawValue
            )
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
            "当前 Mac 不支持该翻译方向"
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
