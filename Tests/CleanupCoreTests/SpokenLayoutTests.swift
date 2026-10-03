import XCTest
@testable import CleanupCore

/// Ported verbatim from Pomvox `SpokenFormattingTests` (app v0.2.8); only the
/// type name changed. Every case must give identical output in both repos.
final class SpokenLayoutTests: XCTestCase {

    // The two outputs the shipped model produced on 2026-09-13 for spoken
    // commands — commands became words.
    func testNewLineAsTheModelRendersIt() {
        XCTAssertEqual(
            SpokenLayout.apply("Hi John, new line, thanks for the update. New line, best Abhi."),
            "Hi John,\nThanks for the update.\nBest Abhi.")
    }

    func testNewParagraphAsTheModelRendersIt() {
        XCTAssertEqual(
            SpokenLayout.apply(
                "The first paragraph is about the budget. New paragraph: the second one is about hiring."),
            "The first paragraph is about the budget.\n\nThe second one is about hiring.")
    }

    func testRawTranscriptWithoutPunctuation() {
        XCTAssertEqual(
            SpokenLayout.apply("hi john new line thanks for the update new line best abhi"),
            "hi john\nThanks for the update\nBest abhi")
    }

    func testBulletPoints() {
        XCTAssertEqual(
            SpokenLayout.apply("Things to do. Bullet fix login. Bullet point update docs. Bullet ship it."),
            "Things to do.\n- Fix login.\n- Update docs.\n- Ship it.")
    }

    func testContentUsesStayWords() {
        for text in [
            "We launched a new line of products.",
            "The new line of products sells well.",
            "That was a silver bullet.",
            "Every bullet point on that slide matters.",
            "It was the magic bullet.",
            "There's a new paragraph in the contract that changes everything.",
        ] {
            XCTAssertEqual(SpokenLayout.apply(text), text, text)
        }
    }

    func testIdempotent() {
        let once = SpokenLayout.apply("Hi, new line, there. New paragraph. Bye.")
        XCTAssertEqual(SpokenLayout.apply(once), once)
    }

    func testNoCommandsNoChange() {
        let text = "Nothing to see here, just a sentence."
        XCTAssertEqual(SpokenLayout.apply(text), text)
    }

    func testCaseInsensitiveAndAtTheEdges() {
        XCTAssertEqual(SpokenLayout.apply("NEW LINE hello"), "\nHello")
        XCTAssertEqual(SpokenLayout.apply("hello new line"), "hello\n")
    }
}

private struct ImmediateRuntime: CleanupRuntime {
    let output: RuntimeOutput
    func generate(_ request: CleanupRequest, deadline: ContinuousClock.Instant) async throws -> RuntimeOutput { output }
    func close() async {}
}

/// The request transform: opt-in, accepted output only, edits cover it, fallbacks stay exact.
final class SpokenLayoutTransformTests: XCTestCase, @unchecked Sendable {
    private let provenance = Provenance(packID: "test", packVersion: "1.0.0", artifactDigest: "test",
        modelRevision: "test", runtime: "deterministic-test-double", route: "local")
    private let raw = "hi john new line thanks for the update"
    private let model = "Hi John, new line, thanks for the update."

    private func clean(_ output: RuntimeOutput, transforms: CleanupTransforms) async throws -> CleanupResult {
        let session = try CleanupSession(runtime: ImmediateRuntime(output: output), provenance: provenance)
        let result = try await session.clean(CleanupRequest(raw, transforms: transforms))
        await session.close()
        return result
    }

    func testOptedInAppliesToAcceptedOutputAndEditsReconstruct() async throws {
        let result = try await clean(RuntimeOutput(candidate: model), transforms: [.spokenLayout])
        XCTAssertEqual(result.status, .cleaned)
        XCTAssertEqual(result.text, "Hi John,\nThanks for the update.")
        XCTAssertEqual(Array(try TextEdit.applying(result.edits, to: raw).utf8), Array(result.text.utf8))
        XCTAssertEqual(result.provenance.settings["transforms"], "spokenLayout")
    }

    func testOffByDefaultIsByteIdenticalToBefore() async throws {
        let result = try await clean(RuntimeOutput(candidate: model), transforms: [])
        XCTAssertEqual(result.text, model)
        XCTAssertEqual(result.edits, TextEdit.between(raw, and: model))
        XCTAssertNil(result.provenance.settings["transforms"])
        XCTAssertEqual(CleanupRequest(raw).transforms, [])
    }

    func testFallbackStaysExactInputWithNoEdits() async throws {
        for output in [RuntimeOutput(candidate: "assistant: invented"),
                       RuntimeOutput(candidate: nil, failure: .tokenLimit)] {
            let result = try await clean(output, transforms: [.spokenLayout])
            guard case .fallback = result.status else { return XCTFail("expected a fallback") }
            XCTAssertEqual(Array(result.text.utf8), Array(raw.utf8))
            XCTAssertTrue(result.edits.isEmpty)
            XCTAssertNil(result.provenance.settings["transforms"])
        }
    }

    func testHostCanApplyLayoutToAFallbackItself() throws {
        let edits = SpokenLayout.edits(from: raw)
        XCTAssertEqual(try TextEdit.applying(edits, to: raw), SpokenLayout.apply(raw))
        XCTAssertTrue(SpokenLayout.edits(from: "Nothing to see here.").isEmpty)
    }
}
