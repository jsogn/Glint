import Foundation

public enum TranslationTextPolicy {
    public static func isDisplayable(
        _ text: String,
        target: TranslationTarget
    ) -> Bool {
        let value = text.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        // Model sentence translations naturally exceed the 48-character
        // dictionary gloss limit. Dictionary and concise-option filtering
        // enforce their own limits before reaching this shared policy.
        guard !value.isEmpty,
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
