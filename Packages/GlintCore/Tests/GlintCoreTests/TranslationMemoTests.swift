import XCTest
@testable import GlintCore

final class TranslationMemoTests: XCTestCase {
    private actor Counter {
        private(set) var value = 0

        func increment() -> Int {
            value += 1
            return value
        }
    }

    func testExactResultIsCached() async throws {
        let memo = TranslationMemo()
        let counter = Counter()
        let key = TranslationMemoKey(
            text: "你好",
            mode: .dictionaryFirst,
            configuration: "model-a"
        )

        let first = try await memo.resolve(for: key) {
            _ = await counter.increment()
            return TranslationResult(
                text: "hello"
            )
        }
        let second = try await memo.resolve(for: key) {
            _ = await counter.increment()
            return TranslationResult(
                text: "unexpected"
            )
        }

        XCTAssertEqual(first?.text, "hello")
        XCTAssertEqual(second?.text, "hello")
        let count = await counter.value
        XCTAssertEqual(count, 1)
    }

    func testDefaultLimitsAndHitStatistics() async throws {
        let memo = TranslationMemo()
        let key = TranslationMemoKey(
            text: "你好",
            mode: .dictionaryFirst,
            configuration: "model-a"
        )
        let result = TranslationResult(
            text: "hello"
        )

        _ = try await memo.resolve(for: key) { result }
        _ = try await memo.resolve(for: key) { nil }
        let statistics = await memo.statistics()

        XCTAssertEqual(statistics.maximumEntries, 2_048)
        XCTAssertEqual(
            statistics.maximumEstimatedBytes,
            16 * 1_024 * 1_024
        )
        XCTAssertEqual(statistics.entries, 1)
        XCTAssertEqual(statistics.hits, 1)
        XCTAssertGreaterThan(statistics.estimatedBytes, 0)
    }

    func testPrefetchMissDoesNotDoubleCountResolutionMiss() async throws {
        let memo = TranslationMemo()
        let key = TranslationMemoKey(
            text: "你好",
            mode: .dictionaryFirst,
            configuration: "model-a"
        )

        let peeked = await memo.peek(for: key)
        XCTAssertNil(peeked)
        _ = try await memo.resolve(for: key) {
            TranslationResult(
                text: "hello"
            )
        }
        let statistics = await memo.statistics()

        XCTAssertEqual(statistics.misses, 1)
    }

    func testOversizedResultIsRejectedAndNotCached() async throws {
        let memo = TranslationMemo(capacity: 10, maximumCost: 80)
        let counter = Counter()
        let key = TranslationMemoKey(
            text: "你好",
            mode: .dictionaryFirst,
            configuration: "model-a"
        )

        for _ in 0..<2 {
            _ = try await memo.resolve(for: key) {
                _ = await counter.increment()
                return TranslationResult(
                    options: [
                        TranslationOption(
                            text: String(repeating: "x", count: 100),
                            score: 1
                        ),
                    ]
                )
            }
        }

        let count = await counter.value
        let statistics = await memo.statistics()
        XCTAssertEqual(count, 2)
        XCTAssertEqual(statistics.entries, 0)
        XCTAssertEqual(statistics.rejectedEntries, 2)
    }

    func testEstimatedCostIncludesEveryOption() async throws {
        let memo = TranslationMemo()
        let key = TranslationMemoKey(
            text: "方案",
            mode: .modelFirst,
            configuration: "configuration-with-version"
        )

        _ = try await memo.resolve(for: key) {
            TranslationResult(
                options: [
                    TranslationOption(text: "primary", score: 0.9),
                    TranslationOption(text: "alternative", score: 0.7),
                    TranslationOption(text: "secondary", score: 0.5),
                ]
            )
        }

        let statistics = await memo.statistics()
        XCTAssertGreaterThanOrEqual(
            statistics.estimatedBytes,
            "方案".utf8.count
                + "configuration-with-version".utf8.count
                + "primary".utf8.count
                + "alternative".utf8.count
                + "secondary".utf8.count
                + 96
                + 32 * 3
        )
    }

    func testConfigurationChangesBypassCachedResult() async throws {
        let memo = TranslationMemo()
        let counter = Counter()

        for configuration in ["model-a", "model-b"] {
            _ = try await memo.resolve(
                for: TranslationMemoKey(
                    text: "你好",
                    mode: .dictionaryFirst,
                    configuration: configuration
                )
            ) {
                let value = await counter.increment()
                return TranslationResult(
                    text: "result-\(value)"
                )
            }
        }

        let count = await counter.value
        XCTAssertEqual(count, 2)
    }

    func testAlternativeDetailBypassesPrimaryOnlyCache() async throws {
        let memo = TranslationMemo()
        let counter = Counter()

        for includesAlternatives in [false, true] {
            _ = try await memo.resolve(
                for: TranslationMemoKey(
                    text: "方案",
                    mode: .modelFirst,
                    configuration: "model-a",
                    includesAlternatives: includesAlternatives
                )
            ) {
                let value = await counter.increment()
                return TranslationResult(
                    text: "result-\(value)"
                )
            }
        }

        let count = await counter.value
        XCTAssertEqual(count, 2)
    }

    func testConcurrentRequestsAreCoalesced() async throws {
        let memo = TranslationMemo()
        let counter = Counter()
        let key = TranslationMemoKey(
            text: "今天天气不错",
            mode: .dictionaryFirst,
            configuration: "model-a"
        )

        async let first = memo.resolve(for: key) {
            _ = await counter.increment()
            try await Task.sleep(nanoseconds: 30_000_000)
            return TranslationResult(
                text: "It's a nice day."
            )
        }
        async let second = memo.resolve(for: key) {
            _ = await counter.increment()
            return TranslationResult(
                text: "unexpected"
            )
        }

        let firstResult = try await first
        let secondResult = try await second

        XCTAssertNotNil(firstResult)
        XCTAssertEqual(firstResult, secondResult)
        let count = await counter.value
        XCTAssertEqual(count, 1)
    }

    func testCancellingOneWaiterKeepsSharedRequestAlive() async throws {
        let memo = TranslationMemo()
        let counter = Counter()
        let key = TranslationMemoKey(
            text: "共享请求",
            mode: .dictionaryFirst,
            configuration: "model-a"
        )
        let operation: @Sendable () async throws -> TranslationResult? = {
            _ = await counter.increment()
            try await Task.sleep(nanoseconds: 120_000_000)
            return TranslationResult(
                text: "shared result"
            )
        }

        let first = Task {
            try await memo.resolve(for: key, operation: operation)
        }
        for _ in 0..<50 {
            let statistics = await memo.statistics()
            if statistics.misses == 1 {
                break
            }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        let second = Task {
            try await memo.resolve(for: key, operation: operation)
        }
        for _ in 0..<50 {
            let statistics = await memo.statistics()
            if statistics.inFlightHits == 1 {
                break
            }
            try await Task.sleep(nanoseconds: 2_000_000)
        }

        first.cancel()
        let result = try await second.value

        XCTAssertEqual(result?.text, "shared result")
        let count = await counter.value
        XCTAssertEqual(count, 1)
    }

    func testLRUEvictionKeepsNewestEntry() async throws {
        let memo = TranslationMemo(capacity: 1)
        let counter = Counter()

        for text in ["你好", "再见"] {
            _ = try await memo.resolve(
                for: TranslationMemoKey(
                    text: text,
                    mode: .dictionaryFirst,
                    configuration: "model-a"
                )
            ) {
                let value = await counter.increment()
                return TranslationResult(
                    text: "result-\(value)"
                )
            }
        }

        _ = try await memo.resolve(
            for: TranslationMemoKey(
                text: "你好",
                mode: .dictionaryFirst,
                configuration: "model-a"
            )
        ) {
            let value = await counter.increment()
            return TranslationResult(
                text: "result-\(value)"
            )
        }

        let count = await counter.value
        XCTAssertEqual(count, 3)
        let statistics = await memo.statistics()
        XCTAssertEqual(statistics.evictions, 2)
    }
}
