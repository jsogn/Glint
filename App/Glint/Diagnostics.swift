import AppKit
import ApplicationServices
import Darwin
import Foundation
import GlintCore
import GlintInference
import GlintMac

enum Diagnostics {
    static func run() -> Never {
        Task { @MainActor in
            let process = ProcessInfo.processInfo
            let bundle = Bundle.main
            let inputSource = InputSourceMonitor()
            let activeInputSource = inputSource.currentInputSource()
            let focus = FocusMonitor().snapshot()
            let candidate: AXCandidateSnapshot?
            switch activeInputSource.identity.bundleIdentifier {
            case InputMethodIdentifier.weTypeBundle:
                candidate = WeTypeCandidateReader().snapshot(
                    includeVisibleCandidates: true
                )
            case InputMethodIdentifier.sogouBundle:
                candidate = SogouCandidateReader().snapshot(
                    includeVisibleCandidates: true
                )
            default:
                candidate = AXCandidateReader().snapshot(
                    includeVisibleCandidates: true
                )
            }
            let frontmost = NSWorkspace.shared.frontmostApplication

            print("glint.version=\(bundle.version)")
            print("glint.bundle=\(bundle.bundleIdentifier ?? "<unknown>")")
            print("glint.path=\(bundle.bundlePath)")
            print(
                "system.version="
                    + process.operatingSystemVersionString
            )
            print(
                "accessibility.trusted="
                    + String(FocusMonitor.isAccessibilityTrusted())
            )
            print("input.source=\(activeInputSource.id)")
            print(
                "input.bundle="
                    + (activeInputSource.identity.bundleIdentifier
                        ?? "<unknown>")
            )
            print(
                "input.name="
                    + activeInputSource.identity.displayName
            )
            print(
                "input.type="
                    + activeInputSource.identity.sourceType
            )
            print("input.kind=\(activeInputSource.kind.rawValue)")
            print(
                "input.applePinyin="
                    + String(activeInputSource.kind == .applePinyin)
            )
            print(
                "secureInput.enabled="
                    + String(FocusMonitor.isSecureInputEnabled())
            )
            print(
                "frontmost.app=\(frontmost?.localizedName ?? "<unknown>")"
            )
            print(
                "frontmost.pid=\(frontmost?.processIdentifier ?? 0)"
            )
            print(
                "focus.available=\(focus != nil)"
                    + " editable=\(focus?.isEditableTextInput ?? false)"
                    + " hasCaret=\(focus?.caretRect != nil)"
                    + " hasSelection=\(focus?.hasTextSelection ?? false)"
                    + " composition=\(focus?.compositionState.label ?? "missing")"
            )
            print(
                "candidate.available=\(candidate != nil)"
                    + " options=\(candidate?.options.count ?? 0)"
                    + " visible=\(candidate?.visibleTexts.count ?? 0)"
                    + " hasFrame=\(candidate?.frame != nil)"
                    + " selectionExact="
                    + "\(candidate?.selectionIsExact ?? false)"
            )
            print(
                "translation.ct2="
                    + String(CTranslate2Engine() != nil)
            )
            exit(EXIT_SUCCESS)
        }
        RunLoop.main.run()
        exit(EXIT_FAILURE)
    }
}

private extension Bundle {
    var version: String {
        object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "<unknown>"
    }
}

private extension TextCompositionState {
    var label: String {
        switch self {
        case .unknown:
            "unknown"
        case .composing:
            "composing"
        case .inactive:
            "inactive"
        }
    }
}
