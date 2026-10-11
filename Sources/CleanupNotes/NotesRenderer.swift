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
    }

    public static func markdown(_ notes: Notes, options: Options = Options()) -> String {
        var lines: [String] = []
        if let title = options.title { lines += ["# " + title, ""] }
        func name(_ speaker: SpeakerLabel?) -> String {
            guard let speaker else { return options.unknownSpeakerName }
            return options.speakerNames[speaker] ?? speaker.rawValue
        }
        if options.includeParticipants, !notes.participants.isEmpty {
            lines.append("## Participants")
            for participant in notes.participants {
                var detail = "\(participant.turns) turn\(participant.turns == 1 ? "" : "s"), \(participant.words) word\(participant.words == 1 ? "" : "s")"
                if let seconds = participant.speakingSeconds { detail += ", " + clock(seconds) }
                lines.append("- \(name(participant.speaker)): \(detail)")
            }
            lines.append("")
        }
        let headings: [(NoteKind, String)] = [(.actionItem, "Action items"), (.decision, "Decisions"),
                                              (.question, "Questions"), (.listItem, "List items")]
        for (kind, heading) in headings where options.sections.contains(kind) {
            let items = notes.items(of: kind)
            guard !items.isEmpty else { continue }
            lines.append("## " + heading)
            for item in items { lines.append("- \(name(item.speaker)): \(item.text)") }
            lines.append("")
        }
        if options.includeTranscript, !notes.source.turns.isEmpty {
            lines.append("## Transcript")
            for result in notes.source.turns {
                var prefix = "**" + name(result.turn.speaker) + "**"
                if options.includeTimestamps, let span = result.turn.span {
                    prefix += " (" + clock(span.start) + "–" + clock(span.end) + ")"
                }
                lines.append(prefix + ": " + result.text)
                lines.append("")
            }
        }
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
