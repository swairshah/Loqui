# Loqui Developer Guide

Loqui is a macOS menu bar TTS service. It exposes one local Unix socket API and a `loqui` CLI so other apps can share a single local speech queue.

For end-user installation and usage, see the root [README](../README.md).

## Building from Source

Requires macOS 14 or newer and Xcode command line tools.

```bash
./scripts/build-app.sh
```

The app bundle is written to:

```text
.build/Loqui.app
```

The release CLI binary is built as:

```text
.build/release/loqui-cli
```

Install the built app and copy the CLI into `bin/loqui`:

```bash
./scripts/install.sh
```

FluidAudio downloads PocketTTS CoreML model assets on first synthesis and caches them in Application Support.

## Project Layout

```text
Sources/Loqui/          macOS menu bar app
Sources/LoquiCLI/       command-line client
Sources/LoquiClient/    shared Swift socket client
Extensions/pi-talk/     Pi extension
Extensions/claude-code-talk/
docs/IPC.md             local socket protocol
docs/RELEASE.md         release workflow
scripts/build-app.sh    local app build
scripts/release.sh      signed/notarized release build
```

## Architecture

```text
Any App or CLI -> Loqui.app -> Audio Output
```

Loqui starts a local Unix socket listener at:

```text
~/Library/Application Support/Loqui/loqui.sock
```

The socket protocol is NDJSON over a Unix domain socket: clients send one JSON object per line and receive one JSON response line.

Primary request types:

- `speak`: enqueue speech into Loqui's centralized playback broker
- `stop`: stop current speech and clear active playback
- `health`: check broker status
- `voices`: list voices
- `raw`: synthesize raw PCM audio
- `generate`: synthesize WAV audio

See [IPC.md](IPC.md) for the request and response schema.

## Queueing Model

Broker playback groups requests by `sourceApp + sessionId`. Each queue is FIFO, and Loqui schedules active queues in round-robin order so one client does not monopolize playback.

If a `speak` request omits `voice`, Loqui assigns a stable per-queue voice from its available voices. If the client provides a voice, Loqui uses it directly.

## CLI Examples

```bash
loqui say "Hello, world!"
loqui say -v alba "Good morning"
loqui say -S session-123 "Scoped to a session queue"
echo "Long text from stdin" | loqui say
loqui raw "Hello" > audio.pcm
loqui generate "Hello" > audio.wav
loqui voices
loqui status
loqui stop
```

## Integrations

The Pi extension extracts `<voice>` tagged content from assistant responses and sends it to Loqui with `sourceApp`, `sessionId`, and `pid` metadata.

The Claude Code plugin also extracts `<voice>` content, but Claude Code hooks only run after the full response completes. Speech therefore starts after each response rather than streaming while Claude writes.

## Releases

Release notes and commands live in [RELEASE.md](RELEASE.md).

```bash
./scripts/release.sh <version>
```
