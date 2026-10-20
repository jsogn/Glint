import SwiftUI

struct GlintSegmentedTabs<Value: Hashable>: View {
    @Binding var selection: Value

    let values: [Value]
    let accessibilityTitle: String
    let title: (Value) -> String

    init(
        selection: Binding<Value>,
        values: [Value],
        accessibilityTitle: String,
        title: @escaping (Value) -> String
    ) {
        self._selection = selection
        self.values = values
        self.accessibilityTitle = accessibilityTitle
        self.title = title
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(values, id: \.self) { value in
                Button {
                    select(value)
                } label: {
                    Text(title(value))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(
                            selection == value ? Color.white : Color.secondary
                        )
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)
                        .background {
                            if selection == value {
                                RoundedRectangle(
                                    cornerRadius: 10,
                                    style: .continuous
                                )
                                .fill(Color.accentColor)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(
                    selection == value ? .isSelected : []
                )
            }
        }
        .background(
            Color.primary.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .fixedSize()
        .accessibilityRepresentation {
            Picker(accessibilityTitle, selection: $selection) {
                ForEach(values, id: \.self) { value in
                    Text(title(value))
                        .tag(value)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private func select(_ value: Value) {
        guard selection != value else { return }

        withAnimation(.easeOut(duration: 0.15)) {
            selection = value
        }
    }
}
