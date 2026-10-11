import XCTest
@testable import CleanupNotes

final class ModelNotesTests: XCTestCase {
    private let provenance = Provenance(packID: "p", packVersion: "1.0.0", artifactDigest: "d",
                                        modelRevision: "r", runtime: "mock", route: "cloud")

    private func source() -> TranscriptResult {
        TranscriptResult(turns: (0..<3).map { index in
            let turn = SpeakerTurn(speaker: SpeakerLabel("S\(index % 2 + 1)"), text: "Turn \(index).",
                                   span: index == 2 ? nil : TimeSpan(start: Double(index) * 5, end: Double(index) * 5 + 4))
            return TurnResult(turn: turn, result: CleanupResult(text: turn.text, edits: [], status: .unchanged, provenance: provenance))
        }, elapsedMS: 0)
    }

    private func notes(_ summary: [CitedNote], actionItems: [CitedNote] = [], timings: CleanupTimings = .init()) -> ModelNotes {
        ModelNotes(summary: summary, actionItems: actionItems, decisions: [], questions: [], provenance: provenance, timings: timings)
    }

    func testValidationRequiresExistingCitationsAndBoundedSingleLineText() throws {
        XCTAssertNoThrow(try notes([CitedNote(text: "Fine.", turns: [0, 2])]).validate(against: source()))
        XCTAssertThrowsError(try notes([CitedNote(text: "Fine.", turns: [])]).validate(against: source()))
        XCTAssertThrowsError(try notes([CitedNote(text: "Fine.", turns: [3])]).validate(against: source()))
        XCTAssertThrowsError(try notes([CitedNote(text: "Fine.", turns: [-1])]).validate(against: source()))
        XCTAssertThrowsError(try notes([CitedNote(text: "  ", turns: [0])]).validate(against: source()))
        XCTAssertThrowsError(try notes([CitedNote(text: "two\nlines", turns: [0])]).validate(against: source()))
        XCTAssertThrowsError(try notes([CitedNote(text: String(repeating: "x", count: 1_025), turns: [0])]).validate(against: source()))
        XCTAssertThrowsError(try notes([CitedNote(text: "x", turns: Array(repeating: 0, count: 65))]).validate(against: source()))
        XCTAssertThrowsError(try notes(Array(repeating: CitedNote(text: "x", turns: [0]), count: 257)).validate(against: source()))
        var timings = CleanupTimings(); timings.totalMS = -1
        XCTAssertThrowsError(try notes([CitedNote(text: "x", turns: [0])], timings: timings).validate(against: source()))
        XCTAssertNoThrow(try notes([]).validate(against: source()))
    }

    func testRenderingWithModelNotesKeepsQuotedCandidatesAndTranscript() {
        let base = TranscriptResult(turns: [TurnResult(turn: SpeakerTurn(speaker: SpeakerLabel("S1"), text: "We'll ship Friday. Is that okay?",
                                                                          span: TimeSpan(start: 0, end: 3)),
                                                       result: CleanupResult(text: "We'll ship Friday. Is that okay?", edits: [],
                                                                             status: .unchanged, provenance: provenance))], elapsedMS: 0)
        let deterministic = Notes.extract(from: base)
        let model = notes([CitedNote(text: "Shipping is planned for Friday.", turns: [0])],
                          actionItems: [CitedNote(text: "Confirm the Friday date.", turns: [0, 7])])
        let markdown = NotesRenderer.markdown(deterministic, model: model, options: .init(title: "Sync"))
        XCTAssertEqual(markdown, """
        # Sync

        ## Participants
        - S1: 1 turn, 6 words, 0:03

        ## Summary
        - Shipping is planned for Friday. — S1 0:00

        ## Action items (model)
        - Confirm the Friday date. — S1 0:00, turn 7

        ## Action items (quoted)
        - S1: We'll ship Friday.

        ## Questions (quoted)
        - S1: Is that okay?

        ## Transcript
        **S1**: We'll ship Friday. Is that okay?

        """)
        // Without a model the document is unchanged from before.
        XCTAssertFalse(NotesRenderer.markdown(deterministic).contains("(quoted)"))
    }

    func testModelNotesRoundTripThroughJSON() throws {
        let value = notes([CitedNote(text: "x", turns: [0])], actionItems: [CitedNote(text: "y", turns: [1, 2])])
        let data = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(ModelNotes.self, from: data), value)
        XCTAssertEqual(ModelNotesError.busy.errorDescription, "A notes request is already running.")
    }
}
