import XCTest
@testable import CleanupCore

private actor CountingRuntime: CleanupRuntime {
    var active = 0
    var maximumActive = 0
    var calls = 0
    var closes = 0
    var closedWhileActive = false
    let output: RuntimeOutput?
    let delay: Duration
    init(output: RuntimeOutput? = nil, delay: Duration = .milliseconds(2)) {
        self.output = output; self.delay = delay
    }
    func generate(_ request: CleanupRequest, deadline: ContinuousClock.Instant) async throws -> RuntimeOutput {
        active += 1; calls += 1; maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        try await Task.sleep(for: delay)
        return output ?? RuntimeOutput(candidate: request.text)
    }
    func close() { closes += 1; closedWhileActive = closedWhileActive || active != 0 }
    func snapshot() -> (Int, Int, Int, Bool) { (calls, maximumActive, closes, closedWhileActive) }
}

final class LifecycleTests: XCTestCase, @unchecked Sendable {
    private let provenance = Provenance(packID: "test", packVersion: "1.0.0", artifactDigest: "digest",
        modelRevision: "revision", runtime: "controlled", route: "local")

    func testConcurrentBurstsRemainBoundedAndRecover() async throws {
        let runtime = CountingRuntime()
        let session = try CleanupSession(runtime: runtime, provenance: provenance, queueCapacity: 4)
        for _ in 0..<10 {
            let results = try await withThrowingTaskGroup(of: CleanupResult.self) { group in
                for _ in 0..<64 { group.addTask { try await session.clean("hello") } }
                var all: [CleanupResult] = []
                for try await result in group { all.append(result) }
                return all
            }
            XCTAssertEqual(results.count, 64)
            XCTAssertTrue(results.contains { $0.status == .unchanged })
            XCTAssertTrue(results.allSatisfy { $0.status == .unchanged || $0.status == .fallback(.busy) })
            for result in results {
                XCTAssertEqual(result.text, "hello"); XCTAssertTrue(result.edits.isEmpty)
                XCTAssertTrue(result.timings.isValid)
            }
        }
        let recovered = try await session.clean("hello")
        XCTAssertEqual(recovered.status, .unchanged)
        await session.close(); await session.close()
        let state = await runtime.snapshot()
        XCTAssertEqual(state.1, 1); XCTAssertEqual(state.2, 1); XCTAssertFalse(state.3)
    }

    func testRepeatedCancellationAndCloseNeverOverlapResourceRelease() async throws {
        for _ in 0..<40 {
            let runtime = CountingRuntime(delay: .milliseconds(50))
            let session = try CleanupSession(runtime: runtime, provenance: provenance)
            let tasks = (0..<8).map { _ in Task { try await session.clean("hello") } }
            for task in tasks { task.cancel() }
            await session.close()
            for task in tasks {
                do { _ = try await task.value; XCTFail("cancelled caller must throw") }
                catch is CancellationError {}
            }
            let closed = try await session.clean("hello")
            XCTAssertEqual(closed.status, .fallback(.unavailable))
            // Wait for cooperative runtime retirement, with a bounded test deadline.
            for _ in 0..<100 {
                if await runtime.snapshot().2 == 1 { break }
                try await Task.sleep(for: .milliseconds(2))
            }
            let state = await runtime.snapshot()
            XCTAssertEqual(state.2, 1); XCTAssertFalse(state.3)
            XCTAssertLessThanOrEqual(state.1, 1)
        }
    }

    func testRuntimeInvalidMetadataCannotEscapeOrBreakJSONEncoding() async throws {
        for value in [Double.nan, .infinity, -1] {
            var timings = CleanupTimings(); timings.inferenceMS = value
            let runtime = CountingRuntime(output: RuntimeOutput(candidate: "Hello.", timings: timings))
            let session = try CleanupSession(runtime: runtime, provenance: provenance)
            let result = try await session.clean("hello")
            XCTAssertEqual(result.status, .fallback(.invalidResponse))
            XCTAssertEqual(result.text, "hello"); XCTAssertTrue(result.edits.isEmpty)
            XCTAssertNoThrow(try JSONEncoder().encode(result))
            await session.close()
        }
    }

    func testVocabularyProvenancePreservesOrderAndBoundariesWithoutRawTerms() async throws {
        let session = try CleanupSession(runtime: CountingRuntime(), provenance: provenance)
        var hashes: Set<String> = []
        for vocabulary in [["ab", "c"], ["a", "bc"], ["c", "ab"], []] {
            let result = try await session.clean(CleanupRequest("hello", vocabulary: vocabulary))
            hashes.insert(try XCTUnwrap(result.provenance.settings["vocabularySHA256"]))
            XCTAssertEqual(result.provenance.settings.count, 1)
        }
        XCTAssertEqual(hashes.count, 4)
        await session.close()
    }

    func testRejectsInvalidSessionConfiguration() throws {
        for capacity in [-1, 17, Int.max] {
            XCTAssertThrowsError(try CleanupSession(runtime: CountingRuntime(), provenance: provenance, queueCapacity: capacity))
        }
        for preparation in [Double.nan, .infinity, -1] {
            XCTAssertThrowsError(try CleanupSession(runtime: CountingRuntime(), provenance: provenance, preparationMS: preparation))
        }
    }
}
