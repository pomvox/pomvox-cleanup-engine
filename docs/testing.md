# Testing and release validation

Tests protect a concrete contract: preserve input bytes on fallback, never deliver a canceled result, bound admitted work, verify assets before allocation, and never choose a remote route implicitly. Coverage is a gap-finding tool; hitting a line does not prove its behavior is correct.

## Run the SDK checks

Use macOS 14+ and full Xcode with Swift 6. The root package needs neither model assets nor third-party Swift dependencies. Python 3 runs the installer tests and loopback HTTP fixture.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
python3 scripts/check.py --sanitizers --repeat 20
```

The runner builds Debug with coverage and warnings treated as errors, builds Release, runs Python tests, repeats lifecycle tests, and optionally runs Thread Sanitizer and Address Sanitizer in separate builds. It fails on the first failed command, bounds each command to ten minutes, and retains logs plus `checks.json` in a fresh `/tmp/pomvox-check-*` directory. It terminates fixture children on timeout. Use `--build-dir /tmp/my-pomvox-check` to reuse disposable caches. It does not edit CI or run model downloads.

For one focused check:

```sh
swift test --scratch-path /tmp/pomvox-core --filter LifecycleTests
python3 -m unittest discover -s scripts/tests -v
```

The cloud tests bind only `127.0.0.1` on an ephemeral port and use a synthetic token. Network denial for the **entire** root suite prevents its intentional loopback tests; apply it to local runtime checks instead.

## Coverage by risk

| Risk | Tests and evidence | Acceptance condition |
| --- | --- | --- |
| Corrupted Unicode or incorrect offsets | 5,000 deterministic seeded pairs; every byte boundary in a mixed-script fixture; UTF-16 mapping; multiple edits; extreme integer offsets | Exact UTF-8 reconstruction, invalid ranges rejected |
| Misleading outcomes | Guard fixtures; fallback reasons; output/status consistency; JSON round trips | Every fallback equals original bytes with zero edits |
| Concurrency and resource lifetime | 640-call bursts per lifecycle run; 40 cancellation/close rounds; uncooperative worker; busy queue and queued deadline | At most one generation, exactly one resource close, no late delivery |
| Invalid setup | Manifest/metadata mutation matrices; symlink/FIFO/size/checksum checks; factory errors and cancellation | No model factory invocation for invalid packs; canceled allocation cleaned up |
| Corrupted installation | Copy checksums; source symlinks; concurrent installers; disk-failure injection; partial cleanup | Source unchanged; no overwrite; manifest published only after verified artifacts |
| Host insertion race | Superseded completion, host cancellation, invalid timeout, transform ordering | Canceled/superseded text never reaches insertion |
| Untrusted remote response | Real HTTP: wrong request/pack/schema/route, malformed/truncated/oversized bodies, invalid Unicode edits/status/metrics, redirect refusal, slow headers/body/credentials | Bounded request, exact raw fallback, explicit route, no redirect or retry |
| Decoder/cache changes | Pinned real model versus source reference and four SDK modes; vocabulary isolation; closed/expired/canceled runtime | Exact fixture parity; speculative drafts actually accepted; no reused mutable cache |

Boundary matrices are table-driven: the test-method count is smaller than the number of cases. The seeded tests use a fixed generator so failures reproduce. Concurrency checks assert lifetime invariants rather than a machine-specific throughput. Deadline tests include scheduling tolerance and are not latency benchmarks.

## Real MLX validation

Required for changes to prompts, tokenization, model dependencies, cache ownership, decoding, artifact pins or runtime lifecycle. Optional locally for contract-only contributors; release validation must run it with **zero skipped model tests**.

First prepare the pinned assets with the [README](../README.md) instructions. Build the separate Xcode consumer to package Metal shaders, then run:

```sh
POMVOX_TEST_PACK=/absolute/path/to/installed/pack \
  sandbox-exec -p '(version 1)(allow default)(deny network*)' \
  xcrun xctest /absolute/path/to/DerivedData/Build/Products/Debug/ModelTests.xctest
```

The model suite explicitly skips live inference when `POMVOX_TEST_PACK` is absent. A green run with that skip is not parity evidence. Compare the source reference to library, greedy, cached speculative and uncached speculative output byte for byte. The current corpus includes 24 public synthetic inputs: self-corrections, repetition, negation, amounts, identifiers and Unicode. Parity proves extraction behavior on those inputs; it does not prove all outputs are semantically correct.

Run consumer benchmarks **after** tests and other inference have finished. Report hardware, OS, build configuration, exact artifacts, preparation, every outcome, sample counts and full-path timing. Never replace failures with successful-only latency statistics.

## Release gates

Before a stable production release:

- Pass Debug, Release, both sanitizers, installer and real-model suites on each supported platform/toolchain; retain evidence for the exact source version.
- Validate a separate consumer and actual Pomvox development integration: cancellation, insertion, concurrent STT, memory pressure, sleep/wake, close/reopen and long-session soak.
- Establish a reviewed, consented quality corpus and thresholds for meaning changes, names, numbers, negation, prompt injection and unsupported-language behavior. Keep private transcripts outside this public repository.
- Measure cold/warm latency, memory and energy under representative load. Define supported workload limits and service objectives from those measurements.
- Make pinned baseline acquisition reproducible and archive the applicable model license and notices.
- Review API/wire compatibility, dependency notices and the [security boundary](../SECURITY.md). Record known limitations in release notes.

A production cloud service needs its own authentication, authorization, tenancy, retention, quota and abuse tests. This repository currently supplies a transport client and test fixture only. Passing these client tests cannot certify a service that does not exist here.
