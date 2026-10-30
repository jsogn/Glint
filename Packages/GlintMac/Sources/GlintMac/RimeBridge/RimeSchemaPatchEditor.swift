import Foundation

public enum RimeSchemaPatchError: Error, Equatable {
    case missingPatchRoot
    case unsupportedEngineStructure
    case unsupportedFilterList
}

struct RimeSchemaPatchResult: Equatable {
    let source: String
    let changed: Bool
    let createdFile: Bool
}

struct RimeSchemaPatchEditor {
    static let filterValue = "lua_filter@*glint.candidate_bridge"
    static let beginMarker = "# BEGIN GLINT RIME CANDIDATE BRIDGE"
    static let endMarker = "# END GLINT RIME CANDIDATE BRIDGE"

    func install(
        into source: String?,
        schemaID: String
    ) throws -> RimeSchemaPatchResult {
        _ = schemaID
        guard let source, !source.isEmpty else {
            return RimeSchemaPatchResult(
                source: Self.managedPatchFile,
                changed: true,
                createdFile: true
            )
        }
        let originalLines = source.components(separatedBy: "\n")
        let patchIndices = Self.patchRootIndices(in: originalLines)
        guard patchIndices.count <= 1 else {
            throw RimeSchemaPatchError.missingPatchRoot
        }
        guard !Self.containsYAMLAnchorOrAlias(in: originalLines) else {
            throw RimeSchemaPatchError.unsupportedEngineStructure
        }
        guard
            !Self.containsUnsupportedDocumentSyntax(
                in: originalLines
            )
        else {
            throw RimeSchemaPatchError.unsupportedEngineStructure
        }
        let markerLineCount = originalLines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed == Self.beginMarker
                || trimmed == Self.endMarker
        }.count
        if markerLineCount > 0 {
            guard
                markerLineCount == 2,
                removeManagedFilter(from: source) != source
            else {
                throw RimeSchemaPatchError.unsupportedFilterList
            }
            return RimeSchemaPatchResult(
                source: source,
                changed: false,
                createdFile: false
            )
        }
        guard let patchIndex = patchIndices.first else {
            guard Self.isEffectivelyEmpty(source) else {
                throw RimeSchemaPatchError.missingPatchRoot
            }
            let separator =
                source.hasSuffix("\n") ? "" : "\n"
            return RimeSchemaPatchResult(
                source:
                    source + separator + Self.managedPatchFile,
                changed: true,
                createdFile: false
            )
        }

        guard
            Self.contentBeforeComment(originalLines[patchIndex])
                .trimmingCharacters(in: .whitespaces) == "patch:"
        else {
            throw RimeSchemaPatchError.missingPatchRoot
        }

        var lines = originalLines
        let patchEnd = Self.endOfMapping(
            lines: lines,
            after: patchIndex
        )
        let meaningfulChildIndices = ((patchIndex + 1)..<patchEnd)
            .filter { index in
                let content = Self.contentBeforeComment(lines[index])
                    .trimmingCharacters(in: .whitespaces)
                return !content.isEmpty
            }
        let directIndent =
            meaningfulChildIndices.first.map {
                Self.indentation(of: lines[$0])
            } ?? 2
        guard directIndent > 0 else {
            throw RimeSchemaPatchError.missingPatchRoot
        }
        if meaningfulChildIndices.contains(where: {
            let indentation = Self.indentation(of: lines[$0])
            return indentation > 0 && indentation < directIndent
        }) {
            throw RimeSchemaPatchError.unsupportedEngineStructure
        }
        let directChildIndices = meaningfulChildIndices.filter {
            Self.indentation(of: lines[$0]) == directIndent
        }
        let filterKeys = directChildIndices.filter { index in
            let (key, _) = Self.keyAndValue(
                Self.contentBeforeComment(lines[index])
            )
            return Self.unquoted(key) == "engine/filters/+"
        }
        guard filterKeys.count <= 1 else {
            throw RimeSchemaPatchError.unsupportedFilterList
        }
        if let filterKeyIndex = filterKeys.first {
            let (_, value) = Self.keyAndValue(
                Self.contentBeforeComment(lines[filterKeyIndex])
            )
            guard value.isEmpty else {
                throw RimeSchemaPatchError.unsupportedFilterList
            }
            if Self.filterListContainsManagedFilter(
                lines: lines,
                keyIndex: filterKeyIndex,
                parentIndent: directIndent
            ) {
                return RimeSchemaPatchResult(
                    source: source,
                    changed: false,
                    createdFile: false
                )
            }
            let itemIndent = String(
                repeating: " ",
                count: directIndent + 2
            )
            lines.insert(
                contentsOf: [
                    "\(itemIndent)\(Self.beginMarker)",
                    "\(itemIndent)- \(Self.filterValue)",
                    "\(itemIndent)\(Self.endMarker)",
                ],
                at: filterKeyIndex + 1
            )
            return RimeSchemaPatchResult(
                source: lines.joined(separator: "\n"),
                changed: true,
                createdFile: false
            )
        }

        for index in directChildIndices {
            let content = Self.contentBeforeComment(lines[index])
            let (rawKey, value) = Self.keyAndValue(content)
            let key = Self.unquoted(rawKey)
            if key == "engine" {
                throw RimeSchemaPatchError.unsupportedEngineStructure
            }
            if key.hasPrefix("engine/filters") {
                if key.hasPrefix("engine/filters/@"),
                    Self.unquoted(value) == Self.filterValue
                {
                    return RimeSchemaPatchResult(
                        source: source,
                        changed: false,
                        createdFile: false
                    )
                }
                throw RimeSchemaPatchError.unsupportedFilterList
            }
        }

        let keyIndent = String(repeating: " ", count: directIndent)
        let itemIndent = String(
            repeating: " ",
            count: directIndent + 2
        )
        lines.insert(
            contentsOf: [
                "\(keyIndent)engine/filters/+:",
                "\(itemIndent)\(Self.beginMarker)",
                "\(itemIndent)- \(Self.filterValue)",
                "\(itemIndent)\(Self.endMarker)",
            ],
            at: patchEnd
        )
        return RimeSchemaPatchResult(
            source: lines.joined(separator: "\n"),
            changed: true,
            createdFile: false
        )
    }

    func removeManagedFilter(
        from source: String,
        removingEmptyFilterKey: Bool = false
    ) -> String {
        var lines = source.components(separatedBy: "\n")
        let begins = lines.indices.filter { index in
            lines[index].trimmingCharacters(in: .whitespaces)
                == Self.beginMarker
        }
        let ends = lines.indices.filter { index in
            lines[index].trimmingCharacters(in: .whitespaces)
                == Self.endMarker
        }
        if begins.isEmpty, ends.isEmpty {
            return source
        }
        guard
            begins.count == 1,
            ends.count == 1,
            let begin = begins.first,
            let end = ends.first,
            begin < end,
            let parentIndex = Self.parentFilterKeyIndex(
                lines: lines,
                before: begin
            )
        else {
            return source
        }
        let managedBody = lines[(begin + 1)..<end]
            .filter { line in
                let trimmed = line.trimmingCharacters(
                    in: .whitespaces
                )
                return !trimmed.isEmpty && !trimmed.hasPrefix("#")
            }
        guard
            managedBody.count == 1,
            Self.scalarValue(in: managedBody[0]) == Self.filterValue,
            Self.indentation(of: managedBody[0])
                == Self.indentation(of: lines[begin]),
            Self.indentation(of: lines[end])
                == Self.indentation(of: lines[begin])
        else {
            return source
        }
        if let begin = begins.first,
            let end = ends.first
        {
            lines.removeSubrange(begin...end)
        }
        if removingEmptyFilterKey {
            lines = removingEmptyManagedFilterKey(
                from: lines,
                at: parentIndex
            )
        }
        return lines.joined(separator: "\n")
    }

    func containsFilter(in source: String) -> Bool {
        let lines = source.components(separatedBy: "\n")
        let patchIndices = Self.patchRootIndices(in: lines)
        guard patchIndices.count == 1, let patchIndex = patchIndices.first
        else {
            return false
        }
        let patchEnd = Self.endOfMapping(lines: lines, after: patchIndex)
        let children = ((patchIndex + 1)..<patchEnd).filter {
            !Self.contentBeforeComment(lines[$0])
                .trimmingCharacters(in: .whitespaces).isEmpty
        }
        guard
            let directIndent = children.first.map({
                Self.indentation(of: lines[$0])
            })
        else {
            return false
        }
        for index in children
        where Self.indentation(of: lines[index]) == directIndent {
            let (rawKey, value) = Self.keyAndValue(
                Self.contentBeforeComment(lines[index])
            )
            let key = Self.unquoted(rawKey)
            if key == "engine/filters/+", value.isEmpty {
                return Self.filterListContainsManagedFilter(
                    lines: lines,
                    keyIndex: index,
                    parentIndent: directIndent
                )
            }
            if key.hasPrefix("engine/filters"),
                key.hasPrefix("engine/filters/@"),
                Self.unquoted(value) == Self.filterValue
            {
                return true
            }
        }
        return false
    }

    private static func patchRootIndices(in lines: [String]) -> [Int] {
        lines.indices.filter { index in
            let content = contentBeforeComment(lines[index])
            let trimmed = content.trimmingCharacters(
                in: .whitespaces
            )
            guard
                !trimmed.isEmpty,
                indentation(of: content) == 0
            else {
                return false
            }
            let (key, _) = keyAndValue(content)
            return unquoted(key) == "patch"
        }
    }

    private static func containsYAMLAnchorOrAlias(
        in lines: [String]
    ) -> Bool {
        lines.contains { line in
            let content = contentBeforeComment(line)
                .trimmingCharacters(in: .whitespaces)
            guard !content.isEmpty else { return false }
            if content.hasPrefix("<<:")
                || content.hasPrefix("!")
            {
                return true
            }
            let tokens = content.split(
                whereSeparator: { $0.isWhitespace }
            )
            return tokens.contains { token in
                token.first == "&"
                    || token.first == "*"
                    || token.first == "!"
            }
        }
    }

    private static func containsUnsupportedDocumentSyntax(
        in lines: [String]
    ) -> Bool {
        lines.contains { line in
            if line.contains("\r") { return true }
            let content = contentBeforeComment(line)
            let trimmed = content.trimmingCharacters(
                in: .whitespaces
            )
            if trimmed == "---" || trimmed == "..." {
                return true
            }
            let leadingSpaces = content.prefix(
                while: { $0 == " " }
            ).count
            if content.dropFirst(leadingSpaces).first == "\t" {
                return true
            }
            let (rawKey, _) = keyAndValue(trimmed)
            return unquoted(rawKey).hasPrefix("__")
        }
    }

    private static func scalarValue(in line: String) -> String? {
        let content = contentBeforeComment(line)
            .trimmingCharacters(in: .whitespaces)
        guard !content.isEmpty else { return nil }
        let rawValue: String
        if content.hasPrefix("- ") {
            rawValue = String(content.dropFirst(2))
                .trimmingCharacters(in: .whitespaces)
        } else {
            let (_, value) = keyAndValue(content)
            rawValue = value
        }
        guard !rawValue.isEmpty else { return nil }
        return unquoted(rawValue)
    }

    private static func filterListContainsManagedFilter(
        lines: [String],
        keyIndex: Int,
        parentIndent: Int
    ) -> Bool {
        let end =
            ((keyIndex + 1)..<lines.count).first { index in
                let content = contentBeforeComment(lines[index])
                guard
                    !content.trimmingCharacters(in: .whitespaces).isEmpty
                else {
                    return false
                }
                return indentation(of: content) <= parentIndent
            } ?? lines.count
        return lines[(keyIndex + 1)..<end].contains { line in
            let content = contentBeforeComment(line)
                .trimmingCharacters(in: .whitespaces)
            return content.hasPrefix("- ")
                && unquoted(String(content.dropFirst(2)))
                    .trimmingCharacters(in: .whitespaces)
                    == filterValue
        }
    }

    private static func parentFilterKeyIndex(
        lines: [String],
        before markerIndex: Int
    ) -> Int? {
        guard markerIndex > 0 else { return nil }
        let markerIndent = indentation(of: lines[markerIndex])
        for index in stride(
            from: markerIndex - 1,
            through: 0,
            by: -1
        ) {
            let content = contentBeforeComment(lines[index])
                .trimmingCharacters(in: .whitespaces)
            guard !content.isEmpty else { continue }
            if indentation(of: lines[index]) < markerIndent {
                guard
                    content == "engine/filters/+:",
                    indentation(of: lines[index]) < markerIndent
                else {
                    return nil
                }
                return index
            }
        }
        return nil
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

    private static func keyAndValue(
        _ line: String
    ) -> (key: String, value: String) {
        guard let colon = line.firstIndex(of: ":") else {
            return (line.trimmingCharacters(in: .whitespaces), "")
        }
        let key = String(line[..<colon])
            .trimmingCharacters(in: .whitespaces)
        let value = String(line[line.index(after: colon)...])
            .trimmingCharacters(in: .whitespaces)
        return (key, value)
    }

    private static func indentation(of line: String) -> Int {
        line.prefix(while: { $0 == " " }).count
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

    private static func endOfMapping(
        lines: [String],
        after index: Int
    ) -> Int {
        guard index + 1 < lines.count else {
            return lines.count
        }
        for candidate in (index + 1)..<lines.count {
            let trimmed = lines[candidate].trimmingCharacters(
                in: .whitespaces
            )
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else {
                continue
            }
            if lines[candidate].first.map({
                !$0.isWhitespace
            }) == true {
                return candidate
            }
        }
        return lines.count
    }

    private static func isEffectivelyEmpty(_ source: String) -> Bool {
        source.components(separatedBy: "\n").allSatisfy { line in
            let trimmed = line.trimmingCharacters(
                in: .whitespaces
            )
            return trimmed.isEmpty || trimmed.hasPrefix("#")
        }
    }

    private func removingEmptyManagedFilterKey(
        from lines: [String],
        at keyIndex: Int
    ) -> [String] {
        guard lines.indices.contains(keyIndex) else {
            return lines
        }
        let keyIndent =
            lines[keyIndex].prefix(while: { $0 == " " }).count
        let firstSibling =
            ((keyIndex + 1)..<lines.count).first { index in
                let content = lines[index].trimmingCharacters(
                    in: .whitespaces
                )
                return !content.isEmpty
                    && lines[index].prefix(while: { $0 == " " }).count
                        <= keyIndent
            } ?? lines.count
        let hasChildren = lines[(keyIndex + 1)..<firstSibling]
            .contains { line in
                let content = line.trimmingCharacters(
                    in: .whitespaces
                )
                return !content.isEmpty && !content.hasPrefix("#")
            }
        guard !hasChildren else { return lines }
        var result = lines
        result.removeSubrange((keyIndex + 1)..<firstSibling)
        result.remove(at: keyIndex)
        return result
    }

    private static let managedPatchFile = """
        patch:
          engine/filters/+:
            # BEGIN GLINT RIME CANDIDATE BRIDGE
            - lua_filter@*glint.candidate_bridge
            # END GLINT RIME CANDIDATE BRIDGE

        """
}
