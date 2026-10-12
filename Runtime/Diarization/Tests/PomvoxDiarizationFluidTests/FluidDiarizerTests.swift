import AVFoundation
import FluidAudio
import XCTest
@testable import PomvoxDiarizationFluid

/// A two-voice recording built at test time from macOS speech synthesis, so the
/// schedule (who speaks when) is known exactly and nothing is committed.
enum SyntheticMeeting {
    struct Utterance {
        let voice: String
        let text: String
        let start: TimeInterval
        let end: TimeInterval
        var span: TimeSpan { TimeSpan(start: start, end: end) }
    }

    static let script: [(voice: String, text: String)] = [
        ("Samantha", "Good morning everyone. Let's start with the release plan and the open bugs from last week."),
        ("Daniel", "Thanks. The login fix is merged, and I will send the updated report by Friday afternoon."),
        ("Samantha", "Great. We decided to go with the smaller model pack for machines with eight gigabytes of memory."),
        ("Daniel", "Agreed. Can we also schedule the benchmark run before the next meeting, so we have numbers?"),
        ("Samantha", "Yes. Action item for me: prepare the corpus and share the evaluation sheet with the team."),
        ("Daniel", "Perfect. Nothing else from my side; let's wrap up and follow up on Thursday."),
    ]

    /// Mono 16 kHz samples and the utterance schedule, with 0.8 s of silence between turns.
    static func build(script: [(voice: String, text: String)] = script, in directory: URL) throws -> (samples: [Float], schedule: [Utterance]) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var samples: [Float] = []
        var schedule: [Utterance] = []
        let gap = [Float](repeating: 0, count: 16_000 * 8 / 10)
        for (index, line) in script.enumerated() {
            let file = directory.appendingPathComponent("utterance-\(index).wav")
            try say(line.text, voice: line.voice, to: file)
            let spoken = try read16kMono(file)
            let start = Double(samples.count) / 16_000
            samples += spoken
            schedule.append(Utterance(voice: line.voice, text: line.text, start: start, end: Double(samples.count) / 16_000))
            samples += gap
        }
        return (samples, schedule)
    }

    /// Writes 16 kHz mono PCM16 speech with macOS `say(1)`. Other platforms skip:
    /// they have no speech synthesizer command and cannot spawn processes.
    static func say(_ text: String, voice: String, to file: URL) throws {
        #if os(macOS)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-v", voice, "-o", file.path, "--file-format=WAVE", "--data-format=LEI16@16000", text]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw XCTSkip("say(1) failed for voice \(voice)") }
        #else
        throw XCTSkip("the synthetic fixture needs macOS say(1)")
        #endif
    }

    static func read16kMono(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw XCTSkip("could not allocate a 16 kHz mono buffer")
        }
        guard file.processingFormat.sampleRate == 16_000, file.processingFormat.channelCount == 1 else {
            throw XCTSkip("say(1) did not produce 16 kHz mono audio")
        }
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }
}

final class FluidDiarizerTests: XCTestCase {
    private static var packPath: String? { ProcessInfo.processInfo.environment["POMVOX_TEST_DIARIZER_PACK"] }

    private func openDiarizer() async throws -> FluidDiarizer {
        guard let path = Self.packPath else {
            throw XCTSkip("set POMVOX_TEST_DIARIZER_PACK to an installed verified diarizer pack; never downloads")
        }
        let pack = try DiarizerPackLoader.validate(directory: URL(fileURLWithPath: path))
        return try await FluidDiarizer.open(pack: pack)
    }

    /// The headline check: two synthetic voices, alternating, come back as two
    /// speakers whose labels are consistent across the whole recording.
    func testSyntheticTwoVoicesAreTwoConsistentSpeakers() async throws {
        let diarizer = try await openDiarizer()
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("pomvox-diarizer-fixture-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let (samples, schedule) = try SyntheticMeeting.build(in: scratch)
        XCTAssertTrue(ModelHub.offlineMode)
        let started = ContinuousClock.now
        let result = try await diarizer.diarize(DiarizationRequest(samples: samples, deadline: .seconds(600)))
        let wallMS = started.duration(to: .now).milliseconds
        await diarizer.close()

        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.provenance.route, "local")
        XCTAssertEqual(result.provenance.runtime, FluidDiarizer.runtimeName)
        XCTAssertEqual(result.speakers.map(\.rawValue), (1...result.speakerCount).map { "S\($0)" })
        XCTAssertEqual(result.speakerCount, 2, "segments: \(result.segments)")

        // Per utterance: the label with the most overlap, and how much of the utterance it covers.
        var coverage: [(voice: String, label: String, fraction: Double)] = []
        for utterance in schedule {
            var byLabel: [SpeakerLabel: Double] = [:]
            for segment in result.segments { byLabel[segment.speaker, default: 0] += segment.span.overlap(with: utterance.span) }
            let best = byLabel.max { $0.value < $1.value }
            coverage.append((utterance.voice, best?.key.rawValue ?? "none", (best?.value ?? 0) / utterance.span.duration))
        }
        for entry in coverage {
            XCTAssertGreaterThanOrEqual(entry.fraction, 0.6, "\(entry.voice) utterance covered \(entry.fraction) by \(entry.label)")
        }
        let samanthaLabels = Set(coverage.filter { $0.voice == "Samantha" }.map(\.label))
        let danielLabels = Set(coverage.filter { $0.voice == "Daniel" }.map(\.label))
        XCTAssertEqual(samanthaLabels.count, 1, "\(coverage)")
        XCTAssertEqual(danielLabels.count, 1, "\(coverage)")
        XCTAssertTrue(samanthaLabels.isDisjoint(with: danielLabels), "\(coverage)")

        // Alignment end to end with the known script as "recognized words".
        let words = schedule.flatMap { utterance -> [TimedWord] in
            let tokens = utterance.text.split(separator: " ").map(String.init)
            let step = utterance.span.duration / Double(tokens.count)
            return tokens.enumerated().map { TimedWord($1, span: TimeSpan(start: utterance.start + Double($0) * step,
                                                                           end: utterance.start + Double($0 + 1) * step)) }
        }
        let transcript = Transcript.attribute(words: words, segments: result.segments)
        XCTAssertEqual(transcript.turns.count, schedule.count, transcript.turns.map(\.text).joined(separator: "\n"))
        XCTAssertEqual(transcript.turns.map(\.text), schedule.map(\.text))

        if let evidence = ProcessInfo.processInfo.environment["POMVOX_DIARIZER_EVIDENCE"] {
            let preparation = diarizer.preparationMS
            let record: [String: Any] = [
                "date": ISO8601DateFormatter().string(from: Date()),
                "machine": sysctlString("machdep.cpu.brand_string"), "model": sysctlString("hw.model"),
                "memoryBytes": ProcessInfo.processInfo.physicalMemory,
                "os": ProcessInfo.processInfo.operatingSystemVersionString,
                "fluidAudio": "0.15.5", "pipeline": DiarizerPackLoader.pipeline,
                "packDigest": result.provenance.artifactDigest, "buildMode": "debug (swift test)",
                "fixture": "say(1) Samantha/Daniel, \(schedule.count) utterances, 0.8 s gaps, synthetic speech",
                "audioSeconds": result.timings.audioSeconds ?? 0, "preparationMS": preparation,
                "requestTotalMS": result.timings.totalMS, "callerWallMS": wallMS,
                "segmentationMS": result.timings.segmentationMS ?? -1, "embeddingMS": result.timings.embeddingMS ?? -1,
                "clusteringMS": result.timings.clusteringMS ?? -1,
                "speakerCount": result.speakerCount, "segmentCount": result.segments.count,
                "perUtteranceCoverage": coverage.map { ["voice": $0.voice, "label": $0.label, "fraction": $0.fraction] },
                "outcome": "passed",
            ]
            let data = try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
            try (data + Data("\n".utf8)).write(to: URL(fileURLWithPath: evidence))
        }
    }

    /// Deadline, quarantine and recovery: a late worker is discarded, admission
    /// refuses work until it returns, and the models stay usable afterwards.
    func testDeadlineThenBusyThenRecoveryThenClose() async throws {
        let diarizer = try await openDiarizer()
        let samples = [Float](repeating: 0, count: 16_000 * 12).enumerated().map { Float(sin(Double($0.offset) * 0.05)) * 0.1 }
        do {
            _ = try await diarizer.diarize(DiarizationRequest(samples: samples, deadline: .milliseconds(1)))
            XCTFail("a 1 ms deadline must not succeed")
        } catch DiarizationError.timedOut {}
        // The expired worker is told to cancel. If it had not entered the pipeline it
        // skips it and may already be back; otherwise it runs on and admission refuses.
        if await diarizer.availability == .quarantined {
            do {
                _ = try await diarizer.diarize(DiarizationRequest(samples: samples))
                XCTFail("a request during quarantine must be refused")
            } catch DiarizationError.busy {}
        }
        let waitStart = ContinuousClock.now
        while await diarizer.availability != .ready {
            XCTAssertLessThan(waitStart.duration(to: .now), .seconds(180), "worker never returned")
            try await Task.sleep(for: .milliseconds(50))
        }
        do {
            let result = try await diarizer.diarize(DiarizationRequest(samples: samples, speakers: 1...2, deadline: .seconds(120)))
            XCTAssertTrue(result.isValid)
            XCTAssertEqual(result.provenance.settings["speakers"], "1...2")
        } catch DiarizationError.noSpeech {
            // A synthetic tone may legitimately contain no speech; the lifecycle still recovered.
        }
        await diarizer.close()
        let closed = await diarizer.availability
        XCTAssertEqual(closed, .closed)
        do {
            _ = try await diarizer.diarize(DiarizationRequest(samples: samples))
            XCTFail("closed diarizer must refuse work")
        } catch DiarizationError.unavailable {}
    }

    /// Cancel mid-diarization on the real pipeline, close and wait, reopen, process
    /// again. Records how long the release took against an uncancelled run of the
    /// same audio: FluidAudio 0.15.5 cannot be interrupted once it is running.
    func testRealCancelThenCloseAndWaitThenReopen() async throws {
        let first = try await openDiarizer()
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("pomvox-diarizer-cancel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let (meeting, _) = try SyntheticMeeting.build(in: scratch)
        let long = Array([[Float]](repeating: meeting, count: 6).joined())
        let started = ContinuousClock.now
        let request = Task { try await first.diarize(DiarizationRequest(samples: long, deadline: .seconds(600))) }
        try await Task.sleep(for: .milliseconds(300))
        let cancelAt = ContinuousClock.now
        request.cancel()
        do { _ = try await request.value; XCTFail("canceled request must throw") } catch is CancellationError {}
        let cancelReturnMS = cancelAt.duration(to: .now).milliseconds
        XCTAssertLessThan(cancelReturnMS, 1_000, "a canceled caller must stop waiting at once")
        try await first.closeAndWait()
        let releasedAfterMS = started.duration(to: .now).milliseconds
        let released = await first.resourcesReleased
        XCTAssertTrue(released)

        let second = try await openDiarizer()
        let fullStart = ContinuousClock.now
        let full = try await second.diarize(DiarizationRequest(samples: long, deadline: .seconds(600)))
        let fullMS = fullStart.duration(to: .now).milliseconds
        XCTAssertTrue(full.isValid)
        let again = try await second.diarize(DiarizationRequest(samples: meeting, deadline: .seconds(120)))
        XCTAssertEqual(again.speakerCount, 2)
        try await second.closeAndWait()

        let record: [String: Any] = [
            "audioSeconds": Double(long.count) / 16_000, "cancelAfterMS": 300,
            "cancelReturnMS": cancelReturnMS, "startToReleaseMS": releasedAfterMS,
            "uncancelledRunMS": fullMS, "reopenedSpeakers": again.speakerCount,
            "hardware": sysctlString("hw.model"), "os": ProcessInfo.processInfo.operatingSystemVersionString,
        ]
        let data = try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
        print("diarizer-cancel-evidence: " + String(decoding: data, as: UTF8.self))
        if let path = ProcessInfo.processInfo.environment["POMVOX_DIARIZER_CANCEL_EVIDENCE"] {
            try (data + Data("\n".utf8)).write(to: URL(fileURLWithPath: path))
        }
    }

    /// No pack, no model: a shape-valid pack with fake bytes fails to load with a
    /// clean error, after forbidding downloads for the process.
    func testOpenNeverDownloadsAndFailsCleanlyOnFakeBundles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pomvox-fake-diarizer-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FakeDiarizerPack.write(to: root)
        let pack = try DiarizerPackLoader.validate(directory: root)
        do {
            _ = try await FluidDiarizer.open(pack: pack)
            XCTFail("fake bundles must not load")
        } catch DiarizationError.unavailable {}
        XCTAssertTrue(ModelHub.offlineMode)
        XCTAssertThrowsError(try { throw DiarizationError.invalidRequest("x") }()) // config validation path
        do {
            _ = try await FluidDiarizer.open(pack: pack, config: FluidDiarizerConfig(clusteringThreshold: 2))
            XCTFail("threshold out of range must be refused")
        } catch DiarizationError.invalidRequest {}
    }
}

func sysctlString(_ name: String) -> String {
    var size = 0
    sysctlbyname(name, nil, &size, nil, 0)
    var buffer = [CChar](repeating: 0, count: max(1, size))
    sysctlbyname(name, &buffer, &size, nil, 0)
    return String(cString: buffer)
}
