import ApplicationServices
import CoreGraphics
import Foundation

struct AXAccessLimits: Sendable, Equatable {
    let messagingTimeout: Float
    let maximumAttributeCalls: Int
    let maximumDuration: Duration

    static let interactive = AXAccessLimits(
        messagingTimeout: 0.25,
        maximumAttributeCalls: 192,
        maximumDuration: .milliseconds(300)
    )

    static let discovery = AXAccessLimits(
        messagingTimeout: 0.05,
        maximumAttributeCalls: 64,
        maximumDuration: .milliseconds(150)
    )
}

final class AXReadSession {
    private let deadline: ContinuousClock.Instant
    private let limits: AXAccessLimits
    private var remainingAttributeCalls: Int
    private(set) var attributeCalls = 0

    init(limits: AXAccessLimits) {
        self.limits = limits
        deadline = ContinuousClock.now.advanced(
            by: limits.maximumDuration
        )
        remainingAttributeCalls = max(
            0,
            limits.maximumAttributeCalls
        )
    }

    var isExhausted: Bool {
        remainingAttributeCalls == 0
            || ContinuousClock.now >= deadline
    }

    func attribute(
        _ element: AXUIElement,
        _ name: String
    ) -> Any? {
        guard consumeAttributeCall() else {
            return nil
        }
        AXUIElementSetMessagingTimeout(
            element,
            limits.messagingTimeout
        )
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                element,
                name as CFString,
                &value
            ) == .success
        else {
            return nil
        }
        return value
    }

    func elementsAttribute(
        _ element: AXUIElement,
        _ name: String
    ) -> [AXUIElement] {
        attribute(element, name) as? [AXUIElement] ?? []
    }

    func elementAttribute(
        _ element: AXUIElement,
        _ name: String
    ) -> AXUIElement? {
        AXValueReader.element(attribute(element, name))
    }

    func stringAttribute(
        _ element: AXUIElement,
        _ name: String
    ) -> String? {
        attribute(element, name) as? String
    }

    func boolAttribute(
        _ element: AXUIElement,
        _ name: String
    ) -> Bool? {
        (attribute(element, name) as? NSNumber)?.boolValue
    }

    func parameterizedAttribute(
        _ element: AXUIElement,
        _ name: String,
        _ parameter: CFTypeRef
    ) -> Any? {
        guard consumeAttributeCall() else {
            return nil
        }
        AXUIElementSetMessagingTimeout(
            element,
            limits.messagingTimeout
        )
        var value: CFTypeRef?
        guard
            AXUIElementCopyParameterizedAttributeValue(
                element,
                name as CFString,
                parameter,
                &value
            ) == .success
        else {
            return nil
        }
        return value
    }

    func text(of element: AXUIElement) -> String? {
        for name in [
            kAXValueAttribute,
            kAXTitleAttribute,
            kAXDescriptionAttribute,
            "AXValueDescription",
        ] {
            guard
                let value = attribute(element, name) as? String
            else {
                continue
            }
            let text = value.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if !text.isEmpty {
                return text
            }
        }
        return nil
    }

    func frame(of element: AXUIElement) -> CGRect? {
        if let frame = AXValueReader.rect(
            attribute(element, "AXFrame")
        ) {
            return frame
        }
        guard
            let positionValue = attribute(
                element,
                kAXPositionAttribute
            ),
            let sizeValue = attribute(
                element,
                kAXSizeAttribute
            ),
            let position = AXValueReader.point(positionValue),
            let size = AXValueReader.size(sizeValue)
        else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    private func consumeAttributeCall() -> Bool {
        guard
            remainingAttributeCalls > 0,
            ContinuousClock.now < deadline
        else {
            remainingAttributeCalls = 0
            return false
        }
        remainingAttributeCalls -= 1
        attributeCalls += 1
        return true
    }
}

struct AXCandidateWindowSnapshot: Sendable, Equatable {
    let candidateCount: Int
    let snapshot: AXCandidateSnapshot
    let isVisible: Bool
}

enum AXCandidateWindowSelector {
    static func preferred(
        from candidates: [AXCandidateWindowSnapshot]
    ) -> AXCandidateSnapshot? {
        candidates.max { lhs, rhs in
            if lhs.isVisible != rhs.isVisible {
                return !lhs.isVisible
            }
            let lhsHasFrame =
                lhs.snapshot.candidateWindowFrame.map {
                    $0.width > 0 && $0.height > 0
                } ?? false
            let rhsHasFrame =
                rhs.snapshot.candidateWindowFrame.map {
                    $0.width > 0 && $0.height > 0
                } ?? false
            if lhsHasFrame != rhsHasFrame {
                return !lhsHasFrame
            }
            return lhs.candidateCount < rhs.candidateCount
        }?.snapshot
    }
}
