# Contributing to Pomvox Cleanup Engine

Start with the [README](README.md), [behavior contract](docs/contract.md) and [testing guide](docs/testing.md). Keep each change focused on one problem. Discuss public API changes and new runtime/artifact support before combining them with implementation changes.

## Development setup

Use macOS 14+, full Xcode with Swift 6, and Python 3. The root tests do not need model weights or external package dependencies. MLX development requires Apple Silicon, the pinned installed pack and the separate Xcode consumer described in the README.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
python3 scripts/check.py --sanitizers --repeat 20
```

The test runner keeps build products outside the source tree by default. It does not configure CI. Read [testing and release validation](docs/testing.md) for targeted commands, live-model tests and what remains outside automated coverage.

## Code and tests

- Match nearby style: four-space Swift indentation, explicit public APIs and `Sendable` values at concurrency boundaries.
- Keep MLX types inside the optional runtime. Keep audio, STT, UI, clipboard and insertion in the host.
- Add a regression test that fails before a bug fix. Exercise behavior, error paths and boundaries; avoid tests that merely repeat an implementation.
- Use synthetic fixtures. Seed generated cases and make failures reproducible. Bound asynchronous waits and clean up processes/files.
- Changes to prompt, tokenizer, cache, decoding or dependency pins require installed-artifact differential evidence and the separate consumer build. Do not enable an optimized path on untested weights.
- Document observable API or protocol changes. Treat fallback/cancellation and UTF-8 offsets as compatibility contracts.

## Pull requests

Explain the concrete problem, resulting behavior, relevant tests and remaining limitations. Link the issue when one exists. Include before/after screenshots for UI changes. Keep performance claims tied to exact hardware, artifacts, build mode, workloads and **all** outcomes.

Use conventional commit subjects under 72 characters and sign commits with your configured GPG key. Preserve upstream notices. Do not commit model weights, private transcripts, credentials, build products or private planning material. Do not publish, deploy, push or alter CI/CD as part of routine implementation work without explicit authorization.

## Invariants reviewers must preserve

A local request never downloads or routes to cloud. Cloud execution is an explicit caller choice. Cancellation never becomes an insertion. A fallback preserves exact input bytes with no edits. At most one local generation owns mutable caches at a time, and resources remain alive until that generation returns.

See [SECURITY.md](SECURITY.md) for private vulnerability reporting and the pack/runtime trust model.
