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
