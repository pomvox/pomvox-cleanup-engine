import XCTest
@testable import PomvoxCleanupMLX

/// Incremental transcript cleanup on the real pack: a run interrupted after some
/// turns and resumed from its checkpoint must equal an uninterrupted batch run,
/// byte for byte, on the same cleaner. Records every turn's outcome and timing.
final class TranscriptResumeTests: XCTestCase {
    func testInterruptedAndResumedEqualsBatchOnTheRealPack() async throws {
        guard let path = ProcessInfo.processInfo.environment["POMVOX_TEST_PACK"] else {
            throw XCTSkip("set POMVOX_TEST_PACK to an installed verified pack; never downloads")
        }
        let cleaner = try await Cleaner.open(pack: .directory(URL(fileURLWithPath: path)), runtime: .mlx, policy: .local)
        let transcript = Transcript(turns: ModelDifferentialTests.transcripts.enumerated().map { index, text in
            SpeakerTurn(speaker: SpeakerLabel(index % 3 == 2 ? "S2" : "S1"), text: text,
                        span: TimeSpan(start: Double(index) * 5, end: Double(index) * 5 + 4.5))
        })
        let batchStart = ContinuousClock.now
        let batch = try await cleaner.clean(transcript)
        let batchMS = batchStart.duration(to: .now).milliseconds

        let cut = 9
        var accepted: [TurnResult] = []
        let firstStart = ContinuousClock.now
        for try await cleaned in cleaner.cleanIncrementally(transcript) {
            accepted.append(cleaned.result)
            if accepted.count == cut { break }
        }
        let firstMS = firstStart.duration(to: .now).milliseconds
        let checkpoint = TranscriptCheckpoint(identity: try await cleaner.checkpointIdentity(for: transcript), accepted: accepted)
        let saved = try JSONEncoder().encode(checkpoint)
        // The stream was abandoned mid-transcript; wait for the worker to be free again.
        while await cleaner.availability != .ready { try await Task.sleep(for: .milliseconds(10)) }
        var resumed: [TurnResult] = []
        let resumeStart = ContinuousClock.now
        for try await cleaned in cleaner.cleanIncrementally(transcript,
                resuming: try JSONDecoder().decode(TranscriptCheckpoint.self, from: saved)) {
            XCTAssertEqual(cleaned.index, cut + resumed.count)
            resumed.append(cleaned.result)
        }
        let resumeMS = resumeStart.duration(to: .now).milliseconds
        try await cleaner.closeAndWait()

        let combined = accepted + resumed
        XCTAssertEqual(combined.count, batch.turns.count)
        for (index, (a, b)) in zip(batch.turns, combined).enumerated() {
            XCTAssertEqual(Array(a.text.utf8), Array(b.text.utf8), "turn \(index) text")
            XCTAssertEqual(a.result.edits, b.result.edits, "turn \(index) edits")
            XCTAssertEqual(a.result.status, b.result.status, "turn \(index) status")
            XCTAssertEqual(a.result.provenance, b.result.provenance, "turn \(index) provenance")
            XCTAssertEqual(a.turn, b.turn, "turn \(index) speaker and span")
            XCTAssertEqual(Array(try TextEdit.applying(b.result.edits, to: transcript.turns[index].text).utf8), Array(b.text.utf8))
        }

        func outcomes(_ turns: [TurnResult]) -> [[String: Any]] {
            turns.map { turn in
                ["status": "\(turn.result.status)", "inputBytes": turn.turn.text.utf8.count, "outputBytes": turn.text.utf8.count,
                 "totalMS": turn.result.timings.totalMS, "inferenceMS": turn.result.timings.inferenceMS ?? NSNull(),
                 "warnings": turn.result.warnings]
            }
        }
        let record: [String: Any] = [
            "pack": "\(cleaner.pack.manifest.id) \(cleaner.pack.manifest.version)", "turns": transcript.turns.count, "cut": cut,
            "batchMS": batchMS, "firstPartMS": firstMS, "resumedPartMS": resumeMS,
            "batch": outcomes(batch.turns), "interruptedThenResumed": outcomes(combined),
            "os": ProcessInfo.processInfo.operatingSystemVersionString, "memoryBytes": ProcessInfo.processInfo.physicalMemory,
        ]
        let data = try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
        if let evidence = ProcessInfo.processInfo.environment["POMVOX_TRANSCRIPT_EVIDENCE"] {
            try data.write(to: URL(fileURLWithPath: evidence))
        }
    }
}
