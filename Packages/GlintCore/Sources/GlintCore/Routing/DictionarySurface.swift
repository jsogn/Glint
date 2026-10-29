import Foundation

public enum DictionarySurface {
    public static func split(_ text: String) -> [String] {
        text.split(separator: ";")
            .compactMap { normalize(String($0)) }
    }

    public static func normalize(_ text: String) -> String? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let opening = value.firstIndex(of: "(") {
            guard let closing = value[opening...].firstIndex(of: ")") else {
                value = String(value[..<opening])
                break
            }
            value.removeSubrange(opening...closing)
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        value = value.split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        for prefix in ["to ", "the ", "a ", "an ", "be ", "of "] {
            if value.lowercased().hasPrefix(prefix) {
                value = String(value.dropFirst(prefix.count))
                break
            }
        }
        value = trimSurfacePunctuation(value)
        guard !value.isEmpty,
            !containsHan(value),
            !isMetadata(value)
        else {
            return nil
        }
        return value
    }

    private static func trimSurfacePunctuation(_ value: String) -> String {
        let nonPeriodPunctuation = CharacterSet.punctuationCharacters
            .subtracting(CharacterSet(charactersIn: "."))
        var result = value.trimmingCharacters(
            in: .whitespacesAndNewlines.union(nonPeriodPunctuation)
        )
        guard result.last == ".", !endsWithAbbreviation(result) else {
            return result
        }
        result.removeLast()
        return result.trimmingCharacters(
            in: .whitespacesAndNewlines.union(nonPeriodPunctuation)
        )
    }

    private static func endsWithAbbreviation(_ value: String) -> Bool {
        guard
            let lastWord = value.lowercased()
                .split(whereSeparator: \.isWhitespace)
                .last
        else {
            return false
        }
        if abbreviationSuffixes.contains(String(lastWord)) {
            return true
        }
        if lastWord.count == 2, lastWord.first?.isLetter == true {
            return true
        }
        return lastWord.count >= 4 && lastWord.filter { $0 == "." }.count >= 2
    }

    public static func penalty(for text: String) -> Double {
        let words = text.split(whereSeparator: \.isWhitespace)
        var penalty = min(
            0.20,
            max(0, Double(words.count - 3)) * 0.04
        )
        penalty += min(
            0.12,
            max(0, Double(text.count - 28)) * 0.005
        )
        if text.lowercased().hasPrefix("surname ") {
            penalty += 0.25
        }
        return penalty
    }

    /// Dictionary glosses are not always concise translations.
    /// Keep compact surfaces and reject prose that would read as a definition.
    public static func isDisplayable(_ text: String) -> Bool {
        let words = text.split(whereSeparator: \.isWhitespace)
        let value = text.lowercased()
        let paddedValue = " \(value) "
        return text.count <= 48
            && words.count <= 8
            && !explanatoryPrefixes.contains(where: value.hasPrefix)
            && !explanatoryFragments.contains(where: paddedValue.contains)
            && !hasExplanatoryAppositive(value)
    }

    private static func hasExplanatoryAppositive(
        _ value: String
    ) -> Bool {
        guard let comma = value.firstIndex(of: ",") else {
            return false
        }
        let prefixWordCount = value[..<comma]
            .split(whereSeparator: \.isWhitespace)
            .count
        let suffix = value[value.index(after: comma)...]
        var tokens =
            suffix
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        while let first = tokens.first,
            ["a", "an", "the"].contains(first)
        {
            tokens.removeFirst()
        }
        guard let first = tokens.first else { return false }
        if ["aka", "formerly", "located"].contains(first) {
            return true
        }
        if first == "one", tokens.dropFirst().first == "of" {
            return true
        }
        if first == "also",
            let next = tokens.dropFirst().first,
            next == "called" || next == "known"
        {
            return true
        }
        if prefixWordCount > 1,
            tokens.prefix(4).contains(where: appositiveHeadNouns.contains)
        {
            return true
        }
        if appositiveHeadNouns.contains(first) {
            if prefixWordCount > 1 {
                return true
            }
            if let next = tokens.dropFirst().first,
                appositivePrepositions.contains(next)
            {
                return true
            }
            return false
        }
        return descriptorNationalities.contains(first)
            && tokens.dropFirst().contains(where: appositiveHeadNouns.contains)
    }

    private static let abbreviationSuffixes: Set<String> = [
        "co.",
        "corp.",
        "dr.",
        "etc.",
        "inc.",
        "jr.",
        "ltd.",
        "mr.",
        "mrs.",
        "ms.",
        "sr.",
        "st.",
    ]

    private static let appositivePrepositions: Set<String> = [
        "at",
        "from",
        "in",
        "of",
        "on",
        "with",
    ]

    private static let appositiveHeadNouns: Set<String> = [
        "abbreviation",
        "acronym",
        "actor",
        "actress",
        "agency",
        "animal",
        "app",
        "application",
        "artist",
        "author",
        "band",
        "bank",
        "belief",
        "bird",
        "businessman",
        "businesswoman",
        "capital",
        "character",
        "chemical",
        "city",
        "club",
        "code",
        "committee",
        "company",
        "compound",
        "concept",
        "condition",
        "corporation",
        "country",
        "county",
        "currency",
        "deity",
        "device",
        "dialect",
        "dish",
        "disease",
        "district",
        "doctrine",
        "drink",
        "emperor",
        "festival",
        "film",
        "fish",
        "food",
        "game",
        "gang",
        "general",
        "god",
        "goddess",
        "group",
        "insect",
        "institution",
        "instrument",
        "island",
        "islands",
        "king",
        "lake",
        "language",
        "leader",
        "machine",
        "manga",
        "mark",
        "mathematician",
        "missionary",
        "monk",
        "movement",
        "municipality",
        "musician",
        "name",
        "novel",
        "number",
        "officer",
        "organization",
        "organisation",
        "painter",
        "party",
        "peninsula",
        "philosopher",
        "physicist",
        "plant",
        "poet",
        "politician",
        "president",
        "prefecture",
        "priest",
        "province",
        "queen",
        "region",
        "revolutionary",
        "river",
        "ruler",
        "sauce",
        "scholar",
        "scientist",
        "sea",
        "series",
        "singer",
        "soldier",
        "species",
        "state",
        "strait",
        "symbol",
        "syndrome",
        "system",
        "team",
        "term",
        "territory",
        "theory",
        "title",
        "tool",
        "town",
        "tree",
        "university",
        "village",
        "volcano",
        "website",
        "writer",
    ]

    private static let descriptorNationalities: Set<String> = [
        "american",
        "asian",
        "australian",
        "austrian",
        "belgian",
        "british",
        "byzantine",
        "canadian",
        "chinese",
        "dutch",
        "english",
        "european",
        "french",
        "german",
        "greek",
        "indian",
        "iranian",
        "iraqi",
        "italian",
        "japanese",
        "korean",
        "ottoman",
        "portuguese",
        "roman",
        "russian",
        "spanish",
        "swedish",
        "swiss",
        "taiwanese",
        "turkish",
        "uk",
        "us",
        "usa",
    ]

    private static let explanatoryPrefixes = [
        "degree of ",
        "emergency number for ",
        "fig. ",
        "lit. ",
        "name of ",
        "nickname of ",
        "one who ",
        "person who ",
        "refers to ",
        "someone who ",
        "system where ",
        "used as ",
        "used for ",
        "used in ",
    ]

    private static let explanatoryFragments = [
        " also called ",
        " also known as ",
        " established in ",
        " founded in ",
        " i.e. ",
        " located in ",
        " namely ",
    ]

    private static func containsHan(_ text: String) -> Bool {
        text.unicodeScalars.contains {
            (0x3400...0x4DBF).contains($0.value)
                || (0x4E00...0x9FFF).contains($0.value)
        }
    }

    private static func isMetadata(_ text: String) -> Bool {
        let value = text.lowercased()
        return value.hasPrefix("see ")
            || value.hasPrefix("variant of ")
            || value.hasPrefix("old variant ")
            || value.hasPrefix("abbr. for ")
            || value.hasPrefix("taiwan pr.")
    }
}
