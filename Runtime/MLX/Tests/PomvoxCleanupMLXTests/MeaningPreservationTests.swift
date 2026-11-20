import XCTest
import MLXLMTokenizers
@testable import PomvoxCleanupMLX

/// Opt-in local evaluation. Never prints input or candidates. Fixtures and evidence
/// stay in caller-selected local files; shared fixtures must be synthetic.
final class MeaningPreservationTests: XCTestCase {
    struct Fixture: Codable {
        let id: String
        let split: String
        let raw: String
        let vocabulary: [String]
        let required: [String]
        let forbidden: [String]

        func preservesMeaning(_ text: String) -> Bool {
            Array(text.utf8) == Array(raw.utf8) || satisfiesAssertions(text)
        }

        func satisfiesAssertions(_ text: String) -> Bool {
            required.allSatisfy { text.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
                && forbidden.allSatisfy { text.range(of: $0, options: [.regularExpression, .caseInsensitive]) == nil }
        }
    }

    private struct RecordedRuntime: CleanupRuntime {
        let output: RuntimeOutput
        func generate(_ request: CleanupRequest, deadline: ContinuousClock.Instant) async throws -> RuntimeOutput { output }
        func close() async {}
    }

    func testUnresolvedCorrectionIsNotMeaningLoss() {
        let fixture = Fixture(id: "oracle", split: "synthetic", raw: "Order forty labels, correction, fourteen labels.",
            vocabulary: [], required: ["fourteen labels"], forbidden: ["forty labels"])
        XCTAssertTrue(fixture.preservesMeaning(fixture.raw))
        XCTAssertFalse(fixture.satisfiesAssertions(fixture.raw))
        XCTAssertFalse(fixture.preservesMeaning("Order forty labels."))
        XCTAssertTrue(fixture.preservesMeaning("Order fourteen labels."))
        XCTAssertTrue(fixture.satisfiesAssertions("Order fourteen labels."))
    }

    func testLocalSemanticReplay() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["POMVOX_TEST_PACK"], let input = env["POMVOX_SEMANTIC_INPUT"],
              let evidence = env["POMVOX_SEMANTIC_EVIDENCE"] else {
            throw XCTSkip("set pack, local semantic input and evidence paths; never downloads")
        }
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: URL(fileURLWithPath: input)))
        XCTAssertFalse(fixtures.isEmpty)
        let pack = try PackLoader.validate(directory: URL(fileURLWithPath: path))
        let tokenizer = try await TokenizersLoader().load(from: pack.directory)
        let provenance = Provenance(packID: pack.manifest.id, packVersion: pack.manifest.version,
            artifactDigest: pack.digest, modelRevision: pack.manifest.modelRevision,
            runtime: PackLoader.runtimeVersion, route: "local")
        var rows: [[String: Any]] = []
        for (name, mode) in [("greedy", Decoding.greedy), ("speculative", .speculative)] {
            let runtime = try await MLXRuntime.open(pack: pack, mode: mode)
            do {
                for fixture in fixtures {
                    let output = try await runtime.generate(CleanupRequest(fixture.raw, vocabulary: fixture.vocabulary),
                        deadline: .now.advanced(by: .seconds(60)))
                    let session = try CleanupSession(runtime: RecordedRuntime(output: output), provenance: provenance)
                    let result = try await session.clean(CleanupRequest(fixture.raw, vocabulary: fixture.vocabulary))
                    await session.close()
                    var guardResult = "not-run"
                    if let candidate = output.candidate {
                        switch CleanupLogic.evaluateOutput(raw: fixture.raw, cleaned: candidate) {
                        case .success: guardResult = "accepted"
                        case .failure(let reason): guardResult = reason.rawValue
                        }
                    }
                    let fallback: Bool
                    if case .fallback = result.status {
                        fallback = true
                        XCTAssertTrue(Array(result.text.utf8) == Array(fixture.raw.utf8), fixture.id)
                        XCTAssertTrue(result.edits.isEmpty, fixture.id)
                    } else { fallback = false }
                    let semantic = output.candidate.map(fixture.preservesMeaning) ?? false
                    rows.append([
                        "id": fixture.id, "split": fixture.split, "raw": fixture.raw,
                        "candidate": output.candidate as Any? ?? NSNull(),
                        // For greedy/speculative MLXRuntime only emits a candidate on EOS.
                        "stopReason": output.failure.map { String(describing: $0) } ?? "eos",
                        "guard": guardResult, "delivered": result.text, "fallback": fallback,
                        "candidateSemanticPass": semantic,
                        "candidateAssertionsPass": output.candidate.map(fixture.satisfiesAssertions) ?? false,
                        "deliveredAssertionsPass": fixture.satisfiesAssertions(result.text),
                        "unchanged": Array(result.text.utf8) == Array(fixture.raw.utf8),
                        "deliveredSemanticPass": fixture.preservesMeaning(result.text),
                        "mode": name, "temperature": 0, "prefixCacheUsed": output.timings.prefixCacheUsed ?? false,
                        "maxTokens": max(64, min(2 * tokenizer.encode(text: fixture.raw).count, 1024)),
                        "decodeTokens": output.timings.decodeTokens ?? 0,
                        "vocabulary": fixture.vocabulary, "deadlineSeconds": 60,
                    ])
                    if env["POMVOX_REQUIRE_SEMANTICS"] == "1" {
                        XCTAssertTrue(semantic, "candidate semantic failure: \(fixture.id), \(name)")
                        XCTAssertTrue(fixture.preservesMeaning(result.text), "delivery semantic failure: \(fixture.id), \(name)")
                    }
                }
                await runtime.close()
            } catch { await runtime.close(); throw error }
        }
        let report: [String: Any] = [
            "modelID": pack.manifest.modelID, "revision": pack.manifest.modelRevision,
            "manifestDigest": pack.digest, "guardRules": CleanupLogic.rulesVersion,
            "artifacts": pack.manifest.artifacts.map { ["path": $0.path, "sha256": $0.sha256] },
            "runtime": PackLoader.runtimeVersion, "rows": rows,
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: evidence), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: evidence)
    }
}
