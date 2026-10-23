import GlintCore
import SwiftUI

struct TranslationSettingsPage: View {
    let model: MainWindowModel

    var body: some View {
        PageContainer {
            SettingsCard("翻译策略") {
                VStack(alignment: .leading, spacing: 12) {
                    Grid(
                        alignment: .leading,
                        horizontalSpacing: 24,
                        verticalSpacing: 10
                    ) {
                        GridRow {
                            Text("优先来源")
                            Color.clear
                                .frame(height: 1)
                                .gridCellUnsizedAxes(.vertical)
                            Picker(
                                "优先来源",
                                selection: Binding(
                                    get: { model.translationMode },
                                    set: { model.setTranslationMode($0) }
                                )
                            ) {
                                ForEach(TranslationMode.allCases, id: \.self) {
                                    mode in
                                    Text(mode.title).tag(mode)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(width: 240, alignment: .trailing)
                            .gridCellAnchor(.trailing)
                            .accessibilityHint(model.translationMode.explanation)
                        }
                    }
                    .frame(maxWidth: .infinity)

                    Text(model.translationMode.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
