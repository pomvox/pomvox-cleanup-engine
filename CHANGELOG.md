# Changelog

## Unreleased

- Publish the diarization runtime as its own remote package, `pomvox/pomvox-diarization-fluid`, generated from `Runtime/Diarization` by the new `scripts/export-diarization-release.py` (#25). Apps no longer need a local checkout for `PomvoxDiarizationFluid`. SDK CI gains a `diarization` job that runs the runtime's tests without a model (the real-pack tests skip and say so) and verifies the export; the release procedure covers the second runtime.
- Add `PackInstaller.installed(at:)` and `PackInstaller.remove(_:)` (#12). Listing returns each pack directory under a parent with its manifest id and version, install date, `allocatedBytes` (allocated blocks, what `du` reports; an APFS clone counts in full) and `privateBytes` (what removing it frees now, via `ATTR_CMNEXT_PRIVATESIZE`; near zero while the pack still shares blocks with its source snapshot). Removal refuses, with `CleanupError.unavailable`, while a `Cleaner` in the same process holds the pack, from before validation until its runtime resources are released; it renames the directory aside under that check before deleting, so the published path never holds a partial pack and a stale listing never deletes a replacement. Cleaners in other processes are not detected. Documented in `docs/packs.md`.

## 0.2.0-beta.1 — 2026-10-11

- Declare iOS 17 in the root package, `Runtime/MLX` and `Runtime/Diarization`. Without it an iOS 17 app could not link the runtimes (mlx-swift-lm, swift-tokenizers and FluidAudio require iOS 17, while an undeclared package defaults to iOS 12). Add `Examples/iOSConsumer`, an iPhone app that links all four libraries with no deployment-target override. Builds only: nothing is validated on a device.
- Make `import PomvoxNotes` and `import PomvoxDiarization` work as the README and speaker-notes guide say. The products used to expose only the `CleanupNotes` and `CleanupDiarization` modules; both names now import, so existing code is unaffected.
- Add `closeAndWait()` to `FluidDiarizer`, `CloudDiarizer` and the `Diarizing` protocol (with a default implementation that only calls `close()`, so other conformers still compile), plus `resourcesReleased`. Like `Cleaner.closeAndWait()`, it stops admission and returns only after the running worker has returned and the models or session are released. Cancelling the wait never reopens admission. A canceled, expired or closed `FluidDiarizer` request now cancels its worker, which skips the pipeline if it has not started. A pipeline that is already running is not interrupted: FluidAudio 0.15.5 has no cancellation point the caller can reach.
- Add opt-in long-turn segmentation for transcripts (#13): `TranscriptCleanOptions.segmentation = TurnSegmentation()` splits a turn longer than `maxSegmentBytes` (default 1,000, so the output fits the 1,024-token cap in any script) into ordinary requests. Splits fall at sentence ends, then whitespace, then grapheme-cluster boundaries. The engine reassembles one `TurnResult` with the same speaker and span, edits at their byte offsets in the turn, and per-segment `segments` outcomes mapping output ranges to source ranges. Separators are copied verbatim. A segment that falls back keeps its exact bytes, and a turn with no cleaned segment is its exact input. Off by default; limits, prompt and output cap are unchanged. `TurnSegmenter.split` is public.
- Fix transcript cleaning after a timeout: a timed-out turn left the worker quarantined, and every following turn fell back at once as `unavailable`. On the real pack, one timed-out segment of an 18 KB monologue turned the remaining 13 segments into fallbacks. The loop now waits for the cleaner to recover, within each turn's own budget and the overall deadline; otherwise the turn keeps its exact bytes with `cleaner-quarantined`. Adds `Cleaning.availability` (default `.ready`).
- Add `cleanIncrementally(_:options:resuming:)` on every `Cleaning` value. It yields each transcript turn's final `TurnResult` with its index as soon as the turn finishes, running the same loop as the unchanged batch `clean(_:options:)`. It can resume from a host-saved `TranscriptCheckpoint` of accepted turns and cleans only the rest. The checkpoint is refused unless the transcript's exact bytes, speakers and spans, the output-affecting options, the pack (`PackIdentity`, a new `Cleaning.packIdentity` requirement with a nil default) and every accepted result match. `checkpointIdentity(for:options:)` builds the identity.
- Add `docs/ios-validation.md`: the on-device checklist for the iPhone app (airplane-mode pack load, short / 15-min / 60-min recordings, stage latency, peak and residual memory, thermal state, fallback counts, cancellation during load and inference, background and foreground, quote ranges) and an empty device × pack results matrix. Nothing in it is measured; the app's 600 s deadlines are guesses until it is.
- Add speaker-attributed transcripts: `Transcript`, `SpeakerTurn`, `SpeakerSegment`, `TimedWord` and the pure `Transcript.attribute(words:segments:)` alignment, plus `clean(_ transcript:options:)` on every `Cleaning` value, which cleans one turn per ordinary request and preserves speakers, spans and order. Turns the model never sees (overall deadline spent, over the admission limit, hopeless budget) keep their exact bytes with `Provenance.skipped` and a named warning. The dictation path is unchanged.
- Add `PomvoxDiarization` (dependency-free): the `Diarizing` protocol, `DiarizationRequest`, `SpeakerSegmentation`, and a verified diarizer pack format (`DiarizerPackLoader`, 23 pinned files, nested Core ML bundles) with `scripts/prepare-diarizer-pack.py`.
- Add the optional `Runtime/Diarization` package (`PomvoxDiarizationFluid`): `FluidDiarizer` runs FluidAudio 0.15.5's offline pyannote community-1 pipeline (CC-BY-4.0 artifacts pinned in `packs/pyannote-community1-coreml/pack.json`) on host-supplied audio, loads only from a validated pack, forbids downloads for the process, enforces deadlines caller-side with quarantine, exposes the community-1 knobs (`computeUnits`, `clusteringThreshold`, `minSegmentSeconds`) and returns first-appearance `S1…` labels. Includes a host stand-in example (`speaker-notes-example`) and tests on a synthetic two-voice fixture generated with macOS speech synthesis.
- Add `CloudDiarizer` to `PomvoxCleanupCloud`: an explicit cloud diarizer with the same posture as `CloudCleaner` (endpoint and credentials required, HTTPS or loopback, no redirects, no retries, one in flight, caller-side deadline). It uploads 16 kHz mono PCM16 WAV with pack and budget headers and validates the JSON `SpeakerSegmentation` reply before relabeling speakers by first appearance. Diarization wire protocol version 1 is documented in `docs/cloud.md`. No provider is selected.
- Add `CloudNotes` to `PomvoxCleanupCloud` and `ModelNotes` to `PomvoxNotes`: an explicit cloud note writer with `CloudCleaner`'s transport rules. It sends the cleaned transcript and returns a model's summary and categorized notes only after checking that every note cites turns that exist; `NotesRenderer.markdown(_:model:)` renders them ahead of the quoted candidates. On any failure the host keeps the deterministic notes it already has. Notes wire protocol version 1 is in `docs/cloud.md`. No provider is selected.
- Add `Examples/LocalServer`: a loopback reference server over the real local runtimes that speaks the cleanup and diarization wire protocols (the SDK's own cloud clients accept its replies) plus a demo endpoint running the whole speaker-notes pipeline, and a one-page web app that uses it. Host stand-in code: a browser cannot run the SDK; it can talk to a local companion process that does.
- Add `PomvoxNotes`, deterministic notes over a cleaned transcript: participants, and action-item, decision, question and list-item candidates quoted verbatim with turn index and UTF-8 range, rendered to Markdown by `NotesRenderer`. No model writes the notes; the cue set is versioned as `pomvox-notes-v0.1`.

## 0.1.0-beta.3 — 2026-10-05

Prepared but never tagged; these changes first ship in 0.2.0-beta.1.


- Own the output-guard specification: every guard vector from the Pomvox app's `test_cleanup.py` and `CleanupLogicTests` is a table-driven case in `GuardVectorTests` that asserts the rejection reason. `PackCapabilities.guardRules` reports the guard set identity (`CleanupLogic.rulesVersion`) through the capability query. Guard behaviour is unchanged.
- Add `CleanupBudgetPolicy`, a length-sized deadline helper moved from the Pomvox app with its tests. It is opt-in: the default request budget is unchanged.
- Add a capability query (`ValidatedPack.capabilities`, `Cleaner.capabilities`) and an optional pack schema 2 that declares it. Schema 1 packs, including `simplewords-v3`, are unchanged and report the frozen baseline.
- Add an opt-in spoken-layout transform (`CleanupRequest(transforms: [.spokenLayout])`), moved from the Pomvox app with its tests. It applies to accepted output only; fallbacks stay exact input, and `SpokenLayout.apply` is public for hosts that want it there too.
- Report the request text admission limit as `PackCapabilities.maxTextBytes` (`CleanupRequest.maxTextBytes`, 16,384 UTF-8 bytes, unchanged), and document it with the runtime's output cap as one pair in the contract guide. Requests that cannot fit the output cap are not yet rejected at admission; that check needs the tokenizer (#13).

## 0.1.0-beta.2 — 2026-09-24

- Fix remote SwiftPM consumption: keep the exact tokenizer version active by depending on its product.
- Build runtime CI through a remote dependency on the exact pushed commit and verify resolved versions.
- Supersede beta.1 tags, which were withheld from GitHub Releases after the final remote-install check failed.

## 0.1.0-beta.1 — 2026-09-24

First tagged public SDK release. This beta does not claim production readiness.

- Publish core/cloud SDK and standalone MLX Swift packages with matching exact versions.
- Add public CI for Debug/Release, sanitizers, lifecycle/installer checks, and Xcode consumer builds.
- Reuse a bounded vocabulary-aware prefix cache, with real-model differential coverage.
- Add native pack installation, APFS cloning, immutable-pack validation reuse, and safe close/reopen.
- Preserve rejection reasons and observed runtime diagnostics on completed fallbacks.
- Expose quarantine state, decoder counters, cache use and optional MLX buffer-pool clearing.
- Preserve explicit host deadlines and recheck cancellation/session identity immediately before insertion.
- Provide a reviewed integration prompt and reproducible validation evidence.

Model weights are separate gated artifacts. macOS 14 is the deployment floor; Linux,
Intel inference, style controls, auxiliary generation, unlimited output and production
cloud hosting are not part of this release. See docs/testing.md for remaining stable-release gates.
