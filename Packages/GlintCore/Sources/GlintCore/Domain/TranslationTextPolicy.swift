import Foundation

public enum TranslationTextPolicy {
    public static func isDisplayable(
        _ text: String,
        target: TranslationTarget
    ) -> Bool {
        let value = text.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !value.isEmpty,
            value.count <= 48,
            !value.contains(where: \.isNewline)
        else {
            return false
        }

        if target.allowsHanOutput {
            return true
        }
        let hanCount = value.unicodeScalars.count {
            (0x4E00...0x9FFF).contains($0.value)
        }
        return hanCount <= max(1, value.count / 5)
    }
}
