import XCTest
@testable import CleanupCore

private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64 = 0x706f6d766f78
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

final class RobustnessTests: XCTestCase {
    func testFiveThousandSeededUnicodeEditReconstructions() throws {
        var random = SeededGenerator()
        let alphabet = ["a", "Z", " ", "\r\n", "\0", "é", "e\u{301}", "🇮🇳", "👩🏽‍💻", "中", "ع", "\u{200D}", "\u{FE0F}", "\u{10FFFF}"]
        func string(_ random: inout SeededGenerator) -> String {
            (0..<Int(random.next() % 40)).map { _ in alphabet[Int(random.next() % UInt64(alphabet.count))] }.joined()
        }
        for iteration in 0..<5_000 {
            let original = string(&random), replacement = string(&random)
            let edits = TextEdit.between(original, and: replacement)
            XCTAssertEqual(Array(try TextEdit.applying(edits, to: original).utf8), Array(replacement.utf8), "seed iteration \(iteration)")
            XCTAssertLessThanOrEqual(edits.count, 1)
            for edit in edits {
                let range = try edit.range(in: original)
                let nsRange = try edit.utf16Range(in: original)
                XCTAssertEqual(nsRange, NSRange(range, in: original))
            }
        }
    }

    func testEveryByteOffsetRejectsOnlyInsideScalar() throws {
        let input = "Aé中😀e\u{301}👩🏽‍💻\r\n"
        var boundaries: Set<Int> = [0]
        var offset = 0
        for scalar in input.unicodeScalars {
            offset += scalar.utf8.count
            boundaries.insert(offset)
        }
        for start in -1...(input.utf8.count + 1) {
            for end in -1...(input.utf8.count + 1) {
                let edit = TextEdit(start: start, end: end, replacement: "x")
                if start <= end && boundaries.contains(start) && boundaries.contains(end) {
                    XCTAssertNoThrow(try TextEdit.applying([edit], to: input))
                } else {
                    XCTAssertThrowsError(try TextEdit.applying([edit], to: input))
                }
            }
        }
        for edit in [TextEdit(start: Int.min, end: Int.max, replacement: ""),
                     TextEdit(start: Int.max, end: Int.max, replacement: "")] {
            XCTAssertThrowsError(try edit.range(in: input))
        }
    }

    func testMultipleEditsUseOriginalCoordinatesAndStableInsertionOrder() throws {
        let edits = [TextEdit(start: 0, end: 0, replacement: "["),
                     TextEdit(start: 0, end: 0, replacement: "+"),
                     TextEdit(start: 0, end: 4, replacement: "🙂"),
                     TextEdit(start: 5, end: 6, replacement: "B"),
                     TextEdit(start: 6, end: 6, replacement: "]")]
        XCTAssertEqual(try TextEdit.applying(edits, to: "😀ab"), "[+🙂aB]")
        XCTAssertThrowsError(try TextEdit.applying(edits.reversed(), to: "😀ab"))
        XCTAssertFalse(TextEdit.between("é", and: "e\u{301}").isEmpty)
    }

    func testRequestLimitsAtAndBeyondEveryBoundary() throws {
        let valid: [CleanupRequest] = [
            .init(String(repeating: "😀", count: 4096)),
            .init("x", vocabulary: Array(repeating: "a", count: 64)),
            .init("x", vocabulary: Array(repeating: String(repeating: "é", count: 64), count: 16)),
            .init("x", context: String(repeating: "é", count: 1024)),
            .init("x", settings: Dictionary(uniqueKeysWithValues: (0..<16).map { (String($0), "x") })),
            .init("x", settings: [String(repeating: "a", count: 64): String(repeating: "a", count: 128)]),
            .init("x", deadline: .nanoseconds(1)), .init("x", deadline: .seconds(60))]
        let invalid: [CleanupRequest] = [
            .init(String(repeating: "a", count: 16_385)),
            .init("x", vocabulary: Array(repeating: "a", count: 65)),
            .init("x", vocabulary: [String(repeating: "a", count: 129)]),
            .init("x", vocabulary: Array(repeating: String(repeating: "a", count: 128), count: 17)),
            .init("x", vocabulary: [""]), .init("x", vocabulary: ["a\r\nb"]),
            .init("x", vocabulary: ["a\u{2028}b"]),
            .init("x", context: String(repeating: "a", count: 2049)),
            .init("x", settings: Dictionary(uniqueKeysWithValues: (0..<17).map { (String($0), "x") })),
            .init("x", settings: [String(repeating: "a", count: 65): "x"]),
            .init("x", settings: ["x": String(repeating: "a", count: 129)]),
            .init("x", deadline: .zero), .init("x", deadline: .seconds(-1)),
            .init("x", deadline: .seconds(60) + .nanoseconds(1))]
        for (i, request) in valid.enumerated() { XCTAssertNoThrow(try request.validate(), "valid \(i)") }
        for (i, request) in invalid.enumerated() { XCTAssertThrowsError(try request.validate(), "invalid \(i)") }
        XCTAssertEqual(CleanupRequest("").budget, .seconds(5))
        XCTAssertEqual(CleanupRequest(String(repeating: "a", count: 16_384)).budget, .seconds(60))
        XCTAssertEqual(CleanupRequest("hello", deadline: .milliseconds(10)).budget, .milliseconds(10))
    }

    func testTimingValidationAndAllOutcomesRoundTrip() throws {
        let keys: [WritableKeyPath<CleanupTimings, Double>] = [\.preparationMS, \.queueMS, \.validationMS, \.diffMS, \.totalMS, \.budgetMS]
        let optional: [WritableKeyPath<CleanupTimings, Double?>] = [\.tokenizationMS, \.prefillMS, \.inferenceMS, \.serverInferenceMS]
        for value in [-1, Double.nan, .infinity, -.infinity] {
            for key in keys { var t = CleanupTimings(); t[keyPath: key] = value; XCTAssertFalse(t.isValid) }
            for key in optional { var t = CleanupTimings(); t[keyPath: key] = value; XCTAssertFalse(t.isValid) }
        }
        XCTAssertTrue(CleanupTimings().isValid)
        let reasons: [FallbackReason] = [.timedOut, .rejected, .unavailable, .busy, .tokenLimit, .transport, .invalidResponse]
        for status in [CleanupStatus.cleaned, .unchanged] + reasons.map(CleanupStatus.fallback) {
            let encoded = try JSONEncoder().encode(status)
            XCTAssertEqual(try JSONDecoder().decode(CleanupStatus.self, from: encoded), status)
        }
        // Freeze the public v1 wire representation independently of the encoder.
        let wire = Data(#"{"fallback":{"_0":"timedOut"}}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(CleanupStatus.self, from: wire), .fallback(.timedOut))
        for error in [CleanupError.invalidRequest("test"), .invalidPack("test"), .incompatible("test"), .invalidEdits, .unavailable("test")] {
            XCTAssertNotNil(error.errorDescription)
        }
    }
}
