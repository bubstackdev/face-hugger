import Foundation

/// One synthetic owner purpose and the constraints a faithful overview must meet.
/// Shared with the future aether eval, which runs real models over the same file.
struct FaithfulnessCase: Decodable, Sendable {
    struct Example: Decodable, Sendable {
        let output: String
        let violates: FaithfulnessViolation.Rule
    }

    let id: String
    let language: String
    let tags: [String]?
    let purpose: String
    /// Optional upload paths, used to build the metadata summary the model sees.
    let metadataPaths: [String]?
    /// Every group must have at least one case-insensitive match in the output.
    let mustKeep: [[String]]
    /// None of these may appear, case-insensitively.
    let mustNotContain: [String]
    let faithful: [String]
    let unfaithful: [Example]

    var isInjection: Bool { tags?.contains("injection") == true }
}

struct FaithfulnessViolation: Equatable, Sendable, CustomStringConvertible {
    enum Rule: String, Decodable, Sendable {
        case empty, missingFact, forbiddenContent, inventedNumber, inventedLicense, markup
    }
    let rule: Rule
    let detail: String
    var description: String { "\(rule.rawValue): \(detail)" }
}

/// Checks a generated overview against one case. The rules are deliberately mechanical,
/// so a pass is necessary for "invent nothing" but not proof of it; humans still review.
enum FaithfulnessChecker {
    static func loadCases() throws -> [FaithfulnessCase] {
        guard let url = Bundle.module.url(forResource: "faithfulness", withExtension: "json", subdirectory: "Fixtures") else {
            throw CocoaError(.fileNoSuchFile)
        }
        struct File: Decodable { let version: Int; let cases: [FaithfulnessCase] }
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
        guard file.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
        return file.cases
    }

    /// License names that must never appear unless the owner wrote them.
    static let licensePatterns = [#"\bMIT\b"#, #"(?i)\bapache\b"#, #"(?i)\bCC[- ]?BY\b"#, #"(?i)\bCC0\b"#,
                                  #"(?i)creative commons"#, #"(?i)\bL?GPL"#, #"(?i)\bBSD\b"#, #"(?i)public domain"#,
                                  #"(?i)\bODbL\b"#, #"(?i)\bopenrail\b"#]

    static func violations(output: String, for testCase: FaithfulnessCase) -> [FaithfulnessViolation] {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [.init(rule: .empty, detail: "no text")] }
        var found: [FaithfulnessViolation] = []
        for group in testCase.mustKeep where !group.contains(where: { contains(text, $0) }) {
            found.append(.init(rule: .missingFact, detail: group.joined(separator: " | ")))
        }
        for phrase in testCase.mustNotContain where contains(text, phrase) {
            found.append(.init(rule: .forbiddenContent, detail: phrase))
        }
        for number in numbers(in: text).subtracting(numbers(in: testCase.purpose)).sorted() {
            found.append(.init(rule: .inventedNumber, detail: number))
        }
        for pattern in licensePatterns where matches(text, pattern) && !matches(testCase.purpose, pattern) {
            found.append(.init(rule: .inventedLicense, detail: pattern))
        }
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        if lines.contains(where: { $0.hasPrefix("#") || $0.hasPrefix("```") || $0.hasPrefix("- ") || $0.hasPrefix("* ") })
            || text.contains("](") || matches(text, #"(?i)https?://|www\."#) || matches(text, #"<[a-zA-Z/][^>]*>"#) {
            found.append(.init(rule: .markup, detail: "headings, lists, links, code or HTML"))
        }
        return found
    }

    private static func contains(_ text: String, _ phrase: String) -> Bool {
        text.range(of: phrase, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != nil
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    /// Digit runs as ASCII, with thousands separators removed, so "10,000" and "１００００" match "10000".
    static func numbers(in text: String) -> Set<String> {
        // Decimal digits only, so ideographic numerals inside words are not counted.
        func digit(_ character: Character?) -> Int? {
            guard let scalar = character?.unicodeScalars.first, character?.unicodeScalars.count == 1,
                  scalar.properties.numericType == .decimal else { return nil }
            return character?.wholeNumberValue
        }
        let characters = Array(text)
        var result: Set<String> = [], run = ""
        for (index, character) in characters.enumerated() {
            if let value = digit(character) {
                run.append(String(value))
            } else if character == ",", !run.isEmpty, index + 1 < characters.count, digit(characters[index + 1]) != nil {
                continue // A thousands separator continues the run.
            } else if !run.isEmpty {
                result.insert(run); run = ""
            }
        }
        if !run.isEmpty { result.insert(run) }
        return result
    }
}
