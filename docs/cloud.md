# Explicit cloud transport — protocol version 1

`PomvoxCleanupCloud` is a separate client. It has no link to `CleanupMLX`, no premium weights, and no default service endpoint. `CloudCleaner.connect` requires an exact endpoint, credential provider, and remote pack ID/version. Construction validates configuration without transmitting anything; `clean` is the explicit upload operation.

```swift
import PomvoxCleanupCloud

struct Tokens: CredentialProvider {
    let fetch: @Sendable () async throws -> String
    func bearerToken() async throws -> String { try await fetch() }
}
let remote = try CloudCleaner.connect(
    endpoint: configuredEndpoint,
    credentials: Tokens(fetch: acquireShortLivedToken),
    pack: RemotePack(id: configuredPack, version: configuredVersion)
)
let result = try await remote.clean(CleanupRequest(rawTranscript, deadline: .seconds(2)))
await remote.close()
```

Applications supply their own credential acquisition. Never embed a shared service secret in an end-user application. HTTPS is required except for loopback HTTP development. URL user information, query strings and fragments are rejected. Redirects are refused, cookies/cache/credential persistence are disabled, and the client performs no automatic retries or local fallback.

## Request

POST JSON to the configured endpoint (no inferred URL path):

```json
{
  "schemaVersion": 1,
  "requestID": "00000000-0000-0000-0000-000000000001",
  "pack": {"id": "example", "version": "1.0.0"},
  "text": "um hello",
  "vocabulary": [],
  "context": "",
  "settings": {},
  "remainingMilliseconds": 1800
}
```

Headers: `Authorization: Bearer <provided credential>`, `Content-Type: application/json`, and `Idempotency-Key: <requestID>`. Remaining budget is calculated **after** credential retrieval. The client's monotonic deadline starts before it and covers the full operation. Remote servers must start a bounded worker deadline on receipt and account for queueing; the client timer remains authoritative for delivery.

Admission is one active request and no queue. Busy calls return exact-input fallback. A credential provider or transport that ignores cancellation retains this slot until its worker exits; the client never grows replacement operations. User cancellation throws. Operational failures return labeled exact input. Invalid endpoint or input configuration throws. `close` cancels delivery and invalidates the ephemeral session.

## Response

The JSON response has `schemaVersion`, matching `requestID`, and `result` matching the SDK's versioned Codable result. Status encoding is explicit:

```json
{"cleaned": {}}
{"unchanged": {}}
{"fallback": {"_0": "timedOut"}}
```

`result` includes `text`, `edits`, `status`, `provenance`, `timings`, and `warnings`. Edits contain integer `start`/`end` UTF-8 byte offsets and `replacement`. Provenance must identify the requested pack/version, actual runtime, artifact/service revision and `route: "cloud"`.

The client requires HTTP 200 JSON, matching protocol/request/pack/route, bounded body size (128 KiB), at most 1,024 valid edits, and exact byte reconstruction. Unchanged/fallback responses must return input bytes and no edits; cleaned responses must actually differ. Timings must be finite and nonnegative. Invalid responses become `fallback(invalidResponse)`; the client does not display an unvalidated remote candidate. HTTP or connectivity failures become `fallback(transport)` unless the deadline expires.

Client-observed total replaces the server total, while server inference is exposed separately as `serverInferenceMS`. Server stage timing remains server-reported, not an independently verified measurement. If no valid response is obtained, provenance records the requested pack and `unavailable` for the unobserved actual model/runtime.

## What the mock establishes

The Python test fixture binds only to an ephemeral loopback port. Tests verify headers, explicit vocabulary/context/settings, response reconstruction, wrong-pack rejection, oversized responses, redirect refusal, timeouts and cancellation. It does not run a model or implement a premium service.

A real service still needs tenant authentication/entitlements, scoped worker queues, quotas, deduplicated retry accounting, retention/deletion and no-training-by-default policies, region and reliability decisions, service-side response validation, cancellation and measured serving costs. No provider, production host, region, billing system or deployment has been selected.

## Diarization — protocol version 1

`CloudDiarizer` is the explicit cloud counterpart of the local diarizer runtime,
with `CloudCleaner`'s rules: `connect` validates an HTTPS (or loopback HTTP)
endpoint, a credential provider and a remote pack id/version without
transmitting anything; `diarize` is the upload. One request in flight, no queue,
no retries, no redirects, no cookies or caches, a client-side monotonic deadline
that starts before credential retrieval. There is no text to fall back to, so
failures throw `DiarizationError` instead of returning a labeled result:
`busy`, `timedOut`, `transport(detail)`, `invalidResponse(detail)`,
`unavailable(detail)` after close, `noSpeech` when the server says so.

```swift
import PomvoxCleanupCloud

let remote = try CloudDiarizer.connect(endpoint: configuredEndpoint,
    credentials: Tokens(fetch: acquireShortLivedToken),
    pack: RemotePack(id: configuredDiarizerPack, version: configuredVersion))
let who = try await remote.diarize(DiarizationRequest(samples: samples16k, speakers: 2...4, deadline: .seconds(120)))
await remote.close()
```

### Request

`POST` to the configured endpoint. The body is the audio as a 16 kHz mono
16-bit PCM WAV (`Content-Type: audio/wav`), encoded by the client from the
request's samples; `.file(URL)` audio is refused (`invalidRequest`), decoding
files is the host's job. At most 60 minutes of audio per request (about 115 MB).

Headers:

| Header | Value |
| --- | --- |
| `Authorization` | `Bearer <provided credential>` |
| `Content-Type` | `audio/wav` |
| `Idempotency-Key` | the request UUID |
| `X-Pomvox-Schema` | `1` |
| `X-Pomvox-Pack` / `X-Pomvox-Pack-Version` | the configured remote pack |
| `X-Pomvox-Audio-Seconds` | audio length, decimal seconds |
| `X-Pomvox-Remaining-Milliseconds` | budget left after credential retrieval |
| `X-Pomvox-Speakers` | `min-max`, only when the request bounds the count |

### Response

HTTP 200, `application/json`, at most 1 MiB:

```json
{"schemaVersion": 1, "requestID": "…", "result": {
  "segments": [{"speaker": "A", "span": {"start": 0.0, "end": 4.2}, "confidence": 0.9}],
  "speakerCount": 1,
  "provenance": {"packID": "…", "packVersion": "…", "artifactDigest": "…", "modelRevision": "…",
                 "runtime": "…", "route": "cloud", "settings": {}},
  "timings": {"totalMS": 310, "budgetMS": 120000},
  "warnings": []
}}
```

The client requires matching schema, request id, pack id and version, route
`cloud`, nonempty runtime, artifact digest and model revision, at most 4,096
segments with finite, ordered, nonnegative spans that end within the audio
length (0.5 s tolerance), a speaker count equal to the distinct labels, and
finite nonnegative timings. Anything else is `invalidResponse`; the client
never hands an unvalidated segmentation to the host. Speakers are then relabeled
`S1`, `S2`, ... in order of first appearance, as the local runtime does, and
`timings.totalMS` and `budgetMS` are replaced by client-observed values. HTTP or
connectivity failures are `transport`; an elapsed deadline is `timedOut`
whatever the server was doing.

The Python fixture answers `audio/wav` posts with a two-speaker split of the
reported duration and the same family of malformed variants as the text
protocol. It does not run a model. Everything a real service still needs
(tenancy, quotas, retention, consent, region, cancellation, cost) is listed
above and unchanged; which provider sits behind the endpoint (pyannoteAI,
Deepgram, AssemblyAI, a self-hosted pyannote, …) is the host's choice, outside
this SDK.
