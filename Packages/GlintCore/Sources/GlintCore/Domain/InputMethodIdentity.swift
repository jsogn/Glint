import Foundation

public enum InputMethodIdentifier {
    public static let appleInputMethodBundle =
        "com.apple.inputmethod.SCIM"
    public static let applePinyinInputMode =
        "com.apple.inputmethod.SCIM.ITABC"
    public static let weTypeBundle =
        "com.tencent.inputmethod.wetype"
    public static let weTypePinyinMode =
        "com.tencent.inputmethod.wetype.pinyin"
    public static let sogouBundle =
        "com.sogou.inputmethod.sogou"
    public static let sogouPinyinMode =
        "com.sogou.inputmethod.sogou.pinyin"
    public static let squirrelBundle =
        "im.rime.inputmethod.Squirrel"
    public static let squirrelHansMode =
        "im.rime.inputmethod.Squirrel.Hans"
    public static let squirrelHantMode =
        "im.rime.inputmethod.Squirrel.Hant"
}

public struct InputMethodIdentity: Sendable, Equatable {
    public let bundleIdentifier: String?
    public let inputSourceIdentifier: String
    public let sourceType: String
    public let localizedName: String?

    public init(
        bundleIdentifier: String?,
        inputSourceIdentifier: String,
        sourceType: String,
        localizedName: String?
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.inputSourceIdentifier = inputSourceIdentifier
        self.sourceType = sourceType
        self.localizedName = localizedName
    }

    public var displayName: String {
        if inputSourceIdentifier
            == InputMethodIdentifier.applePinyinInputMode
            || (bundleIdentifier
                == InputMethodIdentifier.appleInputMethodBundle
                && inputSourceIdentifier
                    == InputMethodIdentifier.appleInputMethodBundle)
        {
            return "简体拼音"
        }
        if bundleIdentifier == InputMethodIdentifier.squirrelBundle {
            return "Rime"
        }
        let localizedName =
            localizedName?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ) ?? ""
        if !localizedName.isEmpty {
            return localizedName
        }
        if bundleIdentifier == InputMethodIdentifier.weTypeBundle {
            return "微信输入法"
        }
        return "输入法"
    }
}
