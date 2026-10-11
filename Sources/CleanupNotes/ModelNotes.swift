import Foundation

public enum ModelNotesError: Error, Equatable, Sendable, LocalizedError {
    case invalidRequest(String)
    case unavailable(String)
    case busy
    case timedOut
    case transport(String)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRequest(let detail): "Invalid notes request: \(detail)"
        case .unavailable(let detail): "Model notes are unavailable: \(detail)"
        case .busy: "A notes request is already running."
        case .timedOut: "The notes request did not finish before its deadline."
        case .transport(let detail): "Notes transport failed: \(detail)"
        case .invalidResponse(let detail): "The notes endpoint returned an invalid response: \(detail)"
        }
    }
}

/// A note a model wrote, with the turns it rests on. Unlike `NoteItem` it is
/// not a quote; the citations are what make it checkable.
public struct CitedNote: Codable, Equatable, Sendable {
    public let text: String
    /// Indexes into `TranscriptResult.turns`, at least one, each existing.
    public let turns: [Int]
    public init(text: String, turns: [Int]) { self.text = text; self.turns = turns }
}

/// Notes a model wrote over a cleaned transcript: a summary and categorized
/// items, every one citing turns that exist. A layer over `Notes`, never a
/// replacement for it: the deterministic notes and the full transcript stay
/// the record, and a host that cannot obtain these renders without them.
public struct ModelNotes: Codable, Equatable, Sendable {
    public let summary: [CitedNote]
    public let actionItems: [CitedNote]
    public let decisions: [CitedNote]
    public let questions: [CitedNote]
    public let provenance: Provenance
    public var timings: CleanupTimings
    public let warnings: [String]

    public static let maxEntries = 256
    public static let maxTextBytes = 1_024
    public static let maxCitations = 64

    public init(summary: [CitedNote], actionItems: [CitedNote], decisions: [CitedNote], questions: [CitedNote],
                provenance: Provenance, timings: CleanupTimings = .init(), warnings: [String] = []) {
        self.summary = summary; self.actionItems = actionItems; self.decisions = decisions; self.questions = questions
        self.provenance = provenance; self.timings = timings; self.warnings = warnings
    }

    public var entries: [CitedNote] { summary + actionItems + decisions + questions }

    /// What a client checks before model notes reach the host: bounded counts,
    /// single-line bounded nonempty text, and citations that all point at turns
    /// of `source`. A note without a citation is refused outright.
    public func validate(against source: TranscriptResult) throws {
        for list in [summary, actionItems, decisions, questions] where list.count > Self.maxEntries {
            throw ModelNotesError.invalidResponse("too many notes")
        }
        for note in entries {
            guard !note.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  note.text.utf8.count <= Self.maxTextBytes, !note.text.contains(where: \.isNewline) else {
                throw ModelNotesError.invalidResponse("note text must be one nonempty line of at most \(Self.maxTextBytes) bytes")
            }
            guard !note.turns.isEmpty, note.turns.count <= Self.maxCitations,
                  note.turns.allSatisfy({ source.turns.indices.contains($0) }) else {
                throw ModelNotesError.invalidResponse("every note must cite existing turns")
            }
        }
        guard timings.isValid else { throw ModelNotesError.invalidResponse("timings") }
        guard warnings.count <= 64, warnings.allSatisfy({ $0.utf8.count <= 256 }) else {
            throw ModelNotesError.invalidResponse("warnings")
        }
    }
}
