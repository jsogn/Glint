import AppKit

@MainActor
func runApplication() {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.disableRelaunchOnLogin()
    app.run()
}

#if DEBUG
    if CommandLine.arguments.contains("--ax-candidate-probe") {
        AXCandidateProbe.run()
    } else if CommandLine.arguments.contains("--selfcheck") {
        SelfCheck.run()
    } else if CommandLine.arguments.contains("--input-method-status") {
        SelfCheck.runInputMethodStatus()
    } else if CommandLine.arguments.contains("--diagnose") {
        Diagnostics.run()
    } else {
        runApplication()
    }
#else
    if CommandLine.arguments.contains("--diagnose") {
        Diagnostics.run()
    } else {
        runApplication()
    }
#endif
