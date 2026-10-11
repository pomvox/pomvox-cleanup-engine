import Foundation

/// Markdown for a `Notes` value. The transcript section carries every cleaned
/// turn verbatim; nothing is escaped or reflowed, so what the cleaner produced
/// is what the document contains.
public enum NotesRenderer {
    public struct Options: Sendable {
        /// First-level heading. Nil omits it.
        public var title: String?
        /// Display names per label; unlisted labels print as the label itself.
        public var speakerNames: [SpeakerLabel: String]
        /// Name for turns no speaker claimed.
        public var unknownSpeakerName: String
        /// Which candidate sections to render, in this fixed order:
        /// action items, decisions, questions, list items. Empty sections are omitted.
        public var sections: Set<NoteKind>
        public var includeParticipants: Bool
        public var includeTranscript: Bool
        /// Prefix each transcript turn with its `mm:ss` span when it has one.
        public var includeTimestamps: Bool

        public init(title: String? = "Notes", speakerNames: [SpeakerLabel: String] = [:],
                    unknownSpeakerName: String = "Unknown speaker",
                    sections: Set<NoteKind> = [.actionItem, .decision, .question],
                    includeParticipants: Bool = true, includeTranscript: Bool = true,
                    includeTimestamps: Bool = false) {
            self.title = title; self.speakerNames = speakerNames; self.unknownSpeakerName = unknownSpeakerName
            self.sections = sections; self.includeParticipants = includeParticipants
            self.includeTranscript = includeTranscript; self.includeTimestamps = includeTimestamps
        }

        func name(_ speaker: SpeakerLabel?) -> String {
            guard let speaker else { return unknownSpeakerName }
            return speakerNames[speaker] ?? speaker.rawValue
        }
    }

    public static func markdown(_ notes: Notes, options: Options = Options()) -> String {
        join(header(options) + participants(notes, options) + candidates(notes, options, suffix: "") + transcript(notes, options))
    }

    /// The same document with a model's cited notes first. Model sections are
    /// marked "(model)" and each note names the turns it cites; the quoted
    /// candidates follow, marked "(quoted)", and the transcript is unchanged.
    public static func markdown(_ notes: Notes, model: ModelNotes, options: Options = Options()) -> String {
        var lines = header(options) + participants(notes, options)
        let groups: [([CitedNote], String)] = [(model.summary, "Summary"), (model.actionItems, "Action items (model)"),
                                               (model.decisions, "Decisions (model)"), (model.questions, "Questions (model)")]
        for (entries, heading) in groups where !entries.isEmpty {
            lines.append("## " + heading)
            for note in entries { lines.append("- \(note.text) — \(citation(note, notes, options))") }
            lines.append("")
        }
        lines += candidates(notes, options, suffix: " (quoted)") + transcript(notes, options)
        return join(lines)
    }

    private static func citation(_ note: CitedNote, _ notes: Notes, _ options: Options) -> String {
        note.turns.map { index -> String in
            guard notes.source.turns.indices.contains(index) else { return "turn \(index)" }
            let turn = notes.source.turns[index].turn
            let who = options.name(turn.speaker)
            return turn.span.map { who + " " + clock($0.start) } ?? who
        }.joined(separator: ", ")
    }

    private static func header(_ options: Options) -> [String] {
        options.title.map { ["# " + $0, ""] } ?? []
    }

    private static func participants(_ notes: Notes, _ options: Options) -> [String] {
        guard options.includeParticipants, !notes.participants.isEmpty else { return [] }
        var lines = ["## Participants"]
        for participant in notes.participants {
            var detail = "\(participant.turns) turn\(participant.turns == 1 ? "" : "s"), \(participant.words) word\(participant.words == 1 ? "" : "s")"
            if let seconds = participant.speakingSeconds { detail += ", " + clock(seconds) }
            lines.append("- \(options.name(participant.speaker)): \(detail)")
        }
        return lines + [""]
    }

    private static func candidates(_ notes: Notes, _ options: Options, suffix: String) -> [String] {
        let headings: [(NoteKind, String)] = [(.actionItem, "Action items"), (.decision, "Decisions"),
                                              (.question, "Questions"), (.listItem, "List items")]
        var lines: [String] = []
        for (kind, heading) in headings where options.sections.contains(kind) {
            let items = notes.items(of: kind)
            guard !items.isEmpty else { continue }
            lines.append("## " + heading + suffix)
            for item in items { lines.append("- \(options.name(item.speaker)): \(item.text)") }
            lines.append("")
        }
        return lines
    }

    private static func transcript(_ notes: Notes, _ options: Options) -> [String] {
        guard options.includeTranscript, !notes.source.turns.isEmpty else { return [] }
        var lines = ["## Transcript"]
        for result in notes.source.turns {
            var prefix = "**" + options.name(result.turn.speaker) + "**"
            if options.includeTimestamps, let span = result.turn.span {
                prefix += " (" + clock(span.start) + "–" + clock(span.end) + ")"
            }
            lines.append(prefix + ": " + result.text)
            lines.append("")
        }
        return lines
    }

    private static func join(_ lines: [String]) -> String {
        var lines = lines
        while lines.last == "" { lines.removeLast() }
        return lines.joined(separator: "\n") + "\n"
    }

    /// `m:ss`, or `h:mm:ss` past an hour. Nonfinite or negative values print as `0:00`.
    static func clock(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let (hours, rest) = total.quotientAndRemainder(dividingBy: 3_600)
        let (minutes, secs) = rest.quotientAndRemainder(dividingBy: 60)
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }
}
