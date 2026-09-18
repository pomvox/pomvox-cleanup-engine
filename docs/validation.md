# Developer preview validation

Verified September 14–15, 2026. This is local implementation evidence, not a published release or a premium service launch.

The subsequent [hardening report](hardening.md) records the expanded tests, sanitizer runs and defects found after this original milestone run.

## Environment and pin

Apple M1, 16 GiB RAM, macOS 15.7.4, Xcode 26.3 (17C529), Swift 6.2.4, Debug builds. Source baseline: `pomvox/pomvox` commit `8d693ad15964e7d5dd731ab7b7e80186d65166ad`; remote main rechecked September 15 and still matched. The source checkout remained clean.

SimpleWords v3 snapshot `b1f7ac8282ce060e4ad1374cb9a34750e31723c1`, seven artifact hashes in the [manifest](../packs/simplewords-v3/pack.json). Dependencies are pinned in [Package.resolved](../Runtime/MLX/Package.resolved).

## Original milestone checks

| Check | Evidence |
| --- | --- |
| Root contract/pack/cloud/adapter suite | 74 tests passed, no skips or failures |
| MLX/source differential and decoder policy suite | 15 tests passed, no skips or failures |
| Source versus SDK outputs | 16 fixtures matched exact UTF-8 in library, greedy, cached speculative and uncached speculative modes |
| Speculation exercised | 122 accepted drafted tokens in each speculative mode |
| Cache ownership | Original result unchanged after a vocabulary request; duplicate resident MLX allocation rejected |
| Consumer packaging | Separate Xcode project compiled, linked, and loaded its generated Metal resource bundle |
| Local execution boundary | Real-model suite and consumer ran successfully under `sandbox-exec` with all networking denied |
| Cloud transport | Actual ephemeral loopback HTTP server checked explicit payload/auth/idempotency headers, valid edits, malformed/wrong-pack/oversized responses, refused redirects, deadlines and cancellation |
| Host integration example | Superseded/canceled results never inserted; raw fallback passed through formatting → dictionary → signature exactly once |
| Private documentation | Existing vault updated; changed-note wikilinks resolved; no vault commit/push |

The source reference is test-only: directory-only preparation replaces downloads and unrelated app lifecycle is omitted. It shares the extracted decoder helper and guards; the library/greedy/speculative differential separately checks the decoding algorithm. These tests establish extraction parity on the named fixtures, not end-to-end Pomvox app parity or universal semantic correctness.

## Consumer smoke benchmark

One preparation, followed by three public synthetic fixtures repeated five times sequentially. Full SDK result latency includes queueing, tokenization, prefill, inference, validation and edit construction. No concurrent model/test run, and networking denied.

| Measurement | Observed |
| --- | --- |
| Outcomes | 15 cleaned; 0 unchanged, rejected, timed out or otherwise fallen back |
| Preparation (hash validation + load + warmup) | 4,822 ms |
| Full warm request median | 445 ms |
| Full warm request nearest-rank p95 | 1,190 ms |
| Short greeting median, 5 runs | 303 ms |
| Self-correction median, 5 runs | 445 ms |
| Numbered list median, 5 runs | 1,168 ms |

[Per-request benchmark data](evidence/consumer-benchmark-2026-09-15.json) and [model differential summary](evidence/model-differential-2026-09-15.txt) are included. The benchmark fixtures are defined in the consumer source. There are no human quality labels; a guard-accepted `cleaned` result is not proof of a correct edit. Fifteen synthetic requests do not establish a production p95, broad quality, memory behavior, or a latency improvement over the app. The differential's runtime-only medians are diagnostic and must not be substituted for full SDK/client latency.

Sub-100ms cleanup is **not demonstrated**. No memory/energy benchmark, STT contention run, cold launch repetition, long-idle test or real dictation-to-paste run was performed.

## Reproduce

Run from the repository root with an already installed matching snapshot. The temporary directory avoids iCloud evicting disposable Desktop build caches:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
build_dir=$(mktemp -d /tmp/pomvox-cleanup-validation.XXXXXX)
swift test --scratch-path "$build_dir/core"
python3 scripts/prepare-local-pack.py /path/to/pinned/snapshot "$build_dir/pack"
xcodegen generate --spec Examples/Consumer/project.yml
xcodebuild -project Examples/Consumer/CleanupConsumer.xcodeproj \
  -scheme Consumer -configuration Debug -derivedDataPath "$build_dir/DerivedData" \
  -destination 'platform=macOS,arch=arm64' build-for-testing
POMVOX_TEST_PACK="$build_dir/pack" sandbox-exec \
  -p '(version 1)(allow default)(deny network*)' \
  xcrun xctest "$build_dir/DerivedData/Build/Products/Debug/ModelTests.xctest"
sandbox-exec -p '(version 1)(allow default)(deny network*)' \
  "$build_dir/DerivedData/Build/Products/Debug/Consumer" "$build_dir/pack" --benchmark
```

The initial command-line-tools-only test attempt failed because XCTest was unavailable; selecting full Xcode fixed it. Initial consumer compilation also required renaming its `main.swift` file to use Swift's `@main` entry point correctly. iCloud eviction caused stalled incremental caches and source hydration timestamp errors on resume; fresh temporary build directories and reading source before compilation resolved them. These were tooling failures, not skipped acceptance checks.

## Remaining gaps and next milestone

1. Integrate the adapter in a development Pomvox build under a separately authorized app task. Test real insertion, cancellation, dictionary changes, STT contention, memory pressure and close/reopen behavior.
2. Establish a reviewed quality set and repeatable latency/memory measurements with cold/warm and longer inputs. Current guards retain upstream limitations, including ASCII-oriented word overlap checks.
3. Resolve reproducible baseline acquisition and archive applicable artifact licenses/notices before distribution. The current upstream page is gated; no installer/download flow or signed pack distribution is implemented.
4. Production cloud auth/tenant isolation, service-side queueing, quotas, retry accounting, retention/no-training policy and deployment remain unimplemented. No billing, marketplace or specialist packs were built.
5. Native C/Python/Node bindings, Linux/on-device backends, memory-pressure automation, model pooling and multiple simultaneous local packs remain future work. If Linux is the first committed deployment, its runtime feasibility precedes optional bindings.

Only this new repository contains implementation changes. The existing app was read-only; there were no CI/CD edits, deployments, publication, pushes or commits. The target directory initially had no Git metadata and still has none.
