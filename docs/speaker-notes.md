# Speaker transcripts and notes — preview

Two optional aspects for a host that records more than one voice: a
speaker-attributed transcript that goes through the ordinary cleaner one turn
at a time, and deterministic notes over the result. Neither changes the
dictation path. Nothing here runs unless a host calls it.

| Aspect | Module | What it is |
| --- | --- | --- |
| Transcript | `CleanupCore` (`PomvoxCleanup`) | `SpeakerLabel`, `TimeSpan`, `SpeakerSegment`, `TimedWord`, `SpeakerTurn`, `Transcript`, `Transcript.attribute`, `TranscriptResult` |
| Transcript cleaning | `PomvoxCleanup` | `Cleaning.clean(_ transcript:options:)`, `TranscriptCleanOptions` |
| Notes | `CleanupNotes` (product `PomvoxNotes`) | `Notes.extract`, `NoteItem`, `Participant`, `NoteHeuristics`, `NotesRenderer.markdown` |
| Diarization contract | `CleanupDiarization` (product `PomvoxDiarization`) | `Diarizing`, `DiarizationRequest`, `SpeakerSegmentation`, `DiarizerPackLoader` |
| Local diarizer | `Runtime/Diarization` (product `PomvoxDiarizationFluid`, optional) | `FluidDiarizer` over FluidAudio 0.15.5's offline pyannote community-1 pipeline |

The SDK still owns no microphone, STT or UI. The host captures audio, runs its
speech recognizer with word timings, and obtains speaker segments from a
diarizer. The engine takes it from there:

```swift
import PomvoxCleanup
import PomvoxNotes

// 1. Host side: recognized words with timings, and who-spoke-when segments.
let words: [TimedWord] = sttTokens.map { TimedWord($0.text, span: TimeSpan(start: $0.start, end: $0.end)) }
let segments: [SpeakerSegment] = diarization.segments

// 2. Pure alignment: words become speaker turns. No model, no state.
let transcript = Transcript.attribute(words: words, segments: segments)

// 3. One ordinary cleanup request per turn, through the opened cleaner.
let cleaned = try await cleaner.clean(transcript, options: TranscriptCleanOptions(
    vocabulary: selectedTerms, transforms: [.spokenLayout],
    turnBudget: .measuredM1, overallDeadline: .seconds(120)))

// 4. Deterministic notes, rendered as Markdown.
let notes = Notes.extract(from: cleaned)
let markdown = NotesRenderer.markdown(notes, options: .init(speakerNames: [SpeakerLabel("S1"): "Abhi"]))
```

## Attribution

`Transcript.attribute(words:segments:options:)` assigns each word to the
segment it overlaps most (ties go to the earlier segment). A word nothing
overlaps goes to the nearest segment within `nearestTolerance` (1 s), else to
the previous word's speaker; leading unclaimed words take the first speaker
that follows. Consecutive same-speaker words form one turn; a silence of at
least `splitGap` (2 s) starts a new turn for the same speaker. Words keep their
input order and text, empty texts are dropped, and with no segments the result
is one unattributed turn.

The property the tests pin: the turn texts, split on the joining space, are
exactly the nonempty input words in order, for any timings and any segments.
Invalid segments (non-finite or reversed spans) are ignored, never fatal.

## Cleaning a transcript

`clean(_ transcript:)` is an extension on `Cleaning`, so it works on the local
`Cleaner`, on `CloudCleaner`, and on any test double. Each turn is one
`CleanupRequest` with the options' vocabulary and transforms; each goes through
the same admission, guards, deadline and fallback as a dictation. The result
has one `TurnResult` per input turn, in order, with the same speaker and span.
The engine never merges, splits, reorders or relabels turns.

Why one request per turn: the frozen model was trained on single utterances.
A multi-speaker prompt with speaker prefixes would change the prompt bytes
and put the model off-distribution; the length and list guards would misfire
on it. Per-turn requests keep parity with the shipped engine exactly.

Budgets. Without `turnBudget` each turn gets the request's default budget
(`2 + 0.012·chars` seconds, 5 to 60 s). With a `CleanupBudgetPolicy`, each turn
gets `deadline(for:base:)`; a turn the policy calls hopeless is skipped. An
`overallDeadline` caps the whole call: once spent, remaining turns are returned
as `.fallback(.timedOut)` without inference. Per-turn deadlines are also
clamped to what remains of the overall budget.

Turns the model never sees carry `Provenance.skipped` (route `skipped`) and one
warning naming why:

| Warning | Status | Cause |
| --- | --- | --- |
| `transcript-budget-exhausted` | `.fallback(.timedOut)` | the overall deadline was spent before this turn |
| `turn-exceeds-admission-limit` | `.fallback(.unavailable)` | the turn's text is over `CleanupRequest.maxTextBytes` (16,384 bytes); it is not split or truncated |
| `turn-budget-hopeless` | `.fallback(.timedOut)` | the budget policy's ceiling cannot fit the estimated work |

Every such turn is its exact bytes with zero edits. Cancellation throws and
delivers nothing, as for a single request. A transcript may have at most
`Transcript.maxTurns` (2,048) turns; longer input is refused before any
inference, as are invalid spans, invalid vocabulary and a non-positive overall
deadline.

This is a batch call on the same one-request worker as live dictation. Run it
when no dictation is waiting on the cleaner, or accept that dictations queue
behind it (the queue holds two; the third is `busy`). Timing is proportional
to the number and length of turns; a figure for a given transcript comes from
`TranscriptResult.elapsedMS` and the per-turn timings, not from this document.

## Notes

`Notes.extract(from:)` runs no model. It produces:

- `participants`: per speaker in order of first appearance, turn count, token
  count (whitespace-separated, list markers included) and summed speaking time
  when every turn of that speaker has a span.
- `items`: candidate action items, decisions, questions and list items. Each is
  a **verbatim** sentence or list line of a cleaned turn with `turnIndex` and
  the UTF-8 byte range of that sentence in the turn text (the `TextEdit`
  convention), so a host can highlight the source. The tests assert every item
  reconstructs from its range.
- `source`: the whole `TranscriptResult`, so nothing is lost by taking notes.
- `heuristics`: the cue-set identity (`pomvox-notes-v0.1`), to log next to the output.

Classification is deliberately simple and visible: a list line (`- item`,
`1. item`) is a list item; a sentence ending in `?` is a question; a sentence
matching an action cue (`I'll`, `we need to`, `follow up`, `by Friday`,
`deadline`, ...) is an action item; one matching a decision cue (`decided`,
`agreed`, `let's go with`, `approved`, ...) is a decision; action wins over
decision. Sentences are cut at `.`, `!`, `?` followed by whitespace and at
line breaks, without changing a byte. These are candidates for a person to
keep or discard, not an understanding of the meeting. Hosts can pass their own
cue lists through `NoteHeuristics(actionCues:decisionCues:version:)`; change
the version string with them.

`NotesRenderer.markdown` writes Participants, the candidate sections that are
nonempty, and a Transcript section that carries every cleaned turn verbatim
(optionally with `m:ss` spans). Text is not escaped or reflowed. Hosts that
want their own layout read the `Notes` value directly; everything the renderer
prints is in it.

A model-written summary is not part of this preview. When one is added it will
be an explicit cloud client, like `CloudCleaner`, whose output must cite turn
ranges that exist and which falls back to these deterministic notes otherwise.

## Diarization

Who spoke when is a separate aspect with its own contract and an optional
runtime, because it needs audio and a model. The root package carries only
the contract (`PomvoxDiarization`, no third-party dependencies):

- `DiarizationRequest`: `.samples16kMono([Float])` or `.file(URL)`, optional
  speaker bounds (`2...2` pins the count), optional deadline. At most two hours
  of audio; the default budget is half the audio length, at least one minute,
  ten minutes for a file of unknown length, never over an hour.
- `SpeakerSegmentation`: segments sorted by start with opaque labels, speaker
  count, `Provenance` (route `local` or `cloud`), timings and warnings.
  `relabeled()` renames speakers `S1`, `S2`, ... in order of first appearance;
  runtimes return that form.
- `Diarizing`: `diarize(_:)` and `close()`. Errors are thrown
  (`DiarizationError`): `busy`, `timedOut`, `noSpeech`, `unavailable`,
  `failed`. There is no text to fall back to, so there is no fallback result.
- `DiarizerPackLoader`: an installed diarizer pack is `pack.json` plus exactly
  23 pinned files under `speaker-diarization/` (four compiled Core ML
  bundles, the PLDA parameters, the upstream `LICENSE` and `NOTICE.md`), each
  checked by size and SHA-256; extra files, symlinks and a changed byte are
  refused. `scripts/prepare-diarizer-pack.py` installs one from an already
  obtained snapshot; it never downloads.

### The local runtime

`Runtime/Diarization` is a separate Swift package, like `Runtime/MLX`, so
contract users do not acquire Core ML model dependencies. It depends on
FluidAudio at exactly `0.15.5` (inside the range the Pomvox app allows) and
runs that release's **offline** pipeline: pyannote community-1 segmentation,
WeSpeaker embeddings, VBx clustering, on the Neural Engine. The artifacts are
Fluid Inference's Core ML conversions, CC-BY-4.0; see `THIRD_PARTY_NOTICES.md`
for the attribution that travels with a distribution. The repository's older
online pipeline and its bundles are not used: their license statement excludes
them.

```swift
import PomvoxDiarizationFluid // re-exports PomvoxDiarization and the transcript types

let pack = try DiarizerPackLoader.validate(directory: installedDiarizerPack)
let diarizer = try await FluidDiarizer.open(pack: pack)      // never downloads
let who = try await diarizer.diarize(DiarizationRequest(samples: samples16k, speakers: 2...4))
let transcript = Transcript.attribute(words: words, segments: who.segments)
await diarizer.close()
```

Rules the runtime keeps:

- **Local-first.** `open` revalidates the pack's file identity, then sets
  FluidAudio's `ModelHub.offlineMode` to `true`. That switch is process-global:
  from then on every FluidAudio loader in the process throws instead of
  downloading. A host that also runs Parakeet through FluidAudio must have those
  models on disk already (the Pomvox app does).
- **One request, no queue.** A second `diarize` while one runs throws `busy`.
- **Deadlines are the caller's.** The pipeline has no cancellation point, so the
  actor enforces the budget: a late result is discarded, the waiter gets
  `timedOut` (or `CancellationError`), and admission stays refused
  (`availability == .quarantined`) until the worker returns. Models stay alive
  until then; `close()` releases them when the worker is done.
- **Labels are first-appearance order**, `S1` first, and segments are sorted.
  Degenerate (zero-length or invalid) pipeline segments are dropped with a
  warning naming the count.

Validated on macOS 15 (Apple M1, 16 GiB, Xcode 26.3). FluidAudio documents a
Core ML BNNS crash on macOS 14 for this pipeline, fixed in macOS 15; the SDK's
deployment floor is unchanged, but the diarizer is not validated below macOS 15.

### Testing it

The runtime's tests skip unless `POMVOX_TEST_DIARIZER_PACK` names an installed
pack. The fixture is built at test time from macOS speech synthesis: two voices
(`Samantha`, `Daniel`) alternate six utterances with 0.8 s gaps. The test asserts
two speakers, one consistent label per voice, at least 60 % of each utterance
covered by its voice's label, and that `Transcript.attribute` recovers the six
scripted turns from the segments. Set `POMVOX_DIARIZER_EVIDENCE` to a path to
record timings and coverage as JSON.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
python3 scripts/prepare-diarizer-pack.py /path/to/speaker-diarization-coreml-snapshot .local/pyannote-community1-coreml
swift build --package-path Runtime/Diarization --scratch-path /tmp/pomvox-diarizer --build-tests
POMVOX_TEST_DIARIZER_PACK=$PWD/.local/pyannote-community1-coreml \
POMVOX_DIARIZER_EVIDENCE=/tmp/diarizer-evidence.json \
  sandbox-exec -p '(version 1)(allow default)(deny network*)' \
  xcrun xctest /tmp/pomvox-diarizer/debug/PomvoxDiarizationFluidPackageTests.xctest
```

The build runs outside the sandbox (SwiftPM needs the network to resolve and
cannot compile a manifest under `deny network*`); the test bundle runs inside it.

Measured on 2026-10-11 on an Apple M1 (MacBookPro17,1, 16 GiB, macOS 15.7.4,
Xcode 26.3, Debug build), recorded in
[`docs/evidence/diarizer-synthetic-2026-10-11.json`](evidence/diarizer-synthetic-2026-10-11.json):

| Measure | Value |
| --- | --- |
| Fixture | 36.7 s of synthetic speech, 6 utterances, 2 voices |
| Model load (`preparationMS`) | 54 ms (bundles already compiled by Core ML on an earlier run) |
| Request total | 752 ms, of which segmentation 381 ms, embedding 719 ms (overlapping stages), clustering 6 ms |
| Outcome | 2 speakers, 6 segments; every utterance ≥ 99 % covered by its voice's label |

One run, one machine, synthetic voices: a plumbing and lifecycle result, not a
quality measurement on real meetings. That needs a consented corpus and is a
stated gap.

### Host stand-in example

`swift run --package-path Runtime/Diarization speaker-notes-example meeting.wav --diarizer-pack .local/pyannote-community1-coreml`
diarizes a file, runs Parakeet through FluidAudio **in the example only** to get
word timings, aligns, and prints deterministic notes over the recognized (not
cleaned) transcript. The cleanup step is left out because the MLX runtime needs
an Xcode build to package Metal shaders; the cleaned path is covered by the root
package tests and the Xcode consumer.

## Limits and non-goals

- Offline (whole recording) diarization only; no streaming speaker breaks.
- No cloud diarizer in this change. When added it will be an explicit client
  with an endpoint and credentials, like `CloudCleaner`.
- No speaker naming or enrollment. Labels are opaque; names are the host's.
- No streaming. Turns are cleaned after the recording, not while it runs.
- No summarization, no invented text, no reordering. Every byte of output is a
  cleaned turn or a quote of one.
- English and the frozen baseline's limits apply per turn, unchanged.
