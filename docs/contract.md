# Behavior and lifecycle contract — preview 1

Public request/result values are independent of MLX. `PomvoxCleanup` contains the local facade; `CleanupCore` owns results, guards and scheduling; `CleanupPacks` checks installed artifacts. `Runtime/MLX` is an optional Swift package so contract and transport users do not acquire GPU dependencies.

## Limits and preparation

Requests permit 16,384 UTF-8 bytes of text; 64 vocabulary terms, 128 bytes each and 2,048 bytes combined; context up to 2,048 bytes; and at most 16 settings with 64-byte keys and 128-byte values. The frozen local baseline rejects any context/settings. Vocabulary cannot contain line breaks. Unsupported configuration fails before admission.

Preparation hashes local artifacts in chunks, loads using the directory-only model/tokenizer APIs, performs sampling-free prefix prefill, then generates a warmup. No fallback to a different model is possible. The preview only enables the optimized runtime for its exact supported artifact hashes. Opening fails if prefix/warmup preparation cannot complete.

## Worker and request lifetime

One worker runs per cleaner and at most two requests queue. MLX also takes a process-wide resident-model lease, so another cleaner cannot allocate a second model until the first closes. This is a conservative preview constraint, not shared model pooling or a system-wide GPU lock.

Each request has one continuation and one deadline timer. A timeout or cancellation resolves the waiter without a structured task group waiting for inference to stop. The backend receives cooperative cancellation. A still-running worker is quarantined: new calls return unavailable, pending requests return unavailable, and no replacement worker starts. Late output is discarded. Resources are released only after the worker returns. `close` stops admission and can return before resource release if the worker is unresponsive.

The SDK cannot preempt a GPU kernel or provide hard real-time scheduling. A hung in-process worker can retain its device lease indefinitely. Process isolation is future work.

## Cache isolation

Each runtime instance owns a single immutable prefix for its exact loaded artifact/tokenizer/prompt set. No cache survives a cleaner replacement. Every generation gets new mutable cache objects copied from that prefix. Vocabulary is rendered after the frozen prompt; if the exact cached prefix no longer matches, generation runs uncached and reports `prefix-cache-not-used`. There is no per-user cache dictionary. Instances are the scope boundary; multi-tenant serving and tenant cache pools are outside this local preview.

Hybrid recurrent layers legitimately report zero offsets and cannot trim rejected tokens. Prefix preparation requires counting layers to reach exactly the prefix length. Speculative decoding copies caches before verification, then restores and carries accepted tokens forward after a mismatch. Pass length remains five. The differential compares exact UTF-8, not visually equivalent Swift strings.

## Results and privacy

Ordinary failures preserve input bytes. Empty input is unchanged without inference. Cancellation throws, including cancellation racing completion. The host must also prevent delivery from superseded sessions.

Edits are ordered, non-overlapping scalar-boundary ranges measured in original UTF-8 bytes. A single minimal contiguous replacement avoids quadratic diff work and preserves decomposed Unicode. It can include an unchanged interior span. No normalization occurs.

Provenance includes the pack manifest digest (which covers every artifact digest), model revision, runtime route and applied settings. Vocabulary is represented by a hash of its ordered JSON encoding; the diagnostic does not contain the words. Prefix/tokenizer identities are transitively pinned by the manifest. Hashes are identifiers, not anonymization promises.

Timings report preparation, queue, tokenization, prefill, decode/inference, validation, diff, total, and chosen budget. A stage not observed is nil. Preparation is separate from request total. The cloud client preserves server inference separately and replaces total with client-observed latency. Fallback timing never counts as successful model cleanup.

Local request code contains no network client, downloads, telemetry or content logging. Setup paths are private filesystem paths and should not be sent to external logging services. Local pack manifests are developer-trusted, hash-checked installations; hash validation does not authenticate a publisher. Signed remote pack distribution is future work. Installed files must remain immutable between validation and loading; hostile concurrent filesystem mutation is outside the preview trust model.
