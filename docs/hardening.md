# Hardening evidence — September 15, 2026

This follow-up tests failure boundaries and repairs concrete defects found during the audit. It builds on the [original milestone evidence](validation.md). The source is still unreleased; passing this suite does not satisfy every production release gate.

## Repairs

- Pack validation opens bounded regular files without following final-component symlinks. FIFOs cannot block opening. Hash reads check cancellation and file changes; metadata is parsed from the verified bytes. Unknown artifact fields and malformed version identifiers are rejected.
- Asset preparation verifies copied bytes in staging. Concurrent installers cannot overwrite a destination; failed publication removes only the invocation's owned directory. The source snapshot is unchanged.
- Cancellation during pack validation propagates to the hashing task. A backend constructed during canceled preparation is closed.
- Invalid runtime metrics cannot escape as non-JSON values. Cloud timeout errors retain the timeout outcome. Discarded cloud clients invalidate their URLSession.
- The host adapter rejects nonfinite/nonpositive timeouts before constructing a Duration and clears completed tasks on error paths.
- The optional MLX package uses an explicit local dependency name, avoiding dependence on the checkout directory name.
- The library reference mode collects raw token IDs and decodes the complete sequence, preserving joined Unicode graphemes. It awaits the underlying generation task before releasing caches.

## Core, host adapter and installer

Executed on Apple M1, 16 GiB, macOS 15.7.4, Xcode 26.3, Swift 6.2.4:

| Check | Result |
| --- | --- |
| Debug, warnings as errors, LLVM coverage | 99 tests passed; no failures/skips |
| Release, warnings as errors | 99 tests passed; no failures/skips |
| Thread Sanitizer | 99 tests passed; no reported races |
| Address Sanitizer | 99 tests passed; no reported memory errors |
| Python installer suite | 9 tests passed |
| Repeated lifecycle suite | 20 × 5 tests passed |
| Seeded Unicode reconstruction | 5,000 input/output pairs per full suite |
| Lifecycle workload per run | 640 burst requests and 40 cancellation/close rounds |
| Real artifact preparation | Seven pinned assets copied and verified from the installed source snapshot |

The repeated lifecycle runs alone exercised 12,800 burst requests and 800 cancellation/close rounds. These are lifetime/admission checks, not a throughput benchmark. Sanitizers cover the root package and adapter; they do not instrument the MLX GPU backend or Python interpreter.

Command: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer python3 scripts/check.py --sanitizers --repeat 20 --build-dir /tmp/pomvox-hardening-runner`. [Machine-readable completed checks](evidence/hardening-checks-2026-09-15.json) record command exit status and elapsed time. The runner retains full local logs; repository evidence omits private paths and generated build logs.

### Coverage

LLVM reported **928/938 executable lines (98.93%)** covered across root production sources and the host adapter. [Per-file coverage](evidence/hardening-coverage-2026-09-15.json) includes function coverage. This excludes tests, generated sources, dependencies, scripts and the optional MLX runtime. It is line coverage, not branch coverage, mutation testing, semantic quality or a security certification. Rare filesystem mutation/cancellation races remain partially covered by inspection and bounded fail-closed behavior.

## Model regression

The expanded corpus has 24 synthetic fixtures, including negation, numeric corrections, identifiers and Unicode. The first expanded run **failed**: the library streaming mode returned `👩` where the source reference and both speculative modes preserved `👩🏽‍💻`. Two assertions failed on that single fixture. The fixture remains in the suite; it was not relaxed or removed.

The library path now accumulates raw token IDs using the pinned library API, joins the generation task on completion/cancellation, then decodes once. The default speculative algorithm and prompt are unchanged. The final run passed all **15 model/decoder tests**, with no skips or failures, under a sandbox denying all network access. All **24 fixtures matched exact UTF-8 across four modes**. Each speculative mode accepted **184 drafted tokens**. Vocabulary isolation, rejection of a second resident allocation, expired/pre-canceled requests and closed-runtime behavior also passed. The Xcode consumer rebuilt successfully with the pinned Metal resources.

[Model summary](evidence/hardening-model-2026-09-15.txt) records the mode results. Runtime-only diagnostic medians are not end-to-end latency claims. The source reference shares extracted helpers; the separate library/raw-token and greedy paths provide additional algorithm comparisons. This corpus does not establish semantic quality on arbitrary dictation.

## Final separate-consumer smoke check

After model tests finished, the freshly built Debug consumer ran its three synthetic fixtures five times each with networking denied, using the pack produced by the hardened installer. **15/15 results were cleaned**, with no fallbacks. Preparation was **3,008 ms**; full warm request median **441 ms**, nearest-rank p95 **1,204 ms**. [Per-request data](evidence/hardening-consumer-2026-09-15.json) includes every outcome and timing. This small sample does not establish a production p95 or prove improvement over the earlier run.

Because the working directory has no Git metadata, [source SHA-256 identities](evidence/hardening-source-sha256-2026-09-15.json) identify the implementation/test files used for this run. No commit or release was created.

## Limits of this evidence

The quality, integration, supported-platform and artifact-distribution gates in [testing.md](testing.md#release-gates) remain open. There is no actual Pomvox app integration, no human-reviewed quality score, no long-duration memory/STT contention test, and no production cloud service. No CI configuration, existing app source, release, deployment or remote repository was changed.

Initial Git check-in note: two whitespace-only issues (a trailing space in a model test and a final blank line in the guard source) were normalized. The September 15 SHA-256 record above remains the identity of the original tested snapshot; runtime behavior and fixtures are unchanged.
