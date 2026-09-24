# Pomvox integration gap review

Review of [the app's report](https://github.com/pomvox/pomvox/blob/feat/cleanup-engine-sdk/docs/cleanup-engine-sdk-gaps.md), against SDK baseline `00bd4d8`. The report's measurements are historical app evidence, not benchmarks of these changes.

| Gap | Disposition |
| --- | --- |
| 1: installation / duplicate weights | Added native `PackInstaller.install(snapshot:manifestData:destination:)`. Resolves snapshot symlinks, uses APFS clones where supported, verifies staged bytes, exclusively publishes a complete directory. Other filesystems require a copy. Downloads, license acceptance and acquisition remain host responsibilities. |
| 2: vocabulary cache | Fixed with one replaceable prefix keyed by the rendered dictionary hint. `RuntimeFactory.mlx(vocabulary:)` prepares the initial dictionary during open. Each request must still carry its vocabulary. Subsequent dictionary changes rebuild once; there is no unbounded dictionary cache. |
| 3: eviction/revalidation | Added `.validated(cleaner.pack)` reopening, with process-local file-identity checks, and `closeAndWait()` for actual lease release. Close releases both weights and prefix memory; reopen reloads and warms the runtime. This avoids repeated hashing, not all preparation. |
| 4: quarantine | Preserved resource ownership. Exposed `availability` (`ready`, `working`, `quarantined`, `closed`). Host may wait within its remaining utterance budget. The report's 699–1,323 ms is not a recovery guarantee; a hung kernel can hold the lease indefinitely. A second cleaner is not a safe workaround. |
| 4b: rejection diagnostics | Added `evaluateOutput`, eleven typed rejection reasons, `rejectedBy:<reason>` warnings, and retained observed runtime timings/warnings on rejection and token-limit fallback. No candidate text is exposed. Timer-driven fallback cannot include statistics that have not arrived. |
| 4c: list formatting | Kept existing behavior deliberately. The frozen prompt permits lists only when requested. `listPreservesContent` checks 80% word overlap; it does **not** prove semantic preservation, preserve negation, or validate headers. Trusting model formatting alone weakens the guard. Broader cues require a separately reviewed positive/negative quality corpus and a new rules version. |
| 4d: first dictation | Eager host preparation is required. Reuse helps same-process reopen only; initial validation remains mandatory. |
| 5: output token cap | Retained the bounded 1,024-token ceiling. Input bytes cannot predict required output tokens; raising the cap or rejecting by character count without evidence creates new behavior gaps. The report explicitly did not reproduce this cliff. Long non-repetitive model/host fixtures remain a release gate. Fallback now retains completed generation diagnostics. |
| 6: vocabulary bounds | Retained strict validation; silently dropping a requested spelling rule is undesirable. Host must choose a deterministic bounded subset before open and each request. The full dictionary remains available to the later host dictionary transform. |
| 7: diagnostics | Added optional cache-use, prompt/decode token counts and speculative counters to timings, retained on completed fallback. Detailed load/prefix/warmup preparation split remains unimplemented; `preparationMS` is still aggregate. |
| 8: global cache clearing | Removed unconditional clearing. `RuntimeFactory.mlx(vocabulary:clearBufferCache:)` allows deliberate opt-in at generation and close. The default coexists with other MLX buffer-pool users; freeing model references does not promise immediate OS RSS reduction. |
| 9: remote SwiftPM | Resolved for `0.1.0-beta.2` by publishing `pomvox/pomvox-cleanup-mlx` as a standalone package with an exact dependency on the matching core tag. Development source remains in `Runtime/MLX`; deterministic export tests prevent distribution drift. |
| 10: duplicate guards | Added `CleanupLogic.rulesVersion`; manifest validation compares against it. Host must remove the redundant guard pass. A version constant identifies behavior but does not automatically prove source equivalence. |
| 11: inert settings | Existing `pack.manifest.capabilities` advertises vocabulary only. Hide/disable style and speculative controls for this backend; never silently accept unsupported settings. No new style or decoder configuration is claimed. |
| 12: auxiliary generation | Unsupported by this cleanup-only API. Do not load a second engine for suggestions. Disable model suggestions on this backend or design a separately tested serialized auxiliary API. The SDK lease only coordinates SDK instances; it cannot stop an independent in-app MLX engine from allocating another model. The host must enforce that policy. A generic prompt escape hatch expands the SDK's contract and needs its own lifecycle/security tests. |

## Boundaries of the fixes

Validation-handle reuse is neither persistent certification nor protection against a hostile filesystem. It verifies the same regular-file set, device/inode, mode, size and nanosecond modification/change times before reopening. Changed files require full validation. Hosts must keep installed packs immutable; no handle can authorize replacing files under an open model.

Installation is synchronous filesystem work and must run off the main actor. The caller supplies trusted pinned manifest bytes, not a manifest obtained from an untrusted snapshot. Clone/copy itself may not stop immediately on cancellation; cancellation is checked between files and during hash validation. Failure before publication removes staging. No destination is overwritten.

A cache rebuild is request work when the vocabulary changes; the session deadline still includes it, and an expired worker retains ownership until it returns. Initial vocabulary preparation avoids this cost on the first dictation. Exact token-prefix matching remains mandatory even after rebuilding.

## Initial validation — 2026-09-23

- 106 root tests passed in Debug (warnings as errors), Release (warnings as errors), Thread Sanitizer and Address Sanitizer; nine Python installer tests passed.
- Twenty lifecycle stress repetitions passed. An existing test incorrectly assumed that eight callers could all be canceled after submitting them to a two-slot queue; a completed busy response cannot be canceled retroactively. The test now admits all eight and keeps the runtime pending for cancellation. The initial failure at repetition 15 is retained in the evidence summary.
- The separate Xcode consumer built successfully. Network-denied real-model validation passed all 16 tests with zero skips: the 24 baseline fixtures matched across library, greedy, cached speculative and uncached speculative paths. New tests verified byte parity and actual cache use with 0/1/2/64 terms, repeated requests and dictionary changes.
- The Desktop's dataless/cloud-synced files changed timestamps during an initial pack validation and a source build. Final root checks used a byte-identical temporary source copy; model validation used the existing pinned Hugging Face snapshot copied to local temporary storage. These setup failures were not discarded from the record.

See [check summary](evidence/integration-gap-checks-2026-09-23.json), [model test log](evidence/integration-gap-model-2026-09-23.txt), and [tested source hashes](evidence/integration-gap-source-sha256-2026-09-23.json). Model timings in this test log are diagnostic observations, not a controlled app latency benchmark. Real microphone/STT integration, sleep/wake, memory pressure, private-corpus quality, and full app soak testing remain host release gates.

## Follow-up code and prompt review — 2026-09-23

Two reproduced adapter defects were fixed:

- **Stale insertion after a host callback cancels the session:** the adapter checked validity only before host transforms. A synchronous formatting callback could call `cancel()` and the old text would still be inserted. The adapter now rechecks both task cancellation and session identity after all transforms, immediately before insertion. A regression failed before the fix and passes afterward.
- **Explicit remaining budget extended by transcript length:** the adapter's adaptive formula turned a 100 ms caller budget into approximately 39 seconds for a 3,000-character input. It now preserves the caller's remaining budget, capped at the SDK's 60-second maximum. A regression failed before the fix and passes afterward.

The prompt now specifies the actual uncommitted-checkout state, cancellation-aware shared-preparation waiters, retirement of late preparation results, dormant memory-pressure eviction, retention of a retiring cleaner, explicit MLX buffer-pool policy, input byte limits, exhausted budgets, no automatic cloud fallback, and a final insertion check after host transforms. Fresh installer handles can be reused for the first open without hashing the same installation twice.

The review also investigated canonical Unicode equality in dictionary cache keys. The pinned tokenizer passed composed/decomposed vocabulary tests with correct cache reuse before any runtime change; this was not a reproduced runtime defect. The runtime was left unchanged, and those cases remain in the differential tests. Repeated cached requests now compare with their corresponding uncached repetition.

These fixes remain local working-tree changes. No containing release or pushed SDK revision is claimed. Host integration and the previously listed release gates are still required.

Follow-up validation passed: **108 root tests** in Debug, Release, Thread Sanitizer and Address Sanitizer; **20 lifecycle repetitions**; and **16 network-denied model tests with zero failures and zero skips**, including the expanded Unicode vocabulary cases. See [review checks](evidence/review-checks-2026-09-23.json), [model log](evidence/review-model-2026-09-23.txt), and [reviewed source and prompt hashes](evidence/review-source-sha256-2026-09-23.json). Both adapter regression failures were captured before their fixes: [deadline](evidence/review-before-2026-09-23.txt), [stale insertion](evidence/review-insertion-before-2026-09-23.txt).

Release update: the earlier local/uncommitted descriptions above record the review state, not the published distribution. Version `0.1.0-beta.2` adds tagged core/runtime packages and CI; use the current integration prompt for installation. Other stable-production gates remain unchanged.
