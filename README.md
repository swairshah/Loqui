# <img src="Resources/icons/app-icon.png" width="32" height="32" alt="Loqui icon" style="vertical-align: middle;"> Loqui

Loqui is a TTS server that gives a voice to any application on your Mac.
Instead of every app bundling its own TTS solution, Loqui runs one local TTS service and any application can talk to it through a Unix domain socket or the `loqui` CLI.

## Credits

- **[Pocket TTS](https://github.com/kyutai-labs/pocket-tts)** by Kyutai Labs - The original model. A small (~225MB), fast, high-quality TTS model that runs locally.
- **[FluidAudio](https://github.com/FluidInference/FluidAudio)** by Fluid Inference - Native Swift/CoreML PocketTTS inference for Apple platforms. This is what Loqui uses under the hood.

Loqui wraps these into a macOS menubar app with a settings UI and exposes local Unix socket APIs for direct synthesis and centralized playback. FluidAudio downloads the CoreML PocketTTS assets on first synthesis and caches them locally.

## Usecase

I wanted to give voice output to [Pi](https://github.com/badlogic/pi-coding-agent) (a coding agent). The assistant writes `<voice>` tags in its responses, and I wanted those spoken aloud. Cloud TTS APIs work but they add latency, cost money per request, and require API keys. Local TTS models exist but setting them up is annoying—you need to download models, set up Python environments, deal with HuggingFace tokens, etc.

Loqui bundles everything into a single macOS app. Install it, and any application on your Mac can use TTS with the `loqui` CLI or the local socket protocol. The Pi extension is included as an example, but the real point is that Loqui is a general-purpose TTS service for your entire system.

## Usage

### CLI

The `loqui` command lets any application use TTS. By default it enqueues speech into Loqui's local broker queue (centralized playback):

```bash
loqui say "Hello, world!"
loqui say --voice alba "Good morning!"
loqui say --session-id my-session-123 "Scoped to one session queue"
echo "Text from a pipe" | loqui say
loqui voices
loqui stop
```

### Local API

Loqui exposes one Unix domain socket:

- `~/Library/Application Support/Loqui/loqui.sock` - NDJSON API for speech, stop, health, voices, and direct synthesis.

### Local Broker Queue (NDJSON over Unix Socket)

For centralized playback, clients connect to `~/Library/Application Support/Loqui/loqui.sock` and send one JSON object per line.

Request examples:

```json
{"type":"speak","text":"Hello","voice":"fantine","sourceApp":"pi","sessionId":"session-abc","pid":12345}
{"type":"raw","text":"Hello","voice":"fantine"}
{"type":"generate","text":"Hello","voice":"fantine"}
{"type":"voices"}
{"type":"health"}
{"type":"stop"}
```

`type: "speak"` fields:
- `text` (required)
- `voice` (optional)
- `sourceApp` (optional)
- `sessionId` (optional)
- `pid` (optional)

Response fields (depending on command):
- `ok`
- `queued`
- `pending`
- `playing`
- `currentQueue`
- `voices`
- `audioBase64`
- `contentType`
- `error`

Queueing behavior:
- Requests are grouped by queue key: `sourceApp + sessionId`
- Missing session IDs are grouped into one shared session bucket
- Scheduler processes queues fairly in round-robin order
- If `voice` is omitted, Loqui auto-assigns per-queue voices from:
  - `fantine`, `alba`, `cosette`, `marius`, `azelma`
  - If more than 5 active queues, assignment cycles

Detailed IPC notes: `docs/IPC.md`

### Voices

Seven voices are available: `fantine` (default), `alba`, `marius`, `cosette`, `eponine`, `azelma`, `javert`. You can change the default voice in the menubar settings.

### Microphone-aware playback

Loqui is microphone-aware when using broker playback:
- If the microphone becomes active while Loqui is speaking, current playback is interrupted and already-queued items are cancelled.
- If the microphone is already active before playback starts, queued items wait and resume after microphone activity ends.

### With Pi

The bundled Pi extension intercepts `<voice>` tags from the assistant and enqueues them to Loqui's local broker for centralized playback. It sends `sourceApp`, `sessionId`, and `pid` metadata so Loqui can isolate per-session queues:

```
<voice>Found the bug. It was an off-by-one error in the loop.</voice>
```

Commands in Pi:
- `/tts` - Toggle TTS on/off
- `/tts-mute` - Mute audio (keeps voice tags in responses)
- `/tts-say <text>` - Speak arbitrary text
- `/tts-stop` - Stop current speech

Global shortcut: **Cmd+.** stops speech system-wide.

## Building from Source

Requires macOS 14 or newer and Xcode command line tools.

```bash
./scripts/build-app.sh
```

The app ends up in `.build/Loqui.app`. The build script compiles the Swift menubar app and the `loqui` CLI. FluidAudio downloads PocketTTS CoreML models on first synthesis.

## Architecture

```
┌─────────────────┐     ┌──────────────────┐     ┌─────────┐
│  Any App        │────▶│  Loqui.app       │────▶│ Audio   │
│  (Socket/CLI)   │     │  (TTS service)   │     │ Output  │
└─────────────────┘     └──────────────────┘     └─────────┘
```

Loqui runs as a menubar app. It starts a local Unix socket listener at `~/Library/Application Support/Loqui/loqui.sock`.

- `speak` is the IPC path for centralized queueing, scheduling, and playback.
- `raw` and `generate` are for direct audio synthesis workflows.

## Troubleshooting

**TTS not working?**
1. Check Loqui is running (speaker icon in menubar)
2. Test: `loqui status`

**No audio?**
1. Check ffplay: `which ffplay`
2. Install if missing: `brew install ffmpeg`

## License

MIT
