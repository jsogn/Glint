import SwiftUI

public struct HUDView: View {
    private let text: String
    private let backgroundOpacity: Double

    public init(text: String, backgroundOpacity: Double = 0.92) {
        self.text = text
        self.backgroundOpacity = backgroundOpacity
    }

    public var body: some View {
        Text(text)
            .font(.system(size: 14, weight: .medium))
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background {
                Capsule()
                    .fill(
                        Color(nsColor: .controlBackgroundColor)
                            .opacity(backgroundOpacity)
                    )
            }
            .overlay {
                Capsule().stroke(.separator, lineWidth: 1)
            }
    }
}
