import SwiftUI

public struct SystemTranslationHostView: View {
    @ObservedObject private var coordinator: SystemTranslationCoordinator

    public init(coordinator: SystemTranslationCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .translationTask(coordinator.configuration) { session in
                await coordinator.run(session: session)
            }
    }
}
