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

These license identifiers were checked against the installed pinned dependency
sources for this release. Inspect each resolved package's LICENSE/NOTICE files,
including transitive dependencies, when distributing an application binary. The SDK
source release does not bundle those third-party sources or model weights.

SimpleWords weights are a separate gated artifact, labeled Apache-2.0 by the
upstream model metadata. Model acquisition conditions and model/base-model notices
must be handled separately; the SDK's MIT license does not grant access to weights.
See docs/packs.md in the core source repository for the pinned artifact identity and
outstanding model-distribution documentation requirements.
