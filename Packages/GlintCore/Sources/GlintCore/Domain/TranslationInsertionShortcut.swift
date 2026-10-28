import Foundation

public struct TranslationInsertionModifiers:
    OptionSet, Codable, Hashable, Sendable
{
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let control = Self(rawValue: 1 << 0)
    public static let option = Self(rawValue: 1 << 1)
    public static let shift = Self(rawValue: 1 << 2)
    public static let command = Self(rawValue: 1 << 3)
    public static let capsLock = Self(rawValue: 1 << 4)

    public static let supportedTrigger: Self = [
        .control,
        .option,
        .shift,
        .command,
        .capsLock,
    ]

    public var displayText: String {
        var components: [String] = []
        if contains(.control) { components.append("⌃") }
        if contains(.option) { components.append("⌥") }
        if contains(.shift) { components.append("⇧") }
        if contains(.command) { components.append("⌘") }
        if contains(.capsLock) { components.append("⇪") }
        return components.joined(separator: " ")
    }
}

public struct TranslationInsertionShortcut:
    Codable, Hashable, Sendable
{
    public let modifiers: TranslationInsertionModifiers

    public init(
        modifiers: TranslationInsertionModifiers
    ) {
        self.modifiers = modifiers
    }

    public var displayText: String {
        modifiers.displayText
    }

    public var isValid: Bool {
        !modifiers.isEmpty
            && modifiers.subtracting(.supportedTrigger).isEmpty
    }

    public static let presets: [TranslationInsertionShortcut] = [
        TranslationInsertionShortcut(modifiers: [.option]),
        TranslationInsertionShortcut(modifiers: [.control]),
        TranslationInsertionShortcut(modifiers: [.command]),
        TranslationInsertionShortcut(modifiers: [.shift]),
        TranslationInsertionShortcut(modifiers: [.capsLock]),
    ]

    public static let defaultTrigger = presets[0]
}
