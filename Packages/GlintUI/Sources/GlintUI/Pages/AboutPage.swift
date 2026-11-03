import AppKit
import SwiftUI

struct AboutPage: View {
    private let repositoryURL = URL(string: "https://github.com/jsogn/Glint")!
    private let issuesURL = URL(string: "https://github.com/jsogn/Glint/issues")!
    @Environment(\.openURL) private var openURL
    @State private var updateModel: AppUpdateModel
    private let version: String
    private let onCheckForUpdates: @MainActor () -> Void

    init(
        updateModel: AppUpdateModel,
        onCheckForUpdates: @MainActor @escaping () -> Void
    ) {
        let version =
            Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "未知"
        self.version = version
        self.onCheckForUpdates = onCheckForUpdates
        _updateModel = State(initialValue: updateModel)
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 32) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: 96, height: 96)
                        .accessibilityHidden(true)

                    VStack(spacing: 8) {
                        Text("Glint")
                            .font(.title2.weight(.semibold))

                        Text("输入中文时，在候选旁查看对应的译文。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)

                        Text("版本 \(version)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()

                        Button(updatePresentation.title) {
                            if let destinationURL =
                                updatePresentation.destinationURL
                            {
                                openURL(destinationURL)
                            } else {
                                onCheckForUpdates()
                            }
                        }
                        .controlSize(.small)
                        .disabled(
                            !updatePresentation.isEnabled
                                || updateModel.isChecking
                        )
                        .padding(.top, 4)
                    }

                    HStack(spacing: 32) {
                        Link(destination: repositoryURL) {
                            Label {
                                Text("GitHub 项目")
                            } icon: {
                                Image("GitHubMark")
                                    .resizable()
                                    .renderingMode(.template)
                                    .scaledToFit()
                                    .frame(width: 14, height: 14)
                                    .accessibilityHidden(true)
                            }
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }

                        Link(destination: issuesURL) {
                            Label("问题反馈", systemImage: "bubble.left")
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                        }
                    }
                    .font(.callout)
                }
                .frame(maxWidth: 520)
                .padding(.horizontal, 30)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 44)
                .frame(
                    minHeight: geometry.size.height,
                    alignment: .center
                )
                .offset(y: -24)
            }
        }
    }

    private var updatePresentation: AppUpdateMenuPresentation {
        updateModel.status.menuPresentation
    }
}
