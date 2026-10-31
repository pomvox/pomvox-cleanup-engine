import XCTest
@testable import CleanupCore

/// Cleans and variants on one worker. Variant output is scripted; cleanups echo.
private actor VariantRuntime: CleanupRuntime, AuxiliaryGenerating {
    var active = 0, maximumActive = 0, cleans = 0, variants = 0
    let output: RuntimeOutput
    let delay: Duration
    let failing: Bool
    init(output: RuntimeOutput = RuntimeOutput(candidate: "- pom box\n2. palm vox\nPomvox\n"),
         delay: Duration = .milliseconds(2), failing: Bool = false) {
        self.output = output; self.delay = delay; self.failing = failing
    }
    /// Holds the "device" for the whole delay even when cancelled, like a running kernel.
    private func occupy() async throws {
        active += 1; maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        let delay = self.delay
        await Task.detached { try? await Task.sleep(for: delay) }.value
    }
    func generate(_ request: CleanupRequest, deadline: ContinuousClock.Instant) async throws -> RuntimeOutput {
        cleans += 1; try await occupy(); return RuntimeOutput(candidate: request.text)
    }
    func generateVariants(_ request: VariantRequest, deadline: ContinuousClock.Instant) async throws -> RuntimeOutput {
        variants += 1; try await occupy()
        if failing { throw CleanupError.unavailable("injected") }
        return output
    }
    func close() {}
    func counts() -> (cleans: Int, variants: Int, maximumActive: Int) { (cleans, variants, maximumActive) }
}

private struct PlainRuntime: CleanupRuntime {
    func generate(_ request: CleanupRequest, deadline: ContinuousClock.Instant) async throws -> RuntimeOutput {
        RuntimeOutput(candidate: request.text)
    }
    func close() async {}
}

final class VariantTests: XCTestCase, @unchecked Sendable {
    private let provenance = Provenance(packID: "test", packVersion: "1.0.0", artifactDigest: "digest",
        modelRevision: "revision", runtime: "controlled", route: "local")

    // MARK: - Parser: the app's fixtures (pomvox/pomvox VariantParsingTests) and a differential

    /// The app's fixtures (last two: digit-leading variants keep their digit, pomvox/pomvox#168),
    /// each through the old path too. The old path is `parseVariantLines` + `stripVariantListPrefix`
    /// from pomvox/pomvox `Pomvox/Sources/Engine/VariantGenerator.swift`, copied verbatim below.
    func testParsesTheAppsFixturesIdenticallyToTheAppsParser() {
        let fixtures: [(raw: String, term: String, expected: [String])] = [
            ("- pom box\n2. palm vox\n* pomm vocks\n", "Pomvox", ["pom box", "palm vox", "pomm vocks"]),
            ("Pomvox\n\npom box\nthis is a whole explanatory sentence about the word\n", "Pomvox", ["pom box"]),
            ("Pom Box\npom box\n", "Pomvox", ["pom box"]),
            ((1...10).map { "variant \($0)" }.joined(separator: "\n"), "X", (1...6).map { "variant \($0)" }),
            ("3 d printing\n3d printing\n", "additive", ["3 d printing", "3d printing"]),
            ("- 3d printing\n2. palm vox\n1) one more\n", "X", ["3d printing", "palm vox", "one more"])]
        for f in fixtures {
            XCTAssertEqual(VariantParser.parse(f.raw, term: f.term), f.expected, f.raw)
            XCTAssertEqual(legacyParseVariantLines(f.raw, term: f.term), f.expected, f.raw)
        }
        XCTAssertEqual(VariantParser.parse((1...10).map { "v\($0)" }.joined(separator: "\n"), term: "X", limit: 2), ["v1", "v2"])
        // Seeded differential over list markers, digits, echoes and long lines.
        var state: UInt64 = 0x706f6d766f78
        func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state }
        let pieces = ["-", "*", "•", " ", "  ", "1", "23", ".", ")", "pom", "Box", "Pomvox", "3d", "\t", "é", "\n", "a b c d e f"]
        for iteration in 0..<5_000 {
            let raw = (0..<Int(next() % 24)).map { _ in pieces[Int(next() % UInt64(pieces.count))] }.joined()
            let term = ["Pomvox", "pom", "3d", "X"][Int(next() % 4)]
            XCTAssertEqual(VariantParser.parse(raw, term: term), legacyParseVariantLines(raw, term: term), "iteration \(iteration)")
        }
    }

    // MARK: - One worker for both

    func testVariantsRunOnTheWorkerAndNeverQueueBehindOrAheadOfACleanup() async throws {
        let runtime = VariantRuntime(delay: .milliseconds(50))
        let session = try CleanupSession(runtime: runtime, provenance: provenance)
        // Idle worker: generated and parsed, with the term's echo dropped.
        let idle = await session.suggestVariants(VariantRequest(term: "Pomvox"))
        XCTAssertEqual(idle, ["pom box", "palm vox"])
        // Cleanup active: variants answer [] at once without a generation; the cleanup is unaffected.
        let cleaning = Task { try await session.clean("hello") }
        try await Task.sleep(for: .milliseconds(10))
        let busy = await session.suggestVariants(VariantRequest(term: "Pomvox"))
        XCTAssertEqual(busy, [])
        let cleaned = try await cleaning.value
        XCTAssertEqual(cleaned.status, .unchanged)
        // Variants active: a cleanup queues behind them and still runs, one generation at a time.
        let suggesting = Task { await session.suggestVariants(VariantRequest(term: "Pomvox")) }
        try await Task.sleep(for: .milliseconds(10))
        let queued = try await session.clean("hello")
        XCTAssertEqual(queued.status, .unchanged)
        XCTAssertGreaterThan(queued.timings.queueMS, 0)
        let suggested = await suggesting.value
        XCTAssertEqual(suggested, ["pom box", "palm vox"])
        let counts = await runtime.counts()
        XCTAssertEqual(counts.cleans, 2); XCTAssertEqual(counts.variants, 2); XCTAssertEqual(counts.maximumActive, 1)
        await session.close()
    }

    func testEveryFailureIsEmptyAndNeverTouchesTheModel() async throws {
        // Invalid requests are refused before admission.
        let runtime = VariantRuntime()
        let session = try CleanupSession(runtime: runtime, provenance: provenance)
        for request in [VariantRequest(term: ""), VariantRequest(term: " "), VariantRequest(term: "a\nb"),
                        VariantRequest(term: "x", limit: 0), VariantRequest(term: "x", limit: 65),
                        VariantRequest(term: "x", deadline: .zero), VariantRequest(term: "x", deadline: .seconds(61)),
                        VariantRequest(term: String(repeating: "a", count: 129))] {
            let invalid = await session.suggestVariants(request)
            XCTAssertEqual(invalid, [], request.term)
        }
        let untouched = await runtime.counts().variants
        XCTAssertEqual(untouched, 0)
        // A runtime without auxiliary generation is never asked.
        let plain = await (try CleanupSession(runtime: PlainRuntime(), provenance: provenance)).suggestVariants(VariantRequest(term: "Pomvox"))
        XCTAssertEqual(plain, [])
        // Thrown, failed, invalid-metric and oversized outputs are no suggestion.
        var metrics = CleanupTimings(); metrics.inferenceMS = .nan
        for bad in [VariantRuntime(failing: true), VariantRuntime(output: RuntimeOutput(candidate: nil, failure: .tokenLimit)),
                    VariantRuntime(output: RuntimeOutput(candidate: "x", timings: metrics)),
                    VariantRuntime(output: RuntimeOutput(candidate: String(repeating: "a\n", count: 40_000)))] {
            let empty = await (try CleanupSession(runtime: bad, provenance: provenance)).suggestVariants(VariantRequest(term: "Pomvox"))
            XCTAssertEqual(empty, [])
        }
        // Closed and cancelled callers get [], never a late answer.
        await session.close()
        let closed = await session.suggestVariants(VariantRequest(term: "Pomvox"))
        XCTAssertEqual(closed, [])
        let slow = try CleanupSession(runtime: VariantRuntime(delay: .seconds(2)), provenance: provenance)
        let cancelled = Task { await slow.suggestVariants(VariantRequest(term: "Pomvox")) }
        try await Task.sleep(for: .milliseconds(10))
        cancelled.cancel()
        let late = await cancelled.value
        XCTAssertEqual(late, [])
        await slow.close()
    }

    func testExpiredVariantsQuarantineLikeACleanupAndRecover() async throws {
        let runtime = VariantRuntime(delay: .milliseconds(200))
        let session = try CleanupSession(runtime: runtime, provenance: provenance)
        let expired = await session.suggestVariants(VariantRequest(term: "Pomvox", deadline: .milliseconds(20)))
        XCTAssertEqual(expired, [])
        let availability = await session.availability
        XCTAssertEqual(availability, .quarantined)
        let quarantined = try await session.clean("hello")
        XCTAssertEqual(quarantined.status, .fallback(.unavailable))
        try await Task.sleep(for: .milliseconds(300))
        let recovered = try await session.clean("hello")
        XCTAssertEqual(recovered.status, .unchanged)
        await session.close()
    }
}

// MARK: - The app's parser, verbatim (old path of the differential)

private func stripVariantListPrefix(_ line: String) -> String {
    var t = line.trimmingCharacters(in: .whitespaces)
    let bullets: Set<Character> = ["-", "*", "•"]
    if let first = t.first, bullets.contains(first) {
        while let c = t.first, bullets.contains(c) { t.removeFirst() }
        while t.first == " " { t.removeFirst() }
    }
    var index = t.startIndex
    var sawDigit = false
    while index < t.endIndex, t[index].isNumber {
        sawDigit = true
        t.formIndex(after: &index)
    }
    if sawDigit, index < t.endIndex, t[index] == "." || t[index] == ")" {
        t.formIndex(after: &index)
        while index < t.endIndex, t[index] == " " { t.formIndex(after: &index) }
        return String(t[index...])
    }
    return t
}

private func legacyParseVariantLines(_ raw: String, term: String) -> [String] {
    var out: [String] = []
    for line in raw.components(separatedBy: "\n") {
        let t = stripVariantListPrefix(line).trimmingCharacters(in: .whitespaces).lowercased()
        guard !t.isEmpty,
              t.caseInsensitiveCompare(term) != .orderedSame,
              t.components(separatedBy: " ").count <= 5,
              !out.contains(t) else { continue }
        out.append(t)
        if out.count == 6 { break }
    }
    return out
}
