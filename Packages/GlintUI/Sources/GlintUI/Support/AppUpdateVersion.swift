import Foundation

enum AppUpdateVersion {
    static func isValid(_ rawVersion: String) -> Bool {
        numericParts(rawVersion) != nil
    }

    static func displayVersion(_ rawVersion: String) -> String {
        var version = rawVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        if version.first == "v" || version.first == "V" {
            version.removeFirst()
        }
        return version
    }

    static func isNewer(_ release: String, than current: String) -> Bool {
        guard let releaseParts = numericParts(release),
            let currentParts = numericParts(current)
        else {
            return false
        }

        let count = max(releaseParts.count, currentParts.count)
        for index in 0..<count {
            let releasePart =
                index < releaseParts.count ? releaseParts[index] : 0
            let currentPart =
                index < currentParts.count ? currentParts[index] : 0
            if releasePart != currentPart {
                return releasePart > currentPart
            }
        }
        return false
    }

    private static func numericParts(_ rawVersion: String) -> [Int]? {
        let version = displayVersion(rawVersion)
        guard !version.isEmpty else {
            return nil
        }

        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else {
            return nil
        }

        var result: [Int] = []
        result.reserveCapacity(parts.count)
        for part in parts {
            guard !part.isEmpty, let value = Int(part) else {
                return nil
            }
            result.append(value)
        }
        return result
    }
}
