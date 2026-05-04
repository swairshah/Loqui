---
description: "Change Claude Talk voice (auto, alba, vera, paul, charles, michael, anna, fantine, eponine, cosette, eve, george, mary, marius, javert, azelma, caro_davy, peter_yearsley, stuart_bell)"
argument-hint: "[voice-name]"
allowed-tools: ["Bash"]
---

Change or show the current TTS voice:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tts-control.py" voice $ARGUMENTS
```

Show the result to the user.
