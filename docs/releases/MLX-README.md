# Pomvox Cleanup MLX

Apple Silicon runtime for [Pomvox Cleanup Engine](https://github.com/pomvox/pomvox-cleanup-engine), version **@SDK_VERSION@**. This is a **beta developer SDK**, not a production-readiness certification. macOS 14+, Apple Silicon and full Xcode with Swift 6 are required.

## Install

Add this public repository in Xcode's **Add Package Dependencies**, selecting exact version `@SDK_VERSION@`, and add the `PomvoxCleanupMLX` product to your app target. No local checkout or submodule is required. Alternatively:

```swift
.package(url: "https://github.com/pomvox/pomvox-cleanup-mlx.git", exact: "@SDK_VERSION@")
// In your application target's dependencies:
.product(name: "PomvoxCleanupMLX", package: "pomvox-cleanup-mlx")
```

Build through Xcode to package MLX Metal resources. Plain `swift build` does not package the shader library needed for inference. The core SDK is pulled automatically at the matching exact version; MLX dependencies are also pinned. The SDK's code is MIT-licensed. Model weights are separate and are not included or downloaded by the SDK.

## Obtain and install a model

The supported baseline snapshot is `b1f7ac8282ce060e4ad1374cb9a34750e31723c1` of [SimpleWords v3](https://huggingface.co/ReFyneLabs/simplewords-dictation-cleanup-v3). Its host currently requires accepting access conditions; anonymous inference setup is **not** promised. Obtain access and the exact snapshot yourself. Do not replace it with the latest revision: the runtime verifies all seven pinned artifacts.

Bundle the trusted [pack manifest](https://github.com/pomvox/pomvox-cleanup-engine/blob/v@SDK_VERSION@/packs/simplewords-v3/pack.json) with your app, then run `PackInstaller.install(snapshot:manifestData:destination:)` off the main actor. It follows snapshot symlinks, verifies staged files, and atomically publishes a new directory. APFS cloning avoids a second physical weight copy where supported. Keep installations immutable in Application Support.

```swift
import Foundation
import PomvoxCleanupMLX

let cleaner = try await Cleaner.open(
    pack: .directory(installedPackURL),
    runtime: .mlx(vocabulary: ["Pomvox"]), policy: .local)
do {
    let result = try await cleaner.clean(CleanupRequest(
        "um send the pomvox report tomorrow", vocabulary: ["Pomvox"], deadline: .seconds(5)))
    print(result.text)
    print(result.status)
    try await cleaner.closeAndWait()
} catch {
    await cleaner.close()
    throw error
}
```

Keep one cleaner open across dictations. `.mlx(vocabulary:)` prewarms the cache; continue supplying the vocabulary in every request. Cancellation throws: **never insert a canceled result**. Fallback returns exact input bytes and no edits. `closeAndWait()` waits for actual model release; a hung worker cannot be forcibly interrupted.

## Integration and limitations

Read the [integration prompt](https://github.com/pomvox/pomvox-cleanup-engine/blob/v@SDK_VERSION@/docs/pomvox-integration-prompt.md), [contract](https://github.com/pomvox/pomvox-cleanup-engine/blob/v@SDK_VERSION@/docs/contract.md), and [release notes](https://github.com/pomvox/pomvox-cleanup-engine/releases/tag/v@SDK_VERSION@). English, bounded vocabulary and the frozen prompt are supported. Style controls, auxiliary generation, unlimited output length, Intel inference and automatic cloud fallback are not supported.

This repository is a generated release distribution. Make contributions in [the source repository](https://github.com/pomvox/pomvox-cleanup-engine/tree/v@SDK_VERSION@/Runtime/MLX); `SOURCE.json` records the source tag and exported file hashes. The source repository's security policy and contribution guide apply. CI validates the public dependency graph and Xcode consumer build without downloading gated weights; real-model validation evidence and remaining production release gates are in the source repository.
