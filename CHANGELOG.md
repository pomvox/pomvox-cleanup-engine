# Changelog

## Unreleased

- Add speaker-attributed transcripts: `Transcript`, `SpeakerTurn`, `SpeakerSegment`, `TimedWord` and the pure `Transcript.attribute(words:segments:)` alignment, plus `clean(_ transcript:options:)` on every `Cleaning` value, which cleans one turn per ordinary request and preserves speakers, spans and order. Turns the model never sees (overall deadline spent, over the admission limit, hopeless budget) keep their exact bytes with `Provenance.skipped` and a named warning. The dictation path is unchanged.
- Add `PomvoxDiarization` (dependency-free): the `Diarizing` protocol, `DiarizationRequest`, `SpeakerSegmentation`, and a verified diarizer pack format (`DiarizerPackLoader`, 23 pinned files, nested Core ML bundles) with `scripts/prepare-diarizer-pack.py`.
- Add the optional `Runtime/Diarization` package (`PomvoxDiarizationFluid`): `FluidDiarizer` runs FluidAudio 0.15.5's offline pyannote community-1 pipeline (CC-BY-4.0 artifacts pinned in `packs/pyannote-community1-coreml/pack.json`) on host-supplied audio, loads only from a validated pack, forbids downloads for the process, enforces deadlines caller-side with quarantine, exposes the community-1 knobs (`computeUnits`, `clusteringThreshold`, `minSegmentSeconds`) and returns first-appearance `S1…` labels. Includes a host stand-in example (`speaker-notes-example`) and tests on a synthetic two-voice fixture generated with macOS speech synthesis.
- Add `CloudDiarizer` to `PomvoxCleanupCloud`: an explicit cloud diarizer with the same posture as `CloudCleaner` (endpoint and credentials required, HTTPS or loopback, no redirects, no retries, one in flight, caller-side deadline). It uploads 16 kHz mono PCM16 WAV with pack and budget headers and validates the JSON `SpeakerSegmentation` reply before relabeling speakers by first appearance. Diarization wire protocol version 1 is documented in `docs/cloud.md`. No provider is selected.
- Add `CloudNotes` to `PomvoxCleanupCloud` and `ModelNotes` to `PomvoxNotes`: an explicit cloud note writer with `CloudCleaner`'s transport rules. It sends the cleaned transcript and returns a model's summary and categorized notes only after checking that every note cites turns that exist; `NotesRenderer.markdown(_:model:)` renders them ahead of the quoted candidates. On any failure the host keeps the deterministic notes it already has. Notes wire protocol version 1 is in `docs/cloud.md`. No provider is selected.
- Add `Examples/LocalServer`: a loopback reference server over the real local runtimes that speaks the cleanup and diarization wire protocols (the SDK's own cloud clients accept its replies) plus a demo endpoint running the whole speaker-notes pipeline, and a one-page web app that uses it. Host stand-in code: a browser cannot run the SDK; it can talk to a local companion process that does.
- Add `PomvoxNotes`, deterministic notes over a cleaned transcript: participants, and action-item, decision, question and list-item candidates quoted verbatim with turn index and UTF-8 range, rendered to Markdown by `NotesRenderer`. No model writes the notes; the cue set is versioned as `pomvox-notes-v0.1`.

## 0.1.0-beta.3 — 2026-10-05

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
