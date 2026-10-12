import XCTest
@testable import PomvoxCleanupMLX

/// Long turns on the real pack: one admitted 6 KB turn as a single request and
/// with opt-in segmentation, and an 18 KB turn (over the admission limit) with
/// segmentation. Records every outcome; asserts only the invariants that must
/// hold whatever the model does.
final class LongTurnTests: XCTestCase {
    private static func monologue(bytes: Int) -> String {
        var text = ""
        var index = 0
        while text.utf8.count < bytes {
            let line = ModelDifferentialTests.transcripts[index % ModelDifferentialTests.transcripts.count]
            text += (text.isEmpty ? "" : " ") + line + (line.last.map { ".!?".contains($0) } == true ? "" : ".")
            index += 1
        }
        return text
    }

    func testLongTurnsSingleRequestVersusSegmented() async throws {
        guard let path = ProcessInfo.processInfo.environment["POMVOX_TEST_PACK"] else {
            throw XCTSkip("set POMVOX_TEST_PACK to an installed verified pack; never downloads")
        }
        let cleaner = try await Cleaner.open(pack: .directory(URL(fileURLWithPath: path)), runtime: .mlx, policy: .local)
        let speaker = SpeakerLabel("S1"), span = TimeSpan(start: 0, end: 900)
        var runs: [[String: Any]] = []
        for (name, bytes, segmentation) in [("admitted-6KB-single-request", 6_000, nil as TurnSegmentation?),
                                            ("admitted-6KB-segmented", 6_000, TurnSegmentation()),
                                            ("oversize-18KB-segmented", 18_000, TurnSegmentation())] {
            let text = Self.monologue(bytes: bytes)
            let transcript = Transcript(turns: [SpeakerTurn(speaker: speaker, text: text, span: span)])
            let start = ContinuousClock.now
            let result = try await cleaner.clean(transcript, options: TranscriptCleanOptions(segmentation: segmentation))
            let elapsedMS = start.duration(to: .now).milliseconds
            let turn = result.turns[0]
            XCTAssertEqual(Array(try TextEdit.applying(turn.result.edits, to: text).utf8), Array(turn.text.utf8), name)
            XCTAssertEqual(turn.turn.speaker, speaker); XCTAssertEqual(turn.turn.span, span)
            if case .fallback = turn.result.status {
                XCTAssertEqual(Array(turn.text.utf8), Array(text.utf8), "\(name): a fallback is the exact input")
            }
            let input = Array(text.utf8), output = Array(turn.text.utf8)
            for segment in turn.segments ?? [] {
                XCTAssertLessThanOrEqual(segment.sourceEnd - segment.sourceStart, TurnSegmentation.defaultMaxSegmentBytes)
                if case .fallback = segment.status, turn.result.status == .cleaned {
                    XCTAssertEqual(Array(output[segment.outputStart..<segment.outputEnd]), Array(input[segment.sourceStart..<segment.sourceEnd]))
                }
            }
            runs.append([
                "name": name, "inputBytes": input.count, "outputBytes": output.count, "status": "\(turn.result.status)",
                "elapsedMS": elapsedMS, "inferenceMS": turn.result.timings.inferenceMS ?? NSNull(),
                "decodeTokens": turn.result.timings.decodeTokens ?? NSNull(), "warnings": turn.result.warnings,
                "segments": (turn.segments ?? []).map { ["sourceBytes": $0.sourceEnd - $0.sourceStart,
                                                         "outputBytes": $0.outputEnd - $0.outputStart, "status": "\($0.status)"] },
            ])
        }
        try await cleaner.closeAndWait()
        let record: [String: Any] = ["pack": "\(cleaner.pack.manifest.id) \(cleaner.pack.manifest.version)", "runs": runs,
                                     "os": ProcessInfo.processInfo.operatingSystemVersionString,
                                     "memoryBytes": ProcessInfo.processInfo.physicalMemory]
        let data = try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
        if let evidence = ProcessInfo.processInfo.environment["POMVOX_LONG_TURN_EVIDENCE"] {
            try data.write(to: URL(fileURLWithPath: evidence))
        }
    }
}
