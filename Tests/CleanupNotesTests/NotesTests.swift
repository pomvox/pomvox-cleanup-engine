import XCTest
@testable import CleanupNotes

final class NotesTests: XCTestCase {
    private let s1 = SpeakerLabel("S1"), s2 = SpeakerLabel("S2")
    private let provenance = Provenance(packID: "test", packVersion: "1.0.0", artifactDigest: "test",
        modelRevision: "test", runtime: "deterministic-test-double", route: "local")

    private func turn(_ speaker: SpeakerLabel?, _ text: String, span: TimeSpan? = nil,
                      status: CleanupStatus = .cleaned) -> TurnResult {
        TurnResult(turn: SpeakerTurn(speaker: speaker, text: text.lowercased(), span: span),
                   result: CleanupResult(text: text, edits: TextEdit.between(text.lowercased(), and: text),
                                         status: status, provenance: provenance))
    }

    private func meeting() -> TranscriptResult {
        TranscriptResult(turns: [
            turn(s1, "Okay, let's start. Can we ship on Friday? I'll send the report by Friday.", span: TimeSpan(start: 0, end: 6)),
            turn(s2, "We decided to go with the smaller pack. Café notes: 👩🏽‍💻 is fine!", span: TimeSpan(start: 6, end: 11)),
            turn(s1, "Things to pack:\n- Shirts\n- Socks\n1. Toothbrush", span: TimeSpan(start: 11, end: 15)),
            turn(nil, "nothing in particular happened here", span: nil, status: .fallback(.rejected)),
        ], elapsedMS: 12)
    }

    func testEveryItemIsAVerbatimQuoteWithAValidRange() throws {
        let notes = Notes.extract(from: meeting())
        XCTAssertFalse(notes.items.isEmpty)
        for item in notes.items {
            let source = notes.source.turns[item.turnIndex].text
            let range = try TextEdit(start: item.start, end: item.end, replacement: "").range(in: source)
            XCTAssertEqual(String(source[range]), item.text)
            XCTAssertEqual(item.speaker, notes.source.turns[item.turnIndex].turn.speaker)
        }
        XCTAssertEqual(notes.heuristics, NoteHeuristics.version)
    }

    func testClassificationVectors() {
        let notes = Notes.extract(from: meeting())
        XCTAssertEqual(notes.items(of: .question).map(\.text), ["Can we ship on Friday?"])
        XCTAssertEqual(notes.items(of: .actionItem).map(\.text), ["I'll send the report by Friday."])
        XCTAssertEqual(notes.items(of: .decision).map(\.text), ["We decided to go with the smaller pack."])
        XCTAssertEqual(notes.items(of: .listItem).map(\.text), ["Shirts", "Socks", "Toothbrush"])
        XCTAssertEqual(notes.items(of: .listItem).map(\.speaker), [s1, s1, s1])
        XCTAssertTrue(notes.items.allSatisfy { $0.turnIndex != 3 })
    }

    func testHeuristicCuesAreCandidatesNotUnderstanding() {
        let heuristics = NoteHeuristics.default
        XCTAssertEqual(heuristics.classify("We need to update the docs.", isListLine: false), .actionItem)
        XCTAssertEqual(heuristics.classify("Follow up with legal.", isListLine: false), .actionItem)
        XCTAssertEqual(heuristics.classify("Deadline is Tuesday.", isListLine: false), .actionItem)
        XCTAssertEqual(heuristics.classify("Agreed, the blue one.", isListLine: false), .decision)
        XCTAssertEqual(heuristics.classify("Let's go with option two.", isListLine: false), .decision)
        XCTAssertEqual(heuristics.classify("Is that right?", isListLine: false), .question)
        XCTAssertEqual(heuristics.classify("anything", isListLine: true), .listItem)
        XCTAssertNil(heuristics.classify("The weather was nice.", isListLine: false))
        // Action wins over decision when both cues appear.
        XCTAssertEqual(heuristics.classify("We agreed that I'll write it.", isListLine: false), .actionItem)
    }

    func testCustomCueSetsAreVersionedAndValidated() throws {
        let custom = try NoteHeuristics(actionCues: [#"\bship\b"#], decisionCues: [], version: "host-v1")
        XCTAssertEqual(custom.classify("Ship it.", isListLine: false), .actionItem)
        XCTAssertNil(custom.classify("We decided.", isListLine: false))
        XCTAssertEqual(Notes.extract(from: meeting(), heuristics: custom).heuristics, "host-v1")
        XCTAssertThrowsError(try NoteHeuristics(actionCues: ["("], decisionCues: [], version: "bad"))
    }

    func testSentenceSplittingKeepsBytesAndHandlesUnicode() {
        let text = "Hé there.  Second one!Not split here. 👩🏽‍💻 ok?\n- item one\n2. item two\n\nTail"
        let pieces = NoteHeuristics.default.sentences(in: text)
        XCTAssertEqual(pieces.map(\.text), ["Hé there.", "Second one!Not split here.", "👩🏽‍💻 ok?", "item one", "item two", "Tail"])
        XCTAssertEqual(pieces.map(\.isListLine), [false, false, false, true, true, false])
        for piece in pieces {
            let bytes = Array(text.utf8)[piece.start..<piece.end]
            XCTAssertEqual(String(decoding: bytes, as: UTF8.self), piece.text)
        }
        XCTAssertEqual(NoteHeuristics.default.sentences(in: "   \n\n"), [])
        XCTAssertEqual(NoteHeuristics.default.sentences(in: "").count, 0)
    }

    func testParticipantsCountTurnsWordsAndTime() {
        let notes = Notes.extract(from: meeting())
        XCTAssertEqual(notes.participants.map(\.speaker), [s1, s2, nil])
        XCTAssertEqual(notes.participants[0].turns, 2)
        XCTAssertEqual(notes.participants[0].speakingSeconds, 10)
        XCTAssertEqual(notes.participants[1].turns, 1)
        XCTAssertEqual(notes.participants[1].speakingSeconds, 5)
        XCTAssertNil(notes.participants[2].speakingSeconds)
        XCTAssertEqual(notes.participants[2].words, 5)
        XCTAssertEqual(notes.participants[0].words, 14 + 9) // list markers count as tokens
        XCTAssertEqual(notes.participants[1].words, 13)
    }

    func testMarkdownCarriesEveryTurnVerbatimAndOmitsEmptySections() {
        let notes = Notes.extract(from: meeting())
        let names = [s1: "Abhi"]
        let markdown = NotesRenderer.markdown(notes, options: NotesRenderer.Options(
            title: "Standup", speakerNames: names, includeTimestamps: true))
        for result in notes.source.turns { XCTAssertTrue(markdown.contains(result.text), result.text) }
        XCTAssertTrue(markdown.hasPrefix("# Standup\n\n## Participants\n- Abhi: 2 turns, 23 words, 0:10\n- S2: 1 turn, 13 words, 0:05\n- Unknown speaker: 1 turn, 5 words\n\n## Action items\n- Abhi: I'll send the report by Friday.\n\n## Decisions\n- S2: We decided to go with the smaller pack.\n\n## Questions\n- Abhi: Can we ship on Friday?\n\n## Transcript\n**Abhi** (0:00–0:06): "), markdown)
        XCTAssertFalse(markdown.contains("## List items"))
        XCTAssertTrue(markdown.contains("**Unknown speaker**: nothing in particular"))
        XCTAssertTrue(markdown.hasSuffix("\n"))
        let bare = NotesRenderer.markdown(Notes.extract(from: TranscriptResult(turns: [], elapsedMS: 0)),
                                          options: NotesRenderer.Options(title: nil))
        XCTAssertEqual(bare, "\n")
        let listsOnly = NotesRenderer.markdown(notes, options: NotesRenderer.Options(
            title: nil, sections: [.listItem], includeParticipants: false, includeTranscript: false))
        XCTAssertEqual(listsOnly, "## List items\n- S1: Shirts\n- S1: Socks\n- S1: Toothbrush\n")
    }

    func testClockFormatting() {
        XCTAssertEqual(NotesRenderer.clock(0), "0:00")
        XCTAssertEqual(NotesRenderer.clock(59.9), "0:59")
        XCTAssertEqual(NotesRenderer.clock(3_661), "1:01:01")
        XCTAssertEqual(NotesRenderer.clock(-5), "0:00")
        XCTAssertEqual(NotesRenderer.clock(.nan), "0:00")
    }

    func testNotesRoundTripThroughJSON() throws {
        let notes = Notes.extract(from: meeting())
        let data = try JSONEncoder().encode(notes)
        XCTAssertEqual(try JSONDecoder().decode(Notes.self, from: data), notes)
    }
}
