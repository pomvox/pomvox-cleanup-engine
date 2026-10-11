import Foundation
import XCTest
@testable import PomvoxDiarizationFluid

/// Several synthetic recordings through the real pipeline, every outcome recorded.
/// Assertions are deliberately only what the pipeline is expected to hold on
/// speech-synthesis voices: two distinct voices come back as two consistent
/// speakers; more voices never produce more speakers than there are voices;
/// speech is not lost. Where same-gender TTS voices merge, the evidence file
/// says so rather than the test pretending otherwise.
final class ScenarioTests: XCTestCase {
    struct Scenario {
        let name: String
        let script: [(voice: String, text: String)]
        let config: FluidDiarizerConfig
        let speakers: ClosedRange<Int>?
        let noise: Float
        let repeats: Int
        var expectedVoices: Int { Set(script.map(\.voice)).count }
    }

    static let release = [
        ("Samantha", "Let's begin with the budget review. We are slightly over on hardware this quarter."),
        ("Daniel", "The overage comes from the extra test machines. I will move two of them to the shared pool."),
        ("Karen", "Before we do that, can we confirm the lab still has capacity for the benchmark runs next week?"),
        ("Samantha", "Good question. We decided last month to keep one machine reserved for benchmarks."),
        ("Daniel", "Agreed, that reservation stays. I'll document it in the runbook by Thursday."),
        ("Karen", "Thanks. Second item: the documentation site needs the new pages before the release announcement."),
    ]
    static let planning = [
        ("Samantha", "Welcome everyone, this is the weekly planning call for the dictation product."),
        ("Daniel", "Thanks for having me. I have an update on the latency regression."),
        ("Moira", "Before that, one quick thing: the installer crashed on my machine this morning."),
        ("Rishi", "Same here, it failed on the second run."),
        ("Samantha", "Okay, let's take the installer first then. Rishi, can you file the crash with logs?"),
        ("Rishi", "Yes, I will file it today."),
        ("Daniel", "On latency, the fix is merged and the numbers are back to normal."),
        ("Moira", "Great news."),
        ("Samantha", "We decided to ship the fix in the next point release."),
    ]
    static let twoVoices = SyntheticMeeting.script

    static let scenarios: [Scenario] = [
        Scenario(name: "two-voices", script: twoVoices, config: .init(), speakers: nil, noise: 0, repeats: 1),
        Scenario(name: "two-voices-long", script: twoVoices, config: .init(), speakers: nil, noise: 0, repeats: 5),
        Scenario(name: "two-voices-noisy", script: twoVoices, config: .init(), speakers: nil, noise: 0.03, repeats: 2),
        Scenario(name: "three-voices", script: release, config: .init(), speakers: nil, noise: 0, repeats: 1),
        Scenario(name: "four-voices", script: planning, config: .init(), speakers: nil, noise: 0, repeats: 1),
        Scenario(name: "four-voices-min-segment-0.5", script: planning, config: .init(minSegmentSeconds: 0.5), speakers: nil, noise: 0, repeats: 1),
        Scenario(name: "four-voices-pinned-count", script: planning, config: .init(minSegmentSeconds: 0.5), speakers: 4...4, noise: 0, repeats: 1),
    ]

    func testScenariosRunAndRecordEveryOutcome() async throws {
        guard let path = ProcessInfo.processInfo.environment["POMVOX_TEST_DIARIZER_PACK"] else {
            throw XCTSkip("set POMVOX_TEST_DIARIZER_PACK to an installed verified diarizer pack; never downloads")
        }
        let pack = try DiarizerPackLoader.validate(directory: URL(fileURLWithPath: path))
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("pomvox-diarizer-scenarios-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        var records: [[String: Any]] = []
        for scenario in Self.scenarios {
            let script = Array(repeating: scenario.script, count: scenario.repeats).flatMap { $0 }
            var (samples, schedule) = try SyntheticMeeting.build(script: script, in: scratch.appendingPathComponent(scenario.name))
            if scenario.noise > 0 {
                var generator = SystemRandomNumberGenerator()
                samples = samples.map { $0 + Float.random(in: -scenario.noise...scenario.noise, using: &generator) }
            }
            let diarizer = try await FluidDiarizer.open(pack: pack, config: scenario.config)
            let result = try await diarizer.diarize(DiarizationRequest(samples: samples, speakers: scenario.speakers, deadline: .seconds(600)))
            await diarizer.close()
            XCTAssertTrue(result.isValid, scenario.name)

            // Per utterance: the label with the most overlap and its coverage.
            var perUtterance: [[String: Any]] = []
            var labelsByVoice: [String: Set<String>] = [:]
            var missed = 0.0, confused = 0.0
            var majority: [String: String] = [:]
            for utterance in schedule {
                var byLabel: [SpeakerLabel: Double] = [:]
                for segment in result.segments { byLabel[segment.speaker, default: 0] += segment.span.overlap(with: utterance.span) }
                let best = byLabel.max { $0.value < $1.value }
                let label = best?.key.rawValue ?? "none"
                perUtterance.append(["voice": utterance.voice, "seconds": utterance.span.duration, "label": label,
                                     "coverage": (best?.value ?? 0) / utterance.span.duration])
                labelsByVoice[utterance.voice, default: []].insert(label)
            }
            for (voice, labels) in labelsByVoice {
                let counts = perUtterance.filter { $0["voice"] as? String == voice }.reduce(into: [String: Int]()) { $0[$1["label"] as! String, default: 0] += 1 }
                majority[voice] = counts.max { $0.value < $1.value }?.key ?? labels.first ?? "none"
            }
            for utterance in schedule {
                let right = result.segments.filter { $0.speaker.rawValue == majority[utterance.voice] }
                    .reduce(0.0) { $0 + $1.span.overlap(with: utterance.span) }
                let other = result.segments.filter { $0.speaker.rawValue != majority[utterance.voice] }
                    .reduce(0.0) { $0 + $1.span.overlap(with: utterance.span) }
                confused += other
                missed += max(0, utterance.span.duration - right - other)
            }
            let oneLabelPerVoice = Set(majority.values).count == majority.count
                && perUtterance.allSatisfy { ($0["label"] as? String) == majority[$0["voice"] as! String] }

            // What must hold on synthetic voices.
            XCTAssertGreaterThanOrEqual(result.speakerCount, min(2, scenario.expectedVoices), scenario.name)
            XCTAssertLessThanOrEqual(result.speakerCount, scenario.expectedVoices, scenario.name)
            XCTAssertLessThan(missed, 1.5 + 0.3 * Double(scenario.repeats), "\(scenario.name): missed speech")
            if scenario.expectedVoices == 2 {
                XCTAssertEqual(result.speakerCount, 2, scenario.name)
                XCTAssertTrue(oneLabelPerVoice, "\(scenario.name): \(perUtterance)")
            }
            if scenario.name == "four-voices-min-segment-0.5" {
                let short = perUtterance.first { ($0["seconds"] as? Double ?? 10) < 1 }
                XCTAssertGreaterThan(short?["coverage"] as? Double ?? 0, 0.6, "a sub-second interjection gets a label at 0.5 s")
            }
            records.append([
                "scenario": scenario.name, "voices": scenario.expectedVoices, "utterances": schedule.count,
                "audioSeconds": Double(samples.count) / 16_000, "speechSeconds": schedule.reduce(0.0) { $0 + $1.span.duration },
                "speakersFound": result.speakerCount, "segments": result.segments.count,
                "confusedSeconds": confused, "missedSeconds": missed, "oneLabelPerVoice": oneLabelPerVoice,
                "requestTotalMS": result.timings.totalMS, "segmentationMS": result.timings.segmentationMS ?? -1,
                "embeddingMS": result.timings.embeddingMS ?? -1, "clusteringMS": result.timings.clusteringMS ?? -1,
                "preparationMS": diarizer.preparationMS, "settings": result.provenance.settings,
                "perUtterance": perUtterance,
            ])
        }
        if let evidence = ProcessInfo.processInfo.environment["POMVOX_DIARIZER_SCENARIO_EVIDENCE"] {
            let record: [String: Any] = [
                "date": ISO8601DateFormatter().string(from: Date()),
                "machine": sysctlString("machdep.cpu.brand_string"), "model": sysctlString("hw.model"),
                "memoryBytes": ProcessInfo.processInfo.physicalMemory,
                "os": ProcessInfo.processInfo.operatingSystemVersionString,
                "fluidAudio": "0.15.5", "pipeline": DiarizerPackLoader.pipeline, "buildMode": "debug",
                "fixture": "say(1) voices Samantha, Daniel, Karen, Moira, Rishi; 0.8 s gaps; synthetic speech from one TTS engine",
                "scenarios": records,
            ]
            let data = try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
            try (data + Data("\n".utf8)).write(to: URL(fileURLWithPath: evidence))
        }
    }
}
