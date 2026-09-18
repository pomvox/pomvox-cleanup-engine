import XCTest
@testable import CleanupCore

private actor ControlledRuntime: CleanupRuntime {
    private var continuation: CheckedContinuation<RuntimeOutput, Never>?
    private var startWaiter: CheckedContinuation<Void, Never>?
    private(set) var calls = 0
    private(set) var didClose = false
    func generate(_ request: CleanupRequest, deadline: ContinuousClock.Instant) async throws -> RuntimeOutput {
        calls += 1
        startWaiter?.resume(); startWaiter = nil
        // Deliberately ignores cancellation; proves the caller doesn't wait for a worker.
        return await withCheckedContinuation { continuation = $0 }
    }
    func waitStarted() async {
        if calls > 0 { return }
        await withCheckedContinuation { startWaiter = $0 }
    }
    func release(_ candidate: String = "Hello.") {
        continuation?.resume(returning: RuntimeOutput(candidate: candidate)); continuation = nil
    }
    func close() { didClose = true }
}

private struct ImmediateRuntime: CleanupRuntime {
    let output: RuntimeOutput
    func generate(_ request: CleanupRequest, deadline: ContinuousClock.Instant) async throws -> RuntimeOutput { output }
    func close() async {}
}

final class ContractTests: XCTestCase, @unchecked Sendable {
    private let provenance = Provenance(packID: "test", packVersion: "1.0.0", artifactDigest: "test",
        modelRevision: "test", runtime: "deterministic-test-double", route: "local")

    func testUnicodeReconstructionAndMapping() throws {
        let pairs = [("👩🏽‍💻 cafe\u{301}\n你好", "👩🏽‍💻 café\n你好！"), ("é", "e\u{301}"),
                     ("", "Hello"), ("a\r\nb", "A\r\nb."), ("سلام", "سلام!"), ("🇮🇳a", "🇮🇳b")]
        for (raw, out) in pairs {
            let edits = TextEdit.between(raw, and: out)
            XCTAssertEqual(Array(try TextEdit.applying(edits, to: raw).utf8), Array(out.utf8))
            for edit in edits { _ = try edit.range(in: raw); _ = try edit.utf16Range(in: raw) }
        }
        XCTAssertEqual(try TextEdit(start: 4, end: 5, replacement: "b").utf16Range(in: "😀a"), NSRange(location: 2, length: 1))
        XCTAssertThrowsError(try TextEdit(start: 1, end: 2, replacement: "").range(in: "😀"))
        XCTAssertThrowsError(try TextEdit.applying([.init(start: 1, end: 3, replacement: ""),
            .init(start: 2, end: 3, replacement: "")], to: "abcd"))
    }

    func testRawFallbackAndHonestOutcomes() async throws {
        for (output, expected) in [
            (RuntimeOutput(candidate: "Hello."), CleanupStatus.cleaned),
            (RuntimeOutput(candidate: "hello"), .unchanged),
            (RuntimeOutput(candidate: "assistant: invented"), .fallback(.rejected)),
            (RuntimeOutput(candidate: nil, failure: .tokenLimit), .fallback(.tokenLimit))
        ] {
            let session = try CleanupSession(runtime: ImmediateRuntime(output: output), provenance: provenance)
            let result = try await session.clean("hello")
            XCTAssertEqual(result.status, expected)
            XCTAssertEqual(try TextEdit.applying(result.edits, to: "hello"), result.text)
            if case .fallback = result.status { XCTAssertEqual(result.text, "hello"); XCTAssertTrue(result.edits.isEmpty) }
            await session.close()
        }
    }

    func testNonCooperativeDeadlineQuarantinesAndSuppressesLateResult() async throws {
        let runtime = ControlledRuntime()
        let session = try CleanupSession(runtime: runtime, provenance: provenance, queueCapacity: 1)
        let start = ContinuousClock.now
        let task = Task { try await session.clean(CleanupRequest("hello", deadline: .milliseconds(100))) }
        await runtime.waitStarted()
        let result = try await task.value
        XCTAssertEqual(result.status, .fallback(.timedOut))
        XCTAssertLessThan(start.duration(to: .now).milliseconds, 500)
        let quarantined = try await session.clean("hello")
        XCTAssertEqual(quarantined.status, .fallback(.unavailable))
        await session.close()
        let prematureClose = await runtime.didClose
        XCTAssertFalse(prematureClose)
        await runtime.release("late words must never be delivered")
        for _ in 0..<100 {
            if await runtime.didClose { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        let didClose = await runtime.didClose
        XCTAssertTrue(didClose)
    }

    func testQueueLimitAndQueueDeadline() async throws {
        let runtime = ControlledRuntime()
        let session = try CleanupSession(runtime: runtime, provenance: provenance, queueCapacity: 1)
        let first = Task { try await session.clean(CleanupRequest("hello", deadline: .seconds(2))) }
        await runtime.waitStarted()
        let second = Task { try await session.clean(CleanupRequest("queued", deadline: .milliseconds(150))) }
        try await Task.sleep(for: .milliseconds(20))
        let excess = try await session.clean("excess")
        XCTAssertEqual(excess.status, .fallback(.busy))
        let emptyWhileBusy = try await session.clean("")
        XCTAssertEqual(emptyWhileBusy.status, .unchanged)
        let queued = try await second.value
        XCTAssertEqual(queued.status, .fallback(.timedOut))
        XCTAssertGreaterThan(queued.timings.queueMS, 100)
        await runtime.release()
        let accepted = try await first.value
        XCTAssertEqual(accepted.status, .cleaned)
        let calls = await runtime.calls
        XCTAssertEqual(calls, 1)
        await session.close()
    }

    func testCancellationThrowsAndNeverBecomesFallback() async throws {
        let runtime = ControlledRuntime()
        let session = try CleanupSession(runtime: runtime, provenance: provenance)
        let task = Task { try await session.clean("hello") }
        await runtime.waitStarted()
        task.cancel()
        do { _ = try await task.value; XCTFail("cancellation must throw") }
        catch is CancellationError {} catch { XCTFail("unexpected error") }
        await runtime.release()
        await session.close()
        let preCancelled = Task { try Task.checkCancellation(); return try await session.clean("hello") }
        preCancelled.cancel()
        do { _ = try await preCancelled.value; XCTFail("must throw") } catch is CancellationError {}
    }

    func testInvalidRequestsAndEmptyInput() async throws {
        XCTAssertThrowsError(try CleanupRequest("x", deadline: .zero).validate())
        XCTAssertThrowsError(try CleanupRequest(String(repeating: "a", count: 16_385)).validate())
        XCTAssertThrowsError(try CleanupRequest("x", vocabulary: ["bad\nterm"]).validate())
        XCTAssertThrowsError(try CleanupRequest("x", deadline: .seconds(61)).validate())
        let runtime = ControlledRuntime()
        let session = try CleanupSession(runtime: runtime, provenance: provenance)
        let result = try await session.clean("")
        XCTAssertEqual(result.status, .unchanged)
        let calls = await runtime.calls
        XCTAssertEqual(calls, 0)
        await session.close()
    }
}
