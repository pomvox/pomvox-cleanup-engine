# Changelog

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
