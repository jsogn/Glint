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
        if containsFilter(in: source) {
            return RimeSchemaPatchResult(
                source: source,
                changed: false,
                createdFile: false
            )
        }

        var lines = source.components(separatedBy: "\n")
        guard
            let patchIndex = lines.firstIndex(where: {
                $0 == "patch:"
            })
        else {
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

        let patchEnd = Self.endOfMapping(
            lines: lines,
            after: patchIndex
        )
        let childIndices = (patchIndex + 1)..<patchEnd
        let filterKeyIndex = childIndices.first {
            let trimmed = lines[$0].trimmingCharacters(
                in: .whitespaces
            )
            return trimmed.hasPrefix("engine/filters/+:")
        }

        if let filterKeyIndex {
            let keyLine = lines[filterKeyIndex]
            let value =
                keyLine
                .split(
                    separator: ":",
                    maxSplits: 1,
                    omittingEmptySubsequences: false
                )
                .dropFirst()
                .joined(separator: ":")
                .trimmingCharacters(in: .whitespaces)
            guard value.isEmpty else {
                throw RimeSchemaPatchError.unsupportedFilterList
            }
            lines.insert(
                contentsOf: Self.managedFilterItems,
                at: filterKeyIndex + 1
            )
            return RimeSchemaPatchResult(
                source: lines.joined(separator: "\n"),
                changed: true,
                createdFile: false
            )
        }

        for index in childIndices {
            let trimmed = lines[index].trimmingCharacters(
                in: .whitespaces
            )
            if trimmed == "engine:" {
                throw RimeSchemaPatchError.unsupportedEngineStructure
            }
            if trimmed.hasPrefix("engine/filters") {
                throw RimeSchemaPatchError.unsupportedFilterList
            }
        }

        lines.insert(
            contentsOf: [
                "  engine/filters/+:",
                "    \(Self.beginMarker)",
                "    - \(Self.filterValue)",
                "    \(Self.endMarker)",
            ],
            at: patchEnd
        )
        return RimeSchemaPatchResult(
            source: lines.joined(separator: "\n"),
            changed: true,
            createdFile: false
        )
    }

    func removeManagedFilter(from source: String) -> String {
        var lines = source.components(separatedBy: "\n")
        if let begin = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces)
                == Self.beginMarker
        }),
            let end = lines[begin...].firstIndex(where: {
                $0.trimmingCharacters(in: .whitespaces)
                    == Self.endMarker
            })
        {
            lines.removeSubrange(begin...end)
        } else {
            lines.removeAll { line in
                let trimmed = line.trimmingCharacters(
                    in: .whitespaces
                )
                return !trimmed.hasPrefix("#")
                    && trimmed.contains(Self.filterValue)
            }
        }
        lines = removingEmptyManagedFilterKey(from: lines)
        return lines.joined(separator: "\n")
    }

    func containsFilter(in source: String) -> Bool {
        source.components(separatedBy: "\n").contains { line in
            let trimmed = line.trimmingCharacters(
                in: .whitespaces
            )
            return !trimmed.hasPrefix("#")
                && trimmed.contains(Self.filterValue)
        }
    }

    func isPristineManagedPatch(_ source: String) -> Bool {
        source == Self.managedPatchFile
    }

    func isEffectivelyEmptyPatchDocument(_ source: String) -> Bool {
        source.components(separatedBy: "\n").allSatisfy { line in
            let trimmed = line.trimmingCharacters(
                in: .whitespaces
            )
            return trimmed.isEmpty
                || trimmed.hasPrefix("#")
                || trimmed == "patch:"
        }
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
        from lines: [String]
    ) -> [String] {
        guard
            let keyIndex = lines.firstIndex(where: {
                $0.trimmingCharacters(in: .whitespaces)
                    == "engine/filters/+:"
            })
        else {
            return lines
        }
        let keyIndent = lines[keyIndex]
            .prefix(while: { $0 == " " })
            .count
        let end = (keyIndex + 1)..<lines.count
        let firstSibling =
            end.first { index in
                let content = lines[index]
                    .trimmingCharacters(in: .whitespaces)
                return !content.isEmpty
                    && (lines[index].prefix(while: { $0 == " " }).count
                        <= keyIndent)
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

    private static let managedFilterItems = [
        "    \(beginMarker)",
        "    - \(filterValue)",
        "    \(endMarker)",
    ]

    private static let managedPatchFile = """
        patch:
          engine/filters/+:
            # BEGIN GLINT RIME CANDIDATE BRIDGE
            - lua_filter@*glint.candidate_bridge
            # END GLINT RIME CANDIDATE BRIDGE

        """
}
