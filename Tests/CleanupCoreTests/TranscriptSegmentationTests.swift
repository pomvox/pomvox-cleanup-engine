import CleanupNotes
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

/// Deterministic cleanup double. Drops filler words, capitalizes, ends with a
/// period. Text containing "assistant" gets an invented reply the guards reject;
/// text over `outputCapBytes` fails as the real runtime does at its output cap.
private actor SegmentRuntime: CleanupRuntime {
    private(set) var texts: [String] = []
    private let delay: Duration
    private let outputCapBytes: Int
    init(delay: Duration = .zero, outputCapBytes: Int = .max) { self.delay = delay; self.outputCapBytes = outputCapBytes }
    func generate(_ request: CleanupRequest, deadline: ContinuousClock.Instant) async throws -> RuntimeOutput {
        texts.append(request.text)
        if delay > .zero { try await Task.sleep(for: delay) }
        var timings = CleanupTimings()
        timings.inferenceMS = 1
        timings.decodeTokens = request.text.utf8.count / 4
        if request.text.utf8.count > outputCapBytes { return RuntimeOutput(candidate: nil, failure: .tokenLimit, timings: timings) }
        if request.text.contains("assistant") { return RuntimeOutput(candidate: "assistant: invented", timings: timings) }
        let kept = request.text.split(separator: " ", omittingEmptySubsequences: false).filter { $0 != "um" && $0 != "uh" }.joined(separator: " ")
        let capitalized = kept.prefix(1).uppercased() + kept.dropFirst()
        return RuntimeOutput(candidate: capitalized.last.map { ".!?。".contains($0) } == true ? capitalized : capitalized + ".", timings: timings)
    }
    func close() {}
}

/// Ignores cancellation on text containing "slowpoke" and stalls past any
/// deadline, as an uninterruptible GPU call would; otherwise cleans at once.
/// Records the most requests ever running at the same time.
private actor StallingRuntime: CleanupRuntime {
    private let stall: Duration
    private var running = 0
    private(set) var maxConcurrent = 0
    init(stall: Duration) { self.stall = stall }
    func generate(_ request: CleanupRequest, deadline: ContinuousClock.Instant) async throws -> RuntimeOutput {
        running += 1; maxConcurrent = max(maxConcurrent, running)
        defer { running -= 1 }
        if request.text.contains("slowpoke") { try? await Task.sleep(for: stall) }
        return RuntimeOutput(candidate: request.text.prefix(1).uppercased() + request.text.dropFirst() + "!")
    }
    func close() {}
}

final class TranscriptSegmentationTests: XCTestCase, @unchecked Sendable {
    private let provenance = Provenance(packID: "test", packVersion: "1.0.0", artifactDigest: "digest",
        modelRevision: "test", runtime: "deterministic-test-double", route: "local")
    private let speaker = SpeakerLabel("S1")
    private let span = TimeSpan(start: 12, end: 3_612)

    private func session(_ runtime: any CleanupRuntime) throws -> CleanupSession {
        try CleanupSession(runtime: runtime, provenance: provenance)
    }

    private static let sentences = [
        "um so we decided to ship the smaller pack on friday.", "uh the café near josé's office has wifi?",
        "i will send the updated report by thursday afternoon.", "naïve estimates said two weeks 👩🏽‍💻 but it took three.",
        "日本語のテストも含めます。", "the invoice is for twelve dollars and fifty cents!", "let's wrap up and follow up next week.",
        "e\u{301}clair orders go to the second floor 🇯🇵.", "can we also schedule the benchmark run before the next meeting?",
    ]

    private func monologue(bytes: Int, seed: UInt64 = 1) -> String {
        var random = SplitMix(seed: seed)
        var text = ""
        while text.utf8.count < bytes {
            if !text.isEmpty { text += Bool.random(using: &random) ? " " : (Bool.random(using: &random) ? "\n" : "  ") }
            text += Self.sentences.randomElement(using: &random)!
        }
        return text
    }

    /// Invariants every segmented turn keeps, whatever the model did.
    private func assertRoundTrips(_ turn: TurnResult, maxBytes: Int, requests: [String]? = nil,
                                  file: StaticString = #filePath, line: UInt = #line) throws {
        let input = Array(turn.turn.text.utf8), output = Array(turn.text.utf8)
        let segments = try XCTUnwrap(turn.segments, file: file, line: line)
        XCTAssertEqual(Array(try TextEdit.applying(turn.result.edits, to: turn.turn.text).utf8), output, "edits rebuild the text", file: file, line: line)
        for (a, b) in zip(turn.result.edits, turn.result.edits.dropFirst()) {
            XCTAssertLessThanOrEqual(a.end, b.start, "edits ordered and non-overlapping", file: file, line: line)
        }
        // Between segments only verbatim separators: whitespace, identical in input and output.
        var sourceCursor = 0, outputCursor = 0
        for segment in segments {
            let gapIn = input[sourceCursor..<segment.sourceStart]
            XCTAssertTrue(String(decoding: gapIn, as: UTF8.self).allSatisfy(\.isWhitespace), file: file, line: line)
            if turn.result.status == .cleaned {
                XCTAssertEqual(Array(output[outputCursor..<segment.outputStart]), Array(gapIn), "separator copied verbatim", file: file, line: line)
            }
            XCTAssertLessThanOrEqual(segment.sourceEnd - segment.sourceStart, maxBytes, file: file, line: line)
            if case .fallback = segment.status, turn.result.status == .cleaned {
                XCTAssertEqual(Array(output[segment.outputStart..<segment.outputEnd]), Array(input[segment.sourceStart..<segment.sourceEnd]),
                               "a segment that fell back keeps its exact bytes", file: file, line: line)
            }
            sourceCursor = segment.sourceEnd; outputCursor = segment.outputEnd
        }
        XCTAssertTrue(String(decoding: input[sourceCursor...], as: UTF8.self).allSatisfy(\.isWhitespace), file: file, line: line)
        if let requests {
            // Every segment was sent exactly once, in order, and nothing else was.
            XCTAssertEqual(requests.map { Array($0.utf8) }, segments.map { Array(input[$0.sourceStart..<$0.sourceEnd]) }, file: file, line: line)
        }
        XCTAssertEqual(turn.turn.speaker, speaker, file: file, line: line)
        XCTAssertEqual(turn.turn.span, span, file: file, line: line)
    }

    /// Over the admission limit: skipped unchanged without segmentation; with it,
    /// cleaned in segments with nothing omitted or duplicated.
    func testOversizeMonologueIsCleanedInSegments() async throws {
        let text = monologue(bytes: 20_000)
        XCTAssertGreaterThan(text.utf8.count, CleanupRequest.maxTextBytes)
        let transcript = Transcript(turns: [SpeakerTurn(speaker: speaker, text: text, span: span)])

        let plain = try await session(SegmentRuntime()).clean(transcript)
        XCTAssertEqual(plain.turns[0].result.status, .fallback(.unavailable))
        XCTAssertEqual(plain.turns[0].result.warnings, ["turn-exceeds-admission-limit"])
        XCTAssertNil(plain.turns[0].segments)

        let runtime = SegmentRuntime()
        let result = try await session(runtime).clean(transcript, options: TranscriptCleanOptions(segmentation: TurnSegmentation()))
        let turn = result.turns[0]
        XCTAssertEqual(turn.result.status, .cleaned)
        let requests = await runtime.texts
        XCTAssertGreaterThan(requests.count, 20)
        XCTAssertTrue(requests.allSatisfy { $0.utf8.count <= TurnSegmentation.defaultMaxSegmentBytes })
        try assertRoundTrips(turn, maxBytes: TurnSegmentation.defaultMaxSegmentBytes, requests: requests)
        XCTAssertEqual(turn.result.warnings.first, "segmented:\(requests.count)")
        XCTAssertEqual(turn.result.provenance.packID, "test")
        XCTAssertEqual(turn.result.provenance.settings["segmentation"], "maxSegmentBytes=1000")
        XCTAssertEqual(turn.result.timings.inferenceMS, Double(requests.count))
    }

    /// Admitted but too long for the output cap: one request ends in a token-limit
    /// fallback after spending model time; segments fit and clean.
    func testSegmentsStayUnderTheOutputCap() async throws {
        let text = monologue(bytes: 5_000, seed: 2)
        let transcript = Transcript(turns: [SpeakerTurn(speaker: speaker, text: text, span: span)])
        let plain = try await session(SegmentRuntime(outputCapBytes: 1_500)).clean(transcript)
        XCTAssertEqual(plain.turns[0].result.status, .fallback(.tokenLimit))
        XCTAssertEqual(Array(plain.turns[0].text.utf8), Array(text.utf8))
        let split = try await session(SegmentRuntime(outputCapBytes: 1_500)).clean(transcript,
            options: TranscriptCleanOptions(segmentation: TurnSegmentation()))
        XCTAssertEqual(split.turns[0].result.status, .cleaned)
        XCTAssertTrue(split.turns[0].segments!.allSatisfy { $0.status == .cleaned })
    }

    /// Turns at or under the limit are not touched: identical to a run without segmentation.
    func testShortTurnsAreUnaffected() async throws {
        let turns = (0..<300).map { SpeakerTurn(speaker: speaker, text: Self.sentences[$0 % Self.sentences.count], span: span) }
        let transcript = Transcript(turns: turns)
        let plain = try await session(SegmentRuntime()).clean(transcript)
        let split = try await session(SegmentRuntime()).clean(transcript, options: TranscriptCleanOptions(segmentation: TurnSegmentation()))
        XCTAssertEqual(plain.turns.map(\.text), split.turns.map(\.text))
        XCTAssertEqual(plain.turns.map(\.result.edits), split.turns.map(\.result.edits))
        XCTAssertTrue(split.turns.allSatisfy { $0.segments == nil })
    }

    /// Segmentation does not change the turn limit: one result per input turn.
    func testMaxTurnsStillAppliesToInputTurns() async throws {
        let options = TranscriptCleanOptions(segmentation: TurnSegmentation())
        let atLimit = Transcript(turns: Array(repeating: SpeakerTurn(text: ""), count: Transcript.maxTurns))
        let result = try await session(SegmentRuntime()).clean(atLimit, options: options)
        XCTAssertEqual(result.turns.count, Transcript.maxTurns)
        let over = Transcript(turns: Array(repeating: SpeakerTurn(text: ""), count: Transcript.maxTurns + 1))
        do { _ = try await session(SegmentRuntime()).clean(over, options: options); XCTFail("over the turn limit") }
        catch CleanupError.invalidRequest {}
        for bad in [0, 63, CleanupRequest.maxTextBytes + 1] {
            do {
                _ = try await session(SegmentRuntime()).clean(atLimit, options: TranscriptCleanOptions(segmentation: TurnSegmentation(maxSegmentBytes: bad)))
                XCTFail("segment size \(bad) must be refused")
            } catch CleanupError.invalidRequest {}
        }
    }

    /// Seeded: multi-byte, combining and emoji text, small limits so boundaries
    /// land everywhere, filler words at segment edges so edits touch boundaries,
    /// and some segments rejected. Every invariant holds for every case.
    func testPropertyRandomTurnsRoundTripAtEveryLimit() async throws {
        for seed in UInt64(1)...40 {
            var random = SplitMix(seed: seed)
            let words = ["um", "uh", "so", "café", "e\u{301}", "👋🏽", "👩‍💻", "日本語。", "ship.", "friday?", "naïve", "assistant", "привет!", "🇯🇵"]
            let text = (0..<Int.random(in: 40...400, using: &random)).map { _ in words.randomElement(using: &random)! }.joined(separator: " ")
            let maxBytes = [64, 97, 150, 333][Int(seed % 4)]
            let runtime = SegmentRuntime()
            let result = try await session(runtime).clean(Transcript(turns: [SpeakerTurn(speaker: speaker, text: text, span: span)]),
                options: TranscriptCleanOptions(segmentation: TurnSegmentation(maxSegmentBytes: maxBytes)))
            let requests = await runtime.texts
            let turn = result.turns[0]
            guard text.utf8.count > maxBytes else { XCTAssertNil(turn.segments); continue }
            try assertRoundTrips(turn, maxBytes: maxBytes, requests: requests)
            if turn.result.status != .cleaned {
                XCTAssertEqual(Array(turn.text.utf8), Array(text.utf8), "seed \(seed): no cleaned segment means exact input")
                XCTAssertTrue(turn.result.edits.isEmpty)
            }
            let rejected = turn.segments!.enumerated().filter { $0.element.status == .fallback(.rejected) }.map(\.offset)
            for index in rejected { XCTAssertTrue(turn.result.warnings.contains("segment-\(index)-fallback:rejected"), "seed \(seed)") }
        }
    }

    /// If every segment falls back, the turn is a fallback: exact input, no edits.
    func testAllSegmentsFallingBackIsTheExactInput() async throws {
        let text = String(repeating: "assistant please answer this. ", count: 80) + "end"
        let result = try await session(SegmentRuntime()).clean(Transcript(turns: [SpeakerTurn(speaker: speaker, text: text, span: span)]),
            options: TranscriptCleanOptions(segmentation: TurnSegmentation(maxSegmentBytes: 200)))
        let turn = result.turns[0]
        XCTAssertEqual(turn.result.status, .fallback(.rejected))
        XCTAssertEqual(Array(turn.text.utf8), Array(text.utf8))
        XCTAssertTrue(turn.result.edits.isEmpty)
        XCTAssertGreaterThan(turn.segments!.count, 1)
    }

    /// Cancellation throws from the batch call and never yields the split turn incrementally.
    func testCancellationDuringSegmentsDeliversNothingForTheTurn() async throws {
        let transcript = Transcript(turns: [SpeakerTurn(speaker: speaker, text: "short first turn", span: span),
                                            SpeakerTurn(speaker: speaker, text: monologue(bytes: 6_000), span: span)])
        let options = TranscriptCleanOptions(segmentation: TurnSegmentation())
        let runtime = SegmentRuntime(delay: .milliseconds(30))
        let cleaner = try session(runtime)
        let batch = Task { try await cleaner.clean(transcript, options: options) }
        while await runtime.texts.count < 3 { try await Task.sleep(for: .milliseconds(5)) }
        batch.cancel()
        do { _ = try await batch.value; XCTFail("canceled batch must throw") } catch is CancellationError {}

        let slow = SegmentRuntime(delay: .milliseconds(30))
        let incremental = try session(slow)
        var yielded: [Int] = []
        let consumer = Task { () -> [Int] in
            var seen: [Int] = []
            for try await cleaned in incremental.cleanIncrementally(transcript, options: options) { seen.append(cleaned.index) }
            return seen
        }
        while await slow.texts.count < 3 { try await Task.sleep(for: .milliseconds(5)) }
        consumer.cancel()
        yielded = (try? await consumer.value) ?? [0]
        XCTAssertFalse(yielded.contains(1), "a split turn interrupted mid-way is never yielded")
    }

    /// The overall deadline can run out between segments: later segments keep
    /// their exact bytes, marked, and the turn still round-trips.
    func testOverallDeadlineMidTurnKeepsLaterSegmentsExact() async throws {
        let text = monologue(bytes: 8_000, seed: 3)
        let runtime = SegmentRuntime(delay: .milliseconds(40))
        let result = try await session(runtime).clean(Transcript(turns: [SpeakerTurn(speaker: speaker, text: text, span: span)]),
            options: TranscriptCleanOptions(overallDeadline: .milliseconds(150), segmentation: TurnSegmentation()))
        let turn = result.turns[0]
        let segments = try XCTUnwrap(turn.segments)
        XCTAssertTrue(segments.contains { $0.status == .fallback(.timedOut) && $0.warnings == ["transcript-budget-exhausted"] })
        let sent = await runtime.texts
        XCTAssertLessThan(sent.count, segments.count)
        try assertRoundTrips(turn, maxBytes: TurnSegmentation.defaultMaxSegmentBytes)
    }

    /// Notes over a split turn quote the cleaned text with valid ranges, and each
    /// quote falls inside one segment, whose source range the host can show.
    func testNotesCiteSplitTurnsAndMapToSource() async throws {
        let text = (0..<60).map { _ in "we decided to ship on friday. i will send the report by thursday. can we meet next week?" }
            .joined(separator: " ")
        let result = try await session(SegmentRuntime()).clean(Transcript(turns: [SpeakerTurn(speaker: speaker, text: text, span: span)]),
            options: TranscriptCleanOptions(segmentation: TurnSegmentation(maxSegmentBytes: 300)))
        let turn = result.turns[0]
        let notes = Notes.extract(from: result)
        XCTAssertFalse(notes.items.isEmpty)
        let output = Array(turn.text.utf8), input = Array(text.utf8)
        for item in notes.items {
            XCTAssertEqual(Array(output[item.start..<item.end]), Array(item.text.utf8))
            let segment = try XCTUnwrap(turn.segments!.first { $0.outputStart <= item.start && item.end <= $0.outputEnd },
                                        "quote \(item.text) spans segments")
            let source = String(decoding: input[segment.sourceStart..<segment.sourceEnd], as: UTF8.self)
            XCTAssertTrue(source.lowercased().contains(item.text.lowercased().dropLast().split(separator: " ").last!))
        }
    }

    /// A request that times out leaves its worker quarantined until it returns.
    /// The next turns and segments wait for it within their own budget instead of
    /// falling back at once, and never overlap it. Seen on the real pack: one
    /// timed-out segment used to turn every later segment into `unavailable`.
    func testTimedOutPieceDoesNotCascadeIntoLaterPieces() async throws {
        let policy = try CleanupBudgetPolicy(fixedOverheadS: 0, throughputCharsPerS: 1e9, headroom: 1, ceilingS: 0.3)
        for segmented in [false, true] {
            let runtime = StallingRuntime(stall: .milliseconds(500))
            let cleaner = try session(runtime)
            let turns = segmented
                ? [SpeakerTurn(speaker: speaker, text: (["first part slowpoke."] + Array(repeating: "then more words follow here.", count: 8)).joined(separator: " "), span: span)]
                : [SpeakerTurn(speaker: speaker, text: "first part slowpoke", span: span)] + Array(repeating: SpeakerTurn(speaker: speaker, text: "then more words", span: span), count: 4)
            let result = try await cleaner.clean(Transcript(turns: turns), options: TranscriptCleanOptions(
                turnBudget: policy, turnBase: .milliseconds(300), segmentation: segmented ? TurnSegmentation(maxSegmentBytes: 64) : nil))
            let statuses = segmented ? result.turns[0].segments!.map(\.status) : result.turns.map(\.result.status)
            XCTAssertEqual(statuses.first, .fallback(.timedOut), "segmented \(segmented)")
            XCTAssertTrue(statuses.dropFirst().allSatisfy { $0 == .cleaned }, "segmented \(segmented): \(statuses)")
            let overlap = await runtime.maxConcurrent
            XCTAssertEqual(overlap, 1, "never a second worker while the first runs")
        }
    }

    /// Segmentation is part of a checkpoint's identity: results made with another
    /// segment size are not interchangeable.
    func testSegmentationIsPartOfTheCheckpointIdentity() async throws {
        let cleaner = try session(SegmentRuntime())
        let transcript = Transcript(turns: [SpeakerTurn(text: "hello")])
        let a = try await cleaner.checkpointIdentity(for: transcript)
        let b = try await cleaner.checkpointIdentity(for: transcript, options: TranscriptCleanOptions(segmentation: TurnSegmentation()))
        let c = try await cleaner.checkpointIdentity(for: transcript, options: TranscriptCleanOptions(segmentation: TurnSegmentation(maxSegmentBytes: 500)))
        XCTAssertNotEqual(a.optionsSHA256, b.optionsSHA256)
        XCTAssertNotEqual(b.optionsSHA256, c.optionsSHA256)
    }

    /// Old JSON without `segments` still decodes.
    func testTurnResultDecodesWithoutSegments() throws {
        let plain = TurnResult(turn: SpeakerTurn(text: "a"), result: CleanupResult(text: "a", edits: [], status: .unchanged, provenance: provenance))
        let data = try JSONEncoder().encode(plain)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("segments"))
        XCTAssertEqual(try JSONDecoder().decode(TurnResult.self, from: data), plain)
    }
}
