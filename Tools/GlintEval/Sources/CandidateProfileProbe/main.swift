import Darwin
import Foundation
import GlintMac

private struct Options {
    let bundleIdentifier: String
    let inputSourceIdentifier: String
    let seconds: Double
}

private func parseOptions() -> Options? {
    var bundleIdentifier: String?
    var inputSourceIdentifier: String?
    var seconds = 20.0
    var arguments = Array(CommandLine.arguments.dropFirst())
    while !arguments.isEmpty {
        let argument = arguments.removeFirst()
        guard !arguments.isEmpty else {
            return nil
        }
        let value = arguments.removeFirst()
        switch argument {
        case "--bundle":
            bundleIdentifier = value
        case "--source":
            inputSourceIdentifier = value
        case "--seconds":
            seconds = Double(value) ?? seconds
        default:
            return nil
        }
    }
    guard
        let bundleIdentifier,
        let inputSourceIdentifier,
        seconds > 0
    else {
        return nil
    }
    return Options(
        bundleIdentifier: bundleIdentifier,
        inputSourceIdentifier: inputSourceIdentifier,
        seconds: seconds
    )
}

guard let options = parseOptions() else {
    print(
        "usage: CandidateProfileProbe --bundle <id> --source <id> [--seconds 20]"
    )
    exit(EXIT_FAILURE)
}

print(
    "profile.probe bundle=\(options.bundleIdentifier) source=\(options.inputSourceIdentifier)"
)
guard FocusMonitor.isAccessibilityTrusted() else {
    print("profile.probe permission=false")
    exit(EXIT_FAILURE)
}

let deadline = Date().addingTimeInterval(options.seconds)
var lastResult: CandidateProfileProbeResult?
while Date() < deadline {
    let result = CandidateProfileProbe.probe(
        bundleIdentifier: options.bundleIdentifier,
        inputSourceIdentifier: options.inputSourceIdentifier
    )
    lastResult = result
    if let profile = result.profile {
        print(
            "profile.matched=\(profile) version=\(result.applicationVersion) elapsed_ms=\(result.elapsedMilliseconds)"
        )
        exit(EXIT_SUCCESS)
    }
    Thread.sleep(forTimeInterval: 0.25)
}

print(
    "profile.matched=none version=\(lastResult?.applicationVersion ?? "unknown")"
)
exit(EXIT_FAILURE)
