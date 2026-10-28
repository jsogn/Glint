import Foundation
import GlintDictionary

private enum BuilderError: LocalizedError {
    case usage
    case missingOption(String)
    case unknownCommand(String)

    var errorDescription: String? {
        switch self {
        case .usage:
            """
            用法：
              glint-dictionary-builder cedict --input FILE --output FILE
              glint-dictionary-builder ecdict --input FILE --output FILE \
            [--source-checksum VALUE] [--source-date VALUE] \
            [--source-revision VALUE]
            """
        case .missingOption(let name):
            "缺少参数：\(name)"
        case .unknownCommand(let command):
            "未知构建命令：\(command)"
        }
    }
}

@main
struct GlintDictionaryBuilder {
    static func main() throws {
        var arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first else {
            throw BuilderError.usage
        }
        arguments.removeFirst()
        let options = try parseOptions(arguments)
        let input = try required("--input", in: options)
        let output = try required("--output", in: options)
        let inputURL = URL(fileURLWithPath: input)
        let outputURL = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        switch command {
        case "cedict":
            let summary = try CedictDatabaseBuilder.build(
                fromGzipURL: inputURL,
                to: outputURL
            )
            print(
                "entries=\(summary.entryCount) senses=\(summary.senseCount) "
                    + "date=\(summary.sourceDate ?? "") db=\(output)"
            )
        case "ecdict":
            let summary = try ECDICTRankBuilder.build(
                fromCSVURL: inputURL,
                to: outputURL,
                sourceChecksum: options["--source-checksum"],
                sourceDate: options["--source-date"],
                sourceRevision: options["--source-revision"]
            )
            print(
                "terms=\(summary.termCount) rows=\(summary.rankCount) "
                    + "db=\(output)"
            )
        default:
            throw BuilderError.unknownCommand(command)
        }
    }

    private static func parseOptions(
        _ arguments: [String]
    ) throws -> [String: String] {
        var options: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let name = arguments[index]
            guard name.hasPrefix("--"), index + 1 < arguments.count else {
                throw BuilderError.usage
            }
            options[name] = arguments[index + 1]
            index += 2
        }
        return options
    }

    private static func required(
        _ name: String,
        in options: [String: String]
    ) throws -> String {
        guard let value = options[name], !value.isEmpty else {
            throw BuilderError.missingOption(name)
        }
        return value
    }
}
