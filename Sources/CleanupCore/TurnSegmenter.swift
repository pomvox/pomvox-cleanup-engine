import Foundation

/// Opt-in splitting of long transcript turns into ordinary requests
/// (`TranscriptCleanOptions.segmentation`). Off unless a host sets it.
public struct TurnSegmentation: Equatable, Sendable {
    /// Longest segment sent as one request, in UTF-8 bytes; a turn longer than
    /// this is split. The default keeps a segment's acceptable output inside the
    /// MLX runtime's output cap of `max(64, min(2 × input tokens, 1,024))`
    /// tokens for any script: its tokenizer is byte-level, so a token covers at
    /// least one byte, and an output about as long as a 1,000-byte input needs
    /// at most about 1,000 tokens. Hosts may raise it up to
    /// `CleanupRequest.maxTextBytes`; output-cap fallbacks become likelier.
    public var maxSegmentBytes: Int
    public static let defaultMaxSegmentBytes = 1_000
    public static let minSegmentBytes = 64

    public init(maxSegmentBytes: Int = TurnSegmentation.defaultMaxSegmentBytes) {
        self.maxSegmentBytes = maxSegmentBytes
    }

    public func validate() throws {
        guard (Self.minSegmentBytes...CleanupRequest.maxTextBytes).contains(maxSegmentBytes) else {
            throw CleanupError.invalidRequest("maximum segment size must be \(Self.minSegmentBytes)...\(CleanupRequest.maxTextBytes) bytes")
        }
    }
}

/// How one segment of a split turn came out. Ranges are UTF-8 byte offsets (the
/// `TextEdit` convention): `sourceStart..<sourceEnd` in the turn's input text and
/// `outputStart..<outputEnd` in the turn's result text, so a quote in the cleaned
/// text maps back to the source it came from.
public struct SegmentOutcome: Codable, Equatable, Sendable {
    public let sourceStart: Int
    public let sourceEnd: Int
    public let outputStart: Int
    public let outputEnd: Int
    public let status: CleanupStatus
    public let warnings: [String]
    public init(sourceStart: Int, sourceEnd: Int, outputStart: Int, outputEnd: Int, status: CleanupStatus, warnings: [String]) {
        self.sourceStart = sourceStart; self.sourceEnd = sourceEnd
        self.outputStart = outputStart; self.outputEnd = outputEnd
        self.status = status; self.warnings = warnings
    }
}

/// Splits a long turn into pieces that are each small enough for one request.
///
/// The pieces tile the text exactly: concatenating every piece's bytes gives the
/// input bytes back. A `segment` piece is sent to the cleaner; a `separator`
/// piece (the whitespace at a split point, and any leading or trailing
/// whitespace of the turn) is never sent and is copied back verbatim. Splits
/// prefer sentence ends, then whitespace, then grapheme-cluster boundaries,
/// and never fall inside a scalar or a grapheme cluster. A single grapheme
/// cluster larger than the limit stays whole, so it is the only case where a
/// segment can exceed `maxBytes`.
public enum TurnSegmenter {
    public struct Piece: Equatable, Sendable {
        /// UTF-8 byte range in the turn text (the `TextEdit` convention).
        public let start: Int
        public let end: Int
        public let isSegment: Bool
    }

    public static func split(_ text: String, maxBytes: Int) -> [Piece] {
        precondition(maxBytes > 0)
        let characters = Array(text)
        var offsets: [Int] = [0] // byte offset before each character, plus the end
        offsets.reserveCapacity(characters.count + 1)
        for character in characters { offsets.append(offsets.last! + character.utf8.count) }
        let total = offsets.last!

        // Trim the turn's own leading and trailing whitespace into separators.
        var first = 0, last = characters.count
        while first < last, characters[first].isWhitespace { first += 1 }
        while last > first, characters[last - 1].isWhitespace { last -= 1 }
        guard first < last else { return total == 0 ? [] : [Piece(start: 0, end: total, isSegment: false)] }

        var pieces: [Piece] = []
        if first > 0 { pieces.append(Piece(start: 0, end: offsets[first], isSegment: false)) }
        var cursor = first
        while cursor < last {
            if offsets[last] - offsets[cursor] <= maxBytes {
                pieces.append(Piece(start: offsets[cursor], end: offsets[last], isSegment: true))
                break
            }
            // Furthest character index `limit` such that cursor..<limit fits.
            var limit = cursor + 1
            while limit < last, offsets[limit + 1] - offsets[cursor] <= maxBytes { limit += 1 }
            let cut = sentenceCut(characters, from: cursor, to: limit)
                ?? whitespaceCut(characters, from: cursor, to: limit)
                ?? limit
            var end = cut
            while end > cursor, characters[end - 1].isWhitespace { end -= 1 }
            var next = cut
            while next < last, characters[next].isWhitespace { next += 1 }
            pieces.append(Piece(start: offsets[cursor], end: offsets[end], isSegment: true))
            if next > end { pieces.append(Piece(start: offsets[end], end: offsets[next], isSegment: false)) }
            cursor = next
        }
        if last < characters.count { pieces.append(Piece(start: offsets[last], end: total, isSegment: false)) }
        return pieces
    }

    private static let terminators: Set<Character> = [".", "!", "?", "…", "。", "！", "？", "؟", "।"]
    private static let closers: Set<Character> = ["\"", "'", "”", "’", ")", "]", "」", "』", "»"]

    /// The last index in `(from, to]` just after a sentence end, where a sentence
    /// ends at a terminator (plus closing quotes) followed by whitespace, at a
    /// line break, or right after a full-width terminator.
    private static func sentenceCut(_ characters: [Character], from: Int, to: Int) -> Int? {
        var index = to
        while index > from {
            let previous = characters[index - 1]
            if previous.isNewline { return index }
            if index < characters.count, characters[index].isWhitespace || "。！？".contains(previous) {
                var look = index - 1
                while look > from, closers.contains(characters[look]) { look -= 1 }
                if terminators.contains(characters[look]) { return index }
            }
            index -= 1
        }
        return nil
    }

    /// The last index in `(from, to]` that starts a whitespace run.
    private static func whitespaceCut(_ characters: [Character], from: Int, to: Int) -> Int? {
        var index = min(to, characters.count - 1)
        while index > from {
            if characters[index].isWhitespace, !characters[index - 1].isWhitespace { return index }
            index -= 1
        }
        return nil
    }
}
