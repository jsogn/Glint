import AppKit
import SwiftUI

struct AboutPage: View {
    private let repositoryURL = URL(string: "https://github.com/jsogn/Glint")!
    private let issuesURL = URL(string: "https://github.com/jsogn/Glint/issues")!

    private var version: String {
        Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "0.1.0"
    }

    var body: some View {
        PageContainer {
            SettingsPanel {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 14) {
                        Image(nsImage: NSApplication.shared.applicationIconImage)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .frame(width: 48, height: 48)
                            .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Glint")
                                .font(.title3.weight(.semibold))
                            Text("输入中文时，在候选旁查看对应的英文翻译。")
                                .foregroundStyle(.secondary)
                            Text("版本 \(version)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Divider()

                    HStack {
                        Text("系统要求")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("macOS 26+ · Apple 芯片")
                    }
                    .font(.callout)

                    HStack(spacing: 16) {
                        Link("GitHub 项目", destination: repositoryURL)
                        Link("问题反馈", destination: issuesURL)
                    }
                    .font(.callout)
                }
            }
        }
    }
}
