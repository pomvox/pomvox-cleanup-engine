# Pomvox Diarization (FluidAudio)

Local speaker diarization runtime for [Pomvox Cleanup Engine](https://github.com/pomvox/pomvox-cleanup-engine), version **@SDK_VERSION@**. This is a **beta developer SDK**, not a production-readiness certification. It runs FluidAudio 0.15.5's offline pyannote community-1 pipeline (segmentation, WeSpeaker embeddings, VBx clustering) on Apple Silicon, from a verified pack, and never downloads. macOS 14+ with Swift 6 is required; macOS 15 is the validated floor for this pipeline. iOS 17 is a declared build target only; on-device behaviour is not validated.

## Install

Add this public repository in Xcode's **Add Package Dependencies**, selecting exact version `@SDK_VERSION@`, and add the `PomvoxDiarizationFluid` product to your app target. Alternatively:

```swift
.package(url: "https://github.com/pomvox/pomvox-diarization-fluid.git", exact: "@SDK_VERSION@")
// In your application target's dependencies:
.product(name: "PomvoxDiarizationFluid", package: "pomvox-diarization-fluid")
```

The core SDK (`pomvox-cleanup-engine`) is pulled automatically at the matching exact version, and FluidAudio is pinned at exactly 0.15.5. The SDK's code is MIT-licensed; FluidAudio is Apache-2.0.

## Obtain and install a pack

The runtime loads only an installed pack that matches [`packs/pyannote-community1-coreml/pack.json`](packs/pyannote-community1-coreml/pack.json): 23 pinned files from Fluid Inference's `FluidInference/speaker-diarization-coreml` Core ML conversions, published under **CC-BY-4.0**. Obtain that snapshot yourself at the pinned revision and install it with the source repository's `scripts/prepare-diarizer-pack.py` (tag `v@SDK_VERSION@`); it never downloads. Keep the attribution in [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) with any distribution.

```swift
import PomvoxDiarizationFluid // re-exports PomvoxDiarization and the transcript types

let pack = try DiarizerPackLoader.validate(directory: installedDiarizerPack)
let diarizer = try await FluidDiarizer.open(pack: pack)      // never downloads
let who = try await diarizer.diarize(DiarizationRequest(samples: samples16k, speakers: 2...4))
let transcript = Transcript.attribute(words: words, segments: who.segments)
try await diarizer.closeAndWait() // returns once the models are released
```

`open` sets FluidAudio's process-global offline mode, so every FluidAudio loader in the process refuses to download afterwards; have other FluidAudio models (for example Parakeet) on disk first. One request runs at a time and a second throws `busy`. Deadlines are enforced caller-side. **A running pipeline cannot be interrupted**: cancellation returns to the caller at once, and `closeAndWait()` returns when the models are released after the pipeline ends.

## Limits

Diarization quality has been measured only on synthetic speech: two voices are separated reliably, and similar voices can merge. There is no streaming, no speaker naming across recordings and no overlap handling. Read the [speaker transcripts and notes guide](https://github.com/pomvox/pomvox-cleanup-engine/blob/v@SDK_VERSION@/docs/speaker-notes.md) for the full contract, evidence and limits.

This repository is a generated release distribution. Make contributions in [the source repository](https://github.com/pomvox/pomvox-cleanup-engine/tree/v@SDK_VERSION@/Runtime/Diarization); `SOURCE.json` records the source tag and the SHA-256 of every exported file.
