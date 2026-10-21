import AppKit

if CommandLine.arguments.contains("--ax-candidate-probe") {
    AXCandidateProbe.run()
} else if CommandLine.arguments.contains("--selfcheck") {
    SelfCheck.run()
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
