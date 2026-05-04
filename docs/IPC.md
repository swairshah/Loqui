# Loqui IPC Design

Loqui exposes a single local API socket:

- Address: `~/Library/Application Support/Loqui/loqui.sock`
- Protocol: NDJSON over Unix domain socket (one JSON object per line)

## Commands

### speak

```json
{"type":"speak","text":"Hello","voice":"fantine","sourceApp":"pi","sessionId":"abc","pid":12345}
```

Fields:
- `text` (required)
- `voice` (optional)
- `sourceApp` (optional)
- `sessionId` (optional)
- `pid` (optional)

### health

```json
{"type":"health"}
```

### stop

```json
{"type":"stop"}
```

### voices

```json
{"type":"voices"}
```

### raw

Returns raw PCM audio as base64 in `audioBase64`.

```json
{"type":"raw","text":"Hello","voice":"fantine"}
```

### generate

Returns WAV audio as base64 in `audioBase64`.

```json
{"type":"generate","text":"Hello","voice":"fantine"}
```

## Response shape

Responses are JSON lines and can include:
- `ok`
- `queued`
- `pending`
- `playing`
- `currentQueue`
- `voices`
- `audioBase64`
- `contentType`
- `error`

## Queue model

Queue key is:

`sourceApp + sessionId`

Rules:
- Missing session IDs are normalized to a shared `none` session.
- Each queue key has its own FIFO queue.
- Scheduler runs queues fairly in round-robin order.

## Voice assignment behavior

If `voice` is omitted in `speak`:
- Loqui assigns a stable per-queue voice from Tier 1 first:
  - `vera`, `paul`, `charles`, `michael`, `anna`, `fantine`, `eponine`
- If Tier 1 voices are occupied, Loqui assigns from Tier 2:
  - `cosette`, `eve`, `george`, `mary`
- Assignment order is lightly randomized, but a continued app/session keeps its assigned voice.
- If all automatic voices are occupied, assignment cycles through Tier 1 and Tier 2 again.
- Reading voices are explicit-only and are not used for automatic assignment:
  - `caro_davy`, `peter_yearsley`, `stuart_bell`

If `voice` is provided, it is used directly.

## Microphone-aware behavior

When microphone activity is detected:
- If Loqui is already speaking: current item is interrupted and queued items are cancelled.
- If Loqui is not speaking yet: queued playback waits until microphone activity ends.

Detection is done via CoreAudio device-running state for the default input device (no audio capture by Loqui).
