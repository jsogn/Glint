import AppKit
import GlintCore
import SwiftUI

struct DisplayPage: View {
    @Bindable private var preferences: DisplayPreferences

    init(model: MainWindowModel) {
        self._preferences = Bindable(model.displayPreferences)
    }

    init(preferences: DisplayPreferences) {
        self._preferences = Bindable(preferences)
    }

    var body: some View {
        PageContainer {
            SettingsCard("位置与触发") {
                VStack(spacing: 0) {
                    segmentedSetting(
                        title: "翻译",
                        selection: $preferences.translationScope,
                        caption: preferences.translationScope.explanation
                    ) {
                        ForEach(
                            CandidateTranslationScope.allCases,
                            id: \.self
                        ) { scope in
                            Text(scope.title).tag(scope)
                        }
                    }

                    Divider()

                    segmentedSetting(
                        title: "显示位置",
                        selection: $preferences.position
                    ) {
                        ForEach(HUDPosition.allCases, id: \.self) {
                            position in
                            Text(position.title).tag(position)
                        }
                    }

                    Divider()

                    sliderSetting(
                        title: "候选停留",
                        value: String(
                            format: "%.0f ms",
                            preferences.candidateDwellDuration * 1000
                        ),
                        binding: $preferences.candidateDwellDuration,
                        range: 0.08...0.3,
                        step: 0.01,
                        caption: "连续输入时不翻译，候选停留达到该时长后触发。"
                    )
                }
            }
            SettingsCard("外观") {
                VStack(spacing: 0) {
                    backgroundSetting

                    Divider()

                    colorSetting(
                        title: "文字颜色",
                        color: Binding(
                            get: {
                                preferences.hudAppearance
                                    .effectiveTextColor.color
                            },
                            set: {
                                preferences.setHUDTextColor(HUDColor($0))
                            }
                        )
                    )

                    sliderSetting(
                        title: "背景不透明度",
                        value: String(
                            format: "%.0f%%",
                            preferences.hudOpacity * 100
                        ),
                        binding: $preferences.hudOpacity,
                        range: 0.4...1.0,
                        step: 0.02,
                        caption: "只调整显示背景，不改变文字清晰度。"
                    )

                    sliderSetting(
                        title: "文字大小",
                        value: String(
                            format: "%.0f pt",
                            preferences.hudFontSize
                        ),
                        binding: $preferences.hudFontSize,
                        range: HUDAppearance.fontSizeRange,
                        step: 1,
                        caption: "字号会同步调整背景高度和候选槽位。"
                    )
                    segmentedSetting(
                        title: "栏内留白",
                        selection: $preferences.hudDensity
                    ) {
                        ForEach(HUDDensity.allCases, id: \.self) {
                            density in
                            Text(density.title).tag(density)
                        }
                    }
                    Divider()
                    sliderSetting(
                        title: "与候选栏间距",
                        value: String(
                            format: "%.0f pt",
                            preferences.candidateSpacing
                        ),
                        binding: $preferences.candidateSpacing,
                        range: 0...24,
                        step: 1
                    )
                    HStack {
                        Spacer()
                        Button("恢复默认外观") {
                            preferences.resetHUDAppearance()
                        }
                        .buttonStyle(.link)
                    }
                    .padding(.top, 8)
                }
            }
            SettingsCard("预览") {
                HUDPreview(preferences: preferences)
            }
        }
    }

    private func sliderSetting(
        title: String,
        value: String,
        binding: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        caption: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                Text(value)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: binding, in: range, step: step)
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private var backgroundSetting: some View {
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                Text("背景")
                Spacer()
                Picker("背景", selection: $preferences.hudBackgroundStyle) {
                    ForEach(HUDBackgroundStyle.allCases, id: \.self) { style in
                        Text(style.title).tag(style)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 340, alignment: .trailing)
            }

            if preferences.hudBackgroundStyle == .solid {
                HStack {
                    Spacer()
                    ColorPicker(
                        "背景颜色",
                        selection: Binding(
                            get: {
                                preferences.hudBackgroundColor.color
                            },
                            set: {
                                preferences.hudBackgroundColor = HUDColor($0)
                            }
                        ),
                        supportsOpacity: false
                    )
                    .labelsHidden()
                    .frame(width: 340, alignment: .trailing)
                }
            }
        }
        .padding(.vertical, 10)
    }

    private func colorSetting(
        title: String,
        color: Binding<Color>
    ) -> some View {
        HStack(spacing: 24) {
            Text(title)
            Spacer()
            ColorPicker(
                title,
                selection: color,
                supportsOpacity: false
            )
            .labelsHidden()
            .frame(width: 64, alignment: .trailing)
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private func segmentedSetting<Value, Options>(
        title: String,
        selection: Binding<Value>,
        caption: String? = nil,
        @ViewBuilder options: () -> Options
    ) -> some View where Value: Hashable, Options: View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 24) {
                Text(title)
                Spacer(minLength: 24)
                Picker(title, selection: selection) {
                    options()
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 340, alignment: .trailing)
            }
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 10)
    }
}

private struct DisplayPagePreview: View {
    @State private var preferences: DisplayPreferences

    init(scope: CandidateTranslationScope) {
        let suite = "Glint.DisplayPagePreview"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        let preferences = DisplayPreferences(defaults: defaults)
        preferences.translationScope = scope
        self._preferences = State(initialValue: preferences)
    }

    var body: some View {
        DisplayPage(preferences: preferences)
            .frame(width: 1_100, height: 760)
    }
}

#Preview("显示与触发 · 选中") {
    DisplayPagePreview(scope: .selected)
        .preferredColorScheme(.dark)
}

#Preview("显示与触发 · 一栏") {
    DisplayPagePreview(scope: .row)
        .preferredColorScheme(.light)
}

private struct HUDPreview: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let preferences: DisplayPreferences

    private struct Candidate: Identifiable {
        let id: Int
        let text: String
    }

    private let candidates = [
        Candidate(id: 1, text: "你好"),
        Candidate(id: 2, text: "👋"),
        Candidate(id: 3, text: "你好吗"),
        Candidate(id: 4, text: "尼哈哦"),
        Candidate(id: 5, text: "你号"),
        Candidate(id: 6, text: "你"),
    ]

    private var effectivePosition: HUDPosition {
        preferences.position == .above ? .above : .below
    }

    private var previewItems: [HUDItem] {
        switch preferences.translationScope {
        case .selected:
            return [
                HUDItem(id: 0, text: "Hello · hi · ciao")
            ]
        case .row:
            return [
                HUDItem(
                    id: 0,
                    number: 1,
                    text: "hello",
                    isSelected: true
                ),
                HUDItem(id: 1, number: 2, text: "wave"),
                HUDItem(id: 2, number: 3, text: "how are you?"),
                HUDItem(id: 3, number: 4, text: "ni hao"),
                HUDItem(id: 4, number: 5, text: "your number"),
                HUDItem(id: 5, number: 6, text: "you"),
            ]
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if effectivePosition == .above {
                hudPreview
                    .padding(.bottom, preferences.candidateSpacing)
            }

            candidateBar

            if effectivePosition == .below {
                hudPreview
                    .padding(.top, preferences.candidateSpacing)
            }
        }
        .padding(12)
        .frame(
            minHeight: 96,
            alignment: .topLeading
        )
        .background(
            previewBackground,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.separator.opacity(0.7), lineWidth: 1)
        }
        .environment(\.hudMaterialBlendingMode, .withinWindow)
        .animation(
            previewAnimation,
            value: preferences.translationScope
        )
        .animation(previewAnimation, value: preferences.position)
        .animation(previewAnimation, value: preferences.candidateSpacing)
        .animation(previewAnimation, value: preferences.hudOpacity)
        .animation(previewAnimation, value: preferences.hudAppearance)
    }

    private var previewAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.18)
    }

    private var hudPreview: some View {
        HUDView(
            items: previewItems,
            appearance: preferences.hudAppearance,
            backgroundOpacity: preferences.hudOpacity
        )
        .padding(.leading, 4)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var candidateBar: some View {
        HStack(spacing: 4) {
            ForEach(candidates) { candidate in
                candidateView(candidate)
            }

            Rectangle()
                .fill(.separator)
                .frame(width: 1, height: 26)
                .padding(.horizontal, 9)

            Image(systemName: "chevron.down")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.trailing, 8)
        }
        .padding(3)
        .background {
            HUDNativeMaterialBackground(blendingMode: .withinWindow)
                .clipShape(Capsule())
        }
        .overlay {
            Capsule().strokeBorder(.separator, lineWidth: 1)
        }
        .shadow(
            color: .black.opacity(colorScheme == .dark ? 0.45 : 0.18),
            radius: 5,
            y: 2
        )
        .fixedSize()
    }

    private func candidateView(_ candidate: Candidate) -> some View {
        let selected = candidate.id == 1

        return HStack(spacing: 3) {
            Text("\(candidate.id)")
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(
                    selected ? Color.white.opacity(0.86) : Color.secondary
                )

            Text(candidate.text)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .padding(.horizontal, selected ? 9 : 8)
        .padding(.vertical, 4)
        .background {
            if selected {
                Capsule().fill(Color.accentColor)
            }
        }
    }

    private var previewBackground: Color {
        if colorScheme == .dark {
            Color(red: 0.04, green: 0.04, blue: 0.04)
        } else {
            Color(nsColor: .textBackgroundColor)
        }
    }
}
