# Installed pack format — schema 1

A pack is a flat, immutable directory containing `pack.json` and seven artifact files. See [the baseline manifest](../packs/simplewords-v3/pack.json) for a complete machine-readable instance.

| Area | Fields |
| --- | --- |
| Identity | `schemaVersion`, `id`, semantic `version`, `publisher` |
| License | `license`, `licenseURL` |
| Model | `modelID`, exact 40-character `modelRevision`, `quantization` |
| Behavior | `prompt`, `capabilities`, `rules`, `languages` |
| Compatibility | exact `runtime` identifier |
| Artifacts | `path`, exact `bytes`, SHA-256 for each file |
| Evidence | `evidence`, `limitations` |

The Swift `PackManifest` Codable type and `PackLoader` are the schema implementation. Unknown top-level or artifact fields, schema/runtime mismatches, unsupported rules/capabilities, duplicate or unexpected paths, extra files/directories, symlinks, oversized files, and checksum mismatches fail validation. The weight index may reference only the verified `model.safetensors`. Custom tokenizer code is unsupported. No executable pack plugins or model fallback exist.

The manifest digest is SHA-256 over the exact manifest bytes. It transitively identifies the weights, tokenizer, chat template, model config and frozen prompt. Hash verification proves consistency, not publisher authenticity. Only caller-trusted developer installations are supported; signed installation and distribution are a later milestone.

## Baseline

- Pack: `simplewords-v3`, `0.1.0-preview`.
- Source identifier: `abhiram3040/simplewords-dictation-cleanup-v3`.
- Installed snapshot: `b1f7ac8282ce060e4ad1374cb9a34750e31723c1`.
- Weights SHA-256: `dbe5a5cdc26d383eaf3f7a009d41a746ec2a99ed262095c1ab9146870090240c`.
- Model: fused Qwen3.5 2B, affine 8-bit, group size 64.
- Prompt: `system_v2.txt`, loaded from that snapshot; one user turn, no system role or examples, thinking disabled, greedy sampling.
- Limits: English, frozen prompt, optional vocabulary. No style settings, adapter stacking, private packs, or claims of specialist validation.

`SupportedBaseline.swift` pins the seven artifact hashes admitted by the optimized MLX runtime. A third-party artifact set requires a new validated runtime compatibility entry; changing a manifest alone does not enable speculative decoding on untested weights.

The [upstream model page](https://huggingface.co/ReFyneLabs/simplewords-dictation-cleanup-v3) labels the model Apache-2.0. During this implementation the old URL redirected there and displayed an access gate. The manifest pins the already installed August snapshot; it does not claim current remote main has identical weights or that anonymous acquisition works. On 2026-09-24 the public model metadata API resolved the pinned revision under `ReFyneLabs/simplewords-dictation-cleanup-v3` and still reported `gated: auto` and Apache-2.0 metadata. Obtain access from that upstream and request this exact revision; do not substitute current main. Anonymous acquisition and an archived license/notice record remain stable-release gates. No access conditions were accepted and no model files were downloaded during implementation.

To prepare an installation, `scripts/prepare-local-pack.py` reads and hashes already obtained files, while copying only the seven named artifacts into staging before publishing a new destination. It follows source-cache symlinks while copying, so the resulting installation contains regular files. It refuses a mismatched snapshot or existing destination. Checksums cover the bytes actually copied. It reserves the destination with an exclusive directory creation and publishes `pack.json` after all artifacts; another installer cannot overwrite it. Failures remove only this invocation’s staging/owned destination. An abrupt process or machine failure can leave an incomplete directory, which `Cleaner.open` rejects; inspect and remove it explicitly before retrying.

Metadata and compatibility are intentionally narrow in this preview. Memory guidance, signatures, richer support metadata, crash-recovery tooling, portable backend variants and enterprise licensing are not implemented.

Validation uses nonblocking, no-follow file opens and checks the opened descriptor is a bounded regular file. It hashes in cancellation-aware chunks, detects size/metadata changes during reads, and parses captured verified metadata rather than reopening those paths. These defenses do not replace the requirement to keep the installed directory and its parents trusted and immutable while loading.
