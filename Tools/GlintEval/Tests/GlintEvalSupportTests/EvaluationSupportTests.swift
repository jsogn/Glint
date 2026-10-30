import Foundation
import Testing
@testable import GlintEvalSupport

struct EvaluationSupportTests {
    @Test
    func loadCasesMergesExpectedAndForbiddenValuesInFirstSeenOrder()
        throws
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = directory.appendingPathComponent("first.json")
        let second = directory.appendingPathComponent("second.json")
        try Data(
            """
            [
              {
                "text": "你好",
                "category": "sentence",
                "expected": ["hello"],
                "forbidden": ["greetings"]
              },
              {
                "text": "空结果",
                "category": "phrase",
                "expected": []
              }
            ]
            """.utf8
        ).write(to: first)
        try Data(
            """
            [
              {
                "text": "复盘",
                "category": "word",
                "expected": ["review"]
              },
              {
                "text": "你好",
                "category": "sentence",
                "expected": ["hi"],
                "forbidden": ["farewell"]
              }
            ]
            """.utf8
        ).write(to: second)

        let cases = try EvaluationCase.load(paths: [
            first.path,
            second.path,
        ])

        #expect(cases.map(\.text) == ["你好", "复盘"])
        #expect(cases[0].expected == ["hello", "hi"])
        #expect(cases[0].forbidden == ["farewell", "greetings"])
        #expect(cases[1].expected == ["review"])
    }

    @Test
    func summaryScoresAcceptedTopOneMissingAndForbiddenResults() {
        let rows = [
            BenchmarkRow(
                model: "system",
                text: "你好",
                category: "sentence",
                expected: ["hello", "hi"],
                forbidden: ["greetings"],
                output: "Hi",
                latencyMilliseconds: 10
            ),
            BenchmarkRow(
                model: "system",
                text: "设置",
                category: "word",
                expected: ["set"],
                forbidden: ["settings screen"],
                output: "settings screen",
                latencyMilliseconds: 30
            ),
            BenchmarkRow(
                model: "system",
                text: "复盘",
                category: "word",
                expected: ["review"],
                forbidden: [],
                output: nil,
                latencyMilliseconds: 20
            ),
        ]

        let summary = BenchmarkMetrics.summary(rows: rows)

        #expect(summary.total == 3)
        #expect(summary.top1 == 1)
        #expect(summary.missing == 1)
        #expect(summary.forbiddenHits == 1)
        #expect(summary.p50Milliseconds == 20)
        #expect(summary.p95Milliseconds == 30)
        #expect(
            summary.categories.map(\.category)
                == ["sentence", "word"]
        )
        #expect(summary.categories[1].top1 == 0)
        #expect(summary.categories[1].missing == 1)
        #expect(summary.categories[1].forbiddenHits == 1)
    }

    @Test
    func percentileUsesNearestRank() {
        #expect(percentile([10, 20, 30, 40], p: 0.5) == 20)
        #expect(percentile([10, 20, 30, 40], p: 0.95) == 40)
        #expect(percentile([], p: 0.5) == nil)
    }

    @Test
    func optionsUseBothExistingCorporaAndClampRounds() {
        let options = AppleTranslationEvaluationOptions(
            arguments: [
                "AppleTranslationCompare",
                "--rounds",
                "0",
            ]
        )

        #expect(
            options.casesPaths
                == [
                    "Resources/Evaluation/translation-mode-benchmark.json",
                    "Resources/Evaluation/dictionary-benchmark.json",
                ]
        )
        #expect(
            options.ct2Path
                == "Resources/OnlineModels/mt-opus-zh-en/model"
        )
        #expect(
            options.outputPath
                == "build/apple-translation-benchmark.json"
        )
        #expect(options.rounds == 2)
    }

    @Test
    func optionsAcceptExplicitPathsAndRounds() {
        let options = AppleTranslationEvaluationOptions(
            arguments: [
                "AppleTranslationCompare",
                "--cases",
                "/tmp/one.json,/tmp/two.json",
                "--ct2",
                "/tmp/model",
                "--output",
                "/tmp/report.json",
                "--rounds",
                "5",
            ]
        )

        #expect(options.casesPaths == ["/tmp/one.json", "/tmp/two.json"])
        #expect(options.ct2Path == "/tmp/model")
        #expect(options.outputPath == "/tmp/report.json")
        #expect(options.rounds == 5)
    }
}
