import CryptoKit
import FluidAudio
import XCTest
@testable import PomvoxDiarizationFluid

/// A shape-valid pack with fake artifact bytes: it validates, Core ML would refuse it.
enum FakeDiarizerPack {
    static func write(to root: URL) throws {
        var artifacts: [[String: Any]] = []
        for (index, path) in DiarizerPackLoader.artifactPaths.sorted().enumerated() {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = Data(repeating: UInt8(truncatingIfNeeded: index + 1), count: 32)
            try data.write(to: url)
            artifacts.append(["path": path, "bytes": data.count, "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()])
        }
        let manifest: [String: Any] = [
            "schemaVersion": 1, "id": "fake", "version": "0.0.1", "publisher": "test", "license": "CC-BY-4.0",
            "licenseURL": "https://example.invalid", "modelID": "x/y", "modelRevision": String(repeating: "b", count: 40),
            "runtime": DiarizerPackLoader.runtimeVersion, "pipeline": DiarizerPackLoader.pipeline,
            "attribution": ["nobody"], "artifacts": artifacts, "limitations": ["fake"], "evidence": "none",
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: root.appendingPathComponent("pack.json"))
    }
}

/// Pipeline runs across every diarizer in a test: how many started and finished,
/// the most ever in flight at once, and whether a run observed cancellation.
final class PipelineProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var counts = (started: 0, finished: 0, maxActive: 0, sawCancellation: false)

    var started: Int { lock.withLock { counts.started } }
    var finished: Int { lock.withLock { counts.finished } }
    var maxActive: Int { lock.withLock { counts.maxActive } }
    var sawCancellation: Bool { lock.withLock { counts.sawCancellation } }

    func enter() {
        lock.withLock {
            active += 1; counts.started += 1; counts.maxActive = max(counts.maxActive, active)
        }
    }

    func exit() {
        lock.withLock { active -= 1; counts.finished += 1; counts.sawCancellation = counts.sawCancellation || Task.isCancelled }
    }
}

/// Holds an uncooperative run until opened, like a Core ML call that ignores cancellation.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    func open() { lock.withLock { isOpen = true } }
    func wait() { while !lock.withLock({ isOpen }) { usleep(1_000) } }
}

extension DiarizationPipeline {
    static let segment = TimedSpeakerSegment(speakerId: "A", embedding: [], startTimeSeconds: 0, endTimeSeconds: 1, qualityScore: 1)

    /// Ignores cancellation and returns only when the gate opens.
    static func blocking(_ probe: PipelineProbe, _ gate: Gate) -> DiarizationPipeline {
        DiarizationPipeline { _, _ in
            probe.enter(); defer { probe.exit() }
            gate.wait()
            return DiarizationResult(segments: [segment])
        }
    }

    /// Checks for cancellation every 5 ms for up to 30 s.
    static func cooperative(_ probe: PipelineProbe) -> DiarizationPipeline {
        DiarizationPipeline { _, _ in
            probe.enter(); defer { probe.exit() }
            for _ in 0..<6_000 { try await Task.sleep(for: .milliseconds(5)) }
            return DiarizationResult(segments: [segment])
        }
    }

    static func immediate(_ probe: PipelineProbe) -> DiarizationPipeline {
        DiarizationPipeline { _, _ in
            probe.enter(); defer { probe.exit() }
            return DiarizationResult(segments: [segment])
        }
    }
}

/// Lifecycle of `FluidDiarizer` around test pipelines: cancellation, deadline,
/// quarantine, `closeAndWait` and reopening. No model is loaded.
final class LifecycleTests: XCTestCase {
    private var root: URL!
    private var pack: ValidatedDiarizerPack!
    private let samples = [Float](repeating: 0.1, count: 16_000 * 2)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pomvox-lifecycle-\(UUID().uuidString)")
        try FakeDiarizerPack.write(to: root)
        pack = try DiarizerPackLoader.validate(directory: root)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func diarizer(_ pipeline: DiarizationPipeline) -> FluidDiarizer {
        FluidDiarizer(pack: pack, config: FluidDiarizerConfig(), pipeline: pipeline, preparationMS: 0)
    }

    private func waitUntil(_ timeout: Duration = .seconds(5), _ condition: () async -> Bool) async throws {
        let start = ContinuousClock.now
        while !(await condition()) {
            guard start.duration(to: .now) < timeout else { return XCTFail("condition not reached in \(timeout)") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// The handoff scenario: cancel mid-diarization, close, await, reopen, process
    /// again. The wait outlasts the uncooperative run and ends when it returns;
    /// no second run ever overlaps it.
    func testCancelMidRunThenCloseAndWaitThenReopen() async throws {
        let probe = PipelineProbe(), gate = Gate()
        let first = diarizer(.blocking(probe, gate))
        let request = Task { try await first.diarize(DiarizationRequest(samples: samples, deadline: .seconds(30))) }
        try await waitUntil { probe.started == 1 }
        request.cancel()
        do { _ = try await request.value; XCTFail("canceled request must throw") } catch is CancellationError {}
        let quarantined = await first.availability
        XCTAssertEqual(quarantined, .quarantined)
        do { _ = try await first.diarize(DiarizationRequest(samples: samples)); XCTFail("must be busy") }
        catch DiarizationError.busy {}

        let waiter = Task { try await first.closeAndWait() }
        try await Task.sleep(for: .milliseconds(100))
        let releasedEarly = await first.resourcesReleased
        XCTAssertFalse(releasedEarly, "models must stay alive while the run is in flight")
        do { _ = try await first.diarize(DiarizationRequest(samples: samples)); XCTFail("closed must refuse") }
        catch DiarizationError.unavailable {}
        XCTAssertEqual(probe.finished, 0)
        gate.open()
        try await waiter.value
        let released = await first.resourcesReleased
        XCTAssertTrue(released)
        XCTAssertEqual(probe.finished, 1)

        let second = diarizer(.immediate(probe))
        let result = try await second.diarize(DiarizationRequest(samples: samples, deadline: .seconds(5)))
        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.speakerCount, 1)
        try await second.closeAndWait()
        XCTAssertEqual(probe.started, 2)
        XCTAssertEqual(probe.maxActive, 1)
    }

    /// A pipeline that does check cancellation is told to stop, so the release
    /// comes long before its 30 s run would have ended.
    func testCancellationReachesACooperativePipeline() async throws {
        let probe = PipelineProbe()
        let diarizer = diarizer(.cooperative(probe))
        let request = Task { try await diarizer.diarize(DiarizationRequest(samples: samples, deadline: .seconds(60))) }
        try await waitUntil { probe.started == 1 }
        request.cancel()
        do { _ = try await request.value; XCTFail("canceled request must throw") } catch is CancellationError {}
        let start = ContinuousClock.now
        try await diarizer.closeAndWait()
        XCTAssertLessThan(start.duration(to: .now), .seconds(5))
        XCTAssertTrue(probe.sawCancellation)
        XCTAssertEqual(probe.finished, 1)
    }

    /// After a deadline the late run keeps the diarizer quarantined: every request
    /// is refused and none starts a second run. When it returns, work resumes.
    func testDeadlineQuarantineNeverStartsASecondRun() async throws {
        let probe = PipelineProbe(), gate = Gate()
        let diarizer = diarizer(.blocking(probe, gate))
        do { _ = try await diarizer.diarize(DiarizationRequest(samples: samples, deadline: .milliseconds(50))); XCTFail("must time out") }
        catch DiarizationError.timedOut {}
        try await waitUntil { probe.started == 1 }
        for _ in 0..<20 {
            do { _ = try await diarizer.diarize(DiarizationRequest(samples: samples)); XCTFail("must be busy") }
            catch DiarizationError.busy {}
        }
        XCTAssertEqual(probe.started, 1)
        gate.open()
        try await waitUntil { await diarizer.availability == .ready }
        let result = try await diarizer.diarize(DiarizationRequest(samples: samples, deadline: .seconds(5)))
        XCTAssertTrue(result.isValid)
        XCTAssertEqual(probe.started, 2)
        XCTAssertEqual(probe.maxActive, 1)
        try await diarizer.closeAndWait()
    }

    /// Cancelling the wait stops waiting and throws; admission stays closed and the
    /// release still happens when the run returns.
    func testCancellingCloseAndWaitNeverReopens() async throws {
        let probe = PipelineProbe(), gate = Gate()
        let diarizer = diarizer(.blocking(probe, gate))
        let request = Task { try await diarizer.diarize(DiarizationRequest(samples: samples, deadline: .seconds(30))) }
        try await waitUntil { probe.started == 1 }
        let waiter = Task { try await diarizer.closeAndWait() }
        do { _ = try await request.value; XCTFail("close must fail the waiting request") }
        catch DiarizationError.unavailable {}
        waiter.cancel()
        do { try await waiter.value; XCTFail("canceled wait must throw") } catch is CancellationError {}
        let closed = await diarizer.availability
        XCTAssertEqual(closed, .closed)
        let releasedEarly = await diarizer.resourcesReleased
        XCTAssertFalse(releasedEarly)
        gate.open()
        try await waitUntil { await diarizer.resourcesReleased }
        do { _ = try await diarizer.diarize(DiarizationRequest(samples: samples)); XCTFail("closed must refuse") }
        catch DiarizationError.unavailable {}
    }

    /// Closing an idle diarizer releases at once, and `closeAndWait` is idempotent.
    func testCloseAndWaitOnIdleDiarizer() async throws {
        let probe = PipelineProbe()
        let diarizer = diarizer(.immediate(probe))
        try await diarizer.closeAndWait()
        try await diarizer.closeAndWait()
        let released = await diarizer.resourcesReleased
        XCTAssertTrue(released)
        XCTAssertEqual(probe.started, 0)
    }

    /// Through the protocol, as a host holding `any Diarizing` would call it.
    func testClosesThroughTheProtocol() async throws {
        let probe = PipelineProbe(), gate = Gate()
        let local = diarizer(.blocking(probe, gate))
        let any: any Diarizing = local
        let request = Task { try await any.diarize(DiarizationRequest(samples: samples, deadline: .seconds(30))) }
        try await waitUntil { probe.started == 1 }
        request.cancel()
        _ = try? await request.value
        let waiter = Task { try await any.closeAndWait() }
        try await Task.sleep(for: .milliseconds(50))
        let releasedEarly = await local.resourcesReleased
        XCTAssertFalse(releasedEarly, "the protocol call must reach FluidDiarizer's own wait, not the default")
        gate.open()
        try await waiter.value
        let released = await local.resourcesReleased
        XCTAssertTrue(released)
    }
}
