# Pomvox Cleanup Engine

A local-first Swift SDK for turning dictated text into cleaned text, with explicit outcomes, Unicode-safe edits, provenance and timings. Prepare a verified model pack once and reuse the cleaner across requests.

**Version: 0.1.0-beta.2 — public beta.** The implementation has contract, concurrency, adversarial transport and real-model regression tests. Stable production support still requires the [release gates](docs/testing.md#release-gates), including real Pomvox integration and a reviewed quality corpus. Sub-100ms cleanup is a benchmark target, not a demonstrated capability.

## What it provides

- **Local cleanup:** pinned Swift/MLX inference, a frozen baseline prompt, optional vocabulary and reusable prefix caches.
- **Predictable failures:** exact-input fallback, bounded admission and deadlines. Cancellation throws and suppresses late delivery.
- **Inspectable results:** final text, UTF-8 edits, outcome, artifact/runtime identity and stage timings.
- **Explicit cloud access:** a separate transport client requiring an endpoint and credentials. No automatic uploads, downloads, route changes or retries.
- **A small host seam:** the SDK owns no microphone, STT, clipboard, paste, UI, history or telemetry.

The engine is [MIT licensed](LICENSE). Baseline weights are separate artifacts with their own license; see [pack licensing and availability](docs/packs.md#baseline). Premium cloud packs keep proprietary weights server-side. Licensed private enterprise deployment is a separate product direction. This repository does not contain a premium service, billing or a marketplace.

## Requirements

| Component | Requirements | Validated environment |
| --- | --- | --- |
| Core, local facade, cloud client | macOS 14+, Swift 6 | Swift 6.2.4, macOS 15.7.4 |
| MLX runtime | Apple Silicon, full Xcode, pinned installed model | Apple M1, 16 GiB, Xcode 26.3 |
| Tests and asset preparation | Python 3; XcodeGen for the separate consumer | Debug/Release and sanitizer runs; see [evidence](docs/validation.md) |

macOS 14 is the declared deployment minimum; it has not yet been exercised in the release validation matrix. Linux, Intel inference, C/Python/Node bindings and multiple resident local models are not supported in this milestone.

## Quick start: local cleanup

### 1. Add the package

The root package has no MLX dependency. Local inference is distributed as the standalone [PomvoxCleanupMLX package](https://github.com/pomvox/pomvox-cleanup-mlx), generated from `Runtime/MLX` in this source repository. Add the public runtime repository in Xcode at exact version `0.1.0-beta.2`, or declare:

```swift
// Package.swift dependency
.package(url: "https://github.com/pomvox/pomvox-cleanup-mlx.git", exact: "0.1.0-beta.2")

// Application target dependency
.product(name: "PomvoxCleanupMLX", package: "pomvox-cleanup-mlx")
```

Use an Xcode build to package the dependency's Metal shader resources. A plain `swift build` is insufficient to package the required shader library. The [separate consumer](Examples/Consumer) demonstrates a working application build. The runtime pulls the matching core SDK version automatically; no submodule is required. Core/cloud-only consumers can instead add `https://github.com/pomvox/pomvox-cleanup-engine.git` at exact version `0.1.0-beta.2` and select `PomvoxCleanup` or `PomvoxCleanupCloud`.

### 2. Prepare assets already on disk

The baseline requires the exact snapshot recorded in [pack.json](packs/simplewords-v3/pack.json). Given that snapshot:

```sh
python3 scripts/prepare-local-pack.py /path/to/pinned/snapshot .local/simplewords-v3
```

Apps can use the native `PackInstaller.install(snapshot:manifestData:destination:)` with the trusted bundled manifest instead of invoking Python. Install outside cloud-synced folders, keep the pack immutable, and pass the returned handle to `.validated(installedPack)` when opening. Model access is separate from SDK installation: the pinned upstream model currently requires accepting access conditions.

The tool copies and verifies the seven pinned artifacts, refuses existing destinations and cleans up failed copies. It never downloads or modifies the source. The upstream model currently has an access gate; reproducible public acquisition and an archived license/notice record remain release requirements. See [installed packs](docs/packs.md).

### 3. Open once, clean repeatedly, close when done

```swift
import Foundation
import PomvoxCleanupMLX // Exports the runtime-independent PomvoxCleanup API.

let cleaner = try await Cleaner.open(
    pack: .directory(URL(fileURLWithPath: "/absolute/path/to/installed/pack")),
    runtime: .mlx,
    policy: .local
)

let result = try await cleaner.clean(CleanupRequest(
    "um please send the pomvox report tomorrow",
    vocabulary: ["Pomvox"],
    deadline: .seconds(2)
))
print(result.text)
print(result.status)
await cleaner.close()
```

`open` verifies hashes, loads the model, prepares the prefix and warms Metal kernels. Missing or incompatible assets throw before a usable cleaner is returned. Keep the pack immutable while open. The host should close its cleaner on **both success and error paths** when retiring it; opening per request wastes preparation work.

The baseline supports English and bounded vocabulary. It rejects nonempty context or settings, including style. Unicode-safe edits do not imply multilingual model quality. Output guards are heuristics and cannot guarantee meaning preservation.

## Outcomes and cancellation

| Outcome | Meaning | Host action |
| --- | --- | --- |
| `.cleaned` | Accepted output differs from input | Inspect/apply the result |
| `.unchanged` | Accepted output equals input, or input was empty | Preserve the result |
| `.fallback(reason)` | Cleanup did not produce an accepted result | Result contains the exact input bytes and zero edits |
| `CancellationError` | The caller canceled or its session was superseded | Do not insert text |
| Other thrown error | Invalid request, unsupported configuration or setup failure | Correct configuration or present an error |

Fallback reasons include timeout, rejection, unavailability, queue saturation and token limits. The local cleaner runs one request and queues at most two. A canceled/timed-out worker keeps its resources until it returns; replacement work is refused while it remains unresponsive. `close()` stops admission immediately and may return before that worker releases resources. A GPU kernel cannot be forcibly interrupted by this SDK.

Explicit deadlines cover admitted queueing and request work. The default is `min(60, max(5, 2 + 0.012 × characterCount))` seconds. Preparation is measured separately. See [lifecycle and request limits](docs/contract.md).

### Applying edits

```swift
let reconstructed = try TextEdit.applying(result.edits, to: originalTranscript)
// Reconstructed bytes equal result.text. Offsets refer to the original transcript.
for edit in result.edits {
    let swiftRange = try edit.range(in: originalTranscript)
    let textViewRange = try edit.utf16Range(in: originalTranscript)
    // Use the appropriate range for your host editor.
}
```

Edits use half-open **UTF-8 byte offsets**, not character offsets. Invalid or overlapping ranges throw. The local engine emits one minimal contiguous replacement; it may include an unchanged interior span and does not describe editorial intent. Keep the original transcript for mapping these ranges.

## Explicit cloud client

Import `PomvoxCleanupCloud` from the root package. Connect it only after the host has deliberately chosen remote processing and supplied an endpoint, pack/version and `CredentialProvider`. Calling `clean` transmits the request to that endpoint.

See [cloud configuration and protocol](docs/cloud.md) for a complete example, payloads, validation rules and failure semantics. HTTPS is required except for loopback development. The included Python server is a contract test fixture, not a deployable service.

## Build the separate consumer

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodegen generate --spec Examples/Consumer/project.yml
xcodebuild -project Examples/Consumer/CleanupConsumer.xcodeproj \
  -scheme Consumer -configuration Debug -derivedDataPath /tmp/pomvox-consumer \
  -destination 'platform=macOS,arch=arm64' build-for-testing
/tmp/pomvox-consumer/Build/Products/Debug/Consumer \
  "$PWD/.local/simplewords-v3" 'um hello there'
```

The generated Xcode project and local artifacts are ignored. `project.yml` is an example build definition. Build products in `/tmp` avoid cloud-synced Desktop cache eviction.

## Test and contribute

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
python3 scripts/check.py --sanitizers --repeat 20
```

This runs Debug and Release tests, installer tests, repeated lifecycle checks and both sanitizers. It retains logs and exits unsuccessfully on any failed check. Live-model tests require an installed pack and the separate consumer; follow the [testing guide](docs/testing.md). A skipped model test does not count as real-model validation.

Read [CONTRIBUTING.md](CONTRIBUTING.md) before contributing and [SECURITY.md](SECURITY.md) for trust boundaries and private vulnerability reporting.

## Documentation

| Guide | Contents |
| --- | --- |
| [Contract](docs/contract.md) | Request limits, scheduling, deadlines, edits, provenance and privacy |
| [Packs](docs/packs.md) | Layout, hashes, compatibility, licensing and installation |
| [Cloud](docs/cloud.md) | Explicit client setup and versioned wire protocol |
| [Testing](docs/testing.md) | Test strategy, reproducible commands and production release gates |
| [Validation](docs/validation.md) | Original test/benchmark evidence and its limitations |
| [Hardening](docs/hardening.md) | Expanded coverage, sanitizer results and regression repairs |
| [Source baseline](docs/baseline.md) | Extraction provenance and dependency identities |

See the [gap review](docs/integration-gap-review.md) and [ready-to-use app integration prompt](docs/pomvox-integration-prompt.md) for the updated integration APIs and remaining limitations.

## Pomvox integration and next milestone

The [adapter example](Examples/PomvoxAdapter/PomvoxCleanupAdapter.swift) preserves host ordering: cleanup/evaluation → spoken formatting → dictionary → signature → insertion. It checks session validity before synchronous insertion and applies each host transform once. The existing Pomvox app remains unchanged.

The next milestone is a development integration exercising real dictation, cancellation, STT contention, sleep/wake and memory pressure, accompanied by a reviewed quality corpus and repeatable full-path latency measurements. These are required before declaring the SDK production-ready.

## Releases and CI

See [release notes](docs/releases/0.1.0-beta.2.md), [changelog](CHANGELOG.md), and
[release procedure](docs/releases/README.md). SDK and standalone runtime tags share
the version in `VERSION`; the model pack has its own independent version.
GitHub CI tests the dependency-free core in Debug/Release and both sanitizers,
repeats lifecycle tests, checks installers and deterministic runtime exports, and
builds the Xcode MLX consumer. Gated real-model tests remain a separately recorded
local release gate, not an implied result of a green public CI build.
