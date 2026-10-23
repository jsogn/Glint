import Foundation

public enum PluginVersion {
    public static func isNewer(
        _ candidate: String,
        than installed: String
    ) -> Bool {
        compare(candidate, installed) == .orderedDescending
    }

    private static func compare(
        _ lhs: String,
        _ rhs: String
    ) -> ComparisonResult {
        let left = ParsedVersion(lhs)
        let right = ParsedVersion(rhs)

        if let leftCore = left.core, let rightCore = right.core {
            let count = max(leftCore.count, rightCore.count)
            for index in 0..<count {
                let leftPart = index < leftCore.count ? leftCore[index] : 0
                let rightPart = index < rightCore.count ? rightCore[index] : 0
                if leftPart != rightPart {
                    return leftPart < rightPart
                        ? .orderedAscending
                        : .orderedDescending
                }
            }

            switch (left.prerelease, right.prerelease) {
            case (nil, nil):
                return .orderedSame
            case (nil, _):
                return .orderedDescending
            case (_, nil):
                return .orderedAscending
            case let (leftPrerelease?, rightPrerelease?):
                return comparePrerelease(leftPrerelease, rightPrerelease)
            }
        }

        return lhs.compare(
            rhs,
            options: [.numeric, .caseInsensitive]
        )
    }

    private struct ParsedVersion {
        let core: [Int]?
        let prerelease: [String]?

        init(_ value: String) {
            let withoutBuild = value
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                .split(
                    separator: "+",
                    maxSplits: 1,
                    omittingEmptySubsequences: false
                )[0]
            let parts = withoutBuild.split(
                separator: "-",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            let coreParts = parts[0].split(
                separator: ".",
                omittingEmptySubsequences: false
            )
            let parsedCore = coreParts.compactMap { Int($0) }
            self.core = parsedCore.count == coreParts.count && !parsedCore.isEmpty
                ? parsedCore
                : nil
            if parts.count == 2, !parts[1].isEmpty {
                self.prerelease = parts[1].split(separator: ".").map(String.init)
            } else {
                self.prerelease = nil
            }
        }
    }

    private static func comparePrerelease(
        _ lhs: [String],
        _ rhs: [String]
    ) -> ComparisonResult {
        let count = max(lhs.count, rhs.count)
        for index in 0..<count {
            guard index < lhs.count else { return .orderedAscending }
            guard index < rhs.count else { return .orderedDescending }
            let left = lhs[index]
            let right = rhs[index]
            if let leftNumber = Int(left), let rightNumber = Int(right) {
                if leftNumber != rightNumber {
                    return leftNumber < rightNumber
                        ? .orderedAscending
                        : .orderedDescending
                }
                continue
            }
            if Int(left) != nil { return .orderedAscending }
            if Int(right) != nil { return .orderedDescending }
            let comparison = left.compare(
                right,
                options: [.numeric, .caseInsensitive]
            )
            if comparison != .orderedSame {
                return comparison
            }
        }
        return .orderedSame
    }
}
