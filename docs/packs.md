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

### Vocabulary cost on the reference Mac (#14)

Measured 2026-10-31 on Apple M1, 16 GiB, macOS 15.7.4, Xcode 26.3 (17C529), Debug build, `simplewords-v3` (manifest `b18de514…`, revision `b1f7ac82…`), mlx-swift-lm 3.31.4 / MLX 0.31.4, speculative decoding. One 87-byte fixture (the consumer benchmark's numbered list), nine requests per dictionary, 72 requests in all, every one `cleaned`. Terms are synthetic pseudo-names of about 9 bytes (4.6 tokens each); `64 × 32 B` is 64 terms of exactly 32 bytes, the current limits' worst case of 2,048 bytes. Networking was not denied in this run. Method, per-request numbers and limitations: [evidence](evidence/vocabulary-prefill-2026-10-31.json).

| Terms | Term bytes | Prompt tokens, uncached | Cached prefill ms, median of 5 (max) | First request after the dictionary changed, ms | Uncached prefill ms, median of 3 (max) | Cached decode ms / tokens, median |
| --- | --- | --- | --- | --- | --- | --- |
| 0 | 0 | 281 | 148 (149) | 1,848 | 1,065 (1,074) | 989 / 18 |
| 16 | 119 | 363 | 148 (149) | 2,077 | 1,410 (1,466) | 994 / 18 |
| 64 | 544 | 574 | 149 (150) | 2,732 | 2,115 (2,124) | 1,008 / 18 |
| 64 × 32 B | 2,048 | 1,064 | 151 (152) | 4,341 | 3,979 (4,002) | 1,247 / 22 |
| 128 | 1,115 | 845 | 151 (153) | 3,415 | 3,177 (3,211) | 1,024 / 18 |
| 256 | 2,245 | 1,390 | 153 (155) | 5,125 | 5,191 (5,276) | 1,260 / 22 |
| 512 | 4,660 | 2,509 | 156 (157) | 8,763 | 9,471 (9,598) | 1,287 / 22 |
| 1,024 | 9,801 | 4,878 | 162 (168) | 15,627 | 21,749 (25,406) | 1,324 / 22 |

What the table says (arithmetic on the rows above, same run):

- With the prefix cache, per-request prefill does not depend on dictionary size: 148 ms at 0 terms, 162 ms at 1,024, because the suffix the model reads is 25 tokens either way. Decode per token rose from 55 ms (989 / 18) to 60 ms (1,324 / 22), about 10 %, over the same range; the wider steady-state wall time (1,138 → 1,499 ms) is mostly the output being 22 tokens instead of 18 for some dictionaries.
- The cost that scales is the one-off prefix rebuild on the first request after the dictionary changes: 0.7 s above steady state at 0 terms, 1.6 s at 64, 2.9 s at 64 × 32 B, 3.7 s at 256, 7.3 s at 512, 14.1 s at 1,024, which is 2.5–2.9 ms per prefix token or roughly 12 ms per 9-byte term. The uncached path (prefix disabled, or a cache miss) pays 3.7–4.5 ms per prompt token on every request.
- The rebuild is request work inside that request's deadline ([contract](contract.md#cache-isolation)), and the default budget for short text is 5 s. The 256-term rebuild request took 5.1 s and the 512-term one 8.8 s, so a dictionary of that size would time out and fall back on the first dictation after an edit unless the host rebuilds ahead: open with `.mlx(vocabulary:)`, or send one request right after the dictionary is saved. The current worst case (4.3 s) fits.
- Not measured: resident memory with the larger prefix, energy, Release build, concurrent STT load, output quality (the output changed with the dictionary; there are no labels), and how real dictionary words tokenize compared with these pseudo-names.

The limits are unchanged by this measurement. The engine does not trim: a request over the request limits throws `invalidRequest`, one over the pack's declared limits throws `incompatible`, and nothing is dropped silently. The host selects a stable, ordered subset and passes it on **every** request, so the active set is exactly what the host passed; the app keeps the user's order, drops from the end, and reports the omitted count without logging terms ([integration prompt](pomvox-integration-prompt.md), step 3). Raising or pack-declaring the limits (option 2 of the issue, which changes prompt bytes and needs differential evidence) and engine-side trimming with a reported dropped count (option 3) are follow-ups that start from this table.

### Auxiliary generation: declared unsupported (#3)

`auxiliaryGeneration` is the flag behind `Cleaner.suggestVariants(for:limit:deadline:)`, the dictionary editor's spelling-variant chips. Absent (schema 1) or `false` means unsupported, and the call returns `[]` without a generation; a host hides the chips. **Decision (2026-10-31, issue #3 option 1): `simplewords-v3` ships no variant prompt and stays schema 1.** The fine-tune was trained on the frozen cleanup prompt only; asking it for mishearings is off-distribution, and the app's hand-built chat for that purpose was the second resident model this API removes. A pack that does carry its own variant prompt needs a manifest field for it, the MLX runtime conforming to `AuxiliaryGenerating`, and installed-artifact evidence before the validator accepts `auxiliaryGeneration: true` (option 2 in the issue, not done).

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

Metadata and compatibility are intentionally narrow in this preview. Memory guidance, signatures, richer support metadata, crash-recovery tooling, portable backend variants and enterprise licensing are not implemented.

Validation uses nonblocking, no-follow file opens and checks the opened descriptor is a bounded regular file. It hashes in cancellation-aware chunks, detects size/metadata changes during reads, and parses captured verified metadata rather than reopening those paths. These defenses do not replace the requirement to keep the installed directory and its parents trusted and immutable while loading.
