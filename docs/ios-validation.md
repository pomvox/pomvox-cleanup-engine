# iOS device validation — protocol, not results

The engine builds for iOS 17 (`Examples/iOSConsumer` links `PomvoxCleanup`,
`PomvoxNotes`, `PomvoxCleanupMLX` and `PomvoxDiarizationFluid` with no
deployment-target override). **Nothing has run on an iPhone.** Every number in
the tables below is "not measured here" until a session with a device fills it
in from commands it ran, naming the device, iOS version, build configuration
and packs. This page is the checklist that session executes. It is not a support
statement.

## What is known before a device is involved

| Fact | Value | Source |
| --- | --- | --- |
| Deployment floor | iOS 17, set by mlx-swift-lm, swift-tokenizers and FluidAudio 0.15.5 | iOS consumer build, `docs/testing.md` |
| Cleanup pack `simplewords-v3` (8-bit) | 2,020,106,400 bytes of artifacts (1.88 GiB on disk) | `packs/simplewords-v3/pack.json`; `du` on an installed pack |
| Diarizer pack `pyannote-community1-coreml` | 20.7 MiB on disk | `du` on an installed pack |
| Output cap per cleanup request | `max(64, min(2 × input tokens, 1,024))` tokens | `docs/contract.md` |
| Cleanup throughput on an Apple M1 Mac | 0.6 s + chars / 110 ch/s (the `measuredM1` fit) | `CleanupBudgetPolicy.measuredM1`; a Mac, not a phone |
| Diarizer cancellation | a running FluidAudio 0.15.5 pipeline cannot be interrupted; release waits for it | `docs/speaker-notes.md`, `docs/evidence/diarizer-cancel-2026-10-11.json` (M1 Mac) |

The 1.9 GB cleanup pack was sized for a 16 GB Mac. Whether an iPhone's per-app
memory limit admits it is the first thing to find out, and a smaller pack is
tracked in #30 and #2. **The 600 s deadlines in the app are guesses, not
benchmarks.** Replace them with figures from this protocol.

## Setup

1. Build the app (or `Examples/iOSConsumer`) in **Release** with deployment
   target iOS 17. Record the Xcode version and the engine tag.
2. Put the installed packs in the app's container (for example with the Xcode
   devices window or the Files app). The engine never downloads. Record each
   pack's `pack.json` id, version and digest.
3. Before each measured run, record `ProcessInfo.processInfo.thermalState`,
   battery level, Low Power Mode, and `os_proc_available_memory()`.
4. Use consented, scripted speech. Keep recordings and transcripts out of this
   public repository. Record their length, speaker count and noise condition.

## Checks

### 1. Offline pack load (airplane mode)

Turn on airplane mode, kill the app, launch it, open the cleaner
(`Cleaner.open(pack:runtime: .mlx)`) and the diarizer (`FluidDiarizer.open`).

- Pass: both open; `preparationMS` recorded for each; no network attempted.
- Also run each open with a pack directory missing one artifact. Expect
  `invalidPack` / `unavailable` immediately, never a download.
- Record whether open survives memory pressure, or the app is terminated
  (jetsam). Note `os_proc_available_memory()` before and after each open.

### 2. Recording protocol

Three lengths, two speaker counts, two conditions, each run **three times**
(first run after a fresh launch counts as cold, the rest warm):

| Length | Speakers | Condition |
| --- | --- | --- |
| short (about 1 min) | 2, 3 | quiet, noisy |
| 15 min | 2, 3 | quiet, noisy |
| 60 min | 2, 3 | quiet, noisy |

Pipeline per run: host STT with word timings → `FluidDiarizer.diarize` →
`Transcript.attribute` → `cleanIncrementally` with
`TranscriptCleanOptions(turnBudget:segmentation: TurnSegmentation())` →
`Notes.extract`.

### 3. What to measure, every run

- **Stage latency**: STT (host), diarization (`DiarizationTimings`: total,
  segmentation, embedding, clustering), cleanup per turn (`CleanupTimings.totalMS`,
  `inferenceMS`) and for the whole transcript, notes. Report all outcomes, never
  successful-only statistics.
- **Memory**: peak and residual `phys_footprint` (Instruments or `task_info`)
  after open, during each stage, and after `closeAndWait()` on both the diarizer
  and the cleaner. Residual must return near the pre-open level.
- **Thermal**: `thermalState` sampled every 5 s through the run; note any
  transition to `.serious` or `.critical` and the stage it happened in.
- **Outcomes**: counts of turns `.cleaned`, `.unchanged` and each
  `.fallback(reason)`. Count warnings `segmented:*`, `segment-*-fallback:*`,
  `cleaner-quarantined`, `transcript-budget-exhausted` and `turn-budget-hopeless`.
- **Energy** (optional): Xcode energy gauge or `powermetrics`-equivalent
  readings, stated with their tool.

### 4. Cancellation

- **During pack load**: cancel the task running `Cleaner.open` after 100 ms,
  1 s and 5 s. Expect `CancellationError`, then a successful open afterwards
  (no leaked device lease: a second open must not report the MLX device busy).
- **During diarization**: cancel `diarize` mid-run, then `closeAndWait()`.
  Record time to the caller's error (expect immediate) and time to release
  (expect about the remaining pipeline time; FluidAudio 0.15.5 runs to the
  end). Reopen and diarize again.
- **During cleanup**: stop consuming `cleanIncrementally` after N turns, save
  the `TranscriptCheckpoint`, close, reopen, resume. The combined result must
  equal an uninterrupted run byte for byte (text, edits, status, provenance).

### 5. Background and foreground

iOS restricts GPU work for backgrounded apps. Record exactly what happens
rather than assuming:

- Background the app during MLX cleanup. Record the turn that was in flight,
  its outcome, and whether later turns fall back, wait or fail.
- Background during diarization (Core ML). Same records.
- Return to the foreground and resume from the last checkpoint. The result
  must still equal an uninterrupted run.
- Decide from the records whether the app must `closeAndWait()` both runtimes
  before backgrounding. That is app policy, not engine policy.

### 6. Quote ranges

For every `NoteItem`, check that the bytes `start..<end` of its turn's cleaned
text equal `item.text`, and that `TextEdit.utf16Range` converts it for UIKit
or SwiftUI highlighting. For split turns, check that the quote falls in one
`SegmentOutcome` output range and that the source range shown to the user
contains the spoken words. Report any mismatch with the turn's bytes (redacted
if private).

## Results matrix (fill in; leave "not measured here" where a cell was not run)

| Device | iOS | Pack | Recording | Runs | Diarize total | Cleanup total | Peak memory | Residual memory | Worst thermal | Fallbacks by reason | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| not measured here | | simplewords-v3 | short, 2 spk, quiet | | | | | | | | |
| not measured here | | simplewords-v3 | 15 min, 2 spk, quiet | | | | | | | | |
| not measured here | | simplewords-v3 | 60 min, 3 spk, noisy | | | | | | | | |
| not measured here | | pyannote-community1-coreml | 60 min, 3 spk, noisy | | | n/a | | | | n/a | |

| Device | Airplane-mode load | Cancel during load | Cancel during diarize (release time) | Resume equals uninterrupted | Background during cleanup | Background during diarize |
| --- | --- | --- | --- | --- | --- | --- |
| not measured here | | | | | | |

Keep the raw records as JSON under `docs/evidence/` (device identifier, iOS
version, build configuration, pack ids and digests, every outcome), as the Mac
evidence files do. A claim that iOS is supported needs this table filled for at
least one device per memory class the app targets.
