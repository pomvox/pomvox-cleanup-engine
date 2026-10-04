// Moved from Pomvox `CleanupDeadline.swift` (pomvox/pomvox#136, app v0.2.6); MIT. Arithmetic preserved.
import Foundation

/// How long a cleanup pass is allowed to take, sized by transcript length.
///
/// A fixed wall-clock budget cannot cover work that is linear in the
/// transcript: the model decodes at a roughly constant rate, so a long
/// dictation deterministically blows any fixed deadline, and burns the whole
/// budget before falling back. Pomvox's on-device history (2026-09-02, 219
/// dictations, Apple M1) fits warm cleanup latency as a line in output length:
///
///     ms ≈ 564 + 9.07 · chars
///
/// That fit predicted the budget ran out at ~1,316 chars, which is where the
/// observed timeouts sat (1,189 to 2,053 chars).
///
/// A deadline is a ceiling, not a sleep: a generous one costs nothing when
/// generation finishes early and only binds on a slow or runaway pass, so the
/// policy errs generous and bounds the worst case with `ceilingS`.
///
/// This is a helper, not a default: `CleanupRequest.budget` is unchanged. A
/// host opts in by passing `deadline(for:base:)` as `CleanupRequest(deadline:)`.
/// Time the host spends outside the request (waiting for a model reload, an
/// outer watchdog) is host timing and stays with the host.
public struct CleanupBudgetPolicy: Sendable, Equatable {
    /// Per-pass cost that does not scale with length (suffix prefill,
    /// tokenize, cache clearing). The intercept of the M1 fit, rounded up.
    public let fixedOverheadS: Double
    /// Decode throughput in output characters per second. 110 ch/s is the
    /// reciprocal of the M1 fit's 9.07 ms/char; M1 is the slowest supported
    /// tier, so this is a floor. Over-estimating throughput under-budgets.
    public let throughputCharsPerS: Double
    /// Multiplier over the point estimate. The fit is a mean; individual
    /// passes vary (a 961-char cleanup took 10.4 s where the fit predicts 9.3 s).
    public let headroom: Double
    /// Absolute ceiling on a single pass, at most 60 s (the request limit).
    /// Past it the pass is hopeless and should be skipped, not waited out.
    public let ceilingS: Double

    /// Measured on an Apple M1 with SimpleWords v3, the slowest supported tier.
    public static let measuredM1 = CleanupBudgetPolicy(
        uncheckedOverhead: 0.6, throughput: 110, headroom: 1.4, ceiling: 60)

    public init(fixedOverheadS: Double, throughputCharsPerS: Double,
                headroom: Double, ceilingS: Double) throws {
        guard fixedOverheadS.isFinite, fixedOverheadS >= 0,
              throughputCharsPerS.isFinite, throughputCharsPerS > 0,
              headroom.isFinite, headroom >= 1,
              ceilingS.isFinite, ceilingS > 0, ceilingS <= 60
        else {
            throw CleanupError.invalidRequest(
                "budget policy needs finite overhead >= 0, throughput > 0, headroom >= 1 and 0 < ceiling <= 60 s")
        }
        self.init(uncheckedOverhead: fixedOverheadS, throughput: throughputCharsPerS,
                  headroom: headroom, ceiling: ceilingS)
    }

    private init(uncheckedOverhead: Double, throughput: Double, headroom: Double, ceiling: Double) {
        self.fixedOverheadS = uncheckedOverhead
        self.throughputCharsPerS = throughput
        self.headroom = headroom
        self.ceilingS = ceiling
    }

    /// Point estimate of how long cleaning `chars` characters takes.
    public func estimateS(chars: Int) -> Double {
        fixedOverheadS + Double(max(0, chars)) / throughputCharsPerS
    }

    /// The deadline a transcript of `chars` characters gets, given the host's
    /// configured `base`. Never below `base`, so a short utterance keeps exactly
    /// the configured budget; never above `ceilingS`.
    public func effectiveTimeoutS(base: Double, chars: Int) -> Double {
        min(ceilingS, max(base, estimateS(chars: chars) * headroom))
    }

    /// Whether the pass provably cannot fit even its widened deadline, i.e. the
    /// ceiling binds. The outcome is raw either way; skipping saves the wait.
    public func isHopeless(base: Double, chars: Int) -> Bool {
        estimateS(chars: chars) > effectiveTimeoutS(base: base, chars: chars)
    }

    /// The deadline to pass as `CleanupRequest(deadline:)` for `text`, or nil
    /// when the pass is hopeless and the host should keep the exact input.
    /// Characters are counted as `text.count`, as Pomvox does.
    public func deadline(for text: String, base: Duration) -> Duration? {
        let chars = text.count
        let baseS = base.milliseconds / 1_000
        if isHopeless(base: baseS, chars: chars) { return nil }
        // At least 1 ms: the request validator rejects a zero deadline.
        let ms = (effectiveTimeoutS(base: baseS, chars: chars) * 1_000).rounded(.down)
        return .milliseconds(max(1, Int64(ms)))
    }
}
