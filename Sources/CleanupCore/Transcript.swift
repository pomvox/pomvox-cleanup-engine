import Foundation

/// An opaque speaker identity within one transcript ("S1", "S2", ...). Who a
/// label is belongs to the host; the engine never names people. Encodes as a
/// plain JSON string.
public struct SpeakerLabel: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
    public var description: String { rawValue }
}

/// A half-open time range in seconds from the start of the audio.
public struct TimeSpan: Codable, Hashable, Sendable {
    public let start: TimeInterval
    public let end: TimeInterval
    public init(start: TimeInterval, end: TimeInterval) { self.start = start; self.end = end }
    public var duration: TimeInterval { end - start }
    /// Finite, nonnegative and ordered.
    public var isValid: Bool { start.isFinite && end.isFinite && start >= 0 && end >= start }
    /// Seconds the two spans share; zero when they do not touch.
    public func overlap(with other: TimeSpan) -> TimeInterval {
        max(0, min(end, other.end) - max(start, other.start))
    }
    /// Seconds between the two spans; zero when they touch or overlap.
    public func gap(to other: TimeSpan) -> TimeInterval {
        max(0, max(other.start - end, start - other.end))
    }
}

/// "Who spoke when": one speaker's span, as a diarizer reports it.
public struct SpeakerSegment: Codable, Equatable, Sendable {
    public let speaker: SpeakerLabel
    public let span: TimeSpan
    public let confidence: Double?
    public init(speaker: SpeakerLabel, span: TimeSpan, confidence: Double? = nil) {
        self.speaker = speaker; self.span = span; self.confidence = confidence
    }
}

/// One recognized word with its timing, as the host's STT reports it.
public struct TimedWord: Codable, Equatable, Sendable {
    public let text: String
    public let span: TimeSpan
    public let confidence: Double?
    public init(_ text: String, span: TimeSpan, confidence: Double? = nil) {
        self.text = text; self.span = span; self.confidence = confidence
    }
}

/// A run of one speaker's words. `speaker` is nil when nobody claimed the words.
public struct SpeakerTurn: Codable, Equatable, Sendable {
    public let speaker: SpeakerLabel?
    public let text: String
    public let span: TimeSpan?
    public init(speaker: SpeakerLabel? = nil, text: String, span: TimeSpan? = nil) {
        self.speaker = speaker; self.text = text; self.span = span
    }
}

/// How `Transcript.attribute` turns words and speaker segments into turns.
public struct AttributionOptions: Equatable, Sendable {
    /// A word no segment overlaps goes to the nearest segment within this many
    /// seconds; beyond it the word stays with the previous speaker.
    public var nearestTolerance: TimeInterval
    /// Same-speaker words separated by at least this much silence start a new turn.
    public var splitGap: TimeInterval
    public init(nearestTolerance: TimeInterval = 1.0, splitGap: TimeInterval = 2.0) {
        self.nearestTolerance = nearestTolerance; self.splitGap = splitGap
    }
}

/// Speaker-attributed text: an ordered list of turns. The engine cleans a
/// transcript one turn per request and never merges, splits, reorders or
/// relabels turns, so diarization structure survives cleanup unchanged.
public struct Transcript: Codable, Equatable, Sendable {
    public let turns: [SpeakerTurn]

    /// Longest admitted transcript, in turns. Each turn's text is admitted
    /// separately under `CleanupRequest.maxTextBytes`.
    public static let maxTurns = 2_048

    public init(turns: [SpeakerTurn]) { self.turns = turns }

    /// A single unattributed turn: plain dictation in transcript form.
    public init(_ text: String) { self.turns = [SpeakerTurn(text: text)] }

    public func validate() throws {
        guard turns.count <= Self.maxTurns else {
            throw CleanupError.invalidRequest("transcript exceeds \(Self.maxTurns) turns")
        }
        guard turns.allSatisfy({ $0.span?.isValid ?? true }) else {
            throw CleanupError.invalidRequest("transcript turn spans must be finite, nonnegative and ordered")
        }
    }

    /// Turn texts joined by line breaks, without speaker labels.
    public var text: String { turns.map(\.text).joined(separator: "\n") }

    /// Distinct speakers in order of first appearance.
    public var speakers: [SpeakerLabel] {
        var seen = Set<SpeakerLabel>()
        return turns.compactMap { turn in
            guard let speaker = turn.speaker, seen.insert(speaker).inserted else { return nil }
            return speaker
        }
    }

    /// Assign every word to a speaker and group consecutive same-speaker words
    /// into turns. Pure and deterministic: a word goes to the segment it
    /// overlaps most (ties to the earlier segment); a word nothing overlaps goes
    /// to the nearest segment within `options.nearestTolerance`, else to the
    /// previous word's speaker; leading unclaimed words take the first speaker
    /// that follows. Words keep their input order and text; empty texts are
    /// dropped. With no segments the result is one unattributed turn.
    ///
    /// Never loses words: the turn texts, split on the joining space, are exactly
    /// the nonempty input words in order.
    public static func attribute(words: [TimedWord], segments: [SpeakerSegment],
                                 options: AttributionOptions = AttributionOptions()) -> Transcript {
        let words = words.filter { !$0.text.isEmpty }
        guard !words.isEmpty else { return Transcript(turns: []) }
        let index = SegmentIndex(segments)
        var speakers: [SpeakerLabel?] = []
        speakers.reserveCapacity(words.count)
        var previous: SpeakerLabel?
        for word in words {
            let chosen = index.speaker(for: word.span, tolerance: options.nearestTolerance) ?? previous
            speakers.append(chosen)
            if chosen != nil { previous = chosen }
        }
        // Leading words nobody claimed take the first speaker that follows.
        if let first = speakers.first(where: { $0 != nil }) ?? nil {
            for i in speakers.indices where speakers[i] == nil { speakers[i] = first }
        }
        var turns: [SpeakerTurn] = []
        var texts: [String] = []
        var speaker: SpeakerLabel?
        var start = 0.0, end = 0.0, lastEnd = 0.0
        func flush() {
            guard !texts.isEmpty else { return }
            turns.append(SpeakerTurn(speaker: speaker, text: texts.joined(separator: " "),
                                     span: TimeSpan(start: start, end: end)))
            texts.removeAll(keepingCapacity: true)
        }
        for (word, label) in zip(words, speakers) {
            let splits = !texts.isEmpty && (label != speaker || word.span.start - lastEnd >= options.splitGap)
            if splits { flush() }
            if texts.isEmpty { speaker = label; start = word.span.start; end = word.span.end }
            texts.append(word.text)
            start = min(start, word.span.start)
            end = max(end, word.span.end)
            lastEnd = word.span.end
        }
        flush()
        return Transcript(turns: turns)
    }

    /// Segments sorted by start with a running maximum of ends, so the
    /// candidates for a word are a short backward scan rather than every segment.
    private struct SegmentIndex {
        let segments: [SpeakerSegment]
        let maxEndThrough: [TimeInterval]

        init(_ unsorted: [SpeakerSegment]) {
            segments = unsorted.filter { $0.span.isValid }.enumerated()
                .sorted { ($0.element.span.start, $0.offset) < ($1.element.span.start, $1.offset) }
                .map(\.element)
            var running = -TimeInterval.infinity
            maxEndThrough = segments.map { running = max(running, $0.span.end); return running }
        }

        func speaker(for span: TimeSpan, tolerance: TimeInterval) -> SpeakerLabel? {
            // Segments starting at or after the word's end cannot overlap it.
            var hi = segments.count
            var lo = 0
            while lo < hi {
                let mid = (lo + hi) / 2
                if segments[mid].span.start < span.end { lo = mid + 1 } else { hi = mid }
            }
            var best: (overlap: TimeInterval, index: Int)?
            var i = lo - 1
            while i >= 0, maxEndThrough[i] > span.start {
                let overlap = segments[i].span.overlap(with: span)
                if overlap > 0, best.map({ overlap > $0.overlap || (overlap == $0.overlap && i < $0.index) }) ?? true {
                    best = (overlap, i)
                }
                i -= 1
            }
            if let best { return segments[best.index].speaker }
            // Nothing overlaps: the nearest segment within tolerance, earlier one on ties.
            var nearest: (gap: TimeInterval, index: Int)?
            for (index, segment) in segments.enumerated() {
                let gap = segment.span.gap(to: span)
                if gap <= tolerance, nearest.map({ gap < $0.gap }) ?? true { nearest = (gap, index) }
            }
            return nearest.map { segments[$0.index].speaker }
        }
    }
}

/// One turn's cleanup outcome. `turn` is the original; `result.text` is what
/// the host shows for it. A fallback result is the turn's exact bytes.
public struct TurnResult: Codable, Equatable, Sendable {
    public let turn: SpeakerTurn
    public let result: CleanupResult
    public init(turn: SpeakerTurn, result: CleanupResult) { self.turn = turn; self.result = result }
    public var text: String { result.text }
}

/// A cleaned transcript: every input turn, in order, with its own outcome.
public struct TranscriptResult: Codable, Equatable, Sendable {
    public let turns: [TurnResult]
    /// Wall time the whole call took, including turns that ran no inference.
    public let elapsedMS: Double

    public init(turns: [TurnResult], elapsedMS: Double) { self.turns = turns; self.elapsedMS = elapsedMS }

    /// Cleaned turn texts joined by line breaks, without speaker labels.
    public var text: String { turns.map(\.text).joined(separator: "\n") }

    /// The cleaned transcript with the original speakers and spans.
    public var transcript: Transcript {
        Transcript(turns: turns.map { SpeakerTurn(speaker: $0.turn.speaker, text: $0.text, span: $0.turn.span) })
    }

    public var cleanedCount: Int { turns.filter { $0.result.status == .cleaned }.count }
    public var unchangedCount: Int { turns.filter { $0.result.status == .unchanged }.count }
    public var fallbackCount: Int { turns.count - cleanedCount - unchangedCount }

    /// Summed model inference time over turns that reported it; nil when none did.
    public var inferenceMS: Double? {
        let observed = turns.compactMap(\.result.timings.inferenceMS)
        return observed.isEmpty ? nil : observed.reduce(0, +)
    }
}

extension Provenance {
    /// The provenance of a turn the cleaner never sent to a model (budget spent,
    /// turn over the admission limit, hopeless budget). Route `skipped`, so a
    /// host can tell exactly which turns the model saw.
    public static let skipped = Provenance(packID: "none", packVersion: "none", artifactDigest: "none",
                                           modelRevision: "none", runtime: "none", route: "skipped")
}
