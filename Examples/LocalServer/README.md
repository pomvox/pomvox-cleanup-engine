# Local reference server and browser demo

A browser cannot run this SDK: it is Swift over Metal and Core ML. What a web
page can do is talk to a **local companion process** that runs the engine and
speaks the engine's own wire protocols. This example is that process, plus a
one-page web app that uses it. It is host stand-in code like the other
examples, not a product and not part of the SDK.

What the server does, all on `127.0.0.1`:

| Endpoint | What it is |
| --- | --- |
| `POST /v1/clean` | The cleanup wire protocol (version 1, `docs/cloud.md`) served by the real local `Cleaner` on the installed pack. `CloudCleaner` can be pointed at it. |
| `POST /v1/diarize` | The diarization wire protocol (version 1) served by `FluidDiarizer` on the installed diarizer pack. `CloudDiarizer` can be pointed at it. |
| `POST /v1/speaker-notes` | Demo convenience, not a protocol: WAV in, the whole pipeline out (Parakeet word timings, diarization, `Transcript.attribute`, per-turn cleanup with a budget, `Notes.extract`, Markdown). |
| `POST /v1/notes` | Answers 501: model-written notes need a model behind the endpoint and this server has none. |
| `GET /v1/status` | Packs, runtimes, whether speech recognition is loaded. |
| `GET /` | The page. |

Served results carry route `cloud` and a runtime name prefixed
`pomvox-local-server/`, exactly as a hosted service would stamp them, so the
SDK's cloud clients accept them unchanged. Every `/v1` call except status needs
the bearer token the server prints at start (or `--token`); the page gets it
injected. Speech recognition runs **in this example only**, through FluidAudio's
Parakeet from its local cache; the SDK owns no STT. `FluidDiarizer.open`
switches FluidAudio to offline mode for the process, so nothing downloads.

## Build and run

An Xcode build is required (mlx-swift's Metal library is an Xcode build phase).

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodegen generate --spec Examples/LocalServer/project.yml
xcodebuild -project Examples/LocalServer/LocalServer.xcodeproj -scheme LocalServer \
  -configuration Release -derivedDataPath /tmp/pomvox-local-server \
  -destination 'platform=macOS,arch=arm64' build

/tmp/pomvox-local-server/Build/Products/Release/LocalServer \
  "$PWD/.local/simplewords-v3" "$PWD/.local/pyannote-community1-coreml" --port 8787
```

Then open `http://127.0.0.1:8787/`. Options: `--web <dir>` (the page files;
default `Examples/LocalServer/Web`), `--asr-models <dir>` (Parakeet TDT v3
Core ML bundles; default FluidAudio's cache), `--no-stt` (skip speech
recognition; `/v1/speaker-notes` answers 503), `--token <secret>`.

Try the protocol with curl:

```sh
TOKEN=…; ID=$(uuidgen)
curl -s http://127.0.0.1:8787/v1/clean -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -H "Idempotency-Key: $ID" -d "{\"schemaVersion\":1,\"requestID\":\"$ID\",\"pack\":{\"id\":\"simplewords-v3\",\"version\":\"0.1.0-preview\"},\"text\":\"um hello there\",\"vocabulary\":[],\"context\":\"\",\"settings\":{},\"remainingMilliseconds\":30000}"
```

## What the page does

1. **Dictation cleanup.** A textarea; `Clean` sends protocol v1 and shows the
   cleaned text, the outcome, the edit count and the model time.
2. **Speaker notes.** `Record` captures the microphone with Web Audio at 16 kHz
   mono (resampled in the page if the browser refuses that rate), `Stop &
   process` encodes PCM16 WAV and posts it; or upload a WAV. The reply is
   rendered as a speaker timeline, the Markdown notes, and the raw JSON
   (`SpeakerSegmentation`, `TranscriptResult`, `Notes`). An optional speaker
   count or range is sent as `X-Pomvox-Speakers`.

Microphone access requires a secure context; `http://127.0.0.1` and
`http://localhost` qualify in current browsers.

## Limits

One request at a time per runtime: a second diarization while one runs is 429;
cleanup queues at most two. Transcript cleanup is bounded by a 180 s overall
deadline and the measured M1 budget per turn; turns past the budget come back
as their exact words with the `transcript-budget-exhausted` warning. No TLS, no
keep-alive, no CORS: the page is same-origin by design. Nothing is logged, and
nothing leaves the machine.

## For someone building a web product on this

The pattern is the only one that works: engine on a Mac (the user's own, as a
companion app or helper, or an Apple Silicon host you operate), browser as a
client of the documented protocols. A hosted web product is the premium-cloud
case in the vault's deployment decision, with everything a service needs that
this example does not have: authentication and tenancy, queues and quotas,
retention and consent, cost. The client side is already written: `CloudCleaner`,
`CloudDiarizer`, `CloudNotes`.
