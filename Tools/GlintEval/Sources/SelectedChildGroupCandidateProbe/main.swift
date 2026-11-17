import Darwin
import Foundation
import GlintMac

private struct Options {
    let bundleIdentifier: String
    let seconds: Double
}

private func parseOptions() -> Options {
    var bundleIdentifier: String?
    var seconds = 20.0
    var arguments = Array(CommandLine.arguments.dropFirst())
    while !arguments.isEmpty {
        let argument = arguments.removeFirst()
        guard !arguments.isEmpty else { exitUsage() }
        let value = arguments.removeFirst()
        switch argument {
        case "--bundle":
            bundleIdentifier = value
        case "--seconds":
            seconds = min(max(Double(value) ?? seconds, 1), 120)
        default:
            exitUsage()
        }
    }
    guard let bundleIdentifier, !bundleIdentifier.isEmpty else {
        exitUsage()
    }
    return Options(
        bundleIdentifier: bundleIdentifier,
        seconds: seconds
    )
}

private func exitUsage() -> Never {
    print(
        "usage: SelectedChildGroupCandidateProbe "
            + "--bundle <id> [--seconds 20]"
    )
    exit(EXIT_FAILURE)
}

private func frameDescription(_ frame: CGRect?) -> String {
    guard let frame else {
        return "none"
    }
    return String(
        format: "%.0f,%.0f,%.0fx%.0f",
        frame.minX,
        frame.minY,
        frame.width,
        frame.height
    )
}

private let options = parseOptions()
guard FocusMonitor.isAccessibilityTrusted() else {
    print("group.probe permission=false")
    exit(EXIT_FAILURE)
}

let reader = SelectedChildGroupCandidateReader(
    bundleIdentifier: options.bundleIdentifier
)
let deadline = Date().addingTimeInterval(options.seconds)
while Date() < deadline {
    let startedAt = DispatchTime.now().uptimeNanoseconds
    let snapshot = reader.snapshot(
        includeVisibleCandidates: true,
        includeVisibleTexts: false
    )
    let elapsedMilliseconds =
        Double(
            DispatchTime.now().uptimeNanoseconds - startedAt
        ) / 1_000_000
    if let snapshot {
        print(
            "group.probe bundle=\(options.bundleIdentifier) "
                + "candidates=\(snapshot.options.count) "
                + "selected=\(snapshot.selectedIndex ?? -1) "
                + "exact=\(snapshot.selectionIsExact) "
                + "elapsed_ms=\(String(format: "%.3f", elapsedMilliseconds)) "
                + "selected_text_length=\(snapshot.text.count) "
                + "selected_frame=\(frameDescription(snapshot.frame)) "
                + "list_frame=\(frameDescription(snapshot.candidateListFrame)) "
                + "window_frame=\(frameDescription(snapshot.candidateWindowFrame))"
        )
        exit(EXIT_SUCCESS)
    }
    Thread.sleep(forTimeInterval: 0.1)
}

print(
    "group.probe bundle=\(options.bundleIdentifier) candidates=0"
)
exit(EXIT_FAILURE)
