# Third-party dependencies

The core SDK has no external Swift package dependencies. The optional MLX runtime
resolves the following direct dependencies; their licenses are independent of this
repository's MIT license. SwiftPM obtains their source and notices from upstream.

| Dependency | Exact version | License |
| --- | --- | --- |
| [mlx-swift](https://github.com/ml-explore/mlx-swift) | 0.31.4 | MIT |
| [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm) | 3.31.4 | MIT |
| [swift-tokenizers-mlx](https://github.com/DePasqualeOrg/swift-tokenizers-mlx) | 0.3.0 | Apache-2.0 |
| [swift-tokenizers](https://github.com/DePasqualeOrg/swift-tokenizers) | 0.5.0 | Apache-2.0 |

The optional diarization runtime (`Runtime/Diarization`, product
`PomvoxDiarizationFluid`) resolves one further direct dependency:

| Dependency | Exact version | License |
| --- | --- | --- |
| [FluidAudio](https://github.com/FluidInference/FluidAudio) | 0.15.5 | Apache-2.0 |

The diarizer pack it loads (`packs/pyannote-community1-coreml/pack.json`) pins
Core ML conversions published by Fluid Inference under **CC-BY-4.0** at
`FluidInference/speaker-diarization-coreml`, revision
`df2625ac79a7ac6b65ad868fee6d80f320da4232`. Attribution, as that repository's
`NOTICE.md` asks: the pipeline is pyannote's `speaker-diarization-community-1`
(CC-BY-4.0); the embedding model is WeSpeaker ResNet34 as shipped in that
pipeline; the PLDA parameters originate from Brno University of Technology,
BUT Speech@FIT (CC-BY-4.0); Fluid Inference converted the components to Core ML
with modifications (fixed and enumerated input shapes, mixed-precision storage,
a separated FBank front end) and compiled them for Apple platforms. The installed
pack carries the upstream `LICENSE` and `NOTICE.md` as pinned artifacts. Only the
community-1 artifact set is used; the repository's older online-pipeline bundles
are excluded from that license statement and this SDK never loads them.

These license identifiers were checked against the installed pinned dependency
sources for this release. Inspect each resolved package's LICENSE/NOTICE files,
including transitive dependencies, when distributing an application binary. The SDK
source release does not bundle those third-party sources or model weights.

SimpleWords weights are a separate gated artifact, labeled Apache-2.0 by the
upstream model metadata. Model acquisition conditions and model/base-model notices
must be handled separately; the SDK's MIT license does not grant access to weights.
See docs/packs.md in the core source repository for the pinned artifact identity and
outstanding model-distribution documentation requirements.
