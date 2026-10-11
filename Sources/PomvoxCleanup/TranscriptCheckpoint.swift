import CryptoKit
import Foundation

/// One turn's final result from `cleanIncrementally`, with its index in the transcript.
public struct CleanedTurn: Codable, Equatable, Sendable {
    public let index: Int
    public let result: TurnResult
    public init(index: Int, result: TurnResult) { self.index = index; self.result = result }
}

/// What a checkpoint is bound to. Equal identities mean the same turns (exact
/// UTF-8, speakers, spans), the same output-affecting options (vocabulary,
/// transforms, turn budget and base) and the same pack, so results are
/// interchangeable between runs. `overallDeadline` and `progress` are excluded:
/// they are per call.
public struct TranscriptCleanIdentity: Codable, Equatable, Sendable {
    public let transcriptSHA256: String
    public let turnCount: Int
    public let optionsSHA256: String
    public let pack: PackIdentity
    public init(transcriptSHA256: String, turnCount: Int, optionsSHA256: String, pack: PackIdentity) {
        self.transcriptSHA256 = transcriptSHA256; self.turnCount = turnCount
        self.optionsSHA256 = optionsSHA256; self.pack = pack
    }
}

/// Results a host has already accepted for turns `0..<accepted.count`, saved so
/// that an interrupted `cleanIncrementally` can resume without redoing them.
/// Build `identity` with `checkpointIdentity(for:options:)` on the same cleaner.
public struct TranscriptCheckpoint: Codable, Equatable, Sendable {
    public let identity: TranscriptCleanIdentity
    public let accepted: [TurnResult]
    public init(identity: TranscriptCleanIdentity, accepted: [TurnResult]) {
        self.identity = identity; self.accepted = accepted
    }
}

/// Exact, length-prefixed digests. Strings are hashed as UTF-8 bytes, so
/// canonically equivalent but differently encoded text is a different transcript.
enum TranscriptDigest {
    private struct Writer {
        var hasher = SHA256()
        mutating func bytes(_ value: some Collection<UInt8>) { integer(UInt64(value.count)); hasher.update(data: Data(value)) }
        mutating func string(_ value: String) { bytes(Array(value.utf8)) }
        mutating func integer(_ value: UInt64) { withUnsafeBytes(of: value.bigEndian) { hasher.update(bufferPointer: $0) } }
        mutating func double(_ value: Double) { integer(value.bitPattern) }
        mutating func flag(_ value: Bool) { integer(value ? 1 : 0) }
        mutating func hex() -> String { hasher.finalize().map { String(format: "%02x", $0) }.joined() }
    }

    static func transcript(_ transcript: Transcript) -> String {
        var writer = Writer()
        writer.string("pomvox-transcript-v1")
        writer.integer(UInt64(transcript.turns.count))
        for turn in transcript.turns {
            writer.flag(turn.speaker != nil)
            if let speaker = turn.speaker { writer.string(speaker.rawValue) }
            writer.string(turn.text)
            writer.flag(turn.span != nil)
            if let span = turn.span { writer.double(span.start); writer.double(span.end) }
        }
        return writer.hex()
    }

    static func options(_ options: TranscriptCleanOptions) -> String {
        var writer = Writer()
        writer.string("pomvox-transcript-options-v1")
        writer.integer(UInt64(options.vocabulary.count))
        options.vocabulary.forEach { writer.string($0) }
        writer.integer(UInt64(options.transforms.rawValue))
        writer.flag(options.turnBudget != nil)
        if let policy = options.turnBudget {
            [policy.fixedOverheadS, policy.throughputCharsPerS, policy.headroom, policy.ceilingS].forEach { writer.double($0) }
        }
        let base = options.turnBase.components
        writer.integer(UInt64(bitPattern: base.seconds)); writer.integer(UInt64(bitPattern: base.attoseconds))
        return writer.hex()
    }

    /// Same speaker, text and span, comparing text as UTF-8 bytes.
    static func sameTurn(_ a: SpeakerTurn, _ b: SpeakerTurn) -> Bool {
        a.speaker.map { Array($0.rawValue.utf8) } == b.speaker.map { Array($0.rawValue.utf8) }
            && Array(a.text.utf8) == Array(b.text.utf8) && a.span == b.span
    }

    /// Whether a stored result could have come from cleaning `source` with `pack`:
    /// a fallback or unchanged result is the exact input with no edits; a cleaned
    /// result's edits rebuild its text from the input; a turn the model never saw
    /// carries `Provenance.skipped` and is a fallback; any other result names the pack.
    static func isConsistent(_ result: CleanupResult, source: String, pack: PackIdentity) -> Bool {
        let input = Array(source.utf8), output = Array(result.text.utf8)
        switch result.status {
        case .fallback, .unchanged:
            guard result.edits.isEmpty, output == input else { return false }
        case .cleaned:
            guard let rebuilt = try? TextEdit.applying(result.edits, to: source), Array(rebuilt.utf8) == output else { return false }
        }
        if result.provenance == .skipped {
            if case .fallback = result.status { return true }
            return false
        }
        return result.provenance.packID == pack.id && result.provenance.packVersion == pack.version
            && (pack.digest.map { $0 == result.provenance.artifactDigest } ?? true)
    }
}
