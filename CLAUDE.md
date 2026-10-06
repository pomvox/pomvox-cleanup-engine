# CLAUDE.md — pomvox/pomvox-cleanup-engine

Every session, human or agent, starts here. This file is condensed from the
owner's vault (`pomvox/pomvox_obsidian_vault`, section `70 Cleanup Engine/`);
the vault wins over this file, and this file wins over an issue's text. Read
`README.md`, `CONTRIBUTING.md`, `docs/contract.md` and `docs/testing.md` next.

## What this repo is

Pomvox Cleanup Engine is a local-first Swift SDK that turns dictated text into
cleaned text with explicit outcomes, Unicode-safe edits, provenance and timings.
The root package is `PomvoxCleanup` plus the explicit `PomvoxCleanupCloud`
client; `Runtime/MLX` is the Apple Silicon runtime, exported as the separate
`pomvox-cleanup-mlx` package by `scripts/export-mlx-release.py`. Version:
`VERSION` (0.1.0-beta.3, public beta).

**What it is not: the app.** The SDK owns no microphone, STT, clipboard, paste,
UI, history or telemetry; those stay in `pomvox/pomvox`. It is also not a
premium service, billing or a marketplace. Engine-first rule (pomvox/pomvox#173):
every change to cleanup behaviour (prompts, guards, deadlines, packs, decoding,
post-transforms, pack install) lands here or in `pomvox-cleanup-mlx`, gets a
tag, and reaches the app only as a pin bump titled `chore(cleanup): engine vX.Y.Z`.

## Build and test (from `docs/testing.md`)

macOS 14+ and full Xcode with Swift 6. The root package needs neither model
assets nor third-party Swift dependencies. `Runtime/MLX` needs Apple Silicon, the
pinned installed pack and the separate Xcode consumer; in a cloud session do not
attempt it.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
python3 scripts/check.py --sanitizers --repeat 20      # the full runner

swift test --scratch-path /tmp/pomvox-core --filter LifecycleTests   # one focused check
python3 -m unittest discover -s scripts/tests -v                     # installer tests (Python only)
```

`check.py` builds Debug with coverage and warnings as errors, builds Release,
runs the Python tests, repeats lifecycle tests and optionally both sanitizers;
it fails on the first failed command and keeps logs under `/tmp/pomvox-check-*`.

Real MLX validation is required for changes to prompts, tokenization, model
dependencies, cache ownership, decoding, artifact pins or runtime lifecycle:

```sh
POMVOX_TEST_PACK=/absolute/path/to/installed/pack \
  sandbox-exec -p '(version 1)(allow default)(deny network*)' \
  xcrun xctest /absolute/path/to/DerivedData/Build/Products/Debug/ModelTests.xctest
```

The model suite skips live inference when `POMVOX_TEST_PACK` is absent. A green
run with that skip is not parity evidence. Compare source reference, library,
greedy, cached speculative and uncached speculative output byte for byte.

## Invariants that block a PR

From `CONTRIBUTING.md` and the vault's `Review Philosophy`, in the SDK's terms:

1. **Never lose words.** A fallback preserves the exact input bytes with zero
   edits. A canceled or superseded result never reaches insertion.
2. **Never block the latency path.** Admitted work is bounded by deadlines; the
   local cleaner runs one request and queues at most two. A new stage that can
   stall the host's key-up to paste is a bug.
3. **Never break local-first.** A local request never downloads or routes to
   cloud. Cloud execution is an explicit caller choice with an endpoint and
   credentials; no automatic uploads, route changes or retries.
4. **One generation owns the caches.** At most one local generation owns mutable
   caches at a time, and resources stay alive until that generation returns.
5. **Parity is sacred until it isn't.** The SDK reproduced the app's engine on
   423 of 424 real transcripts (vault: `Cleanup Engine Integration Campaign`).
   Prompt bytes never drift; a change to prompt, tokenizer, cache, decoding or
   pins needs installed-artifact differential evidence and the consumer build.
   If a wrong answer would be silent, the test must be differential.

Numbers over adjectives: a performance claim names hardware, artifacts, build
mode, workloads and all outcomes, never successful-only latency statistics.

## Areas not to touch

| Area | Status | Why |
|---|---|---|
| The baseline prompt | frozen, ships inside the model repo as `system_v2.txt` | Never copied into this repo, so it cannot drift from the weights (vault: `Cleanup LLM`, `ADR - Fine-Tuned Cleanup Model`). |
| `packs/simplewords-v3/pack.json` | pinned snapshot, seven verified artifacts | The runtime verifies every artifact; do not swap in a newer revision (`docs/packs.md`). |
| `VERSION` | shared by SDK and runtime tags | A release tag must equal `v$(cat VERSION)`; the model pack has its own version. |
| `pomvox-cleanup-mlx` (the other repo) | generated from `Runtime/MLX` | Edit `Runtime/MLX` here and re-export; never hand-edit the export. |
| The app's `CleanupEngine.swift` (pomvox/pomvox) | frozen, pomvox/pomvox#173 | In-app cleanup bugs are filed here, not fixed there. `vendor/` in the app goes away under pomvox/pomvox#172. |

Never commit model weights, private transcripts, credentials or build products.
Do not publish, deploy, push tags or alter CI/CD without explicit authorization.

## Where the lessons are

Search the vault's `60 Lessons/60 Lessons MOC.md` by symptom. For this repo the
closest are the cleanup-speed lessons (the pass-cost curve is the design; the
guard that ate the fix), The Impossible Optimization (a doc comment that
suppressed the retry), HF Snapshot Globs and the Adapter Trap, and meta-lessons
8 (differential tests) and 16 (a guard is a belief about a model). The engine's
own history is in `70 Cleanup Engine/` and `docs/evidence/`.

## PR checklist (vault: `Reviewing a Pomvox PR.md` §5)

- CHANGELOG entry for user-visible changes; version bump if this cuts a release.
- Docs that the diff invalidates are fixed in the diff.
- Commit style: conventional commits, 72-char subject at most, GPG-signed.
- Follow-ups discovered during review get filed as issues in the PR thread, not
  silently remembered.

Process rules that go with it: one concern per PR; PRs only, never merge, never
`--delete-branch`, no stacking unless the issue says to; request review from
Abhi; at most two open PRs per repo; no fabricated numbers (a figure comes from
a command run in this session on stated hardware, or from the CHANGELOG, with
the source named, else "not measured here"); closing an issue needs Abhi's go.
