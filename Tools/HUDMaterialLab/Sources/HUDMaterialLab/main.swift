import AppKit

@main
@MainActor
struct HUDMaterialLab {
    static func main() {
        let application = NSApplication.shared
        let delegate = MaterialLabApplicationDelegate(
            referencePath: referencePath(from: CommandLine.arguments)
        )
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.mainMenu = makeMainMenu()
        application.run()
    }

    private static func referencePath(from arguments: [String]) -> String? {
        guard let flagIndex = arguments.firstIndex(of: "--reference"),
              arguments.indices.contains(flagIndex + 1) else {
            return nil
        }
        return arguments[flagIndex + 1]
    }

    private static func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu()
        applicationMenu.addItem(
            withTitle: "退出 HUD Material Lab",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        applicationItem.submenu = applicationMenu
        mainMenu.addItem(applicationItem)
        return mainMenu
    }
}

@MainActor
private final class MaterialLabApplicationDelegate:
    NSObject,
    NSApplicationDelegate
{
    private let referencePath: String?
    private var windowController: MaterialLabWindowController?

    init(referencePath: String?) {
        self.referencePath = referencePath
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let windowController = MaterialLabWindowController(
            referencePath: referencePath
        )
        self.windowController = windowController
        windowController.showWindow(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        true
    }
}

@MainActor
private final class MaterialLabWindowController: NSWindowController {
    init(referencePath: String?) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_060, height: 1_000),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Glint HUD Material Lab"
        window.minSize = NSSize(width: 1_060, height: 1_000)
        window.appearance = NSAppearance(named: .aqua)
        window.center()
        window.contentView = MaterialLabView(referencePath: referencePath)
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

@MainActor
private final class MaterialLabView: NSView {
    fileprivate enum BackdropMode: Int {
        case white
        case gray
        case split
        case color
    }

    private struct Sample {
        let title: String
        let material: NSVisualEffectView.Material
        let blendingMode: NSVisualEffectView.BlendingMode
        let tintAlpha: CGFloat
    }

    private let referencePath: String?
    private let titleLabel = NSTextField(
        labelWithString: "HUD 候选栏材质对照"
    )
    private let sampleHost = BackdropView()
    private let explanation = NSTextField(wrappingLabelWithString: "")
    private var referenceSection: NSView!
    private var controlsView: NSView!

    private let samples = [
        Sample(
            title: "popover · within · 0%",
            material: .popover,
            blendingMode: .withinWindow,
            tintAlpha: 0
        ),
        Sample(
            title: "popover · behind · 0%",
            material: .popover,
            blendingMode: .behindWindow,
            tintAlpha: 0
        ),
        Sample(
            title: "popover · behind · white 70%",
            material: .popover,
            blendingMode: .behindWindow,
            tintAlpha: 0.7
        ),
        Sample(
            title: "menu · behind · 0%",
            material: .menu,
            blendingMode: .behindWindow,
            tintAlpha: 0
        ),
        Sample(
            title: "headerView · within · 0%",
            material: .headerView,
            blendingMode: .withinWindow,
            tintAlpha: 0
        ),
        Sample(
            title: "contentBackground · within · 0%",
            material: .contentBackground,
            blendingMode: .withinWindow,
            tintAlpha: 0
        ),
    ]
    private let glassSamples = [
        (title: "Liquid Glass · no tint", tintAlpha: CGFloat(0)),
        (title: "Liquid Glass · white 20%", tintAlpha: CGFloat(0.2)),
        (title: "Liquid Glass · white 40%", tintAlpha: CGFloat(0.4)),
        (title: "Liquid Glass · white 60%", tintAlpha: CGFloat(0.6)),
    ]

    init(referencePath: String?) {
        self.referencePath = referencePath
        super.init(frame: .zero)
        configureView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configureView() {
        titleLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        addSubview(titleLabel)

        explanation.stringValue =
            "先看参考图，再切换背景观察各材质。withinWindow 会采样下方的测试背景；behindWindow 采样窗口后的桌面或应用内容。"
        explanation.font = .systemFont(ofSize: 12)
        explanation.textColor = .secondaryLabelColor
        explanation.maximumNumberOfLines = 2
        addSubview(explanation)

        referenceSection = makeReferenceSection()
        addSubview(referenceSection)
        controlsView = makeControls()
        addSubview(controlsView)
        _ = makeSamplesSection()
        addSubview(sampleHost)
        for view in [
            titleLabel,
            explanation,
            referenceSection!,
            controlsView!,
        ] {
            addSubview(view, positioned: .above, relativeTo: sampleHost)
        }
    }

    override func layout() {
        super.layout()

        let margin: CGFloat = 24
        let contentWidth = max(0, bounds.width - margin * 2)
        var top = bounds.height - margin

        titleLabel.frame = NSRect(
            x: margin,
            y: top - 30,
            width: contentWidth,
            height: 30
        )
        top = titleLabel.frame.minY - 8

        explanation.frame = NSRect(
            x: margin,
            y: top - 34,
            width: contentWidth,
            height: 34
        )
        top = explanation.frame.minY - 14

        referenceSection.frame = NSRect(
            x: margin,
            y: top - 156,
            width: contentWidth,
            height: 156
        )
        top = referenceSection.frame.minY - 14

        controlsView.frame = NSRect(
            x: margin,
            y: top - 28,
            width: contentWidth,
            height: 28
        )
        top = controlsView.frame.minY - 14

        sampleHost.frame = NSRect(
            x: margin,
            y: margin,
            width: contentWidth,
            height: max(0, top - margin)
        )
    }

    private func makeReferenceSection() -> NSView {
        let container = NSBox()
        container.boxType = .custom
        container.fillColor = .controlBackgroundColor
        container.borderColor = .separatorColor
        container.borderWidth = 1
        container.cornerRadius = 10
        container.contentViewMargins = NSSize(width: 12, height: 10)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.contentView?.addSubview(stack)
        if let contentView = container.contentView {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                stack.topAnchor.constraint(equalTo: contentView.topAnchor),
                stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            ])
        }

        let heading = NSTextField(labelWithString: "真实候选栏参考")
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        stack.addArrangedSubview(heading)

        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyDown
        imageView.alignment = .center
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = NSColor.white.cgColor
        imageView.layer?.cornerRadius = 6
        imageView.heightAnchor.constraint(equalToConstant: 110).isActive = true
        imageView.widthAnchor.constraint(equalToConstant: 980).isActive = true

        if let referencePath,
           let image = NSImage(contentsOfFile: referencePath) {
            imageView.image = image
        } else {
            imageView.image = placeholderImage()
            imageView.contentTintColor = .secondaryLabelColor
        }
        stack.addArrangedSubview(imageView)
        return container
    }

    private func makeControls() -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 12

        let label = NSTextField(labelWithString: "测试背景")
        label.font = .systemFont(ofSize: 13, weight: .medium)
        stack.addArrangedSubview(label)

        let control = NSSegmentedControl(
            labels: ["白色", "中灰", "黑白分割", "彩色"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(changeBackdrop(_:))
        )
        control.selectedSegment = 0
        stack.addArrangedSubview(control)

        let hint = NSTextField(
            labelWithString: "建议以 100% 窗口不透明度对比，并同时观察 Digital Color Meter。"
        )
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        stack.addArrangedSubview(hint)
        return stack
    }

    private func makeSamplesSection() -> NSView {
        sampleHost.backdropMode = .white

        let samplesStack = NSStackView()
        samplesStack.orientation = .vertical
        samplesStack.alignment = .leading
        samplesStack.spacing = 8
        samplesStack.translatesAutoresizingMaskIntoConstraints = false
        sampleHost.addSubview(samplesStack)
        NSLayoutConstraint.activate([
            samplesStack.leadingAnchor.constraint(
                equalTo: sampleHost.leadingAnchor,
                constant: 12
            ),
            samplesStack.trailingAnchor.constraint(
                lessThanOrEqualTo: sampleHost.trailingAnchor,
                constant: -12
            ),
            samplesStack.topAnchor.constraint(
                equalTo: sampleHost.topAnchor,
                constant: 10
            ),
            samplesStack.bottomAnchor.constraint(
                lessThanOrEqualTo: sampleHost.bottomAnchor,
                constant: -10
            ),
        ])

        for sample in samples {
            samplesStack.addArrangedSubview(makeSampleRow(sample))
        }

        if #available(macOS 26.0, *) {
            for sample in glassSamples {
                samplesStack.addArrangedSubview(
                    makeGlassSampleRow(
                        title: sample.title,
                        tintAlpha: sample.tintAlpha
                    )
                )
            }
        }
        return sampleHost
    }

    private func makeSampleRow(_ sample: Sample) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12

        let title = NSTextField(labelWithString: sample.title)
        title.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        title.textColor = .secondaryLabelColor
        title.alignment = .right
        title.widthAnchor.constraint(equalToConstant: 224).isActive = true
        row.addArrangedSubview(title)

        let swatch = MaterialSwatchView(
            material: sample.material,
            blendingMode: sample.blendingMode,
            tintAlpha: sample.tintAlpha
        )
        swatch.widthAnchor.constraint(equalToConstant: 700).isActive = true
        swatch.heightAnchor.constraint(equalToConstant: 44).isActive = true
        row.addArrangedSubview(swatch)
        return row
    }

    @available(macOS 26.0, *)
    private func makeGlassSampleRow(
        title: String,
        tintAlpha: CGFloat
    ) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12

        let label = NSTextField(labelWithString: title)
        label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 224).isActive = true
        row.addArrangedSubview(label)

        let glass = NSGlassEffectView()
        glass.style = .regular
        glass.cornerRadius = 22
        if tintAlpha > 0 {
            glass.tintColor = NSColor.white.withAlphaComponent(tintAlpha)
        }
        glass.contentView = makeCandidateContent()
        glass.widthAnchor.constraint(equalToConstant: 700).isActive = true
        glass.heightAnchor.constraint(equalToConstant: 44).isActive = true
        row.addArrangedSubview(glass)
        return row
    }

    private func makeCandidateContent() -> NSView {
        let content = NSView()

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -16),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])

        let selected = NSTextField(labelWithString: "1  玻璃")
        selected.font = .systemFont(ofSize: 15, weight: .medium)
        selected.textColor = .white
        selected.alignment = .center
        selected.wantsLayer = true
        selected.layer?.backgroundColor = NSColor.systemBlue.cgColor
        selected.layer?.cornerRadius = 14
        selected.widthAnchor.constraint(equalToConstant: 76).isActive = true
        selected.heightAnchor.constraint(equalToConstant: 28).isActive = true
        stack.addArrangedSubview(selected)

        for text in ["2  玻璃杯", "3  ☕", "4  剥离", "5  薄利", "6  薄礼"] {
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 15, weight: .medium)
            label.textColor = .labelColor
            stack.addArrangedSubview(label)
        }

        let chevron = NSImageView(
            image: NSImage(
                systemSymbolName: "chevron.down",
                accessibilityDescription: nil
            ) ?? NSImage()
        )
        chevron.contentTintColor = .tertiaryLabelColor
        stack.addArrangedSubview(chevron)
        return content
    }

    @objc
    private func changeBackdrop(_ sender: NSSegmentedControl) {
        sampleHost.backdropMode =
            BackdropMode(rawValue: sender.selectedSegment) ?? .white
    }

    private func placeholderImage() -> NSImage {
        NSImage(
            systemSymbolName: "photo.on.rectangle.angled",
            accessibilityDescription: "未提供参考图"
        ) ?? NSImage()
    }
}

@MainActor
private final class MaterialSwatchView: NSView {
    init(
        material: NSVisualEffectView.Material,
        blendingMode: NSVisualEffectView.BlendingMode,
        tintAlpha: CGFloat
    ) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 22
        layer?.masksToBounds = true
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.borderWidth = 1
        shadow = NSShadow()
        shadow?.shadowBlurRadius = 8
        shadow?.shadowOffset = NSSize(width: 0, height: -1)
        shadow?.shadowColor = NSColor.black.withAlphaComponent(0.14)

        let effect = NSVisualEffectView()
        effect.material = material
        effect.blendingMode = blendingMode
        effect.state = .active
        effect.isEmphasized = false
        effect.appearance = NSAppearance(named: .aqua)
        effect.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effect)

        let tint = NSView()
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor.white
            .withAlphaComponent(tintAlpha)
            .cgColor
        tint.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tint)

        let content = makeCandidateContent()
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)

        NSLayoutConstraint.activate([
            effect.leadingAnchor.constraint(equalTo: leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: trailingAnchor),
            effect.topAnchor.constraint(equalTo: topAnchor),
            effect.bottomAnchor.constraint(equalTo: bottomAnchor),
            tint.leadingAnchor.constraint(equalTo: leadingAnchor),
            tint.trailingAnchor.constraint(equalTo: trailingAnchor),
            tint.topAnchor.constraint(equalTo: topAnchor),
            tint.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func makeCandidateContent() -> NSView {
        let content = NSView()
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -16),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])

        let selected = NSTextField(labelWithString: "1  玻璃")
        selected.font = .systemFont(ofSize: 15, weight: .medium)
        selected.textColor = .white
        selected.alignment = .center
        selected.wantsLayer = true
        selected.layer?.backgroundColor = NSColor.systemBlue.cgColor
        selected.layer?.cornerRadius = 14
        selected.widthAnchor.constraint(equalToConstant: 76).isActive = true
        selected.heightAnchor.constraint(equalToConstant: 28).isActive = true
        stack.addArrangedSubview(selected)

        for text in ["2  玻璃杯", "3  ☕", "4  剥离", "5  薄利", "6  薄礼"] {
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 15, weight: .medium)
            label.textColor = .labelColor
            stack.addArrangedSubview(label)
        }
        return content
    }
}

@MainActor
private final class BackdropView: NSView {
    var backdropMode: MaterialLabView.BackdropMode = .white {
        didSet {
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        switch backdropMode {
        case .white:
            NSColor.white.setFill()
            dirtyRect.fill()
        case .gray:
            NSColor(calibratedWhite: 0.48, alpha: 1).setFill()
            dirtyRect.fill()
        case .split:
            NSColor.white.setFill()
            NSRect(
                x: bounds.minX,
                y: bounds.minY,
                width: bounds.width / 2,
                height: bounds.height
            ).fill()
            NSColor(calibratedWhite: 0.08, alpha: 1).setFill()
            NSRect(
                x: bounds.midX,
                y: bounds.minY,
                width: bounds.width / 2,
                height: bounds.height
            ).fill()
        case .color:
            NSGradient(colors: [
                .systemPink,
                .systemYellow,
                .systemTeal,
                .systemIndigo,
            ])?.draw(in: bounds, angle: 24)
        }
    }
}
