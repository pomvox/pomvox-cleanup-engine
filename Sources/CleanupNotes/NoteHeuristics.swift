import Foundation

/// The cue set that turns cleaned sentences into note candidates. Plain
/// pattern matching, versioned so a change in what counts as an action item
/// is visible in `Notes.heuristics`. Hosts may supply their own cue lists; the
/// version string should change with them.
public struct NoteHeuristics: Sendable {
    public static let version = "pomvox-notes-v0.1"
    public static let `default` = NoteHeuristics()

    /// Regular-expression sources, matched case-insensitively against one sentence.
    public let actionCues: [String]
    public let decisionCues: [String]
    public let version: String

    /// Nil when the cue list is empty: nothing of that kind is ever filed.
    private let action: NSRegularExpression?
    private let decision: NSRegularExpression?

    /// Throws when a cue is not a valid pattern. Empty lists are allowed.
    public init(actionCues: [String], decisionCues: [String], version: String) throws {
        self.actionCues = actionCues; self.decisionCues = decisionCues; self.version = version
        action = try Self.compile(actionCues)
        decision = try Self.compile(decisionCues)
    }

    private init() {
        actionCues = Self.defaultActionCues
        decisionCues = Self.defaultDecisionCues
        version = Self.version
        action = try! Self.compile(Self.defaultActionCues)
        decision = try! Self.compile(Self.defaultDecisionCues)
    }

    /// Spoken commitments and deadlines. Broad on purpose: these are candidates
    /// for a person to keep or discard, and a missed commitment costs more than
    /// a spurious one.
    public static let defaultActionCues: [String] = [
        #"\baction items?\b"#, #"\bto-?dos?\b"#, #"\bfollow(?:ing)?[ -]?up\b"#,
        #"\bi(?:'ll| will| need to| have to| am going to| can)\b"#,
        #"\bwe(?:'ll| will| need to| have to| should| must| are going to)\b"#,
        #"\b(?:you|he|she|they)(?:'ll| will| need to| should| must)\b"#,
        #"\bneeds? to\b"#, #"\bmake sure\b"#, #"\bremind(?:er)?\b"#, #"\btake care of\b"#,
        #"\bby (?:monday|tuesday|wednesday|thursday|friday|saturday|sunday|tomorrow|tonight|next week|next month|end of (?:day|week|month)|eod|eow|eom)\b"#,
        #"\bdue\b"#, #"\bdeadline\b"#, #"\bassign(?:ed)?\b"#, #"\bowner\b"#, #"\bschedule\b"#,
    ]

    /// Spoken conclusions.
    public static let defaultDecisionCues: [String] = [
        #"\bdecided\b"#, #"\bdecision\b"#, #"\bagreed?\b"#, #"\bagreement\b"#,
        #"\b(?:let's|we'll|we will|we're|we are|i'm|i am) go(?:ing)? with\b"#,
        #"\bsettled on\b"#, #"\bapproved\b"#, #"\bsign(?:ed)? off\b"#, #"\bfinal(?:ized|ised)?\b"#,
        #"\bconsensus\b"#, #"\bno longer\b"#, #"\binstead of\b"#,
    ]

    private static func compile(_ sources: [String]) throws -> NSRegularExpression? {
        guard !sources.isEmpty else { return nil }
        return try NSRegularExpression(pattern: sources.map { "(?:" + $0 + ")" }.joined(separator: "|"),
                                       options: [.caseInsensitive])
    }

    /// One sentence or list line of a turn, with its UTF-8 byte range. `text` is
    /// exactly `turn.utf8[start..<end]`.
    public struct Sentence: Equatable, Sendable {
        public let text: String
        public let start: Int
        public let end: Int
        public let isListLine: Bool
    }

    /// Split a turn into sentences without changing a byte: a line is cut at
    /// `.`, `!` or `?` followed by whitespace, and at line breaks; a list line
    /// (`- item`, `1. item`) is one unit with its marker stripped. Surrounding
    /// whitespace is excluded from each range. Empty pieces are dropped.
    public func sentences(in text: String) -> [Sentence] {
        var pieces: [Sentence] = []
        var lineStart = text.startIndex
        while lineStart < text.endIndex {
            let lineEnd = text[lineStart...].firstIndex(where: \.isNewline) ?? text.endIndex
            let line = text[lineStart..<lineEnd]
            if let marker = Self.listMarkerEnd(of: line) {
                append(&pieces, text, from: marker, to: lineEnd, isListLine: true)
            } else {
                var pieceStart = lineStart
                var index = lineStart
                while index < lineEnd {
                    let character = text[index]
                    let next = text.index(after: index)
                    if ".!?".contains(character), next == lineEnd || text[next].isWhitespace {
                        append(&pieces, text, from: pieceStart, to: next, isListLine: false)
                        pieceStart = next
                    }
                    index = next
                }
                append(&pieces, text, from: pieceStart, to: lineEnd, isListLine: false)
            }
            lineStart = lineEnd < text.endIndex ? text.index(after: lineEnd) : lineEnd
        }
        return pieces
    }

    private func append(_ pieces: inout [Sentence], _ text: String, from: String.Index, to: String.Index,
                        isListLine: Bool) {
        var lower = from, upper = to
        while lower < upper, text[lower].isWhitespace { lower = text.index(after: lower) }
        while upper > lower, text[text.index(before: upper)].isWhitespace { upper = text.index(before: upper) }
        guard lower < upper else { return }
        pieces.append(Sentence(text: String(text[lower..<upper]),
                               start: text.utf8.distance(from: text.startIndex, to: lower),
                               end: text.utf8.distance(from: text.startIndex, to: upper),
                               isListLine: isListLine))
    }

    /// The index after a `- ` or `12. ` marker; nil when the line is not a list item.
    /// Same shape `CleanupLogic` accepts as a list line.
    static func listMarkerEnd(of line: Substring) -> Substring.Index? {
        if line.hasPrefix("- ") { return line.index(line.startIndex, offsetBy: 2) }
        let digits = line.prefix(while: { $0.isASCII && $0.isNumber })
        guard !digits.isEmpty, line[digits.endIndex...].hasPrefix(". ") else { return nil }
        return line.index(digits.endIndex, offsetBy: 2)
    }

    /// The kind a sentence is filed under, or nil for ordinary speech. A list
    /// line is always a list item; a sentence ending in `?` is a question;
    /// action cues win over decision cues.
    public func classify(_ sentence: String, isListLine: Bool) -> NoteKind? {
        if isListLine { return .listItem }
        if sentence.hasSuffix("?") { return .question }
        let range = NSRange(sentence.startIndex..<sentence.endIndex, in: sentence)
        if action?.firstMatch(in: sentence, options: [], range: range) != nil { return .actionItem }
        if decision?.firstMatch(in: sentence, options: [], range: range) != nil { return .decision }
        return nil
    }
}
