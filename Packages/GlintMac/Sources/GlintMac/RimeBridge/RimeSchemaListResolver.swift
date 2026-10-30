import Foundation

enum RimeSchemaListError: Error, Equatable {
    case unsupportedSchemaList
}

struct RimeSchemaListResolver {
    func enabledSchemaIDs(
        sharedDefault: String,
        userDefaultCustom: String?,
        compiledSchemaIDs: [String]
    ) throws -> [String] {
        var schemaIDs = try parseSharedSchemaList(sharedDefault)
        if let userDefaultCustom,
            !Self.isEffectivelyEmpty(userDefaultCustom)
        {
            switch try parseUserOverride(userDefaultCustom) {
            case .none:
                break
            case .replace(let replacements):
                schemaIDs = replacements
            case .append(let additions):
                schemaIDs.append(contentsOf: additions)
            }
        }

        let compiled = Set(compiledSchemaIDs)
        var seen = Set<String>()
        return schemaIDs.filter { schemaID in
            compiled.contains(schemaID) && seen.insert(schemaID).inserted
        }
    }

    private func parseSharedSchemaList(
        _ source: String
    ) throws -> [String] {
        let lines = source.components(separatedBy: "\n")
        let matches = lines.indices.filter { index in
            let line = Self.contentBeforeComment(lines[index])
            return Self.indentation(of: line) == 0
                && Self.keyAndValue(line).key == "schema_list"
        }
        guard matches.count == 1, let keyIndex = matches.first else {
            throw RimeSchemaListError.unsupportedSchemaList
        }
        let keyAndValue = Self.keyAndValue(lines[keyIndex])
        guard keyAndValue.value.isEmpty else {
            throw RimeSchemaListError.unsupportedSchemaList
        }
        return try parseListItems(
            lines: lines,
            after: keyIndex,
            parentIndent: 0
        )
    }

    private func parseUserOverride(
        _ source: String
    ) throws -> UserOverride? {
        let lines = source.components(separatedBy: "\n")
        try Self.validateSupportedUserOverride(lines)
        let patchMatches = lines.indices.filter { index in
            let line = Self.contentBeforeComment(lines[index])
            return Self.indentation(of: line) == 0
                && Self.keyAndValue(line).key == "patch"
        }
        guard patchMatches.count == 1, let patchIndex = patchMatches.first
        else {
            throw RimeSchemaListError.unsupportedSchemaList
        }
        guard Self.keyAndValue(lines[patchIndex]).value.isEmpty else {
            throw RimeSchemaListError.unsupportedSchemaList
        }

        let patchEnd = Self.endOfBlock(
            lines: lines,
            after: patchIndex,
            parentIndent: 0
        )
        let directIndent = lines[(patchIndex + 1)..<patchEnd]
            .compactMap { line -> Int? in
                let content = Self.contentBeforeComment(line)
                guard
                    !content.trimmingCharacters(in: .whitespaces).isEmpty
                else {
                    return nil
                }
                return Self.indentation(of: content)
            }
            .first
        guard let directIndent, directIndent > 0 else {
            return nil
        }

        var replacementIndex: Int?
        var appendIndex: Int?
        for index in (patchIndex + 1)..<patchEnd {
            let content = Self.contentBeforeComment(lines[index])
            guard
                !content.trimmingCharacters(in: .whitespaces).isEmpty,
                Self.indentation(of: content) == directIndent
            else {
                continue
            }
            let (key, value) = Self.keyAndValue(content)
            let normalizedKey = Self.unquoted(key)
            if normalizedKey.hasPrefix("schema_list"),
                normalizedKey != key
            {
                throw RimeSchemaListError.unsupportedSchemaList
            }
            switch normalizedKey {
            case "schema_list":
                guard replacementIndex == nil, value.isEmpty else {
                    throw RimeSchemaListError.unsupportedSchemaList
                }
                replacementIndex = index
            case "schema_list/+":
                guard appendIndex == nil, value.isEmpty else {
                    throw RimeSchemaListError.unsupportedSchemaList
                }
                appendIndex = index
            case let key where key.hasPrefix("schema_list"):
                throw RimeSchemaListError.unsupportedSchemaList
            default:
                continue
            }
        }

        guard replacementIndex == nil || appendIndex == nil else {
            throw RimeSchemaListError.unsupportedSchemaList
        }
        if let replacementIndex {
            return .replace(
                try parseListItems(
                    lines: lines,
                    after: replacementIndex,
                    parentIndent: directIndent
                )
            )
        }
        if let appendIndex {
            return .append(
                try parseListItems(
                    lines: lines,
                    after: appendIndex,
                    parentIndent: directIndent
                )
            )
        }
        return nil
    }

    private static func validateSupportedUserOverride(
        _ lines: [String]
    ) throws {
        for line in lines {
            let content = contentBeforeComment(line)
            let indent =
                content.prefix(while: { $0 == " " }).count
            if content.dropFirst(indent).first == "\t" {
                throw RimeSchemaListError.unsupportedSchemaList
            }
            let trimmed = content.trimmingCharacters(
                in: .whitespaces
            )
            guard !trimmed.isEmpty else { continue }
            if trimmed == "---" || trimmed == "..." {
                throw RimeSchemaListError.unsupportedSchemaList
            }
            let (rawKey, _) = keyAndValue(trimmed)
            let key = unquoted(rawKey)
            if key.hasPrefix("__") || key == "<<" {
                throw RimeSchemaListError.unsupportedSchemaList
            }
            let tokens = trimmed.split(
                whereSeparator: { $0.isWhitespace }
            )
            if tokens.contains(where: isAnchorOrAliasToken) {
                throw RimeSchemaListError.unsupportedSchemaList
            }
        }
    }

    private static func isAnchorOrAliasToken(
        _ token: Substring
    ) -> Bool {
        token.first == "&"
            || token.first == "*"
            || token.first == "!"
    }

    private func parseListItems(
        lines: [String],
        after keyIndex: Int,
        parentIndent: Int
    ) throws -> [String] {
        let end = Self.endOfBlock(
            lines: lines,
            after: keyIndex,
            parentIndent: parentIndent
        )
        var schemaIDs: [String] = []
        for index in (keyIndex + 1)..<end {
            let content = Self.contentBeforeComment(lines[index])
            let trimmed = content.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            guard Self.indentation(of: content) > parentIndent else {
                throw RimeSchemaListError.unsupportedSchemaList
            }
            guard trimmed.hasPrefix("- ") else {
                throw RimeSchemaListError.unsupportedSchemaList
            }
            let item = String(trimmed.dropFirst(2))
            let (key, rawValue) = Self.keyAndValue(item)
            guard key == "schema" else {
                throw RimeSchemaListError.unsupportedSchemaList
            }
            let schemaID = Self.unquoted(rawValue)
            guard Self.isValidSchemaID(schemaID) else {
                throw RimeSchemaListError.unsupportedSchemaList
            }
            schemaIDs.append(schemaID)
        }
        guard !schemaIDs.isEmpty else {
            throw RimeSchemaListError.unsupportedSchemaList
        }
        return schemaIDs
    }

    private static func endOfBlock(
        lines: [String],
        after index: Int,
        parentIndent: Int
    ) -> Int {
        guard index + 1 < lines.count else {
            return lines.count
        }
        for candidate in (index + 1)..<lines.count {
            let content = contentBeforeComment(lines[candidate])
            guard !content.trimmingCharacters(in: .whitespaces).isEmpty
            else {
                continue
            }
            if indentation(of: content) <= parentIndent {
                return candidate
            }
        }
        return lines.count
    }

    private static func indentation(of line: String) -> Int {
        line.prefix(while: { $0 == " " }).count
    }

    private static func keyAndValue(
        _ line: String
    ) -> (key: String, value: String) {
        let content = contentBeforeComment(line)
            .trimmingCharacters(in: .whitespaces)
        guard let colon = content.firstIndex(of: ":") else {
            return (content, "")
        }
        let key = String(content[..<colon])
            .trimmingCharacters(in: .whitespaces)
        let value = String(content[content.index(after: colon)...])
            .trimmingCharacters(in: .whitespaces)
        return (key, value)
    }

    private static func contentBeforeComment(_ line: String) -> String {
        var quote: Character?
        for index in line.indices {
            let character = line[index]
            if character == "'" || character == "\"" {
                if quote == character {
                    quote = nil
                } else if quote == nil {
                    quote = character
                }
            } else if character == "#", quote == nil {
                if line[..<index].last?.isWhitespace != false {
                    return String(line[..<index])
                }
            }
        }
        return line
    }

    private static func unquoted(_ value: String) -> String {
        guard value.count >= 2 else { return value }
        if (value.first == "\"" && value.last == "\"")
            || (value.first == "'" && value.last == "'")
        {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    private static func isValidSchemaID(_ schemaID: String) -> Bool {
        !schemaID.isEmpty
            && schemaID.unicodeScalars.allSatisfy { scalar in
                CharacterSet.alphanumerics.contains(scalar)
                    || scalar == "_"
                    || scalar == "-"
                    || scalar == "."
            }
    }

    private static func isEffectivelyEmpty(_ source: String) -> Bool {
        source.components(separatedBy: "\n").allSatisfy { line in
            let trimmed = contentBeforeComment(line)
                .trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty
        }
    }

    private enum UserOverride {
        case replace([String])
        case append([String])
    }
}
