import Foundation

public struct AppleTranslationEvaluationOptions:
    Equatable, Sendable
{
    public let casesPaths: [String]
    public let ct2Path: String
    public let outputPath: String
    public let rounds: Int

    public init(arguments: [String]) {
        let values = Array(arguments.dropFirst())

        func value(after name: String) -> String? {
            guard let index = values.firstIndex(of: name),
                values.indices.contains(index + 1)
            else {
                return nil
            }
            return values[index + 1]
        }

        let defaultCases = [
            "Resources/Evaluation/translation-mode-benchmark.json",
            "Resources/Evaluation/dictionary-benchmark.json",
        ]
        let configuredCases = value(after: "--cases")
        let parsedCases =
            configuredCases?
            .split(separator: ",")
            .map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
        casesPaths =
            if let parsedCases, !parsedCases.isEmpty {
                parsedCases
            } else {
                defaultCases
            }
        ct2Path =
            value(after: "--ct2")
            ?? "Resources/OnlineModels/mt-opus-zh-en/model"
        outputPath =
            value(after: "--output")
            ?? "build/apple-translation-benchmark.json"
        rounds = max(
            2,
            Int(value(after: "--rounds") ?? "3") ?? 3
        )
    }
}
