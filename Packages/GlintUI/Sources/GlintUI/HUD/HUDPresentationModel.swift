import Observation
import SwiftUI

@MainActor
@Observable
final class HUDPresentationModel {
    var text: String
    var backgroundOpacity: Double
    var textOpacity: Double
    var animatesTransitions: Bool

    init(
        text: String,
        backgroundOpacity: Double,
        textOpacity: Double = 1,
        animatesTransitions: Bool
    ) {
        self.text = text
        self.backgroundOpacity = backgroundOpacity
        self.textOpacity = textOpacity
        self.animatesTransitions = animatesTransitions
    }
}

struct HUDLiveView: View {
    let model: HUDPresentationModel

    var body: some View {
        Text(model.text)
            .font(.system(size: 14, weight: .medium))
            .lineLimit(1)
            .truncationMode(.tail)
            .opacity(model.textOpacity)
            .contentTransition(.opacity)
            .animation(
                model.animatesTransitions
                    ? .easeOut(duration: 0.08)
                    : nil,
                value: model.text
            )
            .animation(
                model.animatesTransitions
                    ? .easeOut(duration: 0.06)
                    : nil,
                value: model.textOpacity
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background {
                Capsule()
                    .fill(
                        Color(nsColor: .controlBackgroundColor)
                            .opacity(model.backgroundOpacity)
                    )
                    .animation(
                        model.animatesTransitions
                            ? .easeOut(duration: 0.1)
                            : nil,
                        value: model.backgroundOpacity
                    )
            }
            .overlay {
                Capsule().stroke(.separator, lineWidth: 1)
            }
    }
}
