import XCTest
@testable import CleanupCore

/// The length-sized deadline policy, ported from Pomvox `CleanupDeadlineTests`.
/// The six pure-policy cases are verbatim apart from `CleanupDeadline.` →
/// `policy.`; the reload-credit and watchdog cases are host timing and stay in
/// the app.
final class CleanupBudgetPolicyTests: XCTestCase {
    private let policy = CleanupBudgetPolicy.measuredM1

    /// The on-device fit these constants come from: warm cleanup latency is
    /// `564 ms + 9.07 ms/char` (219 dictations, 2026-09-02). If the estimator
    /// drifts from the measurement the whole policy is guesswork.
    func testEstimateMatchesTheMeasuredFit() {
        for chars in [100, 300, 600, 1000, 1500] {
            let measuredS = (564.0 + 9.07 * Double(chars)) / 1000.0
            XCTAssertEqual(
                policy.estimateS(chars: chars), measuredS, accuracy: 0.35,
                "estimate drifted from the measured warm fit at \(chars) chars")
        }
    }

    /// A short utterance must keep EXACTLY the configured budget — the fix may
    /// not quietly lengthen the common case, only the case that could not fit.
    func testShortUtterancesKeepTheConfiguredBudget() {
        for base in [5.0, 12.5] {
            for chars in [0, 40, 120, 250] {
                XCTAssertEqual(
                    policy.effectiveTimeoutS(base: base, chars: chars), base,
                    "\(chars) chars must not move the \(base)s budget")
            }
        }
    }

    /// The defect itself. Every transcript that actually timed out on device
    /// must now be given a deadline that covers the work it needs; before the
    /// fix each of these got a flat 12.5 s against a 11.4–19.3 s requirement.
    func testTranscriptsThatTimedOutOnDeviceNowFit() {
        let base = 12.5   // the user's ~/.pomvox/config.toml
        for chars in [1189, 1512, 1548, 1783, 2053] {
            let effective = policy.effectiveTimeoutS(base: base, chars: chars)
            XCTAssertGreaterThan(
                effective, base,
                "\(chars) chars pasted raw at \(base)s on device and must get more")
            XCTAssertGreaterThan(
                effective, policy.estimateS(chars: chars),
                "\(chars) chars still cannot finish inside its deadline")
            XCTAssertFalse(policy.isHopeless(base: base, chars: chars))
        }
    }

    /// The shipped default is 5 s, where the ceiling binds ~4× sooner — the
    /// same defect, worse. A transcript of the length that fit comfortably on
    /// device (1050 chars cleaned in 9.7 s) must fit here too.
    func testDefaultBudgetAlsoScales() {
        let effective = policy.effectiveTimeoutS(base: 5.0, chars: 1050)
        XCTAssertGreaterThan(effective, policy.estimateS(chars: 1050))
    }

    func testDeadlineIsMonotonicAndCapped() {
        var previous = 0.0
        for chars in stride(from: 0, through: 8000, by: 250) {
            let effective = policy.effectiveTimeoutS(base: 12.5, chars: chars)
            XCTAssertGreaterThanOrEqual(effective, previous, "deadline shrank at \(chars) chars")
            XCTAssertLessThanOrEqual(effective, policy.ceilingS)
            previous = effective
        }
    }

    /// Past the ceiling the answer is raw either way — the point is to hand it
    /// over immediately rather than after `ceilingS` of "polishing".
    func testHopelessOnlyOnceTheCeilingBinds() {
        XCTAssertFalse(policy.isHopeless(base: 12.5, chars: 2053))
        let hopeless = Int((policy.ceilingS + 5) * policy.throughputCharsPerS)
        XCTAssertTrue(policy.isHopeless(base: 12.5, chars: hopeless))
        // …and it must never fire on a transcript the budget already covers.
        XCTAssertFalse(policy.isHopeless(base: 12.5, chars: 0))
    }

    // MARK: - Engine additions

    func testDeadlineForTextIsAValidRequestDeadline() throws {
        let text = String(repeating: "a", count: 1548)
        let deadline = try XCTUnwrap(policy.deadline(for: text, base: .milliseconds(12_500)))
        XCTAssertGreaterThan(deadline.milliseconds, 12_500)
        XCTAssertEqual(deadline.milliseconds / 1_000, policy.effectiveTimeoutS(base: 12.5, chars: 1548), accuracy: 0.001)
        XCTAssertNoThrow(try CleanupRequest(text, deadline: deadline).validate())
        XCTAssertEqual(policy.deadline(for: "hello", base: .seconds(5)), .seconds(5))
    }

    func testDeadlineIsNilWhenHopeless() {
        let text = String(repeating: "a", count: Int((policy.ceilingS + 5) * policy.throughputCharsPerS))
        XCTAssertNil(policy.deadline(for: text, base: .milliseconds(12_500)))
    }

    func testDeadlineNeverZero() throws {
        let instant = try CleanupBudgetPolicy(fixedOverheadS: 0, throughputCharsPerS: 1_000_000,
                                              headroom: 1, ceilingS: 60)
        let deadline = try XCTUnwrap(instant.deadline(for: "", base: .zero))
        XCTAssertNoThrow(try CleanupRequest("", deadline: deadline).validate())
    }

    func testInitRejectsUnusablePolicies() {
        for (overhead, throughput, headroom, ceiling) in [
            (0.6, 110.0, 1.4, 61.0), (0.6, 110.0, 1.4, 0.0), (0.6, 0.0, 1.4, 60.0),
            (0.6, 110.0, 0.9, 60.0), (-1.0, 110.0, 1.4, 60.0), (Double.nan, 110.0, 1.4, 60.0),
            (0.6, Double.infinity, 1.4, 60.0),
        ] {
            XCTAssertThrowsError(try CleanupBudgetPolicy(fixedOverheadS: overhead, throughputCharsPerS: throughput,
                                                         headroom: headroom, ceilingS: ceiling))
        }
        XCTAssertEqual(try CleanupBudgetPolicy(fixedOverheadS: 0.6, throughputCharsPerS: 110,
                                               headroom: 1.4, ceilingS: 60), .measuredM1)
    }
}
