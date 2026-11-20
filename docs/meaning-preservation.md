# Meaning-preservation replay

The trailing-restriction guard is a deterministic SDK rule, not a semantic
validator. It rejects a candidate if the input ends in a clause-boundary or
`and` followed by `nothing else` (case insensitive, optional terminal
punctuation/whitespace), but the candidate does not. Earlier guard precedence
is unchanged. Equivalent paraphrases can conservatively fall back; other
restrictions, in-sentence uses and subsequent corrections are outside this rule.
A rejection returns exact input bytes, no edits and no post-transforms.

The reviewed change originated at `codex/cleanup-replay-guard`, commit
`dda4a99f991c3ad0a6dd17b7d7164814653f5205`. Existing pack declarations of
`pomvox-guards-v0.2.8` remain accepted; capabilities report the actual active
`pomvox-guards-v0.2.9`. Other rule identities and multi-rule declarations remain
incompatible. This does not relax model, prompt or tokenizer hash validation.

## Native semantic checks

Build `Examples/Consumer` as described in [testing](testing.md). Then run the
`MeaningPreservationTests/testLocalSemanticReplay` XCTest selector with:

- `POMVOX_TEST_PACK`: fully installed local pack directory.
- `POMVOX_SEMANTIC_INPUT`: local JSON fixture array. The public synthetic
  development set is [meaning-development.json](fixtures/meaning-development.json).
- `POMVOX_SEMANTIC_EVIDENCE`: local output JSON path, outside tracked content.
- `POMVOX_REQUIRE_SEMANTICS=1`: assert candidate and delivered semantic checks.
  Omitting this flag collects evidence and checks fallback integrity only;
  a passing collection run is **not** semantic correctness evidence.

```sh
POMVOX_TEST_PACK=/absolute/path/to/installed-pack \
POMVOX_SEMANTIC_INPUT="$PWD/docs/fixtures/meaning-development.json" \
POMVOX_SEMANTIC_EVIDENCE=/absolute/local/path/semantic-results.json \
POMVOX_REQUIRE_SEMANTICS=1 \
  sandbox-exec -p '(version 1)(allow default)(deny network*)' \
  xcrun xctest -XCTest ModelTests.MeaningPreservationTests/testLocalSemanticReplay \
  /absolute/path/to/DerivedData/Build/Products/Debug/ModelTests.xctest
```

Run the built test bundle with network access denied. The harness uses Swift
MLX greedy and speculative decoding at temperature zero, a 60-second deadline,
and the runtime's tokenizer-based token cap. It records candidate before guards,
stop reason, guard result, delivered text, exact-input fallback, token cap,
decode count, vocabulary, pack revision, manifest digest and artifact hashes.
The prompt, chat template, tokenizer and tokenizer configuration hashes are
separate artifact entries. With these two decoding modes, a non-failure candidate
means the runtime stopped at EOS; failed decoding has no exposed partial candidate.
No request or output text is printed to test logs.

Fixtures carry `id`, `split`, `raw`, `vocabulary`, `required` and `forbidden`.
Required/forbidden expressions assert meaning-bearing facts, including the final
corrected number (and absence of the superseded number), the original actor,
and every component of a condition and commitment. Exact input bytes preserve meaning even if a correction remains unresolved.
The separate `candidateAssertionsPass` and `deliveredAssertionsPass` fields
report strict correction/fact checks; `unchanged` and `fallback` distinguish
untouched input from successful cleanup. Positive controls include
successful corrections and additive second phrases. These assertions are a
bounded regression oracle, not a general semantic metric: review unexpected
failures locally for harmless rephrasing and inspect condition/actor scope.

Report separately, for each split and decoding mode:

1. Candidate semantic passes / all requests (including runtime failures).
2. Delivered semantic passes / all requests.
3. Exact-input fallback count / all requests, plus each fallback reason.
4. Accepted but semantically incorrect candidates.

Never count preserved raw fallback as successful model cleanup. An unchanged
result can also fail semantics; decoder parity does not establish correctness.

## Ownership and candidate-pack gate

Wrong candidates before validation belong to the SimpleWords model/pack owner
identified in the manifest, `abhiram3040/simplewords-dictation-cleanup-v3`.
Provide a local reproduction bundle and synthetic development cases; keep real
transcripts and generated outputs local. Coordinate prompt/template changes with
the model pack. Do not patch the frozen SDK prompt independently or relax
`SupportedBaseline` to load arbitrary candidate weights.

Before considering a candidate pack, have its owner supply a versioned manifest,
artifact/prompt/template/tokenizer hashes and runtime compatibility evidence.
Evaluate both the development cases and a separately frozen, independent held-out
set that was not used to select or tune the candidate. Keep held-out fixture
hashes and results local and report the four metrics above separately. Do not
relabel development examples as held-out evidence or repeatedly tune against the
held-out set. Require review of semantic regressions and fallback-rate changes,
then the installed-artifact differential and consumer build before adding a
compatibility entry. A candidate that passes these checks still needs separate
release approval.

The engine owns narrow deterministic guards and exact-input fallback. The Pomvox
app participates when adopting a validated SDK/pack release or when a native
reproduction implicates host behavior. A failure reproduced before the guard in
this harness does not require an app-side patch. Deployment and release are
separate actions.
