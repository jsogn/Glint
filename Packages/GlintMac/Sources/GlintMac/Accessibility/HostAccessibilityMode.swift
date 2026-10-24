import AppKit
import ApplicationServices
import Foundation

enum HostAccessibilityPolicy {
    static let messagingTimeout: Float = 0.05
    static let transientRetryNanoseconds: UInt64 = 2_000_000_000
    static let failureRetryNanoseconds: UInt64 = 30_000_000_000
    static let maximumCachedProcessCount = 64
}

struct HostProcessSession: Hashable, Sendable {
    let processIdentifier: pid_t
    let bundleIdentifier: String?
    let launchDate: Date?
    let executablePath: String?

    init(
        processIdentifier: pid_t,
        bundleIdentifier: String? = nil,
        launchDate: Date? = nil,
        executablePath: String? = nil
    ) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.launchDate = launchDate
        self.executablePath = executablePath
    }

    static func current(processIdentifier: pid_t) -> Self {
        let application = NSRunningApplication(
            processIdentifier: processIdentifier
        )
        return Self(
            processIdentifier: processIdentifier,
            bundleIdentifier: application?.bundleIdentifier,
            launchDate: application?.launchDate,
            executablePath: application?.executableURL?.path
        )
    }
}

enum HostAccessibilityActivation: Sendable, Equatable {
    case activated
    case alreadyEnhanced
    case transientFailure
    case unavailable
    case failed
}

enum HostAccessibilityReadState: Sendable, Equatable {
    case enabled
    case disabled
    case transientFailure
    case unsupported

    static func classify(_ error: AXError) -> Self {
        switch error {
        case .attributeUnsupported, .noValue:
            return .unsupported
        default:
            return .transientFailure
        }
    }
}

protocol HostAccessibilityActivating: Sendable {
    func activate(processIdentifier: pid_t) async
        -> HostAccessibilityActivation
}

struct AXHostAccessibilityActivator:
    HostAccessibilityActivating
{
    static let attributeName = "AXEnhancedUserInterface"
    private let readState: @Sendable (pid_t) -> HostAccessibilityReadState
    private let writeEnabled: @Sendable (pid_t) -> AXError

    init() {
        self.init(
            readState: { processIdentifier in
                Self.readEnhancedUserInterfaceState(
                    processIdentifier: processIdentifier
                )
            },
            writeEnabled: { processIdentifier in
                Self.writeEnhancedUserInterface(
                    processIdentifier: processIdentifier
                )
            }
        )
    }

    init(
        readState:
            @escaping @Sendable (
                pid_t
            ) -> HostAccessibilityReadState,
        writeEnabled: @escaping @Sendable (pid_t) -> AXError
    ) {
        self.readState = readState
        self.writeEnabled = writeEnabled
    }

    func activate(processIdentifier: pid_t) async
        -> HostAccessibilityActivation
    {
        switch readState(processIdentifier) {
        case .enabled:
            return .alreadyEnhanced
        case .unsupported:
            return .unavailable
        case .transientFailure:
            return .transientFailure
        case .disabled:
            break
        }

        _ = writeEnabled(processIdentifier)
        // Electron may apply the value while returning
        // kAXErrorNotImplemented, so verify the actual state.
        switch readState(processIdentifier) {
        case .enabled:
            return .activated
        case .transientFailure:
            return .transientFailure
        case .disabled, .unsupported:
            return .failed
        }
    }

    private static func writeEnhancedUserInterface(
        processIdentifier: pid_t
    ) -> AXError {
        let application = AXUIElementCreateApplication(
            processIdentifier
        )
        AXUIElementSetMessagingTimeout(
            application,
            HostAccessibilityPolicy.messagingTimeout
        )
        return AXUIElementSetAttributeValue(
            application,
            Self.attributeName as CFString,
            kCFBooleanTrue
        )
    }

    private static func readEnhancedUserInterfaceState(
        processIdentifier: pid_t
    ) -> HostAccessibilityReadState {
        let application = AXUIElementCreateApplication(
            processIdentifier
        )
        AXUIElementSetMessagingTimeout(
            application,
            HostAccessibilityPolicy.messagingTimeout
        )
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            application,
            Self.attributeName as CFString,
            &value
        )
        guard result == .success else {
            return HostAccessibilityReadState.classify(result)
        }
        guard let enabled = (value as? NSNumber)?.boolValue else {
            return .unsupported
        }
        return enabled ? .enabled : .disabled
    }
}

struct DisabledHostAccessibilityActivator:
    HostAccessibilityActivating
{
    func activate(processIdentifier: pid_t) async
        -> HostAccessibilityActivation
    {
        .unavailable
    }
}
