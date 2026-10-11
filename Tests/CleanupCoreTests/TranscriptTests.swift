import XCTest
@testable import CleanupCore
import PomvoxCleanup

/// SplitMix64: seeded, so a failing case is reproducible by its index.
private struct SeededGenerator: RandomNumberGenerator {
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

final class TranscriptAttributionTests: XCTestCase {
    private let s1 = SpeakerLabel("S1"), s2 = SpeakerLabel("S2")

    private func word(_ text: String, _ start: Double, _ end: Double) -> TimedWord {
        TimedWord(text, span: TimeSpan(start: start, end: end))
    }

    func testTwoSpeakersBecomeTwoTurnsWithSpans() {
        let words = [word("hello", 0, 0.4), word("there", 0.5, 0.9), word("hi", 5.1, 5.4), word("back", 5.5, 5.9)]
        let segments = [SpeakerSegment(speaker: s1, span: TimeSpan(start: 0, end: 5)),
                        SpeakerSegment(speaker: s2, span: TimeSpan(start: 5, end: 10))]
        let transcript = Transcript.attribute(words: words, segments: segments)
        XCTAssertEqual(transcript.turns, [
            SpeakerTurn(speaker: s1, text: "hello there", span: TimeSpan(start: 0, end: 0.9)),
            SpeakerTurn(speaker: s2, text: "hi back", span: TimeSpan(start: 5.1, end: 5.9)),
        ])
        XCTAssertEqual(transcript.speakers, [s1, s2])
        XCTAssertEqual(transcript.text, "hello there\nhi back")
    }

    func testMajorityOverlapWinsAndTiesGoToTheEarlierSegment() {
        let segments = [SpeakerSegment(speaker: s1, span: TimeSpan(start: 0, end: 1)),
                        SpeakerSegment(speaker: s2, span: TimeSpan(start: 0.8, end: 3))]
        XCTAssertEqual(Transcript.attribute(words: [word("mostly-two", 0.9, 2)], segments: segments).turns.first?.speaker, s2)
        XCTAssertEqual(Transcript.attribute(words: [word("tie", 0.6, 1.2)], segments: segments).turns.first?.speaker, s1)
    }

    func testUnclaimedWordsUseNearestWithinToleranceThenPreviousSpeaker() {
        let segments = [SpeakerSegment(speaker: s1, span: TimeSpan(start: 0, end: 1)),
                        SpeakerSegment(speaker: s2, span: TimeSpan(start: 4, end: 5))]
        let words = [word("a", 0, 0.5), word("near-two", 3.2, 3.5), word("far", 10, 10.5)]
        let turns = Transcript.attribute(words: words, segments: segments).turns
        XCTAssertEqual(turns.map(\.speaker), [s1, s2, s2])
        XCTAssertEqual(turns.map(\.text), ["a", "near-two", "far"])
        let strict = Transcript.attribute(words: words, segments: segments,
                                          options: AttributionOptions(nearestTolerance: 0.1, splitGap: 100)).turns
        // Beyond tolerance the word stays with the previous speaker and, within the split gap, the same turn.
        XCTAssertEqual(strict.map(\.speaker), [s1])
        XCTAssertEqual(strict.first?.text, "a near-two far")
    }

    func testLeadingUnclaimedWordsTakeTheFirstSpeakerThatFollows() {
        let segments = [SpeakerSegment(speaker: s2, span: TimeSpan(start: 5, end: 6))]
        let turns = Transcript.attribute(words: [word("early", 0, 0.2), word("later", 5, 5.5)], segments: segments,
                                         options: AttributionOptions(nearestTolerance: 0.5)).turns
        XCTAssertEqual(turns.map(\.speaker), [s2, s2])
        XCTAssertEqual(turns.map(\.text), ["early", "later"]) // the 4.8 s silence splits the turn
    }

    func testSilenceSplitsASpeakerIntoTwoTurns() {
        let segments = [SpeakerSegment(speaker: s1, span: TimeSpan(start: 0, end: 20))]
        let turns = Transcript.attribute(words: [word("one", 0, 0.5), word("two", 0.6, 1), word("three", 4, 4.5)],
                                         segments: segments).turns
        XCTAssertEqual(turns.map(\.text), ["one two", "three"])
        XCTAssertEqual(turns.map(\.speaker), [s1, s1])
    }

    func testNoSegmentsIsOneUnattributedTurnAndEmptyWordsAreDropped() {
        let turns = Transcript.attribute(words: [word("", 0, 0.1), word("just", 0, 0.5), word("text", 0.6, 1)],
                                         segments: []).turns
        XCTAssertEqual(turns, [SpeakerTurn(speaker: nil, text: "just text", span: TimeSpan(start: 0, end: 1))])
        XCTAssertEqual(Transcript.attribute(words: [], segments: []).turns, [])
        XCTAssertEqual(Transcript.attribute(words: [word("", 0, 1)], segments: []).turns, [])
    }

    func testInvalidSegmentsAreIgnoredNotCrashed() {
        let segments = [SpeakerSegment(speaker: s1, span: TimeSpan(start: 3, end: 1)),
                        SpeakerSegment(speaker: s2, span: TimeSpan(start: .nan, end: 1)),
                        SpeakerSegment(speaker: s2, span: TimeSpan(start: 0, end: 1))]
        XCTAssertEqual(Transcript.attribute(words: [word("w", 0, 0.5)], segments: segments).turns.first?.speaker, s2)
    }

    /// Never lose words: the turn texts, split on the joining space, are exactly
    /// the nonempty input words in order, for any timing and any segments.
    func testPropertyEveryWordOnceInOrder() {
        var generator = SeededGenerator(seed: 0x5EED_2026_1011)
        let labels = (1...5).map { SpeakerLabel("S\($0)") }
        for iteration in 0..<2_000 {
            var words: [TimedWord] = []
            var clock = Double.random(in: 0...3, using: &generator)
            for index in 0..<Int.random(in: 0...60, using: &generator) {
                let length = Double.random(in: 0.05...1.2, using: &generator)
                let text = Bool.random(using: &generator) ? "w\(index)" : (Int.random(in: 0..<20, using: &generator) == 0 ? "" : "x\(index)")
                words.append(TimedWord(text, span: TimeSpan(start: clock, end: clock + length)))
                clock += length + (Int.random(in: 0..<6, using: &generator) == 0 ? Double.random(in: 1...6, using: &generator) : Double.random(in: 0...0.4, using: &generator))
            }
            var segments: [SpeakerSegment] = []
            var cursor = 0.0
            for _ in 0..<Int.random(in: 0...12, using: &generator) {
                let start = max(0, cursor + Double.random(in: -1...2, using: &generator))
                let end = start + Double.random(in: 0...8, using: &generator)
                segments.append(SpeakerSegment(speaker: labels.randomElement(using: &generator)!, span: TimeSpan(start: start, end: end)))
                cursor = end
            }
            let options = AttributionOptions(nearestTolerance: Double.random(in: 0...3, using: &generator),
                                             splitGap: Double.random(in: 0.5...5, using: &generator))
            let transcript = Transcript.attribute(words: words.shuffled(using: &generator), segments: segments, options: options)
            let expected = words.filter { !$0.text.isEmpty }
            let produced = transcript.turns.flatMap { $0.text.split(separator: " ").map(String.init) }
            XCTAssertEqual(Set(produced), Set(expected.map(\.text)), "iteration \(iteration)")
            XCTAssertEqual(produced.count, expected.count, "iteration \(iteration)")
            XCTAssertNoThrow(try transcript.validate(), "iteration \(iteration)")
            // Once any word is claimed, every turn has a speaker: leading words inherit
            // the first claim and later unclaimed words keep the previous one.
            let anyClaimed = words.contains { word in segments.contains { $0.span.overlap(with: word.span) > 0 } }
            for turn in transcript.turns {
                XCTAssertFalse(turn.text.isEmpty, "iteration \(iteration)")
                XCTAssertTrue(turn.span?.isValid ?? false, "iteration \(iteration)")
                if anyClaimed { XCTAssertNotNil(turn.speaker, "iteration \(iteration)") }
            }
            // In-order input keeps order exactly.
            let ordered = Transcript.attribute(words: words, segments: segments, options: options)
            XCTAssertEqual(ordered.turns.flatMap { $0.text.split(separator: " ").map(String.init) },
                           expected.map(\.text), "iteration \(iteration)")
        }
    }

    func testValidationLimits() {
        XCTAssertNoThrow(try Transcript(turns: Array(repeating: SpeakerTurn(text: "a"), count: Transcript.maxTurns)).validate())
        XCTAssertThrowsError(try Transcript(turns: Array(repeating: SpeakerTurn(text: "a"), count: Transcript.maxTurns + 1)).validate())
        XCTAssertThrowsError(try Transcript(turns: [SpeakerTurn(text: "a", span: TimeSpan(start: 2, end: 1))]).validate())
        XCTAssertThrowsError(try Transcript(turns: [SpeakerTurn(text: "a", span: TimeSpan(start: -1, end: 1))]).validate())
        XCTAssertNoThrow(try Transcript("plain dictation").validate())
    }

    func testCodableShapeIsPortable() throws {
        let turn = SpeakerTurn(speaker: s1, text: "hi", span: TimeSpan(start: 0.5, end: 1.25))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(turn), as: UTF8.self)
        XCTAssertEqual(json, #"{"span":{"end":1.25,"start":0.5},"speaker":"S1","text":"hi"}"#)
        XCTAssertEqual(try JSONDecoder().decode(SpeakerTurn.self, from: Data(json.utf8)), turn)
    }

    func testTimeSpanArithmetic() {
        let a = TimeSpan(start: 0, end: 2), b = TimeSpan(start: 1, end: 3), c = TimeSpan(start: 5, end: 6)
        XCTAssertEqual(a.overlap(with: b), 1)
        XCTAssertEqual(a.overlap(with: c), 0)
        XCTAssertEqual(a.gap(to: c), 3)
        XCTAssertEqual(c.gap(to: a), 3)
        XCTAssertEqual(a.gap(to: b), 0)
        XCTAssertFalse(TimeSpan(start: .infinity, end: 1).isValid)
    }
}

/// Counts calls and can be slow or cancel-ignoring; the transcript cleaner must
/// never run inference for a turn it has decided to skip.
private actor CountingRuntime: CleanupRuntime {
    private(set) var calls = 0
    private(set) var texts: [String] = []
    private let delay: Duration
    private let transform: @Sendable (String) -> String
    init(delay: Duration = .zero, transform: @escaping @Sendable (String) -> String = { $0.prefix(1).uppercased() + $0.dropFirst() + "." }) {
        self.delay = delay; self.transform = transform
    }
    func generate(_ request: CleanupRequest, deadline: ContinuousClock.Instant) async throws -> RuntimeOutput {
        calls += 1
        texts.append(request.text)
        if delay > .zero { try? await Task.sleep(for: delay) }
        var timings = CleanupTimings()
        timings.inferenceMS = 1
        return RuntimeOutput(candidate: transform(request.text), timings: timings)
    }
    func close() {}
}

final class TranscriptCleaningTests: XCTestCase, @unchecked Sendable {
    private let provenance = Provenance(packID: "test", packVersion: "1.0.0", artifactDigest: "test",
        modelRevision: "test", runtime: "deterministic-test-double", route: "local")
    private let s1 = SpeakerLabel("S1"), s2 = SpeakerLabel("S2")

    private func transcript() -> Transcript {
        Transcript(turns: [
            SpeakerTurn(speaker: s1, text: "hello there how are you", span: TimeSpan(start: 0, end: 2)),
            SpeakerTurn(speaker: s2, text: "fine thanks", span: TimeSpan(start: 2, end: 3)),
            SpeakerTurn(speaker: s1, text: "", span: nil),
            SpeakerTurn(speaker: nil, text: "unattributed words", span: TimeSpan(start: 4, end: 5)),
        ])
    }

    func testOneRequestPerTurnPreservesStructure() async throws {
        let runtime = CountingRuntime()
        let session = try CleanupSession(runtime: runtime, provenance: provenance)
        let result = try await session.clean(transcript())
        await session.close()
        XCTAssertEqual(result.turns.count, 4)
        XCTAssertEqual(result.turns.map { $0.turn }, transcript().turns)
        XCTAssertEqual(result.turns.map(\.result.status), [.cleaned, .cleaned, .unchanged, .cleaned])
        XCTAssertEqual(result.text, "Hello there how are you.\nFine thanks.\n\nUnattributed words.")
        XCTAssertEqual(result.transcript.turns.map(\.speaker), [s1, s2, s1, nil])
        XCTAssertEqual(result.transcript.turns.map(\.span), transcript().turns.map(\.span))
        XCTAssertEqual(result.cleanedCount, 3)
        XCTAssertEqual(result.unchangedCount, 1)
        XCTAssertEqual(result.fallbackCount, 0)
        XCTAssertEqual(result.inferenceMS, 3)
        XCTAssertGreaterThanOrEqual(result.elapsedMS, 0)
        let calls = await runtime.calls
        XCTAssertEqual(calls, 3) // the empty turn runs no inference
        for turn in result.turns {
            XCTAssertEqual(try TextEdit.applying(turn.result.edits, to: turn.turn.text), turn.text)
        }
    }

    func testRejectedTurnKeepsExactBytesWhileOthersClean() async throws {
        let runtime = CountingRuntime { $0.hasPrefix("fine") ? "assistant: invented" : $0 + "." }
        let session = try CleanupSession(runtime: runtime, provenance: provenance)
        let result = try await session.clean(transcript())
        await session.close()
        XCTAssertEqual(result.turns[1].result.status, .fallback(.rejected))
        XCTAssertEqual(Array(result.turns[1].text.utf8), Array("fine thanks".utf8))
        XCTAssertTrue(result.turns[1].result.edits.isEmpty)
        XCTAssertEqual(result.turns[0].result.status, .cleaned)
        XCTAssertEqual(result.fallbackCount, 1)
    }

    func testOverallDeadlineStopsInferenceAndKeepsRemainingTurns() async throws {
        let runtime = CountingRuntime(delay: .milliseconds(150))
        let session = try CleanupSession(runtime: runtime, provenance: provenance)
        let many = Transcript(turns: (0..<6).map { SpeakerTurn(speaker: s1, text: "turn \($0)") })
        let result = try await session.clean(many, options: TranscriptCleanOptions(overallDeadline: .milliseconds(200)))
        await session.close()
        let calls = await runtime.calls
        XCTAssertLessThanOrEqual(calls, 2)
        XCTAssertGreaterThanOrEqual(calls, 1)
        XCTAssertEqual(result.turns.count, 6)
        let skipped = result.turns.filter { $0.result.warnings.contains("transcript-budget-exhausted") }
        XCTAssertGreaterThanOrEqual(skipped.count, 4)
        for turn in skipped {
            XCTAssertEqual(turn.result.status, .fallback(.timedOut))
            XCTAssertEqual(turn.text, turn.turn.text)
            XCTAssertTrue(turn.result.edits.isEmpty)
            XCTAssertEqual(turn.result.provenance, .skipped)
            XCTAssertEqual(turn.result.provenance.route, "skipped")
        }
        // Order is preserved: every skipped turn comes after every turn that ran.
        let firstSkipped = result.turns.firstIndex { $0.result.provenance == .skipped } ?? result.turns.count
        XCTAssertTrue(result.turns[firstSkipped...].allSatisfy { $0.result.provenance == .skipped })
    }

    func testOversizeTurnIsSkippedWithoutInference() async throws {
        let runtime = CountingRuntime()
        let session = try CleanupSession(runtime: runtime, provenance: provenance)
        let huge = String(repeating: "a", count: CleanupRequest.maxTextBytes + 1)
        let result = try await session.clean(Transcript(turns: [SpeakerTurn(text: "ok"), SpeakerTurn(text: huge)]))
        await session.close()
        let texts = await runtime.texts
        XCTAssertEqual(texts, ["ok"])
        XCTAssertEqual(result.turns[1].result.status, .fallback(.unavailable))
        XCTAssertEqual(result.turns[1].result.warnings, ["turn-exceeds-admission-limit"])
        XCTAssertEqual(result.turns[1].text.utf8.count, huge.utf8.count)
    }

    func testHopelessTurnBudgetIsSkippedWithoutInference() async throws {
        let runtime = CountingRuntime()
        let session = try CleanupSession(runtime: runtime, provenance: provenance)
        // 0.6 s overhead can never fit a 1 ms ceiling, so every turn is hopeless.
        let policy = try CleanupBudgetPolicy(fixedOverheadS: 0.6, throughputCharsPerS: 110, headroom: 1, ceilingS: 0.001)
        let result = try await session.clean(Transcript("some words"), options: TranscriptCleanOptions(turnBudget: policy))
        await session.close()
        let calls = await runtime.calls
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(result.turns[0].result.status, .fallback(.timedOut))
        XCTAssertEqual(result.turns[0].result.warnings, ["turn-budget-hopeless"])
        // A workable policy sizes the deadline and the turn runs.
        let sized = try await session.clean(Transcript("some words"),
                                            options: TranscriptCleanOptions(turnBudget: .measuredM1))
        XCTAssertEqual(sized.turns[0].result.status, .fallback(.unavailable)) // session is closed; still exact bytes
    }

    func testVocabularyAndTransformsReachEveryRequest() async throws {
        let runtime = CountingRuntime { "Hi John, new line, " + $0 }
        let session = try CleanupSession(runtime: runtime, provenance: provenance)
        let options = TranscriptCleanOptions(vocabulary: ["Pomvox"], transforms: [.spokenLayout])
        let result = try await session.clean(Transcript(turns: [SpeakerTurn(text: "thanks")]), options: options)
        await session.close()
        XCTAssertEqual(result.text, "Hi John,\nThanks")
        XCTAssertEqual(result.turns[0].result.provenance.settings["transforms"], "spokenLayout")
        XCTAssertNotNil(result.turns[0].result.provenance.settings["vocabularySHA256"])
        await XCTAssertThrowsErrorAsync(try await session.clean(Transcript("x"),
            options: TranscriptCleanOptions(vocabulary: ["bad\nterm"])))
    }

    func testProgressAndCancellation() async throws {
        let runtime = CountingRuntime(delay: .milliseconds(100))
        let session = try CleanupSession(runtime: runtime, provenance: provenance)
        let seen = Progress()
        let many = Transcript(turns: (0..<5).map { SpeakerTurn(text: "turn \($0)") })
        let task = Task { try await session.clean(many, options: TranscriptCleanOptions(progress: { done, total in seen.record(done, total) })) }
        try await Task.sleep(for: .milliseconds(150))
        task.cancel()
        do { _ = try await task.value; XCTFail("cancellation must throw") }
        catch is CancellationError {}
        catch { XCTFail("unexpected \(error)") }
        XCTAssertLessThan(seen.calls.count, 5)
        XCTAssertTrue(seen.calls.allSatisfy { $0.total == 5 })
        await session.close()
    }

    func testInvalidTranscriptAndDeadlineAreRefusedBeforeAnyInference() async throws {
        let runtime = CountingRuntime()
        let session = try CleanupSession(runtime: runtime, provenance: provenance)
        let tooMany = Transcript(turns: Array(repeating: SpeakerTurn(text: "a"), count: Transcript.maxTurns + 1))
        await XCTAssertThrowsErrorAsync(try await session.clean(tooMany))
        await XCTAssertThrowsErrorAsync(try await session.clean(Transcript("a"), options: TranscriptCleanOptions(overallDeadline: .zero)))
        let calls = await runtime.calls
        XCTAssertEqual(calls, 0)
        await session.close()
    }
}

private final class Progress: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(done: Int, total: Int)] = []
    var calls: [(done: Int, total: Int)] { lock.lock(); defer { lock.unlock() }; return recorded }
    func record(_ done: Int, _ total: Int) { lock.lock(); recorded.append((done, total)); lock.unlock() }
}

func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T,
                                  file: StaticString = #filePath, line: UInt = #line) async {
    do { _ = try await expression(); XCTFail("expected an error", file: file, line: line) } catch {}
}
