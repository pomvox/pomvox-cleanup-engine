# Extraction baseline and decisions

## Verified source

Read-only inspection on September 14, 2026 found `pomvox/pomvox` remote main and the selected local source checkout at **`8d693ad15964e7d5dd731ab7b7e80186d65166ad`**, v0.2.8 appcast release. `git ls-remote` was used to check current remote main; the existing checkout was clean. Older candidate checkouts were at `a65c44c` (v0.2.3) and `8944eba` (v0.2.5).

The source's contribution rules and MIT license were read. `Pomvox/project.yml` is the app build definition; `native/Package.swift` is a separate historical spike. Actual source inspection covered cleanup logic, engine preparation/rendering/generation, prompt profiles, deadlines, residency, statistics, prompt lookup, speculative decoding, spoken formatting, NativeEngine integration, and their tests. Stalled local file reads were replaced with read-only Git-object or pinned remote-file reads.

[Source at the extraction commit](https://github.com/pomvox/pomvox/tree/8d693ad15964e7d5dd731ab7b7e80186d65166ad) includes merged speculative decoding (`3546bea`) and spoken formatting (`380349d`). Those changes were extracted from actual source, not inferred from a dated design document.

## Runtime versions

The app declared minimum/range constraints. Its existing Xcode dependency checkout established the concrete versions below, which this preview pins rather than using floating minima:

| Dependency | Version | Revision |
| --- | --- | --- |
| mlx-swift-lm | 3.31.4 | `bd4b7434e6bdb588c7ef55706ff8904cb7fd4c57` |
| mlx-swift | 0.31.4 | `dc43e62d7055353c7f99fa071a4e71d29dfddc44` |
| swift-tokenizers-mlx | 0.3.0 | `6fb48051a8b7e36707725d3ef2f876d6ed860250` |
| swift-tokenizers | 0.5.0 | `9cb02e836c1d8782a36ea02e7c437697ceff2ab8` |

`Runtime/MLX/Package.resolved` records transitive versions as well. The source's minimum `3.31.0` is not an available exact tag; resolving that as an exact version failed, which is why the actual app checkout was checked before pinning `3.31.4`. The local-directory APIs remove the need for the app's Hugging Face downloader dependency.

Artifacts are pinned separately in [the manifest](../packs/simplewords-v3/pack.json). Newer remote model revisions are not automatically selected.

## Implementation decisions

- Separate reusable SDK; the existing app remains unchanged. Free local operation has no subscription, license-server or cleanup network dependency.
- Runtime-independent public types, optional Swift/MLX package, no language rewrite or native C/Python/Node bindings yet.
- Preserve the model-specific frozen prompt, tokenizer, greedy settings, token cap, sampling-free hybrid prefill and speculative snapshot/carry-forward algorithm.
- Replace mutable app lifecycle/configuration with a prepared cleaner. Retain one immutable prefix per instance, reject ineffective style settings, bound admission, and separate worker lifetime from request completion.
- Intentional contract changes: cancellation throws; exact raw fallback precedes host formatting; setup failures throw; no lazy downloads, reload credit, implicit model fallback or transcript logs.
- Cloud is an explicit optional transport package. Premium weights remain server-side in the proposed product; there is no live premium service in this repository. Licensed private enterprise deployments remain a separate option.

The test-only `LegacyReference` retains source prefix/render/generation methods. It substitutes installed-directory preparation and removes unrelated app download/lifecycle/suggestion code. It is not a new maintained production runtime or an end-to-end app test. The reference shares extracted decoder helpers and guards; library-versus-greedy-versus-speculative comparisons separately check algorithm equivalence. Pure guards and prompt builders are checked against extracted source tests.

A final September 15 remote-main check still returned the same extraction commit. The target directory initially had no Git metadata; this task did not initialize a repository, create commits or publish anything.

## Scope remaining after this preview

Pomvox integration, lifecycle under STT and memory pressure, broader quality evaluation, repeatable latency/memory measurements, signed reproducible artifact distribution and wider runtime support remain separate milestones. The host adapter preserves transform order and checks superseded sessions, but cannot prove real microphone-to-paste integration without changing and testing the app.
