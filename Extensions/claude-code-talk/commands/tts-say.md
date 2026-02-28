---
description: "Speak arbitrary text via Loqui TTS"
argument-hint: "<text to speak>"
allowed-tools: ["Bash"]
---

Speak the provided text using Loqui TTS:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tts-control.py" say $ARGUMENTS
```

Report the result briefly.
