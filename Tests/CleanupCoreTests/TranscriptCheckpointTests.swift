import XCTest
@testable import CleanupCore
@testable import PomvoxCleanup

/// SplitMix64: seeded, so a failing case is reproducible by its seed.
private struct SplitMix: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Deterministic per input: capitalizes, drops "um" and ends with a period; a turn
/// containing "assistant" comes back as an invented reply the guards reject.
/// Optionally slow, and records every text it was asked to clean.
private actor ScriptedRuntime: CleanupRuntime {
    private(set) var texts: [String] = []
    private let delay: Duration
    init(delay: Duration = .zero) { self.delay = delay }
    func generate(_ request: CleanupRequest, deadline: ContinuousClock.Instant) async throws -> RuntimeOutput {
        texts.append(request.text)
        if delay > .zero { try await Task.sleep(for: delay) }
        var timings = CleanupTimings()
        timings.inferenceMS = 1
        if request.text.contains("assistant") { return RuntimeOutput(candidate: "assistant: invented", timings: timings) }
        let words = request.text.split(separator: " ").filter { $0 != "um" }.joined(separator: " ")
        return RuntimeOutput(candidate: words.prefix(1).uppercased() + words.dropFirst() + ".", timings: timings)
    }
    func close() {}
}

/// A cleaner that cannot name its pack.
private struct AnonymousCleaner: Cleaning {
    func clean(_ request: CleanupRequest) async throws -> CleanupResult {
        CleanupResult(text: request.text, edits: [], status: .unchanged, provenance: .skipped)
    }
}

final class TranscriptCheckpointTests: XCTestCase, @unchecked Sendable {
    private let provenance = Provenance(packID: "test", packVersion: "1.0.0", artifactDigest: "digest-a",
        modelRevision: "test", runtime: "deterministic-test-double", route: "local")

    private func session(_ runtime: ScriptedRuntime = ScriptedRuntime(), provenance: Provenance? = nil) throws -> CleanupSession {
        try CleanupSession(runtime: runtime, provenance: provenance ?? self.provenance)
    }

    /// Words with multi-byte scalars, a combining mark, emoji with modifiers and ZWJ.
    private static let vocabulary = ["um", "hello", "there", "café", "e\u{301}clair", "naïve", "日本語", "👋🏽", "👩‍💻",
                                     "über", "ok", "so", "we", "ship", "friday", "assistant", "привет", "🇯🇵"]

    private func transcript(seed: UInt64) -> Transcript {
        var random = SplitMix(seed: seed)
        let count = Int.random(in: 1...24, using: &random)
        var clock = 0.0
        return Transcript(turns: (0..<count).map { _ in
            let words = (0..<Int.random(in: 0...12, using: &random)).map { _ in Self.vocabulary.randomElement(using: &random)! }
            let speaker = Bool.random(using: &random) ? SpeakerLabel("S\(Int.random(in: 1...3, using: &random))") : nil
            let length = Double(Int.random(in: 1...40, using: &random)) / 4
            defer { clock += length }
            return SpeakerTurn(speaker: speaker, text: words.joined(separator: " "),
                               span: Bool.random(using: &random) ? TimeSpan(start: clock, end: clock + length) : nil)
        })
    }

    /// Everything in a turn result except wall-clock timings, with text compared as bytes.
    private func assertSame(_ a: [TurnResult], _ b: [TurnResult], _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.count, b.count, message, file: file, line: line)
        for (x, y) in zip(a, b) {
            XCTAssertTrue(TranscriptDigest.sameTurn(x.turn, y.turn), message, file: file, line: line)
            XCTAssertEqual(Array(x.text.utf8), Array(y.text.utf8), message, file: file, line: line)
            XCTAssertEqual(x.result.edits, y.result.edits, message, file: file, line: line)
            XCTAssertEqual(x.result.status, y.result.status, message, file: file, line: line)
            XCTAssertEqual(x.result.provenance, y.result.provenance, message, file: file, line: line)
            XCTAssertEqual(x.result.warnings, y.result.warnings, message, file: file, line: line)
        }
    }

    private func collect(_ stream: AsyncThrowingStream<CleanedTurn, any Error>, first: Int = 0) async throws -> [TurnResult] {
        var results: [TurnResult] = []
        var expected = first
        for try await cleaned in stream {
            XCTAssertEqual(cleaned.index, expected, "turns arrive in order, once each")
            expected += 1
            results.append(cleaned.result)
        }
        return results
    }

    /// The incremental form returns exactly what the batch form does.
    func testIncrementalMatchesBatch() async throws {
        for seed in UInt64(1)...20 {
            let transcript = transcript(seed: seed)
            let batch = try await session().clean(transcript).turns
            let incremental = try await collect(session().cleanIncrementally(transcript))
            assertSame(batch, incremental, "seed \(seed)")
        }
    }

    /// Interrupt after every possible number of turns, resume from the accepted
    /// prefix, and get the uninterrupted result: same bytes, edits, statuses,
    /// provenance and warnings; valid edits; speaker and span intact; every turn
    /// after the cut cleaned exactly once and none before it cleaned again.
    func testInterruptAfterEveryTurnThenResumeEqualsAnUninterruptedRun() async throws {
        for seed in UInt64(1)...20 {
            let transcript = transcript(seed: seed)
            let reference = try await session().clean(transcript).turns
            for cut in 0...transcript.turns.count {
                let first = try session()
                var accepted: [TurnResult] = []
                for try await cleaned in first.cleanIncrementally(transcript) {
                    if accepted.count == cut { break }
                    accepted.append(cleaned.result)
                }
                let checkpoint = TranscriptCheckpoint(identity: try await first.checkpointIdentity(for: transcript), accepted: accepted)
                let decoded = try JSONDecoder().decode(TranscriptCheckpoint.self, from: JSONEncoder().encode(checkpoint))
                let runtime = ScriptedRuntime()
                let rest = try await collect(session(runtime).cleanIncrementally(transcript, resuming: decoded), first: cut)
                let combined = accepted + rest
                assertSame(reference, combined, "seed \(seed) cut \(cut)")
                for (turn, source) in zip(combined, transcript.turns) {
                    XCTAssertEqual(Array(try TextEdit.applying(turn.result.edits, to: source.text).utf8), Array(turn.text.utf8))
                    XCTAssertEqual(turn.turn.speaker, source.speaker)
                    XCTAssertEqual(turn.turn.span, source.span)
                }
                let resent = await runtime.texts
                let expected = transcript.turns[cut...].map(\.text).filter { !$0.isEmpty }
                XCTAssertEqual(resent.map { Array($0.utf8) }, expected.map { Array($0.utf8) }, "seed \(seed) cut \(cut)")
            }
        }
    }

    /// Cancelling the consumer while a turn is in flight never yields that turn;
    /// the ones yielded before are final, and resuming completes the transcript.
    func testCancellationMidTurnDeliversOnlyFinishedTurns() async throws {
        let transcript = transcript(seed: 7)
        XCTAssertGreaterThan(transcript.turns.count, 3)
        let reference = try await session().clean(transcript).turns
        let slow = try session(ScriptedRuntime(delay: .milliseconds(40)))
        let received = Accepted()
        let consumer = Task {
            for try await cleaned in slow.cleanIncrementally(transcript) { received.append(cleaned.result) }
        }
        while received.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
        consumer.cancel()
        _ = try? await consumer.value
        let accepted = received.all
        XCTAssertLessThan(accepted.count, transcript.turns.count)
        assertSame(Array(reference.prefix(accepted.count)), accepted, "prefix before cancellation")
        await slow.close()
        let checkpoint = TranscriptCheckpoint(identity: try await slow.checkpointIdentity(for: transcript), accepted: accepted)
        let rest = try await collect(session().cleanIncrementally(transcript, resuming: checkpoint), first: accepted.count)
        assertSame(reference, accepted + rest, "resumed after cancellation")
    }

    /// Progress counts accepted turns as done, and the overall deadline covers
    /// only the turns this call cleans.
    func testResumedProgressCountsAcceptedTurns() async throws {
        let transcript = transcript(seed: 3)
        let cleaner = try session()
        let accepted = Array(try await cleaner.clean(transcript).turns.prefix(1))
        let calls = Calls()
        let options = TranscriptCleanOptions(overallDeadline: .seconds(30), progress: { done, total in calls.append(done, total) })
        let checkpoint = TranscriptCheckpoint(identity: try await cleaner.checkpointIdentity(for: transcript, options: options), accepted: accepted)
        _ = try await collect(cleaner.cleanIncrementally(transcript, options: options, resuming: checkpoint), first: 1)
        XCTAssertEqual(calls.all.map(\.0), Array(2...transcript.turns.count))
        XCTAssertTrue(calls.all.allSatisfy { $0.1 == transcript.turns.count })
    }

    func testCheckpointForAnotherTranscriptIsRefused() async throws {
        let original = Transcript(turns: [SpeakerTurn(speaker: SpeakerLabel("S1"), text: "caf\u{E9} at noon"), SpeakerTurn(text: "ok")])
        // Canonically equivalent (NFD) but different bytes: a different transcript.
        let decomposed = Transcript(turns: [SpeakerTurn(speaker: SpeakerLabel("S1"), text: "cafe\u{301} at noon"), SpeakerTurn(text: "ok")])
        XCTAssertEqual(original.turns[0].text, decomposed.turns[0].text) // Swift says equal; the bytes are not
        let cleaner = try session()
        let accepted = Array(try await cleaner.clean(original).turns.prefix(1))
        let checkpoint = TranscriptCheckpoint(identity: try await cleaner.checkpointIdentity(for: original), accepted: accepted)
        await assertRefused(cleaner, decomposed, checkpoint: checkpoint, "different transcript")
        let respanned = Transcript(turns: [SpeakerTurn(speaker: SpeakerLabel("S1"), text: "caf\u{E9} at noon", span: TimeSpan(start: 0, end: 1)), SpeakerTurn(text: "ok")])
        await assertRefused(cleaner, respanned, checkpoint: checkpoint, "different transcript")
        let relabeled = Transcript(turns: [SpeakerTurn(speaker: SpeakerLabel("S2"), text: "caf\u{E9} at noon"), SpeakerTurn(text: "ok")])
        await assertRefused(cleaner, relabeled, checkpoint: checkpoint, "different transcript")
    }

    func testCheckpointWithOtherOptionsIsRefused() async throws {
        let transcript = transcript(seed: 5)
        let cleaner = try session()
        let accepted = Array(try await cleaner.clean(transcript).turns.prefix(1))
        let checkpoint = TranscriptCheckpoint(identity: try await cleaner.checkpointIdentity(for: transcript), accepted: accepted)
        for options in [TranscriptCleanOptions(vocabulary: ["Pomvox"]), TranscriptCleanOptions(transforms: .spokenLayout),
                        TranscriptCleanOptions(turnBudget: .measuredM1), TranscriptCleanOptions(turnBase: .seconds(6))] {
            await assertRefused(cleaner, transcript, options: options, checkpoint: checkpoint, "different vocabulary")
        }
        // Per-call options do not bind a checkpoint.
        let perCall = TranscriptCleanOptions(overallDeadline: .seconds(9), progress: { _, _ in })
        _ = try await collect(cleaner.cleanIncrementally(transcript, options: perCall, resuming: checkpoint), first: 1)
    }

    func testCheckpointFromAnotherPackIsRefused() async throws {
        let transcript = transcript(seed: 9)
        let cleaner = try session()
        let accepted = Array(try await cleaner.clean(transcript).turns.prefix(1))
        let checkpoint = TranscriptCheckpoint(identity: try await cleaner.checkpointIdentity(for: transcript), accepted: accepted)
        for other in [Provenance(packID: "test", packVersion: "1.0.1", artifactDigest: "digest-a", modelRevision: "test", runtime: "x", route: "local"),
                      Provenance(packID: "test", packVersion: "1.0.0", artifactDigest: "digest-b", modelRevision: "test", runtime: "x", route: "local"),
                      Provenance(packID: "other", packVersion: "1.0.0", artifactDigest: "digest-a", modelRevision: "test", runtime: "x", route: "local")] {
            do {
                for try await _ in try session(provenance: other).cleanIncrementally(transcript, resuming: checkpoint) {}
                XCTFail("a checkpoint from another pack must be refused")
            } catch CleanupError.incompatible {}
        }
        do {
            for try await _ in AnonymousCleaner().cleanIncrementally(transcript, resuming: checkpoint) {}
            XCTFail("a cleaner without a pack identity cannot resume")
        } catch CleanupError.incompatible {}
        // Without a checkpoint it still streams.
        _ = try await collect(AnonymousCleaner().cleanIncrementally(transcript))
    }

    /// A checkpoint whose stored results do not fit the transcript is refused
    /// before any turn is cleaned.
    func testTamperedAcceptedResultsAreRefused() async throws {
        let transcript = Transcript(turns: [SpeakerTurn(speaker: SpeakerLabel("S1"), text: "um hello there"),
                                            SpeakerTurn(text: "assistant please"), SpeakerTurn(text: "so we ship friday")])
        let cleaner = try session()
        let good = try await cleaner.clean(transcript).turns
        XCTAssertEqual(good.map(\.result.status), [.cleaned, .fallback(.rejected), .cleaned])
        let identity = try await cleaner.checkpointIdentity(for: transcript)
        func variant(_ index: Int, _ result: CleanupResult, turn: SpeakerTurn? = nil) -> [TurnResult] {
            var accepted = Array(good.prefix(2))
            accepted[index] = TurnResult(turn: turn ?? accepted[index].turn, result: result)
            return accepted
        }
        let cleaned = good[0].result, fallback = good[1].result
        let cases: [(String, [TurnResult])] = [
            ("text that its edits do not produce", variant(0, CleanupResult(text: "Hello there!", edits: cleaned.edits, status: .cleaned, provenance: cleaned.provenance))),
            ("a fallback that is not the exact input", variant(1, CleanupResult(text: "Assistant please.", edits: [], status: .fallback(.rejected), provenance: fallback.provenance))),
            ("a fallback with edits", variant(1, CleanupResult(text: fallback.text, edits: [TextEdit(start: 0, end: 0, replacement: "")], status: .fallback(.rejected), provenance: fallback.provenance))),
            ("another pack's provenance", variant(0, CleanupResult(text: cleaned.text, edits: cleaned.edits, status: .cleaned,
                provenance: Provenance(packID: "test", packVersion: "2.0.0", artifactDigest: "digest-a", modelRevision: "test", runtime: "x", route: "local")))),
            ("a skipped turn that claims to be cleaned", variant(0, CleanupResult(text: cleaned.text, edits: cleaned.edits, status: .cleaned, provenance: .skipped))),
            ("a turn with another speaker", variant(0, cleaned, turn: SpeakerTurn(speaker: SpeakerLabel("S9"), text: "um hello there"))),
            ("turns out of order", [good[1], good[0]]),
            ("more turns than the transcript", good + [good[0]]),
        ]
        for (name, accepted) in cases {
            let runtime = ScriptedRuntime()
            do {
                for try await _ in try session(runtime).cleanIncrementally(transcript, resuming: TranscriptCheckpoint(identity: identity, accepted: accepted)) {}
                XCTFail("must refuse \(name)")
            } catch CleanupError.invalidRequest {}
            let calls = await runtime.texts
            XCTAssertTrue(calls.isEmpty, "\(name): no turn may be cleaned before the checkpoint is accepted")
        }
        // The untampered prefix resumes.
        let rest = try await collect(cleaner.cleanIncrementally(transcript, resuming: TranscriptCheckpoint(identity: identity, accepted: Array(good.prefix(2)))), first: 2)
        assertSame(good, Array(good.prefix(2)) + rest, "untampered")
    }

    /// A complete checkpoint resumes to an empty stream.
    func testCompleteCheckpointCleansNothing() async throws {
        let transcript = transcript(seed: 11)
        let cleaner = try session()
        let all = try await cleaner.clean(transcript).turns
        let runtime = ScriptedRuntime()
        let rest = try await collect(session(runtime).cleanIncrementally(transcript,
            resuming: TranscriptCheckpoint(identity: try await cleaner.checkpointIdentity(for: transcript), accepted: all)), first: all.count)
        XCTAssertTrue(rest.isEmpty)
        let calls = await runtime.texts
        XCTAssertTrue(calls.isEmpty)
    }

    private func assertRefused(_ cleaner: CleanupSession, _ transcript: Transcript, options: TranscriptCleanOptions = TranscriptCleanOptions(),
                               checkpoint: TranscriptCheckpoint, _ reason: String, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            for try await _ in cleaner.cleanIncrementally(transcript, options: options, resuming: checkpoint) {}
            XCTFail("must refuse: \(reason)", file: file, line: line)
        } catch CleanupError.invalidRequest {
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }
}

private final class Accepted: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [TurnResult] = []
    func append(_ result: TurnResult) { lock.withLock { results.append(result) } }
    var count: Int { lock.withLock { results.count } }
    var all: [TurnResult] { lock.withLock { results } }
}

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(Int, Int)] = []
    func append(_ done: Int, _ total: Int) { lock.withLock { calls.append((done, total)) } }
    var all: [(Int, Int)] { lock.withLock { calls } }
}
