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
        guard
            !source.unicodeScalars.contains(
                UnicodeScalar("\r")
            )
        else {
            throw RimeSchemaPatchError.unsupportedEngineStructure
        }

        let lines = source.components(separatedBy: "\n")
        let markerIndices = lines.indices.filter { index in
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            return line == Self.beginMarker || line == Self.endMarker
        }
        if !markerIndices.isEmpty {
            guard
                Self.managedPatchBlock(in: lines) != nil
                    || Self.legacyManagedOverrideBlock(in: lines) != nil
                    || Self.legacyManagedFilterList(in: lines) != nil
            else {
                throw RimeSchemaPatchError.unsupportedFilterList
            }
            return RimeSchemaPatchResult(
                source: source,
                changed: false,
                createdFile: false
            )
        }
        try validateDocumentStructure(lines: lines)
        if containsFilter(in: source) {
            return RimeSchemaPatchResult(
                source: source,
                changed: false,
                createdFile: false
            )
        }

        let separator = source.hasSuffix("\n") ? "" : "\n"
        return RimeSchemaPatchResult(
            source: source + separator + Self.managedPatchFile,
            changed: true,
            createdFile: false
        )
    }

    func removeManagedFilter(
        from source: String,
        removingEmptyFilterKey: Bool = false
    ) -> String {
        var lines = source.components(separatedBy: "\n")
        if let block = Self.managedPatchBlock(in: lines) {
            lines.removeSubrange(block.begin...block.end)
            if lines.allSatisfy({
                $0.trimmingCharacters(in: .whitespaces).isEmpty
            }) {
                return ""
            }
            return lines.joined(separator: "\n")
        }
        if let block = Self.legacyManagedOverrideBlock(in: lines) {
            lines.removeSubrange(block.begin...block.end)
            return lines.joined(separator: "\n")
        }
        guard let block = Self.legacyManagedFilterList(in: lines) else {
            return source
        }
        lines.removeSubrange(block.begin...block.end)
        if removingEmptyFilterKey {
            lines = removeEmptyFilterKey(
                from: lines,
                at: block.parent
            )
        }
        return lines.joined(separator: "\n")
    }

    func containsFilter(in source: String) -> Bool {
        let lines = source.components(separatedBy: "\n")
        if Self.managedPatchBlock(in: lines) != nil
            || Self.legacyManagedOverrideBlock(in: lines) != nil
            || Self.legacyManagedFilterList(in: lines) != nil
        {
            return true
        }
        let patchIndices = Self.patchRootIndices(in: lines)
        guard patchIndices.count == 1, let patchIndex = patchIndices.first
        else {
            return false
        }
        let patchEnd = Self.endOfTopLevelMapping(
            lines: lines,
            after: patchIndex
        )
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
            if key == "engine", value.isEmpty,
                Self.nestedEngineContainsFilter(
                    lines: lines,
                    engineIndex: index,
                    engineIndent: directIndent,
                    limit: patchEnd
                )
            {
                return true
            }
            if key == "engine/filters/+", value.isEmpty {
                return Self.filterListContainsFilter(
                    lines: lines,
                    keyIndex: index,
                    parentIndent: directIndent
                )
            }
            if key == "engine/filters/+",
                Self.inlineListContainsFilter(value)
            {
                return true
            }
            if key.hasPrefix("engine/filters/@"),
                Self.unquoted(value) == Self.filterValue
            {
                return true
            }
        }
        return false
    }

    func containsManagedFilter(in source: String) -> Bool {
        let lines = source.components(separatedBy: "\n")
        return Self.managedPatchBlock(in: lines) != nil
            || Self.legacyManagedOverrideBlock(in: lines) != nil
            || Self.legacyManagedFilterList(in: lines) != nil
    }

    private func validateDocumentStructure(
        lines: [String]
    ) throws {
        var patchRootCount = 0
        var rootPatchCount = 0
        for line in lines {
            let content = Self.contentBeforeComment(line)
            let trimmed = content.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if trimmed == "---" || trimmed == "..." {
                throw RimeSchemaPatchError.unsupportedEngineStructure
            }
            let indent = Self.indentation(of: content)
            if content.dropFirst(indent).first == "\t" {
                throw RimeSchemaPatchError.unsupportedEngineStructure
            }
            guard indent == 0 else { continue }
            let key = Self.unquoted(Self.keyAndValue(content).key)
            if key == "patch" {
                patchRootCount += 1
            } else if key == "__patch" {
                rootPatchCount += 1
            }
        }
        guard patchRootCount <= 1, rootPatchCount == 0 else {
            throw RimeSchemaPatchError.missingPatchRoot
        }
    }

    private static func nestedEngineContainsFilter(
        lines: [String],
        engineIndex: Int,
        engineIndent: Int,
        limit: Int
    ) -> Bool {
        let engineEnd =
            ((engineIndex + 1)..<limit).first { index in
                let content = contentBeforeComment(lines[index])
                guard
                    !content.trimmingCharacters(in: .whitespaces).isEmpty
                else {
                    return false
                }
                return indentation(of: content) <= engineIndent
            } ?? limit
        let children = ((engineIndex + 1)..<engineEnd).filter {
            !contentBeforeComment(lines[$0])
                .trimmingCharacters(in: .whitespaces).isEmpty
        }
        guard
            let directIndent = children.first.map({
                indentation(of: lines[$0])
            })
        else {
            return false
        }
        for index in children
        where indentation(of: lines[index]) == directIndent {
            let (rawKey, value) = keyAndValue(
                contentBeforeComment(lines[index])
            )
            let key = unquoted(rawKey)
            if key == "filters", value.isEmpty {
                return filterListContainsFilter(
                    lines: lines,
                    keyIndex: index,
                    parentIndent: directIndent
                )
            }
            if key == "filters", inlineListContainsFilter(value) {
                return true
            }
        }
        return false
    }

    private static func patchRootIndices(in lines: [String]) -> [Int] {
        lines.indices.filter { index in
            let content = contentBeforeComment(lines[index])
            let trimmed = content.trimmingCharacters(in: .whitespaces)
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

    private static func inlineListContainsFilter(_ source: String) -> Bool {
        let value = source.trimmingCharacters(in: .whitespaces)
        guard value.hasPrefix("["), value.hasSuffix("]") else {
            return false
        }
        return value.dropFirst().dropLast()
            .split(separator: ",", omittingEmptySubsequences: true)
            .contains {
                unquoted($0.trimmingCharacters(in: .whitespaces))
                    == filterValue
            }
    }

    private static func filterListContainsFilter(
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

    private static func legacyManagedFilterList(
        in lines: [String]
    ) -> (begin: Int, end: Int, parent: Int)? {
        guard
            let block = markerBlock(
                in: lines,
                expectedBodyCount: 1
            ),
            let parent = parentFilterKeyIndex(
                lines: lines,
                before: block.begin
            ),
            let value = scalarValue(in: lines[block.begin + 1]),
            value == filterValue,
            indentation(of: lines[block.begin + 1])
                == indentation(of: lines[block.begin]),
            indentation(of: lines[block.end])
                == indentation(of: lines[block.begin])
        else {
            return nil
        }
        return (block.begin, block.end, parent)
    }

    private static func legacyManagedOverrideBlock(
        in lines: [String]
    ) -> (begin: Int, end: Int)? {
        guard let block = markerBlock(in: lines, expectedBodyCount: 1)
        else {
            return nil
        }
        let indent = indentation(of: lines[block.begin])
        guard
            indentation(of: lines[block.begin + 1]) == indent,
            indentation(of: lines[block.end]) == indent
        else {
            return nil
        }
        let (rawKey, value) = keyAndValue(
            contentBeforeComment(lines[block.begin + 1])
        )
        guard
            unquoted(rawKey) == "engine/filters/@before 0",
            unquoted(value) == Self.filterValue
        else {
            return nil
        }
        return (block.begin, block.end)
    }

    private static func managedPatchBlock(
        in lines: [String]
    ) -> (begin: Int, end: Int)? {
        guard let block = markerBlock(in: lines, expectedBodyCount: 3)
        else {
            return nil
        }
        guard
            indentation(of: lines[block.begin]) == 0,
            indentation(of: lines[block.end]) == 0
        else {
            return nil
        }
        let patch = keyAndValue(
            contentBeforeComment(lines[block.begin + 1])
        )
        let patchMerge = keyAndValue(
            contentBeforeComment(lines[block.begin + 2])
        )
        let filter = keyAndValue(
            contentBeforeComment(lines[block.begin + 3])
        )
        guard
            unquoted(patch.key) == "__patch",
            patch.value.isEmpty,
            indentation(of: lines[block.begin + 2]) == 2,
            unquoted(patchMerge.key) == "patch/+",
            patchMerge.value.isEmpty,
            indentation(of: lines[block.begin + 3]) == 4,
            unquoted(filter.key) == "engine/filters/@before 0",
            unquoted(filter.value) == Self.filterValue
        else {
            return nil
        }
        return (block.begin, block.end)
    }

    private static func markerBlock(
        in lines: [String],
        expectedBodyCount: Int
    ) -> (begin: Int, end: Int)? {
        let begins = lines.indices.filter {
            lines[$0].trimmingCharacters(in: .whitespaces)
                == Self.beginMarker
        }
        let ends = lines.indices.filter {
            lines[$0].trimmingCharacters(in: .whitespaces)
                == Self.endMarker
        }
        guard
            begins.count == 1,
            ends.count == 1,
            let begin = begins.first,
            let end = ends.first,
            end == begin + expectedBodyCount + 1
        else {
            return nil
        }
        return (begin, end)
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

    private static func endOfTopLevelMapping(
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

    private func removeEmptyFilterKey(
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
        # BEGIN GLINT RIME CANDIDATE BRIDGE
        __patch:
          patch/+:
            engine/filters/@before 0: lua_filter@*glint.candidate_bridge
        # END GLINT RIME CANDIDATE BRIDGE

        """
}
