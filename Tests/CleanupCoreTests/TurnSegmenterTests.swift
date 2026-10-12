import XCTest
@testable import CleanupCore

/// SplitMix64: seeded, so a failing case is reproducible by its seed.
private struct SplitMix: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

final class TurnSegmenterTests: XCTestCase {
    private func texts(_ text: String, _ pieces: [TurnSegmenter.Piece]) -> [String] {
        let bytes = Array(text.utf8)
        return pieces.map { String(decoding: bytes[$0.start..<$0.end], as: UTF8.self) }
    }

    func testShortTextIsOneSegment() {
        XCTAssertEqual(TurnSegmenter.split("so we ship friday", maxBytes: 100),
                       [TurnSegmenter.Piece(start: 0, end: 17, isSegment: true)])
        XCTAssertEqual(TurnSegmenter.split("", maxBytes: 10), [])
        XCTAssertEqual(TurnSegmenter.split("  \n ", maxBytes: 10), [TurnSegmenter.Piece(start: 0, end: 4, isSegment: false)])
    }

    func testSplitsAtSentenceEndsBeforeWhitespace() {
        let text = "One two. Three four? Five six! Seven."
        let pieces = TurnSegmenter.split(text, maxBytes: 22)
        XCTAssertEqual(texts(text, pieces), ["One two. Three four?", " ", "Five six! Seven."])
        XCTAssertEqual(pieces.map(\.isSegment), [true, false, true])
    }

    func testClosingQuotesStayWithTheirSentence() {
        let text = "He said \"stop.\" Then we left the room quietly."
        XCTAssertEqual(texts(text, TurnSegmenter.split(text, maxBytes: 20)).first, "He said \"stop.\"")
    }

    func testLineBreaksAreSentenceEnds() {
        let text = "first line without a stop\nsecond line also long enough"
        XCTAssertEqual(texts(text, TurnSegmenter.split(text, maxBytes: 30)), ["first line without a stop", "\n", "second line also long enough"])
    }

    func testFullWidthTerminatorsNeedNoSpace() {
        let text = "今日は会議です。明日は出荷します。金曜日に報告します。"
        let pieces = TurnSegmenter.split(text, maxBytes: 30)
        XCTAssertEqual(texts(text, pieces), ["今日は会議です。", "明日は出荷します。", "金曜日に報告します。"])
    }

    func testWithoutSentenceEndsSplitsAtWhitespace() {
        let text = "alpha beta gamma delta epsilon zeta eta theta"
        let pieces = TurnSegmenter.split(text, maxBytes: 12)
        XCTAssertEqual(texts(text, pieces).filter { !$0.allSatisfy(\.isWhitespace) },
                       ["alpha beta", "gamma delta", "epsilon zeta", "eta theta"])
    }

    func testWithoutWhitespaceSplitsBetweenGraphemeClusters() {
        let family = "👩‍👩‍👧‍👦" // 25 bytes, one grapheme cluster
        let text = String(repeating: family, count: 3) + "e\u{301}e\u{301}"
        let pieces = TurnSegmenter.split(text, maxBytes: 30)
        XCTAssertEqual(texts(text, pieces), [family, family, family + "e\u{301}", "e\u{301}"])
        // A cluster larger than the limit is kept whole.
        XCTAssertEqual(texts(family, TurnSegmenter.split(family, maxBytes: 4)), [family])
    }

    /// For random text mixing scripts, emoji, combining marks, sentence ends and
    /// line breaks: the pieces tile the input bytes exactly, alternate cleanly,
    /// segments are trimmed and within the limit (or one oversized cluster), and
    /// separators are pure whitespace.
    func testPropertyPiecesTileTheTextExactly() {
        let words = ["so", "we", "ship", "friday.", "café", "e\u{301}clair?", "日本語。", "👋🏽", "👩‍💻", "naïve!", "привет",
                     "\"quoted.\"", "\n", "  ", "long-identifier-without-spaces", "🇯🇵🇯🇵🇯🇵", "x"]
        for seed in UInt64(1)...300 {
            var random = SplitMix(seed: seed)
            let text = (0..<Int.random(in: 0...80, using: &random)).map { _ in words.randomElement(using: &random)! }
                .joined(separator: Bool.random(using: &random) ? " " : "")
            for maxBytes in [8, 25, 64, 1_000] {
                let pieces = TurnSegmenter.split(text, maxBytes: maxBytes)
                var expectedStart = 0
                for (index, piece) in pieces.enumerated() {
                    XCTAssertEqual(piece.start, expectedStart, "seed \(seed) max \(maxBytes)")
                    XCTAssertLessThan(piece.start, piece.end, "seed \(seed) max \(maxBytes)")
                    expectedStart = piece.end
                    if index > 0 { XCTAssertTrue(pieces[index - 1].isSegment || piece.isSegment, "two separators in a row") }
                }
                XCTAssertEqual(expectedStart, text.utf8.count, "seed \(seed) max \(maxBytes)")
                XCTAssertEqual(texts(text, pieces).joined().utf8.elementsEqual(text.utf8), true)
                for (piece, content) in zip(pieces, texts(text, pieces)) {
                    XCTAssertEqual(Array(content.utf8).count, piece.end - piece.start, "split inside a scalar, seed \(seed)")
                    if piece.isSegment {
                        XCTAssertFalse(content.first!.isWhitespace || content.last!.isWhitespace, "untrimmed segment, seed \(seed)")
                        XCTAssertTrue(content.utf8.count <= maxBytes || content.count == 1, "oversized segment, seed \(seed) max \(maxBytes)")
                    } else {
                        XCTAssertTrue(content.allSatisfy(\.isWhitespace), "separator with content, seed \(seed)")
                    }
                }
            }
        }
    }
}
