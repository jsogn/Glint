import AppKit
import SwiftUI

public enum AppUpdatePanelContent: Equatable, Sendable {
    case checking
    case result(AppUpdateResultPresentation)
}

public struct AppUpdatePanelView: View {
    private let content: AppUpdatePanelContent
    private let onPrimaryAction: () -> Void
    private let onSecondaryAction: () -> Void

    public init(
        content: AppUpdatePanelContent,
        onPrimaryAction: @escaping () -> Void = {},
        onSecondaryAction: @escaping () -> Void = {}
    ) {
        self.content = content
        self.onPrimaryAction = onPrimaryAction
        self.onSecondaryAction = onSecondaryAction
    }

    public static func panelSize(
        for content: AppUpdatePanelContent
    ) -> CGSize {
        CGSize(
            width: 320,
            height: content == .checking ? 188 : 240
        )
    }

    public var body: some View {
        let panelSize = Self.panelSize(for: content)
        Group {
            if #available(macOS 26.0, *) {
                card
                    .glassEffect(
                        .regular,
                        in: RoundedRectangle(
                            cornerRadius: 26,
                            style: .continuous
                        )
                    )
            } else {
                card
                    .background {
                        HUDNativeMaterialBackground(material: .popover)
                            .clipShape(
                                RoundedRectangle(
                                    cornerRadius: 26,
                                    style: .continuous
                                )
                            )
                    }
            }
        }
        .shadow(color: .black.opacity(0.2), radius: 16, y: 5)
        .padding(16)
        .frame(
            width: panelSize.width,
            height: panelSize.height
        )
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 48, height: 48)
                .accessibilityHidden(true)

            switch content {
            case .checking:
                checkingContent
            case .result(let presentation):
                resultContent(presentation)
            }
        }
        .padding(20)
        .frame(width: 288, alignment: .leading)
    }

    private var checkingContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("正在检查更新…")
                .font(.system(size: 15, weight: .semibold))

            ProgressView()
                .progressViewStyle(.linear)
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                .accessibilityLabel("正在检查更新")
        }
    }

    private func resultContent(
        _ presentation: AppUpdateResultPresentation
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 7) {
                Text(presentation.message)
                    .font(.system(size: 15, weight: .semibold))

                if let informativeText = presentation.informativeText {
                    Text(informativeText)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let secondaryButtonTitle =
                presentation.secondaryButtonTitle
            {
                HStack(spacing: 10) {
                    secondaryButton(title: secondaryButtonTitle)
                    primaryButton(title: presentation.primaryButtonTitle)
                }
            } else {
                primaryButton(title: presentation.primaryButtonTitle)
            }
        }
    }

    private func primaryButton(title: String) -> some View {
        Button(action: onPrimaryAction) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    Color(nsColor: .systemBlue),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.defaultAction)
    }

    private func secondaryButton(title: String) -> some View {
        Button(action: onSecondaryAction) {
            Text(title)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }
}
