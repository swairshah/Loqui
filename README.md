# <img src="Resources/icons/app-icon.png" width="32" height="32" alt="Loqui icon" style="vertical-align: middle;"> Loqui

Loqui is a TTS server that gives a voice to any application on your Mac.
instead of every app bundling its own TTS solution we run one local TTS server and any application can talk to it. A CLI tool, a coding agent, a custom script—they all just POST some text to `localhost:18080` and Loqui speaks it. 

## Credits

- **[Pocket TTS](https://github.com/kyutai-labs/pocket-tts)** by Kyutai Labs - The original model. A small (~225MB), fast, high-quality TTS model that runs locally.
- **[pocket-tts](https://github.com/babybirdprd/pocket-tts)** by babybirdprd - A native Rust port using [Candle](https://github.com/huggingface/candle) for tensor operations. This is what Loqui uses under the hood.

Loqui wraps these into a macOS menubar app with a settings UI, bundles the model weights, and exposes a simple HTTP API that any application can use. It also runs a local broker queue (`127.0.0.1:18081`) for clients that want centralized playback and scheduling. Since we are not using the voice cloning model we don't need the user to sign up for the huggingface access. 

## Usecase

I wanted to give voice output to [Pi](https://github.com/badlogic/pi-coding-agent) (a coding agent). The assistant writes `<voice>` tags in its responses, and I wanted those spoken aloud. Cloud TTS APIs work but they add latency, cost money per request, and require API keys. Local TTS models exist but setting them up is annoying—you need to download models, set up Python environments, deal with HuggingFace tokens, etc.

Loqui bundles everything into a single macOS app. Install it, and any application on your Mac can use TTS with a simple HTTP call or the `ptts` CLI. The Pi extension is included as an example, but the real point is that Loqui is a general-purpose TTS server for your entire system.

## Usage

### CLI

The `ptts` command lets any application use TTS. By default it enqueues speech into Loqui's local broker queue (centralized playback):

```bash
ptts "Hello, world!"
ptts --voice alba "Good morning!"
echo "Text from a pipe" | ptts
ptts --list-voices
ptts --stop
```

### HTTP API

Any application can POST to the server:

```bash
# Stream audio (pipe to ffplay or any audio player)
curl -X POST http://127.0.0.1:18080/stream \
  -H "Content-Type: application/json" \
  -d '{"text":"Hello world","voice":"fantine"}' | \
  ffplay -f s16le -ar 24000 -ch_layout mono -nodisp -autoexit -i pipe:0

# Generate a WAV file
curl -X POST http://127.0.0.1:18080/generate \
  -H "Content-Type: application/json" \
  -d '{"text":"Hello world","voice":"fantine"}' \
  --output hello.wav
```

Endpoints:
- `GET /health` - Health check
- `POST /stream` - Streaming TTS (PCM s16le, 24kHz, mono)
- `POST /generate` - Generate complete audio (WAV)

### Local Broker Queue (NDJSON over TCP)

For centralized playback, clients can connect to `127.0.0.1:18081` and send one JSON object per line:

```json
{"type":"speak","text":"Hello","voice":"fantine","sourceApp":"pi","sessionId":"..."}
```

Other commands:
- `{"type":"health"}`
- `{"type":"stop"}`

### Voices

Seven voices are available: `fantine` (default), `alba`, `marius`, `cosette`, `eponine`, `azelma`, `javert`. You can change the default voice in the menubar settings.

### With Pi

The bundled Pi extension intercepts `<voice>` tags from the assistant and enqueues them to Loqui's local broker for centralized playback:

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

Requires Xcode command line tools and Rust.

```bash
./build-app.sh
```

The app ends up in `.build/Loqui.app`. The build script compiles the Rust TTS server, the Swift menubar app, and bundles the model weights.

## Architecture

```
┌─────────────────┐     ┌──────────────────┐     ┌─────────┐
│  Any App        │────▶│  Loqui.app       │────▶│ Audio   │
│  (HTTP/CLI)     │     │  (TTS server)    │     │ Output  │
└─────────────────┘     └──────────────────┘     └─────────┘
```

Loqui runs as a menubar app. It starts a local HTTP server on port 18080 and a local broker queue on port 18081. Applications can send text via HTTP/`ptts` for raw audio workflows, or use the broker for centralized playback and queueing.

## Troubleshooting

**TTS not working?**
1. Check Loqui is running (speaker icon in menubar)
2. Test: `curl http://127.0.0.1:18080/health`

**No audio?**
1. Check ffplay: `which ffplay`
2. Install if missing: `brew install ffmpeg`

## License

MIT
