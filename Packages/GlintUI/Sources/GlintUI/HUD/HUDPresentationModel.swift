import Observation
import SwiftUI

@MainActor
@Observable
final class HUDPresentationModel {
    var items: [HUDItem]
    var appearance: HUDAppearance
    var backgroundOpacity: Double
    var textOpacity: Double
    var animatesTransitions: Bool
    var showsOnlySelectedItem: Bool

    init(
        text: String,
        appearance: HUDAppearance,
        backgroundOpacity: Double,
        textOpacity: Double = 1,
        animatesTransitions: Bool
    ) {
        self.items = [HUDItem(id: 0, text: text)]
        self.appearance = appearance
        self.backgroundOpacity = backgroundOpacity
        self.textOpacity = textOpacity
        self.animatesTransitions = animatesTransitions
        self.showsOnlySelectedItem = false
    }
}

struct HUDLiveView: View {
    let model: HUDPresentationModel

    var body: some View {
        HUDItemRow(
            items: displayedItems,
            appearance: model.appearance,
            backgroundOpacity: model.backgroundOpacity,
            animatesBackground: model.animatesTransitions,
            textOpacity: model.textOpacity
        )
        .frame(
            maxWidth: .infinity,
            alignment: .leading
        )
    }

    private var displayedItems: [HUDItem] {
        guard model.showsOnlySelectedItem else {
            return model.items
        }
        guard let selected = model.items.first(where: \.isSelected)
                ?? model.items.first else {
            return []
        }
        return [
            HUDItem(
                id: selected.id,
                number: selected.number,
                text: selected.text,
                isSelected: true
            ),
        ]
    }
}
