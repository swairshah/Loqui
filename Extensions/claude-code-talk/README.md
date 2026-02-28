# loqui-tts — Claude Code Plugin

Text-to-speech for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) using [Loqui](https://github.com/swairshah/Loqui). Speaks `<voice>` tagged content from assistant responses.

## How it works

1. **SessionStart hook** injects a voice prompt teaching Claude to use `<voice>` tags
2. **Stop hook** (async) fires after each response — reads the transcript, extracts `<voice>` tags, sends speech to the Loqui broker
3. **Slash commands** for manual control: `/tts`, `/tts-stop`, `/tts-say`, `/tts-voice`, `/tts-status`

### Limitation vs Pi extension

Unlike the [Pi extension](../pi-talk/) which streams speech in real-time as the response is generated, Claude Code's hook system only fires after the full response completes. Speech plays after the response, not during streaming. This is a fundamental limitation of Claude Code's plugin architecture (no `message_update` or streaming delta hook exists).

## Requirements

**Loqui.app** must be installed and running:

```bash
brew install swairshah/tap/loqui
```

## Installation

### From local directory

```bash
claude plugin install ./Extensions/claude-code-talk
```

### Manual setup

Copy the plugin to `~/.claude/plugins/` or point to it with `--plugin-dir`:

```bash
claude --plugin-dir ./Extensions/claude-code-talk
```

## Commands

| Command | Description |
|---------|-------------|
| `/loqui-tts:tts` | Toggle TTS on/off |
| `/loqui-tts:tts-stop` | Stop current speech |
| `/loqui-tts:tts-say <text>` | Speak arbitrary text |
| `/loqui-tts:tts-voice [name]` | Change/show voice |
| `/loqui-tts:tts-status` | Show TTS status |

### Available voices

`auto` (default), `alba`, `marius`, `javert`, `fantine`, `cosette`, `eponine`, `azelma`

## Architecture

```
claude-code-talk/
├── .claude-plugin/
│   └── plugin.json              # Plugin manifest
├── hooks/
│   └── hooks.json               # SessionStart + Stop hooks
├── scripts/
│   ├── session-start.py         # Injects voice prompt, checks broker health
│   ├── speak-response.py        # Reads transcript, extracts <voice> tags, sends to broker
│   └── tts-control.py           # CLI for stop/say/toggle/voice/status
├── commands/
│   ├── tts.md                   # Toggle TTS
│   ├── tts-stop.md              # Stop speech
│   ├── tts-say.md               # Speak text
│   ├── tts-voice.md             # Change voice
│   └── tts-status.md            # Show status
└── skills/
    └── voice-awareness.md       # Background skill for TTS awareness
```

### State management

State is persisted to `/tmp/loqui-tts-state.json` (enabled, voice, session ID, server health). A separate `/tmp/loqui-tts-spoken.json` tracks already-spoken message UUIDs to avoid re-speaking on session resume or compaction.

### Broker protocol

NDJSON over TCP on port 18081. Same protocol as the Pi extension:
- `{"type": "speak", "text": "...", "sourceApp": "claude-code", "sessionId": "..."}`
- `{"type": "stop"}`
- `{"type": "health"}`

## License

MIT
