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
| Diarization | optional runtime, separate change | A `Diarizing` implementation produces `SpeakerSegment`s from host-captured audio |

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

## Limits and non-goals

- No diarization in the root package: it needs audio and a model, and lives in
  an optional runtime with its own verified pack, as MLX inference does.
- No speaker naming or enrollment. Labels are opaque; names are the host's.
- No streaming. Turns are cleaned after the recording, not while it runs.
- No summarization, no invented text, no reordering. Every byte of output is a
  cleaned turn or a quote of one.
- English and the frozen baseline's limits apply per turn, unchanged.
