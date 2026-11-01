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
    } else if CommandLine.arguments.contains(
        "--dictionary-pos-reload-check"
    ) {
        let option = "--dictionary-pos-reload-check"
        guard
            let index = CommandLine.arguments.firstIndex(of: option),
            CommandLine.arguments.count > index + 4
        else {
            print(
                "usage: \(option) <old-plugin> <new-plugin> <old-word> <new-word>"
            )
            exit(EXIT_FAILURE)
        }
        SelfCheck.runDictionaryPOSReloadCheck(
            oldPluginDirectory: URL(
                fileURLWithPath: CommandLine.arguments[index + 1],
                isDirectory: true
            ),
            newPluginDirectory: URL(
                fileURLWithPath: CommandLine.arguments[index + 2],
                isDirectory: true
            ),
            oldWord: CommandLine.arguments[index + 3],
            newWord: CommandLine.arguments[index + 4]
        )
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
