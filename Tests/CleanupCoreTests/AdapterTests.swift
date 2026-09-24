import XCTest
import PomvoxCleanup
@testable import PomvoxAdapterExample

private actor DelayedCleaner: Cleaning {
    private var waiters: [String: CheckedContinuation<CleanupResult, Never>] = [:]
    func clean(_ request: CleanupRequest) async throws -> CleanupResult {
        await withCheckedContinuation { waiters[request.text] = $0 }
    }
    func has(_ text: String) -> Bool { waiters[text] != nil }
    func release(_ text: String) {
        waiters.removeValue(forKey: text)?.resume(returning: CleanupResult(text: text, edits: [],
            status: .fallback(.timedOut), provenance: Provenance(packID: "test", packVersion: "1",
                artifactDigest: "test", modelRevision: "test", runtime: "fake", route: "local")))
    }
}

@MainActor
final class AdapterTests: XCTestCase {
    func testSupersededCompletionCannotInsertAndFallbackTransformsRunOnceInOrder() async throws {
        let cleaner = DelayedCleaner()
        let adapter = PomvoxCleanupAdapter(cleaner: cleaner)
        var events: [String] = []
        func finish(_ raw: String) async throws -> CleanupResult {
            try await adapter.finish(raw: raw, vocabulary: [], timeoutSeconds: 5,
                spokenFormatting: { events.append("format:\($0)"); return $0 + "-format" },
                dictionary: { events.append("dictionary:\($0)"); return $0 + "-dictionary" },
                signature: { events.append("signature:\($0)"); return $0 + "-signature" },
                insert: { events.append("insert:\($0)") })
        }
        let old = Task { try await finish("old") }
        while !(await cleaner.has("old")) { await Task.yield() }
        let current = Task { try await finish("current") }
        while !(await cleaner.has("current")) { await Task.yield() }
        await cleaner.release("current")
        let result = try await current.value
        XCTAssertEqual(result.text, "current") // Evaluation remains before host transforms.
        await cleaner.release("old")
        do { _ = try await old.value; XCTFail("superseded request must throw") }
        catch is CancellationError {}
        XCTAssertEqual(events, ["format:current", "dictionary:current-format",
            "signature:current-format-dictionary", "insert:current-format-dictionary-signature"])
    }

    func testHostCancellationPreventsAllTransformsAndInsertion() async throws {
        let cleaner = DelayedCleaner()
        let adapter = PomvoxCleanupAdapter(cleaner: cleaner)
        var insertions = 0
        let task = Task {
            try await adapter.finish(raw: "cancel", vocabulary: [], timeoutSeconds: 5,
                spokenFormatting: { $0 }, dictionary: { $0 }, signature: { $0 },
                insert: { _ in insertions += 1 })
        }
        while !(await cleaner.has("cancel")) { await Task.yield() }
        adapter.cancel()
        await cleaner.release("cancel")
        do { _ = try await task.value; XCTFail("must throw") } catch is CancellationError {}
        XCTAssertEqual(insertions, 0)
    }
}

extension AdapterTests {
    func testInvalidHostTimeoutNeverInvokesCleanerOrTransforms() async throws {
        let adapter = PomvoxCleanupAdapter(cleaner: DelayedCleaner())
        for timeout in [Double.nan, .infinity, -.infinity, 0, -1] {
            do {
                _ = try await adapter.finish(raw: "hello", vocabulary: [], timeoutSeconds: timeout,
                    spokenFormatting: { _ in XCTFail("must not format"); return "" },
                    dictionary: { _ in XCTFail("must not transform"); return "" },
                    signature: { _ in XCTFail("must not transform"); return "" },
                    insert: { _ in XCTFail("must not insert") })
                XCTFail("invalid timeout must throw")
            } catch CleanupError.invalidRequest {}
        }
    }
}


private actor DeadlineRecordingCleaner: Cleaning {
    private(set) var deadline: Duration?
    func clean(_ request: CleanupRequest) async throws -> CleanupResult {
        deadline = request.deadline
        return CleanupResult(text: request.text, edits: [], status: .unchanged,
            provenance: Provenance(packID: "test", packVersion: "1", artifactDigest: "test",
                modelRevision: "test", runtime: "fake", route: "local"))
    }
}

extension AdapterTests {
    func testExplicitRemainingBudgetIsNeverExtendedForLongInput() async throws {
        let cleaner = DeadlineRecordingCleaner()
        let adapter = PomvoxCleanupAdapter(cleaner: cleaner)
        _ = try await adapter.finish(raw: String(repeating: "hello ", count: 500),
            vocabulary: [], timeoutSeconds: 0.1, spokenFormatting: { $0 },
            dictionary: { $0 }, signature: { $0 }, insert: { _ in })
        let deadline = await cleaner.deadline
        XCTAssertEqual(deadline, .milliseconds(100))
    }
}

extension AdapterTests {
    func testCancellationInsideHostTransformPreventsInsertion() async throws {
        let adapter = PomvoxCleanupAdapter(cleaner: DeadlineRecordingCleaner())
        var inserted = false
        do {
            _ = try await adapter.finish(raw: "hello", vocabulary: [], timeoutSeconds: 1,
                spokenFormatting: { text in adapter.cancel(); return text },
                dictionary: { $0 }, signature: { $0 }, insert: { _ in inserted = true })
            XCTFail("a host callback retired the session before insertion")
        } catch is CancellationError {}
        XCTAssertFalse(inserted)
    }
}
