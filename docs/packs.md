# Installed pack format — schemas 1 and 2

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

## Schema 2: capabilities

Schema 2 is schema 1 plus one required top-level object, `capabilitiesDetail`. Schema 1 is unchanged and still accepted, so existing installations keep validating with the same manifest digest. A `capabilitiesDetail` key in a schema 1 manifest fails validation.

| Field | Meaning | Rule in this runtime |
| --- | --- | --- |
| `styles` | Style names a request may select | Must be empty (frozen prompt) |
| `speculativeSwitch` | Whether a host may toggle speculative decoding | Must be `false` |
| `auxiliaryGeneration` | Whether the pack offers auxiliary generation | Must be `false` |
| `minResidentMemoryBytes` | Minimum resident memory, bytes | `null` (not measured) or 1 B to 1 TiB |
| `vocabulary` | `maxTerms`, `maxTermBytes`, `maxTotalBytes` | Each positive and no looser than the request limits (64, 128, 2,048) |

Unknown or missing keys at either level fail validation. A pack declaring a style, a speculative switch or auxiliary generation is refused as incompatible, because this runtime cannot honor them. A pack may declare stricter vocabulary limits; `Cleaner` then refuses a request over them before the model runs.

Hosts read the answer as `ValidatedPack.capabilities` before open and `Cleaner.capabilities` after. A schema 1 pack reports `PackCapabilities.frozenBaseline`: no styles, no speculative switch, no auxiliary generation, memory not measured, and the request vocabulary limits. `simplewords-v3` is schema 1; its manifest is unchanged.

## Diarizer packs

A diarizer pack is a second, independent pack format for the optional
diarization runtime: `pack.json` (schema 1, fields `schemaVersion`, `id`,
`version`, `publisher`, `license`, `licenseURL`, `modelID`, `modelRevision`,
`runtime`, `pipeline`, `attribution`, `artifacts`, `limitations`, `evidence`)
plus exactly the 23 files `DiarizerPackLoader.artifactPaths` names under
`speaker-diarization/`: the `Segmentation`, `FBank`, `Embedding` and
`PldaRho` compiled Core ML bundles (five files each), `plda-parameters.json`,
and the upstream `LICENSE` and `NOTICE.md`. Paths are nested, unlike the flat
cleanup pack; symlinks, extra files or directories, unknown manifest fields, a
runtime other than `fluidaudio-0.15.5` or a pipeline other than
`pyannote-community-1-offline` fail validation. The manifest digest is SHA-256
over the exact manifest bytes.

The pinned instance is [`packs/pyannote-community1-coreml/pack.json`](../packs/pyannote-community1-coreml/pack.json):
`FluidInference/speaker-diarization-coreml` at revision
`df2625ac79a7ac6b65ad868fee6d80f320da4232`, CC-BY-4.0, about 21 MB installed.
`scripts/prepare-diarizer-pack.py <snapshot> <destination>` installs it from a
snapshot already on disk with the same copy-verify-publish discipline as the
cleanup installer. See [speaker transcripts and notes](speaker-notes.md#diarization).

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

## Listing and removing installed packs

`PackInstaller.installed(at:)` lists the pack directories under one parent, the directory `install` publishes into, as `InstalledPack` values: `directory`, manifest `id` and `version`, `installedAt` (when `pack.json` was published, the last step of an installation) and two sizes. `allocatedBytes` is the allocated blocks of every file, what `du` reports; on APFS a clone of the source cache counts in full, so a freshly installed baseline reads about 2 GB even though it shares its blocks. `privateBytes` is what removing the pack frees now: the bytes no other file shares through cloning (`ATTR_CMNEXT_PRIVATESIZE`), which is near zero while the source snapshot still exists and grows to `allocatedBytes` once it is gone. On a volume without that attribute the two are equal. A missing parent lists nothing. Hidden entries, including the installer's staging and removal directories, and directories without a decodable manifest (an interrupted installation) are skipped; remove those explicitly. Listing decodes manifests only; `Cleaner.open` still verifies every artifact.

`PackInstaller.remove(_:)` deletes a listed pack. It refuses, with `CleanupError.unavailable`, while a `Cleaner` in the same process holds the directory, from before validation starts until the runtime's resources are released (`closeAndWait()`, or `close()` once any running generation has returned). A cleaner in another process is not detected; macOS keeps that process's mapped weights alive until it is done. Removal checks that the directory is still the listed one (device and inode), renames it aside under the same lock the hold check uses, and deletes the renamed copy afterwards. The published path therefore never holds a partial pack, a stale listing never deletes a replacement installed at the same path, and a concurrent `install` of the same id either fails because the old pack is still there or publishes cleanly after it is gone. Both calls do file IO; run them off the main actor.

Metadata and compatibility are intentionally narrow in this preview. Memory guidance, signatures, richer support metadata, crash-recovery tooling, portable backend variants and enterprise licensing are not implemented.

Validation uses nonblocking, no-follow file opens and checks the opened descriptor is a bounded regular file. It hashes in cancellation-aware chunks, detects size/metadata changes during reads, and parses captured verified metadata rather than reopening those paths. These defenses do not replace the requirement to keep the installed directory and its parents trusted and immutable while loading.
