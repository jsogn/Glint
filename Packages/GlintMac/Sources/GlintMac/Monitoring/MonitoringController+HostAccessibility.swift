import Dispatch
import Foundation
import GlintCore

extension MonitoringController {
    func activateHostAccessibilityIfNeeded(
        source: ActiveInputSource,
        focus: FocusSnapshot
    ) async -> Bool {
        guard
            source.kind == .applePinyin,
            let processIdentifier = focus.processIdentifier
        else {
            return false
        }

        let session = HostProcessSession.current(
            processIdentifier: processIdentifier
        )
        let timestamp = DispatchTime.now().uptimeNanoseconds
        if let attempt = hostAccessibilityAttempts[session] {
            switch attempt.outcome {
            case .activated, .alreadyEnhanced, .unavailable:
                return false
            case .transientFailure:
                guard
                    timestamp >= attempt.timestamp,
                    timestamp - attempt.timestamp
                        >= HostAccessibilityPolicy
                        .transientRetryNanoseconds
                else {
                    return false
                }
            case .failed:
                guard
                    timestamp >= attempt.timestamp,
                    timestamp - attempt.timestamp
                        >= HostAccessibilityPolicy
                        .failureRetryNanoseconds
                else {
                    return false
                }
            }
        }

        let outcome =
            await hostAccessibilityActivator.activate(
                processIdentifier: processIdentifier
            )
        recordHostAccessibilityAttempt(
            HostAccessibilityAttempt(
                timestamp: timestamp,
                outcome: outcome
            ),
            for: session
        )

        switch outcome {
        case .activated:
            monitoringLogger.info(
                "host_ax mode=enhanced action=enabled pid=\(processIdentifier, privacy: .public)"
            )
            return true
        case .failed:
            monitoringLogger.error(
                "host_ax mode=enhanced action=failed pid=\(processIdentifier, privacy: .public)"
            )
            return false
        case .transientFailure, .alreadyEnhanced, .unavailable:
            return false
        }
    }

    func recordHostAccessibilityAttempt(
        _ attempt: HostAccessibilityAttempt,
        for session: HostProcessSession
    ) {
        if hostAccessibilityAttempts.count
            >= HostAccessibilityPolicy.maximumCachedProcessCount,
            let oldest = hostAccessibilityAttempts.min(by: {
                $0.value.timestamp < $1.value.timestamp
            })?.key
        {
            hostAccessibilityAttempts.removeValue(forKey: oldest)
        }
        hostAccessibilityAttempts[session] = attempt
    }
}
