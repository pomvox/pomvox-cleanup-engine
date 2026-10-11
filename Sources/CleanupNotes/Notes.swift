@_exported import CleanupCore
import Foundation

/// What a note candidate is. Heuristic labels over verbatim text, not understanding.
public enum NoteKind: String, Codable, Sendable, CaseIterable {
    case actionItem, decision, question, listItem
}

/// One candidate, quoted verbatim from a cleaned turn. `start..<end` is the
/// UTF-8 byte range of `text` inside `TranscriptResult.turns[turnIndex].text`,
/// in the same form as `TextEdit`, so a host can highlight the source.
public struct NoteItem: Codable, Equatable, Sendable {
    public let kind: NoteKind
    public let text: String
    public let speaker: SpeakerLabel?
    public let turnIndex: Int
    public let start: Int
    public let end: Int

    public init(kind: NoteKind, text: String, speaker: SpeakerLabel?, turnIndex: Int, start: Int, end: Int) {
        self.kind = kind; self.text = text; self.speaker = speaker
        self.turnIndex = turnIndex; self.start = start; self.end = end
    }
}

/// Who spoke, how much. `speaker` is nil for unattributed turns.
public struct Participant: Codable, Equatable, Sendable {
    public let speaker: SpeakerLabel?
    public let turns: Int
    /// Whitespace-separated tokens of the cleaned turns, list markers included.
    public let words: Int
    /// Summed turn spans; nil when any of the participant's turns has no span.
    public let speakingSeconds: TimeInterval?

    public init(speaker: SpeakerLabel?, turns: Int, words: Int, speakingSeconds: TimeInterval?) {
        self.speaker = speaker; self.turns = turns; self.words = words; self.speakingSeconds = speakingSeconds
    }
}

/// Deterministic notes over a cleaned transcript. No model: every item is a
/// verbatim quote with provenance, participants are counts, and the transcript
/// itself is carried whole. `heuristics` names the cue set that produced the
/// items so a host can log it next to the output.
public struct Notes: Codable, Equatable, Sendable {
    public let participants: [Participant]
    public let items: [NoteItem]
    public let source: TranscriptResult
    public let heuristics: String

    public init(participants: [Participant], items: [NoteItem], source: TranscriptResult, heuristics: String) {
        self.participants = participants; self.items = items; self.source = source; self.heuristics = heuristics
    }

    public static func extract(from source: TranscriptResult,
                               heuristics: NoteHeuristics = .default) -> Notes {
        var items: [NoteItem] = []
        for (index, turn) in source.turns.enumerated() {
            for sentence in heuristics.sentences(in: turn.text) {
                guard let kind = heuristics.classify(sentence.text, isListLine: sentence.isListLine) else { continue }
                items.append(NoteItem(kind: kind, text: sentence.text, speaker: turn.turn.speaker,
                                      turnIndex: index, start: sentence.start, end: sentence.end))
            }
        }
        return Notes(participants: participants(of: source), items: items,
                     source: source, heuristics: heuristics.version)
    }

    public func items(of kind: NoteKind) -> [NoteItem] { items.filter { $0.kind == kind } }

    /// Participants in order of first appearance; unattributed turns are one participant.
    static func participants(of source: TranscriptResult) -> [Participant] {
        var order: [SpeakerLabel?] = []
        var turns: [SpeakerLabel?: Int] = [:]
        var words: [SpeakerLabel?: Int] = [:]
        var seconds: [SpeakerLabel?: TimeInterval?] = [:]
        for result in source.turns {
            let speaker = result.turn.speaker
            if turns[speaker] == nil { order.append(speaker); seconds[speaker] = .some(0) }
            turns[speaker, default: 0] += 1
            words[speaker, default: 0] += result.text.split(whereSeparator: { $0.isWhitespace }).count
            if let span = result.turn.span, let total = seconds[speaker] ?? nil {
                seconds[speaker] = .some(total + span.duration)
            } else {
                seconds[speaker] = .some(nil)
            }
        }
        return order.map { speaker in
            Participant(speaker: speaker, turns: turns[speaker] ?? 0, words: words[speaker] ?? 0,
                        speakingSeconds: seconds[speaker] ?? nil)
        }
    }
}
