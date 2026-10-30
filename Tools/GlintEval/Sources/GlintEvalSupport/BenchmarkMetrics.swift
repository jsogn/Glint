import Foundation

public struct BenchmarkRow: Equatable, Sendable {
    public let model: String
    public let text: String
    public let category: String
    public let expected: [String]
    public let forbidden: [String]
    public let output: String?
    public let latencyMilliseconds: Double

    public init(
        model: String,
        text: String,
        category: String,
        expected: [String],
        forbidden: [String],
        output: String?,
        latencyMilliseconds: Double
    ) {
        self.model = model
        self.text = text
        self.category = category
        self.expected = expected
        self.forbidden = forbidden
        self.output = output
        self.latencyMilliseconds = latencyMilliseconds
    }

    var isMissing: Bool {
        output?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ?? true
    }

    var isTop1: Bool {
        guard let output, !isMissing else { return false }
        let actual = BenchmarkMetrics.normalize(output)
        return expected.map(BenchmarkMetrics.normalize).contains(actual)
    }

    var isForbiddenHit: Bool {
        guard let output, !isMissing else { return false }
        let actual = BenchmarkMetrics.normalize(output)
        return forbidden.map(BenchmarkMetrics.normalize).contains(actual)
    }
}

public struct BenchmarkCategorySummary: Equatable, Sendable {
    public let category: String
    public let total: Int
    public let top1: Int
    public let missing: Int
    public let forbiddenHits: Int
}

public struct BenchmarkSummary: Equatable, Sendable {
    public let total: Int
    public let top1: Int
    public let missing: Int
    public let forbiddenHits: Int
    public let p50Milliseconds: Double?
    public let p95Milliseconds: Double?
    public let categories: [BenchmarkCategorySummary]
}

public enum BenchmarkMetrics {
    public static func summary(rows: [BenchmarkRow]) -> BenchmarkSummary {
        let latencies = rows.map(\.latencyMilliseconds)
        return BenchmarkSummary(
            total: rows.count,
            top1: rows.count(where: \.isTop1),
            missing: rows.count(where: \.isMissing),
            forbiddenHits: rows.count(where: \.isForbiddenHit),
            p50Milliseconds: percentile(latencies, p: 0.5),
            p95Milliseconds: percentile(latencies, p: 0.95),
            categories: categories(rows: rows)
        )
    }

    public static func normalize(_ text: String) -> String {
        let allowed = CharacterSet.alphanumerics
        return String(
            text.lowercased().unicodeScalars.filter {
                allowed.contains($0)
            }
        )
    }

    private static func categories(
        rows: [BenchmarkRow]
    ) -> [BenchmarkCategorySummary] {
        let grouped = Dictionary(grouping: rows, by: \.category)
        return grouped.keys.sorted().compactMap { category in
            guard let values = grouped[category] else { return nil }
            return BenchmarkCategorySummary(
                category: category,
                total: values.count,
                top1: values.count(where: \.isTop1),
                missing: values.count(where: \.isMissing),
                forbiddenHits: values.count(where: \.isForbiddenHit)
            )
        }
    }
}

public func percentile(
    _ values: [Double],
    p: Double
) -> Double? {
    guard !values.isEmpty else { return nil }
    let ordered = values.sorted()
    let percentile = min(1, max(0, p))
    let rank = Int(
        (Double(ordered.count) * percentile).rounded(.up)
    )
    let index = min(
        ordered.count - 1,
        max(0, rank - 1)
    )
    return ordered[index]
}
