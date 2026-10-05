# Changelog

## Unreleased

- Add `CleanupBudgetPolicy`, a length-sized deadline helper moved from the Pomvox app with its tests. It is opt-in: the default request budget is unchanged.
- Add a capability query (`ValidatedPack.capabilities`, `Cleaner.capabilities`) and an optional pack schema 2 that declares it. Schema 1 packs, including `simplewords-v3`, are unchanged and report the frozen baseline.
- Add an opt-in spoken-layout transform (`CleanupRequest(transforms: [.spokenLayout])`), moved from the Pomvox app with its tests. It applies to accepted output only; fallbacks stay exact input, and `SpokenLayout.apply` is public for hosts that want it there too.
- Report the request text admission limit as `PackCapabilities.maxTextBytes` (`CleanupRequest.maxTextBytes`, 16,384 UTF-8 bytes, unchanged), and document it with the runtime's output cap as one pair in the contract guide. Requests that cannot fit the output cap are not yet rejected at admission; that check needs the tokenizer (#13).

## 0.1.0-beta.2 — 2026-09-24

- Fix remote SwiftPM consumption: keep the exact tokenizer version active by depending on its product.
- Build runtime CI through a remote dependency on the exact pushed commit and verify resolved versions.
- Supersede beta.1 tags, which were withheld from GitHub Releases after the final remote-install check failed.

## 0.1.0-beta.1 — 2026-09-24

First tagged public SDK release. This beta does not claim production readiness.

- Publish core/cloud SDK and standalone MLX Swift packages with matching exact versions.
- Add public CI for Debug/Release, sanitizers, lifecycle/installer checks, and Xcode consumer builds.
- Reuse a bounded vocabulary-aware prefix cache, with real-model differential coverage.
- Add native pack installation, APFS cloning, immutable-pack validation reuse, and safe close/reopen.
- Preserve rejection reasons and observed runtime diagnostics on completed fallbacks.
- Expose quarantine state, decoder counters, cache use and optional MLX buffer-pool clearing.
- Preserve explicit host deadlines and recheck cancellation/session identity immediately before insertion.
- Provide a reviewed integration prompt and reproducible validation evidence.

Model weights are separate gated artifacts. macOS 14 is the deployment floor; Linux,
Intel inference, style controls, auxiliary generation, unlimited output and production
cloud hosting are not part of this release. See docs/testing.md for remaining stable-release gates.
