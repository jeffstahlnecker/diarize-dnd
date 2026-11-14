# Local HTTP API (`diarize serve`)

`diarize serve` starts a small HTTP server on the loopback interface so that **companion apps running on the same Mac** (a web app in the browser, a menu-bar utility, a script) can start and stop recordings, follow progress, read transcripts and manage speakers, without shelling out to the CLI or speaking MCP.

Everything stays on the machine: the server binds to `127.0.0.1` only, nothing is sent anywhere, and the microphone is opened only when a client explicitly asks for a recording.

> Status: API version **1** (experimental until a tagged release says otherwise). Breaking changes bump the `/v1` prefix.

- [Quick start](#quick-start)
- [Conventions](#conventions)
- [Authentication and pairing](#authentication-and-pairing)
- [Origins, CORS and browser rules](#origins-cors-and-browser-rules)
- [Errors](#errors)
- [Endpoints](#endpoints)
- [Events (SSE)](#events-sse)
- [Schemas](#schemas)
- [Time and clocks](#time-and-clocks)
- [Limits and operational notes](#limits-and-operational-notes)
- [Conformance table](#conformance-table)

---

## Quick start

```sh
diarize serve --allow-origin https://app.example.com
```

```
diarize serve 0.1.0 (API v1)
Listening on  http://127.0.0.1:47653
Allowed origins:  https://app.example.com
Pairing code:     483-912   (valid 5 minutes, single use)
```

A client pairs once, then uses the returned token:

```sh
# 1. Pair (Origin header is what a browser would send; curl has none and may omit it)
curl -s -X POST http://127.0.0.1:47653/v1/pair \
  -H 'Content-Type: application/json' \
  -d '{"code":"483-912","clientName":"My companion app"}'
# {"token":"dz_...","instanceId":"...","tokenId":"tok_..."}

# 2. Use it
export T=dz_...
curl -s http://127.0.0.1:47653/v1/capabilities -H "Authorization: Bearer $T"

# 3. Record
curl -s -X POST http://127.0.0.1:47653/v1/recordings -H "Authorization: Bearer $T" \
  -H 'Content-Type: application/json' -d '{"title":"Team sync","language":"en"}'
curl -s -X POST http://127.0.0.1:47653/v1/recordings/rec_.../stop -H "Authorization: Bearer $T"
curl -s http://127.0.0.1:47653/v1/recordings/rec_.../transcript -H "Authorization: Bearer $T"
```

### `diarize serve` options

| Option | Default | Meaning |
| --- | --- | --- |
| `--port <n>` | `47653` | Port on `127.0.0.1`. `0` picks a free port and prints it. If the port is busy the command fails; it never falls back silently. |
| `--allow-origin <origin>` | none | Browser origin allowed to call the API (`scheme://host[:port]`, exact match, repeatable). Also read from `DIARIZE_SERVE_ORIGINS` (comma separated). **No wildcards.** Without any origin, only clients that send no `Origin` header (curl, scripts) can connect. |
| `--archive <path>` | config | Override archive path (same meaning as for the other commands). |
| `--max-upload-mb <n>` | `2048` | Cap for `POST /v1/transcriptions`. |
| `--max-duration <h>` | `10` | A recording is stopped automatically after this many hours. |
| `--revoke-all` | | Delete every stored token and exit. |

Environment: `DIARIZE_SERVE_ORIGINS`, `DIARIZE_SERVE_PORT`.

---

## Conventions

- Base URL: `http://127.0.0.1:<port>/v1`. Use the literal `127.0.0.1` (the server does not listen on `::1`).
- Requests and responses are UTF-8 JSON (`Content-Type: application/json`) unless stated otherwise. Unknown request fields are ignored; unknown response fields must be ignored by clients.
- Timestamps are ISO-8601 UTC with millisecond precision (`2026-11-14T19:00:01.214Z`). Fields that exist to align audio with another clock also come as epoch milliseconds (`...Ms`).
- Durations and audio positions are seconds (floating point).
- IDs are opaque strings: recordings `rec_...`, speakers `spk_...`, segments are integers (stable until the transcript is regenerated).
- Every response carries `X-Request-Id`. A client may send its own `X-Request-Id` (max 64 chars); it is echoed.
- Request bodies other than uploads are limited to 64 KiB.

---

## Authentication and pairing

A web page can call any service on `127.0.0.1`, so the server never trusts the network position alone. Three independent checks apply to every request except the two marked *public* below:

1. **Host check**: the `Host` header must be `127.0.0.1:<port>` or `localhost:<port>` (defence against DNS rebinding). Otherwise `403 invalid_host`.
2. **Origin check**: if the request carries an `Origin` header, it must exactly match an allowed origin. Otherwise `403 forbidden_origin` (and no CORS headers, so the page cannot read the answer). `Origin: null` is rejected. Requests without `Origin` (non-browser clients) are subject to the token check only.
3. **Bearer token**: `Authorization: Bearer dz_...`. Otherwise `401 unauthorized`.

Public endpoints (no token): `GET /v1/health`, `POST /v1/pair`. They still go through checks 1 and 2.

### Pairing

On start, `diarize serve` prints a one-time **pairing code** (six digits, `NNN-NNN`). It is valid for 5 minutes and is consumed by the first successful pairing; a new code is printed on every start and after five wrong attempts.

The client sends the code once and receives a long-lived token:

- Tokens are 256-bit random values with the prefix `dz_`. Only the SHA-256 hash is stored, in `~/.config/diarize/serve-tokens.json` (mode `0600`) together with the token id, the client name, the origin it was issued to, `createdAt` and `lastUsedAt`.
- A token issued to an origin only works when requests come from that same origin (or carry no `Origin`).
- Revoke one token with `DELETE /v1/pair` (the token itself), or all tokens with `diarize serve --revoke-all`.
- Wrong codes are rate limited: 5 failures invalidate the current code and return `429 pairing_rate_limited` with `Retry-After`.
- The terminal prints a line for every pairing and for every recording start (`started by "<clientName>" from <origin>`).

The server never opens the microphone, loads models or touches the archive on its own. Capture happens only inside an authenticated `POST /v1/recordings` call, and macOS shows its own microphone indicator while it runs.

---

## Origins, CORS and browser rules

For requests whose `Origin` is allowed, the server answers with:

```
Access-Control-Allow-Origin: <the exact request origin>
Vary: Origin
```

and for preflights (`OPTIONS`, status `204`):

```
Access-Control-Allow-Origin: <origin>
Access-Control-Allow-Methods: GET, POST, PATCH, DELETE, OPTIONS
Access-Control-Allow-Headers: Authorization, Content-Type, X-Request-Id
Access-Control-Max-Age: 600
Access-Control-Allow-Private-Network: true      (only if the preflight sent Access-Control-Request-Private-Network: true)
Vary: Origin, Access-Control-Request-Private-Network
```

Rules:

- No wildcard `*`, ever. No `Access-Control-Allow-Credentials` (the API uses a bearer header, not cookies).
- A preflight from a non-allowed origin gets `403` with no CORS headers.
- `Access-Control-Expose-Headers: X-Request-Id, Retry-After` is sent on actual responses.
- **Mixed content.** An `https://` page may call `http://127.0.0.1` in Chromium-based browsers and Firefox, because these treat loopback as a potentially trustworthy origin. Safari does not make that exception; use a page served from `http://localhost`/`http://127.0.0.1` there, or a browser that does.
- **Private Network Access / Local Network Access.** Chromium answers a public-to-loopback request with a preflight carrying `Access-Control-Request-Private-Network: true`, which the server approves as above. Recent Chrome versions additionally ask the *user* once per site for permission to reach the local network; that prompt is a browser feature and not controllable by the server.
- Streaming (`/v1/events`) must be consumed with `fetch()` and a readable stream so that the `Authorization` header can be sent. `EventSource` cannot set headers and is therefore not supported.

---

## Errors

All errors use one envelope and an appropriate HTTP status:

```json
{
  "error": {
    "code": "conflict_recording_active",
    "message": "A recording is already running (rec_9f1c...).",
    "details": { "recordingId": "rec_9f1c..." },
    "requestId": "7c1b0d52"
  }
}
```

`code` is stable and machine readable; `message` is English text for logs; `details` is optional and code-specific.

| Status | `code` | When |
| --- | --- | --- |
| 400 | `bad_request` | Malformed JSON, wrong content type. |
| 401 | `unauthorized` | Missing, unknown or revoked token. Header `WWW-Authenticate: Bearer`. |
| 403 | `forbidden_origin` | `Origin` not allowed, or token not valid for this origin. |
| 403 | `invalid_host` | `Host` header is not loopback. |
| 403 | `pairing_code_invalid` | Wrong, expired or used pairing code. |
| 404 | `not_found` | Unknown route, recording, speaker. |
| 409 | `conflict_recording_active` | A recording is already in progress (from this server, the app, or the CLI). |
| 409 | `wrong_state` | The operation does not fit the recording state (`details.state`). |
| 409 | `not_ready` | Transcript requested while `state` is `recording` or `analyzing`. |
| 413 | `payload_too_large` | Body or upload over the limit. |
| 415 | `unsupported_media_type` | Upload is not a supported audio container. |
| 422 | `validation_failed` | Field-level problems, `details.fields` lists them. |
| 422 | `capture_failed` | Recorder could not start (permission, device). `details.hint` explains. |
| 429 | `pairing_rate_limited` | Too many wrong pairing codes; `Retry-After` seconds. |
| 500 | `internal` | Unexpected; the terminal has the stack. |
| 503 | `models_unavailable` | ASR/diarization models are not downloaded and cannot be loaded. |

---

## Endpoints

Auth column: **P** = public, **T** = bearer token required.

| Method and path | Auth | Purpose |
| --- | --- | --- |
| `GET /v1/health` | P | Is a diarize server here? Version and pairing state. |
| `POST /v1/pair` | P | Exchange the pairing code for a token. |
| `DELETE /v1/pair` | T | Revoke the calling token. |
| `GET /v1/capabilities` | T | Features, languages, input devices, limits, models state. |
| `POST /v1/recordings` | T | Start a recording. |
| `GET /v1/recordings` | T | List recordings (filters). |
| `GET /v1/recordings/{id}` | T | One recording with state, progress, clock. |
| `POST /v1/recordings/{id}/stop` | T | Stop capture; start analysis unless `transcribe` is `manual`. |
| `POST /v1/recordings/{id}/transcribe` | T | Start analysis of a stopped recording (`manual` mode, retry). |
| `GET /v1/recordings/{id}/transcript` | T | Transcript with speakers and clock. |
| `DELETE /v1/recordings/{id}/audio` | T | Delete the raw audio, keep transcript and speakers. |
| `DELETE /v1/recordings/{id}` | T | Delete audio, transcript and row. Requires `?confirm=true`. |
| `POST /v1/transcriptions` | T | Upload an audio file for diarization and transcription. |
| `GET /v1/speakers` | T | Speaker library. |
| `PATCH /v1/speakers/{id}` | T | Set label and/or notes. |
| `POST /v1/speakers/{id}/merge` | T | Merge this speaker into another. |
| `GET /v1/events` | T | Server-sent events stream. |

Not in v1 on purpose (use the app, CLI or MCP): folders, search, segment reassignment and splitting, retention clean-up, configuration.

### `GET /v1/health`

```json
{
  "service": "diarize",
  "version": "0.1.0",
  "apiVersion": 1,
  "paired": false,
  "serverTime": "2026-11-14T18:55:00.123Z"
}
```

`paired` is `true` when at least one token exists. Nothing else is revealed without a token.

### `POST /v1/pair`

Request:

```json
{ "code": "483-912", "clientName": "Companion app" }
```

`clientName`: 1 to 60 characters, shown in the terminal and in the token list.

Response `200`:

```json
{ "token": "dz_Yq3...", "tokenId": "tok_41ab", "instanceId": "0b6f3c1e-...", "apiVersion": 1 }
```

`instanceId` is a random id of this diarize archive (stored next to the database). Clients use it to know whether the speaker ids they remembered belong to this archive.

### `GET /v1/capabilities`

```json
{
  "apiVersion": 1,
  "version": "0.1.0",
  "instanceId": "0b6f3c1e-...",
  "languages": ["auto", "de", "en"],
  "defaultLanguage": "de",
  "sources": ["mic", "system"],
  "inputDevices": [
    { "uid": "BuiltInMicrophoneDevice", "name": "MacBook Pro Microphone", "isDefault": true }
  ],
  "limits": { "maxUploadBytes": 2147483648, "maxDurationSec": 36000, "jsonBodyBytes": 65536 },
  "features": { "upload": true, "deleteAudio": true, "speakerMerge": true },
  "recording": null,
  "orphans": []
}
```

`recording` is the active recording object (or `null`). `orphans` lists recordings left in `recording` state by a crashed process; `POST .../stop` on one analyses whatever audio was written.

### `POST /v1/recordings`

Request:

```json
{
  "title": "Team sync",
  "language": "de",
  "sources": ["mic"],
  "micDeviceUID": null,
  "clientRef": "my-app#sitting-3#1731607392000",
  "transcribe": "onStop",
  "deleteAudioWhenDone": false
}
```

| Field | Type | Default | Notes |
| --- | --- | --- | --- |
| `title` | string 1..200 | `"Recording <timestamp>"` | |
| `language` | `auto`, `de`, `en` | configured default | |
| `sources` | array of `mic`, `system` | `["mic"]` | `system` needs the Screen & System Audio permission. |
| `micDeviceUID` | string or null | system default | From `capabilities.inputDevices`. |
| `clientRef` | string 0..200 | null | Opaque tag stored with the recording; filter with `GET /v1/recordings?clientRef=`. |
| `transcribe` | `onStop`, `manual` | `onStop` | `manual` leaves the audio unanalysed until `POST .../transcribe`. |
| `deleteAudioWhenDone` | bool | `false` | Delete the raw audio after a successful analysis. Persisted server-side; works even if the client has gone away. |

Response `201`: a [Recording](#recording) with `state: "recording"`. The call returns once capture is running and `audioStartedAt` is known (normally under a second). Errors: `409 conflict_recording_active`, `422 capture_failed`, `422 validation_failed`, `503 models_unavailable` (only when `transcribe` is `onStop` and the models are missing, checked up front).

### `POST /v1/recordings/{id}/stop`

No body. Response `202` with the Recording: `state: "analyzing"` for `transcribe: "onStop"`, `state: "stopped"` for `manual` (see [state](#recording)). Stopping a recording that is not in state `recording` returns `409 wrong_state`. Stopping an orphan (see `capabilities.orphans`) analyses the audio that was written before the crash.

### `POST /v1/recordings/{id}/transcribe`

No body. Valid in state `stopped`, `failed`, or `empty` (re-run). Response `202`. Needs the audio to exist (`409 wrong_state` with `details.reason: "audio_deleted"` otherwise).

### `GET /v1/recordings`

Query: `clientRef`, `state`, `limit` (default 20, max 200), `before` (ISO timestamp, by `createdAt`). Response:

```json
{ "recordings": [ { "...": "Recording without clock.syncPoints" } ], "nextBefore": null }
```

### `GET /v1/recordings/{id}`

Response: a [Recording](#recording) including `clock.syncPoints`.

### `GET /v1/recordings/{id}/transcript`

Response `200`:

```json
{
  "recording": { "...": "Recording" },
  "transcript": {
    "recordingId": "rec_9f1c...",
    "title": "Team sync",
    "language": "de",
    "durationSec": 3612.4,
    "createdAt": "2026-11-14T18:59:58.000Z",
    "speakers": [
      { "id": "spk_a1", "label": "Sam", "segmentCount": 212, "speechSec": 1840.2 },
      { "id": "spk_b2", "label": null, "segmentCount": 97, "speechSec": 600.9 }
    ],
    "segments": [
      { "id": 4401, "start": 12.4, "end": 17.9, "speakerId": "spk_a1", "speakerLabel": "Sam", "text": "...", "confidence": 0.93 }
    ]
  }
}
```

`transcript` is a superset of the JSON file written by `diarize` (`TranscriptDocument`): the same keys plus `segments[].id`. `409 not_ready` while `state` is `recording` or `analyzing`; `state: "empty"` returns an empty `segments` array.

### `DELETE /v1/recordings/{id}/audio`

Removes the raw audio file and marks `audioDeletedAt`, keeping transcript and speaker data (same operation as "Delete Audio" in the app). Idempotent. Not allowed while `state` is `recording` or `analyzing` (`409 wrong_state`). Response `200` with the Recording.

### `DELETE /v1/recordings/{id}?confirm=true`

Deletes audio, transcript files and the row. Without `confirm=true`: `422 validation_failed`.

### `POST /v1/transcriptions`

Upload audio for diarization and transcription (for example audio recorded elsewhere).

- Body: the raw audio bytes. `Content-Type`: `audio/wav`, `audio/x-wav`, `audio/mpeg`, `audio/mp4`, `audio/x-m4a`, or `application/octet-stream` (sniffed). The file is streamed to disk, never held in memory.
- Query: `title`, `language` (`auto|de|en`), `clientRef`, `startedAt` (ISO or epoch ms; when the audio was *recorded*, becomes `clock.audioStartedAt` with source `client`), `deleteAudioWhenDone` (bool).
- Response `202` with the Recording (`state: "analyzing"`). Errors: `413 payload_too_large`, `415 unsupported_media_type`.

The file is stored in `<archive>/recordings/` like any other recording.

### `GET /v1/speakers`

```json
{
  "speakers": [
    { "id": "spk_a1", "label": "Sam", "notes": null, "segmentCount": 640, "speechSec": 5400.1,
      "recordingCount": 7, "createdAt": "2026-10-01T19:02:11.000Z" }
  ]
}
```

### `PATCH /v1/speakers/{id}`

Request: `{ "label": "Sam", "notes": "table left" }`. Either field may be `null` to clear it. Labels are global: they apply to every recording that contains this speaker. Response `200` with the Speaker.

### `POST /v1/speakers/{id}/merge`

Request: `{ "into": "spk_c3" }`. Moves all voice embeddings and segments of `{id}` into `into` and deletes `{id}`. Response `200` with the surviving Speaker. `422` if the ids are equal; `404` if either is unknown.

---

## Events (SSE)

`GET /v1/events` returns `Content-Type: text/event-stream` and stays open. Consume it with `fetch()` and a stream reader and send `Authorization`. The server sends a `: ping` comment every 15 seconds. When the connection drops, reconnect; the first event is always a `snapshot`.

```
event: snapshot
data: {"serverTime":1731607392123,"recording":{...Recording or null}}

event: levels
data: {"recordingId":"rec_9f1c","t":1731607400123,"mic":0.42,"system":null}

event: state
data: {"recording":{...Recording}}

event: progress
data: {"recordingId":"rec_9f1c","t":1731610100000,"step":"Transcribing segments 120/412","fraction":0.29}

event: ready
data: {"recordingId":"rec_9f1c","state":"done","segmentCount":412}

event: error
data: {"recordingId":"rec_9f1c","error":{"code":"internal","message":"..."}}
```

| Event | When | Notes |
| --- | --- | --- |
| `snapshot` | on connect | Current recording (or `null`). |
| `levels` | about 10 per second while a recording is running | Values 0..1, smoothed, perceptual scale. `null` for a source that is not captured. |
| `state` | every state transition | |
| `progress` | during analysis, throttled to about one per second | `step` is human readable (English); `fraction` is `null` when the pipeline cannot tell. |
| `ready` | analysis finished (`done` or `empty`) | Fetch the transcript next. |
| `error` | recording or analysis failed | The recording also moves to `state: "failed"` with `errorMessage`. |

Events carry no transcript text and no audio.

---

## Schemas

### Recording

```json
{
  "id": "rec_9f1c2a",
  "title": "Team sync",
  "state": "recording",
  "language": "de",
  "sources": ["mic"],
  "clientRef": "my-app#sitting-3#1731607392000",
  "transcribe": "onStop",
  "createdAt": "2026-11-14T18:59:58.000Z",
  "stoppedAt": null,
  "durationSec": 0,
  "hasAudio": true,
  "audioDeletedAt": null,
  "deleteAudioWhenDone": false,
  "errorMessage": null,
  "progress": null,
  "clock": {
    "audioStartedAt": "2026-11-14T19:00:01.214Z",
    "audioStartedAtMs": 1731610801214,
    "audioStartedAtSource": "recorder",
    "syncPoints": [ { "wallMs": 1731610831230, "audioSec": 30.01 } ]
  }
}
```

| Field | Notes |
| --- | --- |
| `state` | `recording`, `stopped` (capture over, analysis not started, only with `transcribe: "manual"`), `analyzing`, `done`, `empty` (no speech found), `failed`. Maps to the app's processing states; `stopped` is derived. |
| `durationSec` | Live elapsed audio while recording; final audio duration afterwards. |
| `progress` | `{ "step": string, "fraction": number or null, "t": epoch ms }` during analysis, else `null`. |
| `clock` | See [Time and clocks](#time-and-clocks). `syncPoints` only in single-recording and transcript responses. |

### Speaker

`{ id, label, notes, segmentCount, speechSec, recordingCount, createdAt }` as in `GET /v1/speakers`. `label` and `notes` may be `null`.

### Common field limits

| Field | Limit |
| --- | --- |
| `title` | 200 characters |
| `clientRef` | 200 characters |
| `label` | 100 characters |
| `notes` | 2000 characters |
| `clientName` | 60 characters |

---

## Time and clocks

Companion apps usually need to line the transcript up with events on **their own** timeline (a call agenda, a log, a game session). The transcript's own `start`/`end` are seconds from the start of the audio, and `createdAt` is when the database row was created, which is a moment *before* capture starts and has no sub-second precision. Neither is good enough on its own.

The server therefore records a `clock` per recording it captures:

- `audioStartedAt` / `audioStartedAtMs`: the wall-clock time at which audio position 0 was captured. It is determined right after the recorder has started by reading the number of samples already received and subtracting that from the current time. Precision is a few tens of milliseconds.
- `audioStartedAtSource`: `recorder` (measured as above), `client` (given in an upload as `startedAt`), or `createdAt` (a recording that was not captured through this server, such as one made in the app; only coarse, can be off by a second or more).
- `syncPoints`: the server samples `(wallMs, audioSec)` pairs about every 30 seconds while recording. A client maps an audio position to wall-clock time by linear interpolation between the neighbouring points, which absorbs microphone recoveries and similar gaps. With fewer than two points, use `audioStartedAtMs + audioSec * 1000`.

All wall-clock values use the macOS system clock; a client on the same machine sees the same clock. If `durationSec` is clearly shorter than `stoppedAt - audioStartedAt` the Mac probably slept during recording; clients should warn.

---

## Limits and operational notes

- One recording at a time. The check is cross-process (it looks at the database), so it also refuses while the app or CLI is recording.
- The server serialises analyses (one at a time, like the MCP server); starting several uploads queues them.
- Microphone permission belongs to the process that runs `diarize serve` (for example Terminal). The first start shows the macOS prompt; if it was denied, `capture_failed` explains where to enable it.
- Restarting the server does not lose anything: recording rows and sidecar clock data live in the archive. A recording left in `recording` state after a crash shows up under `capabilities.orphans`.
- Sidecar data (client reference, clock, options) is stored as `<archive>/serve/<recordingId>.json` and does not touch the database schema.
- The API is not meant to be exposed beyond the machine. There is no TLS and no LAN mode.

---

## Conformance table

Reference cases for implementers and for the test suites (`H` = `Host`, `O` = `Origin`, `T` = valid token).

| # | Request | Expected |
| --- | --- | --- |
| 1 | `GET /v1/health`, H ok, no O | 200 |
| 2 | `GET /v1/health`, H `evil.test` | 403 `invalid_host` |
| 3 | `GET /v1/health`, O allowed | 200 with `Access-Control-Allow-Origin: <O>`, `Vary: Origin` |
| 4 | `GET /v1/health`, O not allowed | 403 `forbidden_origin`, no CORS headers |
| 5 | `GET /v1/health`, `Origin: null` | 403 `forbidden_origin` |
| 6 | `OPTIONS /v1/recordings`, O allowed, `Access-Control-Request-Method: POST` | 204 with the preflight headers above, no PNA header |
| 7 | as 6 plus `Access-Control-Request-Private-Network: true` | 204 plus `Access-Control-Allow-Private-Network: true` |
| 8 | as 6, O not allowed | 403, no CORS headers |
| 9 | `GET /v1/capabilities`, no token | 401 `unauthorized` |
| 10 | `GET /v1/capabilities`, T for origin A, O = B (also allowed) | 403 `forbidden_origin` |
| 11 | `POST /v1/pair` right code | 200, token; the same code again: 403 `pairing_code_invalid` |
| 12 | `POST /v1/pair` wrong code x5 | 403 x4, then 429 `pairing_rate_limited` with `Retry-After` |
| 13 | `POST /v1/recordings` while one runs | 409 `conflict_recording_active` |
| 14 | `GET .../transcript` while `analyzing` | 409 `not_ready` |
| 15 | `POST /v1/recordings` body of 70 KiB | 413 `payload_too_large` |
