import Foundation
import GlintMac

private struct Options {
    let bundleIdentifier: String
    let seconds: Double
    let includeVisibleTexts: Bool
}

private func parseOptions() -> Options? {
    var bundleIdentifier: String?
    var seconds = 20.0
    var includeVisibleTexts = false
    var arguments = Array(CommandLine.arguments.dropFirst())
    while !arguments.isEmpty {
        let argument = arguments.removeFirst()
        guard !arguments.isEmpty else {
            return nil
        }
        let value = arguments.removeFirst()
        switch argument {
        case "--bundle":
            bundleIdentifier = value
        case "--seconds":
            seconds = Double(value) ?? seconds
        case "--visible-texts":
            includeVisibleTexts = value == "true"
        default:
            return nil
        }
    }
    guard let bundleIdentifier, seconds > 0 else {
        return nil
    }
    return Options(
        bundleIdentifier: bundleIdentifier,
        seconds: min(max(seconds, 1), 120),
        includeVisibleTexts: includeVisibleTexts
    )
}

private func percentile(
    _ values: [Double],
    _ position: Double
) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let index = min(
        sorted.count - 1,
        Int((Double(sorted.count - 1) * position).rounded())
    )
    return sorted[index]
}

guard let options = parseOptions() else {
    print(
        "usage: SelectedTextItemCacheProbe "
            + "--bundle <id> [--seconds 20] "
            + "[--visible-texts true|false]"
    )
    exit(EXIT_FAILURE)
}
guard FocusMonitor.isAccessibilityTrusted() else {
    print("cache.probe permission=false")
    exit(EXIT_FAILURE)
}

let reader = SelectedTextItemCandidateReader(
    bundleIdentifier: options.bundleIdentifier
)
let deadline = Date().addingTimeInterval(options.seconds)
var coldLatency: Double?
var hotLatencies: [Double] = []
var candidateCount = 0

while Date() < deadline {
    let startedAt = DispatchTime.now().uptimeNanoseconds
    let snapshot = reader.snapshot(
        includeVisibleCandidates: true,
        includeVisibleTexts: options.includeVisibleTexts
    )
    let elapsed =
        Double(
            DispatchTime.now().uptimeNanoseconds - startedAt
        ) / 1_000_000
    guard let snapshot else {
        Thread.sleep(forTimeInterval: 0.05)
        continue
    }
    if coldLatency == nil {
        coldLatency = elapsed
        candidateCount = snapshot.options.count
    } else {
        hotLatencies.append(elapsed)
    }
    Thread.sleep(forTimeInterval: 0.025)
}

let statistics = reader.cacheStatistics()
print(
    "cache.probe bundle=\(options.bundleIdentifier) "
        + "candidates=\(candidateCount) "
        + "visible_texts=\(options.includeVisibleTexts) "
        + "cold_ms=\(String(format: "%.3f", coldLatency ?? 0)) "
        + "hits=\(statistics.hits) misses=\(statistics.misses)"
)
if !hotLatencies.isEmpty {
    print(
        "cache.probe hot_samples=\(hotLatencies.count) "
            + "p50_ms=\(String(format: "%.3f", percentile(hotLatencies, 0.5))) "
            + "p95_ms=\(String(format: "%.3f", percentile(hotLatencies, 0.95))) "
            + "max_ms=\(String(format: "%.3f", hotLatencies.max() ?? 0))"
    )
}
