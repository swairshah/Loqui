# <img src="Resources/icons/app-icon.png" width="32" height="32" alt="Loqui icon" style="vertical-align: middle;"> Loqui

Loqui gives your Mac a local voice service. Keep Loqui running in the menu bar, then use it from Terminal, Pi, Claude Code, or any app that knows how to send text to Loqui.

Loqui runs on-device using PocketTTS through FluidAudio, so speech does not require cloud TTS APIs, API keys, or per-request fees. The first speech request may take longer while model assets are downloaded and cached locally.

## Requirements

- macOS 14 or newer
- Apple Silicon Mac recommended
- Homebrew for the easiest install

## Install Loqui

```bash
brew install swairshah/tap/loqui
```

Then open **Loqui** from Applications. It runs as a menu bar app.

To confirm it is running:

```bash
loqui status
```

## Speak from Terminal

```bash
loqui say "Hello, world!"
loqui say --voice alba "Good morning!"
echo "Text from a pipe" | loqui say
loqui voices
loqui stop
```

Available voices:

`fantine`, `alba`, `marius`, `cosette`, `eponine`, `azelma`, `javert`

You can also change the default voice in Loqui's menu bar settings.

## Use with Pi

Install the Pi extension:

```bash
pi install npm:@swairshah/pi-talk
```

Restart Pi if needed. Once installed, Pi can speak short `<voice>` summaries from assistant responses through Loqui.

Pi commands:

| Command | Description |
| --- | --- |
| `/tts` | Toggle TTS on or off |
| `/tts-mute` | Mute audio while keeping voice tags |
| `/tts-voice <name>` | Change voice |
| `/tts-style` | Toggle succinct or verbose voice prompts |
| `/tts-say <text>` | Speak text manually |
| `/tts-stop` | Stop current speech |
| `/tts-status` | Show TTS status |

## Use with Claude Code

Loqui also includes a Claude Code plugin in `Extensions/claude-code-talk`.

From this repository:

```bash
claude plugin install ./Extensions/claude-code-talk
```

Claude Code speaks after each response completes because Claude Code hooks run after the full assistant message is available.

## Stop Speech

Use any of these:

```bash
loqui stop
```

- Press **Cmd+.** anywhere on macOS.
- Click stop in the Loqui menu bar app.
- Use `/tts-stop` in Pi or `/claude-talk:tts-stop` in Claude Code.

## Microphone-Aware Playback

Loqui watches whether the default microphone is active. If your microphone becomes active while Loqui is speaking, current speech stops and queued speech is cleared. If the microphone is already active, queued speech waits until microphone activity ends.

Loqui detects microphone activity through CoreAudio device state; it does not capture microphone audio.

## Troubleshooting

**Loqui is not speaking**

1. Check that Loqui is running in the menu bar.
2. Run `loqui status`.
3. Try `loqui say "Testing Loqui"`.
4. Check your macOS output device and volume.

**The first request is slow**

The model may still be downloading and caching. Try again after the first synthesis finishes.

**Pi or Claude Code is not speaking**

1. Make sure Loqui is running.
2. Test `loqui say "Testing"` from Terminal.
3. Check the extension status command: `/tts-status` in Pi or `/claude-talk:tts-status` in Claude Code.

## Developer Docs

- [Developer guide](docs/DEVELOPMENT.md)
- [IPC protocol](docs/IPC.md)
- [Release process](docs/RELEASE.md)

## Credits

- [Pocket TTS](https://github.com/kyutai-labs/pocket-tts) by Kyutai Labs
- [FluidAudio](https://github.com/FluidInference/FluidAudio) by Fluid Inference

## License

MIT
