import AppKit
import GlintCore
import SwiftUI

struct TranslationShortcutRecorder: View {
    let shortcut: TranslationInsertionShortcut
    let isEnabled: Bool
    let onSelect: (TranslationInsertionShortcut) -> Void

    var body: some View {
        TranslationShortcutRecorderButton(
            shortcut: shortcut,
            isEnabled: isEnabled,
            onRecord: onSelect
        )
        .frame(width: 128, height: 26)
        .accessibilityLabel("释义插入")
        .accessibilityValue(shortcut.shortcutAccessibilityLabel)
        .help("点击录制触发键")
    }
}

private struct TranslationShortcutRecorderButton: NSViewRepresentable {
    let shortcut: TranslationInsertionShortcut
    let isEnabled: Bool
    let onRecord: (TranslationInsertionShortcut) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onRecord: onRecord)
    }

    func makeNSView(context: Context) -> ShortcutRecorderNSButton {
        let button = ShortcutRecorderNSButton(
            frame: NSRect(x: 0, y: 0, width: 128, height: 26),
            shortcut: shortcut
        )
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.isEnabled = isEnabled
        button.target = context.coordinator
        button.action = #selector(Coordinator.startRecording(_:))
        button.toolTip = "点击录制触发键"
        button.setAccessibilityLabel("释义插入")
        button.onShortcutRecorded = {
            context.coordinator.onRecord($0)
        }
        return button
    }

    func updateNSView(
        _ button: ShortcutRecorderNSButton,
        context: Context
    ) {
        context.coordinator.onRecord = onRecord
        button.setInteractionEnabled(isEnabled)
        button.apply(shortcut: shortcut)
        button.setAccessibilityValue(
            shortcut.shortcutAccessibilityLabel
        )
    }

    @MainActor
    final class Coordinator: NSObject {
        var onRecord: (TranslationInsertionShortcut) -> Void

        init(
            onRecord: @escaping (TranslationInsertionShortcut) -> Void
        ) {
            self.onRecord = onRecord
        }

        @objc
        func startRecording(_ sender: ShortcutRecorderNSButton) {
            sender.startRecording()
        }
    }
}

@MainActor
private final class ShortcutRecorderNSButton: NSButton {
    private(set) var isRecordingShortcut = false
    var onShortcutRecorded: ((TranslationInsertionShortcut) -> Void)?
    private var showsInputError = false
    private var errorTask: Task<Void, Never>?
    private var pendingModifiers: TranslationInsertionModifiers = []

    init(
        frame: NSRect,
        shortcut: TranslationInsertionShortcut
    ) {
        super.init(frame: frame)
        setButtonType(.momentaryPushIn)
        apply(shortcut: shortcut)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let window {
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.didResignKeyNotification,
                object: window
            )
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResignKey(_:)),
            name: NSWindow.didResignKeyNotification,
            object: window
        )
    }

    func apply(shortcut: TranslationInsertionShortcut) {
        guard !isRecordingShortcut else {
            return
        }
        storedShortcut = shortcut
        renderSymbols(for: shortcut)
        setAccessibilityValue(shortcut.shortcutAccessibilityLabel)
    }

    func setInteractionEnabled(_ enabled: Bool) {
        if !enabled, isRecordingShortcut {
            cancelRecording()
        }
        isEnabled = enabled
    }

    func startRecording() {
        if isRecordingShortcut {
            cancelRecording()
            return
        }
        clearInputError()
        isRecordingShortcut = true
        pendingModifiers = []
        image = nil
        imagePosition = .noImage
        title = "按下修饰键…"
        font = .systemFont(ofSize: 13, weight: .regular)
        setAccessibilityValue("正在录制")
        window?.makeFirstResponder(self)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard showsInputError else {
            return
        }
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5),
            xRadius: 7,
            yRadius: 7
        )
        path.lineWidth = 2
        NSColor.systemRed.setStroke()
        path.stroke()
    }

    override func keyDown(with event: NSEvent) {
        guard isRecordingShortcut else {
            super.keyDown(with: event)
            return
        }
        rejectKey(event)
    }

    override func flagsChanged(with event: NSEvent) {
        guard isRecordingShortcut else {
            super.flagsChanged(with: event)
            return
        }
        if event.keyCode == 57 {
            pendingModifiers.insert(.capsLock)
            finishRecording()
            return
        }

        let current = Self.modifiers(from: event.modifierFlags)
        if current.isEmpty {
            if !pendingModifiers.isEmpty {
                finishRecording()
            }
            return
        }
        pendingModifiers.formUnion(current)
        showPendingModifiers()
    }

    override func performKeyEquivalent(
        with event: NSEvent
    ) -> Bool {
        guard isRecordingShortcut else {
            return super.performKeyEquivalent(with: event)
        }
        rejectKey(event)
        return true
    }

    private func rejectKey(_ event: NSEvent) {
        if event.keyCode == 53 {
            cancelRecording()
            return
        }
        showInputError()
    }

    private func finishRecording() {
        let shortcut = TranslationInsertionShortcut(
            modifiers: pendingModifiers
        )
        guard shortcut.isValid else {
            showInputError()
            return
        }
        clearInputError()
        isRecordingShortcut = false
        pendingModifiers = []
        apply(shortcut: shortcut)
        onShortcutRecorded?(shortcut)
    }

    override func resignFirstResponder() -> Bool {
        if isRecordingShortcut {
            cancelRecording()
        }
        return super.resignFirstResponder()
    }

    @objc
    private func windowDidResignKey(_ notification: Notification) {
        guard isRecordingShortcut else { return }
        cancelRecording()
    }

    private func cancelRecording() {
        clearInputError()
        isRecordingShortcut = false
        pendingModifiers = []
        if let shortcut = storedShortcut {
            apply(shortcut: shortcut)
        }
    }

    private func showInputError() {
        NSSound.beep()
        errorTask?.cancel()
        showsInputError = true
        pendingModifiers = []
        image = nil
        imagePosition = .noImage
        title = "仅支持修饰键"
        setAccessibilityValue("不支持的快捷键")
        needsDisplay = true
        errorTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled, let self,
                self.isRecordingShortcut
            else {
                return
            }
            self.clearInputError()
        }
    }

    private func clearInputError() {
        errorTask?.cancel()
        errorTask = nil
        guard showsInputError else {
            return
        }
        showsInputError = false
        if isRecordingShortcut {
            showPendingModifiers()
            setAccessibilityValue("正在录制")
        } else {
            needsDisplay = true
        }
    }

    private var storedShortcut: TranslationInsertionShortcut?

    private func showPendingModifiers() {
        guard !pendingModifiers.isEmpty else {
            image = nil
            imagePosition = .noImage
            title = "按下修饰键…"
            needsDisplay = true
            return
        }
        renderSymbols(
            for: TranslationInsertionShortcut(
                modifiers: pendingModifiers
            )
        )
        needsDisplay = true
    }

    private func renderSymbols(
        for shortcut: TranslationInsertionShortcut
    ) {
        imagePosition = .imageOnly
        title = ""
        image = shortcutTemplateImage(for: shortcut)
    }

    private static func modifiers(
        from flags: NSEvent.ModifierFlags
    ) -> TranslationInsertionModifiers {
        let flags = flags.intersection(
            .deviceIndependentFlagsMask
        )
        var modifiers: TranslationInsertionModifiers = []
        if flags.contains(.control) {
            modifiers.insert(.control)
        }
        if flags.contains(.option) {
            modifiers.insert(.option)
        }
        if flags.contains(.shift) {
            modifiers.insert(.shift)
        }
        if flags.contains(.command) {
            modifiers.insert(.command)
        }
        return modifiers
    }
}

@MainActor
private func shortcutTemplateImage(
    for shortcut: TranslationInsertionShortcut
) -> NSImage? {
    let symbolConfiguration = NSImage.SymbolConfiguration(
        pointSize: 15,
        weight: .regular
    )
    let symbols = shortcut.modifierSymbolNames.compactMap {
        NSImage(
            systemSymbolName: $0,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(symbolConfiguration)
    }
    let numberFont = NSFont.systemFont(
        ofSize: 13,
        weight: .regular
    )
    let numberAttributes: [NSAttributedString.Key: Any] = [
        .font: numberFont,
        .foregroundColor: NSColor.black,
    ]
    let numberText = "1–N" as NSString
    let numberSize = numberText.size(
        withAttributes: numberAttributes
    )
    let symbolSpacing = 4.0
    let symbolToNumberSpacing = 6.0
    let height = 18.0
    let symbolsWidth =
        symbols.reduce(0) { $0 + $1.size.width }
        + symbolSpacing * CGFloat(max(0, symbols.count - 1))
    let contentWidth =
        symbolsWidth + symbolToNumberSpacing + numberSize.width
    let imageWidth = max(96, contentWidth)

    let image = NSImage(
        size: NSSize(width: imageWidth, height: height),
        flipped: false
    ) { _ in
        var x = 0.0
        for symbol in symbols {
            let size = symbol.size
            symbol.draw(
                in: NSRect(
                    x: x,
                    y: (height - size.height) / 2,
                    width: size.width,
                    height: size.height
                )
            )
            x += size.width + symbolSpacing
        }
        numberText.draw(
            in: NSRect(
                x: x + symbolToNumberSpacing,
                y: (height - numberSize.height) / 2,
                width: numberSize.width,
                height: numberSize.height
            ),
            withAttributes: numberAttributes
        )
        return true
    }
    image.isTemplate = true
    return image
}

extension TranslationInsertionShortcut {
    var modifierSymbolNames: [String] {
        var names: [String] = []
        if modifiers.contains(.control) {
            names.append("control")
        }
        if modifiers.contains(.option) {
            names.append("option")
        }
        if modifiers.contains(.shift) {
            names.append("shift")
        }
        if modifiers.contains(.command) {
            names.append("command")
        }
        if modifiers.contains(.capsLock) {
            names.append("capslock")
        }
        return names
    }

    var shortcutAccessibilityLabel: String {
        var names: [String] = []
        if modifiers.contains(.control) {
            names.append("Control")
        }
        if modifiers.contains(.option) {
            names.append("Option")
        }
        if modifiers.contains(.shift) {
            names.append("Shift")
        }
        if modifiers.contains(.command) {
            names.append("Command")
        }
        if modifiers.contains(.capsLock) {
            names.append("Caps Lock")
        }
        names.append("1–N")
        return names.joined(separator: " + ")
    }
}
