# Release procedure

The root SDK remains independent of MLX. The development runtime in `Runtime/MLX`
is exported into the public `pomvox/pomvox-cleanup-mlx` repository for distribution,
and `Runtime/Diarization` into `pomvox/pomvox-diarization-fluid`. Do not maintain
independent runtime implementations in the runtime repositories.

1. Update `VERSION`, changelog, release notes and install examples consistently. Use
   semantic prerelease versions until the stable gates in `docs/testing.md` are met.
   SDK/runtime share a version; the separately licensed model pack version is independent.
2. Run `python3 scripts/check.py --sanitizers --repeat 20`, the separate Xcode
   consumer build, and the network-denied real-model suite with no skipped model tests.
   Record exact source/artifact identities. Public CI does not have gated weights.
3. Sign the core commit with the configured GPG key, push normally and require green
   SDK CI on the exact commit. Create a signed `v<VERSION>` tag pointing to it.
4. Export into a new empty directory:
   `python3 scripts/export-mlx-release.py /absolute/path/to/new-export`.
   The exporter replaces only the development path dependency with the matching
   exact public core version and copies an allowlist of runtime code/tests and docs.
   `SOURCE.json` binds the export to the source tag and content hashes.
5. Build the export's Xcode consumer against the tagged **remote** core dependency.
   Commit the export with a signed commit in the runtime repository, push normally,
   and require its CI to pass. Create the matching signed runtime tag.
6. Build a clean external consumer with the remote runtime URL and exact release
   version, with no local package overrides. It must resolve both public packages
   and package Metal resources. This proves package installation, not gated model acquisition.
7. Repeat steps 4–6 for the diarization runtime:
   `python3 scripts/export-diarization-release.py /absolute/path/to/new-export`,
   committed to `pomvox/pomvox-diarization-fluid` with its own signed `v<VERSION>` tag
   after its CI passes. Its CI runs the package tests (gated real-pack tests skip),
   cross-compiles for iOS 17 and consumes the package remotely at the pushed commit.
   Run the real-pack diarizer tests locally with `POMVOX_TEST_DIARIZER_PACK` first.
8. Verify the tags match `VERSION` and the validated commits; publish the GitHub
   releases (core and each runtime) using the reviewed notes. Mark beta versions as prereleases. Attach
   checksums/evidence when applicable. Do not rewrite published tags; issue a new version.

Actions are pinned by commit and use read-only repository permissions. Publishing
is an explicit maintainer operation; PR CI never receives publishing credentials.
Review pinned action/toolchain updates separately. Preserve upstream license notices
and never include weights, access tokens, private dictation history or local build products.
