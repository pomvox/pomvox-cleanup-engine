import XCTest

@testable import CleanupCore

/// The guard specification, owned here (#7, the app's gap 10).
///
/// Every `accept_output` vector in the app's `tests/test_cleanup.py` and every
/// `acceptOutput` vector in its `Pomvox/Tests/CleanupLogicTests.swift`, as one
/// table that asserts WHICH guard decided, not only accept or reject. A vector
/// that is still rejected after a guard change, but now by a different guard,
/// fails here; that is the silent drift "The Guard That Ate the Fix" describes.
///
/// `source` names the app test each row came from, so a row can be traced back
/// when the app retires those vectors. Rows only the app's Swift suite or only
/// its Python suite carries say so.
final class GuardVectorTests: XCTestCase {

    enum Expected {
        /// Accepted, and the guards return exactly this text.
        case accepts(String)
        /// Accepted; the app's vector asserts only "is not None" / XCTAssertNotNil.
        case acceptsAny
        case rejects(CleanupRejection)
    }

    struct Vector {
        let source: String
        let raw: String
        let cleaned: String
        let expected: Expected
    }

    static let raw = "um so I think we should uh ship it tomorrow maybe"
    static let correctionRaw = "Let's meet Thursday. No, no, wait, uh we'll meet Friday actually."
    static let echoRaw = "The above are the text that I just put in. In one case, I saw the a "
        + "being there, as and ums are supposed to be removed, and then uh there "
        + "is one more thing. The list, it is not being actually displayed as a "
        + "list, like one, two, three. This is with the R C build, by the way."

    static let vectors: [Vector] = [
        // Output shape.
        Vector(source: "accept_normal_output", raw: raw,
               cleaned: "I think we should ship it tomorrow.",
               expected: .accepts("I think we should ship it tomorrow.")),
        Vector(source: "accept_strips_wrapping_quotes", raw: raw,
               cleaned: "\"I think we should ship it tomorrow.\"",
               expected: .accepts("I think we should ship it tomorrow.")),
        Vector(source: "reject_empty", raw: raw, cleaned: "", expected: .rejects(.emptyOutput)),
        Vector(source: "reject_empty", raw: raw, cleaned: "   \n", expected: .rejects(.emptyOutput)),
        Vector(source: "reject_think_artifacts", raw: raw,
               cleaned: "<think>hmm</think>Ship it tomorrow, I think.", expected: .rejects(.thinkTags)),
        Vector(source: "run_cleanup_rejected_falls_back_to_raw", raw: raw,
               cleaned: "<think>let me reason</think>", expected: .rejects(.thinkTags)),
        Vector(source: "reject_role_prefix", raw: raw,
               cleaned: "assistant: I think we should ship it tomorrow.", expected: .rejects(.rolePrefix)),

        // Length bounds.
        Vector(source: "reject_far_too_long", raw: "short text here ok",
               cleaned: String(repeating: "x", count: 200), expected: .rejects(.upperLength)),
        Vector(source: "reject_far_too_short", raw: raw, cleaned: "ok", expected: .rejects(.lowerLengthRatio)),
        Vector(source: "short_raw_skips_lower_bound", raw: "ok", cleaned: "OK.", expected: .accepts("OK.")),
        Vector(source: "self_correction_survives_the_floor", raw: correctionRaw,
               cleaned: "Let's meet Friday.", expected: .accepts("Let's meet Friday.")),
        Vector(source: "the_relaxed_floor_still_rejects_a_total_collapse", raw: correctionRaw,
               cleaned: "Fri", expected: .rejects(.lowerLengthRatio)),
        Vector(source: "the_strict_floor_still_applies_without_a_marker",
               raw: "The meeting is confirmed for Tuesday at 3 PM in the main room.",
               cleaned: "Tuesday.", expected: .rejects(.lowerLengthRatio)),

        // Answered questions and short-raw substitutions (2026-07-16).
        Vector(source: "reject_answered_question", raw: "Should I test manually one by one?",
               cleaned: "Yes, test manually one by one.", expected: .rejects(.questionPreservation)),
        Vector(source: "accept_question_cleaned_as_question", raw: "um should I test manually one by one?",
               cleaned: "Should I test manually one by one?",
               expected: .accepts("Should I test manually one by one?")),
        Vector(source: "accept_question_mark_moved_but_kept", raw: "is it done? the build done?",
               cleaned: "Is it done? The build done?", expected: .acceptsAny),
        Vector(source: "reject_short_raw_substitution", raw: "Go ahead.", cleaned: "Okay.",
               expected: .rejects(.shortWordOverlap)),
        Vector(source: "accept_short_raw_sharing_a_word", raw: "go ahead", cleaned: "Go ahead.",
               expected: .accepts("Go ahead.")),
        Vector(source: "accept_short_raw_filler_removed", raw: "um yes", cleaned: "Yes.", expected: .accepts("Yes.")),

        // Assistant-mode breakouts (rc.1, 2026-07-17).
        Vector(source: "reject_echoed_input_with_commentary", raw: echoRaw,
               cleaned: "The text you provided is:\n\n\"" + echoRaw + "\"\n\n"
                   + "Filler words are removed only when they are disfluencies.",
               expected: .rejects(.echoWithCommentary)),
        Vector(source: "accept_passthrough_and_tiny_punctuation_additions",
               raw: "this is with the R C build by the way", cleaned: "this is with the R C build by the way",
               expected: .accepts("this is with the R C build by the way")),
        Vector(source: "accept_passthrough_and_tiny_punctuation_additions", raw: "is it done",
               cleaned: "Is it done.", expected: .accepts("Is it done.")),
        Vector(source: "reject_markdown_headers", raw: "tell me why the list is not showing up here today",
               cleaned: "### Analysis:\nThe list did not trigger.", expected: .rejects(.markdownHeader)),

        // Lists: invitation (2026-09-13 cue set) and content preservation.
        Vector(source: "reject_unrequested_bullets", raw: "Go ahead.", cleaned: "- Go ahead.",
               expected: .rejects(.listNotInvited)),
        Vector(source: "reject_unrequested_bullets", raw: "we need mangoes and grapes",
               cleaned: "- Mangoes\n- Grapes", expected: .rejects(.listNotInvited)),
        Vector(source: "reject_numbered_bullets_without_list_request",
               raw: "we need mangoes and also grapes for the week", cleaned: "1. Mangoes\n2. Grapes",
               expected: .rejects(.listNotInvited)),
        Vector(source: "accept_requested_bullets", raw: "make a list of groceries mangoes and grapes",
               cleaned: "- Mangoes\n- Grapes", expected: .accepts("- Mangoes\n- Grapes")),
        Vector(source: "accept_requested_bullets", raw: "let's create a shopping list mangoes oranges avocados",
               cleaned: "Shopping list:\n- Mangoes\n- Oranges\n- Avocados", expected: .acceptsAny),
        Vector(source: "accept_numbered_list_on_request",
               raw: "here's a list of to dos one get groceries two go to walmart",
               cleaned: "To dos:\n1. Get groceries\n2. Go to Walmart", expected: .acceptsAny),
        Vector(source: "accept_numbered_list_when_the_speaker_counted",
               raw: "number one fix the login bug number two update the docs number three ship it on friday",
               cleaned: "1. Fix the login bug\n2. Update the docs\n3. Ship it on Friday",
               expected: .accepts("1. Fix the login bug\n2. Update the docs\n3. Ship it on Friday")),
        Vector(source: "accept_numbered_list_when_the_speaker_counted",
               raw: "so there are three things first we fix the login bug second we update the docs and third we ship on friday",
               cleaned: "Three things:\n- Fix the login bug\n- Update the docs\n- Ship on Friday", expected: .acceptsAny),
        Vector(source: "testAcceptNumberedListWhenTheSpeakerCounted (Swift only)",
               raw: "give me the steps open the app tap settings and turn on cleanup",
               cleaned: "- Open the app\n- Tap settings\n- Turn on cleanup", expected: .acceptsAny),
        Vector(source: "one_ordinal_is_not_an_invitation", raw: "first of all thanks for the update",
               cleaned: "- Thanks for the update", expected: .rejects(.listNotInvited)),
        Vector(source: "one_ordinal_is_not_an_invitation (Python only)",
               raw: "one more thing we sold two thousand units", cleaned: "- Two thousand units",
               expected: .rejects(.listNotInvited)),
        Vector(source: "an_invited_list_must_be_made_of_the_speakers_words",
               raw: "number one fix the login bug number two update the docs",
               cleaned: "1. Buy milk\n2. Call the dentist", expected: .rejects(.listInventsContent)),
        Vector(source: "testAnInvitedListMustBeMadeOfTheSpeakersWords (Swift only)",
               raw: "make a list we need bananas oranges and grapes",
               cleaned: "Shopping list:\n- Bananas\n- Oranges\n- Grapes", expected: .acceptsAny),
    ]

    func testEveryAppVectorDecidesByTheExpectedGuard() {
        for (index, vector) in Self.vectors.enumerated() {
            let label = "#\(index) \(vector.source)"
            let result = CleanupLogic.evaluateOutput(raw: vector.raw, cleaned: vector.cleaned)
            switch (vector.expected, result) {
            case (.accepts(let text), .success(let accepted)):
                XCTAssertEqual(accepted, text, label)
            case (.acceptsAny, .success):
                break
            case (.rejects(let reason), .failure(let rejection)):
                XCTAssertEqual(rejection, reason, label)
            default:
                XCTFail("\(label): expected \(vector.expected), got \(result)")
            }
            // `acceptOutput` is the same decision with the reason dropped.
            let accepted = CleanupLogic.acceptOutput(raw: vector.raw, cleaned: vector.cleaned)
            XCTAssertEqual(accepted, try? result.get(), label)
        }
    }

    /// Every rejection reason is reached by at least one app vector, so no
    /// guard is left without a pinned case.
    func testTheVectorsCoverEveryRejectionReason() {
        var reached = Set<String>()
        for vector in Self.vectors {
            if case .rejects(let reason) = vector.expected { reached.insert(reason.rawValue) }
        }
        let all: [CleanupRejection] = [.emptyOutput, .thinkTags, .rolePrefix, .upperLength, .lowerLengthRatio,
            .questionPreservation, .shortWordOverlap, .echoWithCommentary, .markdownHeader,
            .listNotInvited, .listInventsContent]
        XCTAssertEqual(reached, Set(all.map(\.rawValue)))
    }

    /// The echo vector only means something if the length bound cannot see it.
    func testTheEchoVectorIsInsideTheUpperLengthBound() {
        let echo = Self.vectors.first { $0.source == "reject_echoed_input_with_commentary" }!
        XCTAssertLessThanOrEqual(echo.cleaned.count, 2 * echo.raw.count + 20)
    }

    // MARK: - Length floor selection (`min_ratio`)

    func testFloorSelection() {
        let cases: [(source: String, raw: String, floor: Double)] = [
            ("correction_markers_lower_the_floor", "Let's meet Thursday. No, no, wait, we'll meet Friday.", CleanupLogic.minRatioCorrection),
            ("correction_markers_lower_the_floor", "Send it Tuesday, scratch that, Wednesday.", CleanupLogic.minRatioCorrection),
            ("correction_markers_lower_the_floor", "We need four, I mean five.", CleanupLogic.minRatioCorrection),
            ("correction_markers_lower_the_floor", "Ship it Monday, make that Tuesday.", CleanupLogic.minRatioCorrection),
            ("correction_markers_lower_the_floor", "Call him first, or rather email him first.", CleanupLogic.minRatioCorrection),
            ("correction_markers_lower_the_floor", "Let's do Friday. Or actually, let's do Thursday.", CleanupLogic.minRatioCorrection),
            ("correction_markers_lower_the_floor", "Book the big room, hold on, the small one.", CleanupLogic.minRatioCorrection),
            ("correction_markers_lower_the_floor", "We'll need two, let's say three.", CleanupLogic.minRatioCorrection),
            ("ordinary_content_keeps_the_strict_floor", "There's no rush on this one at all.", CleanupLogic.minRatio),
            ("ordinary_content_keeps_the_strict_floor", "No, I don't think that's going to work for us.", CleanupLogic.minRatio),
            ("ordinary_content_keeps_the_strict_floor", "We have no idea what happened to the build.", CleanupLogic.minRatio),
            ("ordinary_content_keeps_the_strict_floor", "The meeting is confirmed for Tuesday at 3 PM.", CleanupLogic.minRatio),
            ("doubled_no_is_a_marker_but_a_single_no_is_not", "Bananas. No, no, oranges.", CleanupLogic.minRatioCorrection),
            ("doubled_no_is_a_marker_but_a_single_no_is_not", "Bananas. No no oranges.", CleanupLogic.minRatioCorrection),
            ("doubled_no_is_a_marker_but_a_single_no_is_not", "No, oranges are what we need here.", CleanupLogic.minRatio),
        ]
        for c in cases {
            XCTAssertEqual(CleanupLogic.minRatio(forRaw: c.raw), c.floor, "\(c.source): \(c.raw)")
        }
        XCTAssertEqual(CleanupLogic.minRatio, 0.30)
        XCTAssertEqual(CleanupLogic.minRatioCorrection, 0.15)
    }

    /// `the_correct_answer_is_shorter_than_the_wrong_one`: the inversion the
    /// correction floor exists for, as ratios.
    func testTheCorrectionFloorAdmitsTheRightAnswerOnly() {
        let right = Double("Let's meet Friday.".count) / Double(Self.correctionRaw.count)
        let wrong = Double("Let's meet Thursday.".count) / Double(Self.correctionRaw.count)
        XCTAssertLessThan(right, wrong)
        XCTAssertLessThan(right, CleanupLogic.minRatio)
        XCTAssertGreaterThan(right, CleanupLogic.minRatioCorrection)
    }

    // MARK: - List invitation (`rawInvitesList`, Swift suite only)

    func testListInvitation() {
        let cases: [(raw: String, invites: Bool)] = [
            ("first of all thanks for the update", false),
            ("one more thing we sold two thousand units", false),
            ("we need mangoes and grapes", false),
            ("firstly the budget secondly the hiring plan", true),
            ("Number 1 do this. Number 2 do that.", true),
            ("here are my to-dos for today", true),
            ("give me bullet points", true),
        ]
        for c in cases {
            XCTAssertEqual(CleanupLogic.rawInvitesList(c.raw), c.invites, c.raw)
        }
    }

    // MARK: - Identity

    /// The guard set a host logs next to a rejection. Changing any guard above
    /// must change this string; a pack manifest names it in `rules`.
    func testGuardRulesIdentityIsExposedThroughTheCapabilityQuery() {
        XCTAssertEqual(CleanupLogic.rulesVersion, "pomvox-guards-v0.2.8")
        XCTAssertEqual(PackCapabilities.frozenBaseline.guardRules, CleanupLogic.rulesVersion)
        let custom = PackCapabilities(styles: [], speculativeSwitch: false, auxiliaryGeneration: false,
                                      minResidentMemoryBytes: nil, vocabulary: .request)
        XCTAssertEqual(custom.guardRules, CleanupLogic.rulesVersion)
    }

    /// Exposing the identity does not change the pack schema: it is not
    /// encoded, so a schema-2 `capabilitiesDetail` block keeps its exact keys.
    func testGuardRulesIdentityIsNotPartOfThePackSchema() throws {
        let data = try JSONEncoder().encode(PackCapabilities.frozenBaseline)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["guardRules"])
    }
}
