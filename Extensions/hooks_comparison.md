# Hooks comparison for Loqui-style agent extensions

This document compares how the local Loqui voice extensions integrate with Claude Code, Codex, and Pi. The goal for all three harnesses is the same: teach the agent to emit `<voice>...</voice>` tags, extract those tagged chunks, and send them to Loqui for text-to-speech playback.

## Hook system comparison

| Dimension | Claude Code | Codex | Pi |
|---|---|---|---|
| Hook definition | `hooks/hooks.json` | `hooks/hooks.json` / generated `CODEX_HOME/hooks.json` | TypeScript `pi.on(...)` |
| Hook execution | External Python commands | External Node commands | Same-process async handlers |
| State | External temp JSON files | Extension `.state` files | Mostly in-memory |
| Prompt injection | Hook stdout `additionalContext` | `AGENTS.md` in this setup | Return modified `systemPrompt` |
| Streaming access | No token-level message update | No token-level message update here | Yes, via `message_update` |
| Transcript usage | Reads Claude transcript | Reads Codex transcript | Does not need transcript for speech |
| Tool lifecycle | `PreToolUse`, `PostToolUse` | `PostToolUse` only here | Rich tool events available, though this extension uses message events mostly |
| UI integration | Limited hook output / CLI commands | Limited status messages in hook config | Direct `ctx.ui` notify/status/widgets |
| Commands | Markdown command files | Not implemented as extension commands here | Programmatic `registerCommand` |
| Cleanup | `SessionEnd` hook script | No cleanup hook here | `session_shutdown` event |

## Recommended extension approach by harness

### Claude Code

For Claude Code, build the extension as a plugin with declarative hooks and external scripts.

A practical approach is:

1. Create a Claude plugin directory with a `.claude-plugin/plugin.json` manifest.
2. Add `hooks/hooks.json` that maps Claude lifecycle events to command hooks.
3. Use `SessionStart` to inject voice instructions by printing hook JSON with `hookSpecificOutput.additionalContext`.
4. Use `PreToolUse`, `PostToolUse`, and `Stop` hooks to read the transcript, extract closed `<voice>...</voice>` tags, and send new chunks to Loqui.
5. Store dedupe and configuration state outside the hook process, for example in `/tmp` JSON files, because each hook runs as a separate subprocess.
6. Add Claude slash commands as markdown command files for controls such as toggling TTS, changing voices, stopping speech, or checking status.
7. Use `SessionEnd` for cleanup, such as killing background watchers or removing temporary inbox directories.

This works well for lifecycle-based integrations. The main limitation is that Claude hooks do not provide true token-by-token assistant streaming, so real-time speech has to be approximated by flushing around tool calls and at response end.

### Codex

For Codex, build the extension as a local hook configuration plus small command scripts.

A practical approach is:

1. Enable Codex hooks in `config.toml` with the `codex_hooks` feature flag.
2. Write a `hooks.json` file under the active `CODEX_HOME` that maps lifecycle events to command hooks.
3. Use a setup script to prepare an isolated local `CODEX_HOME` when you want repo-local behavior without mutating the user’s global Codex config.
4. Put agent-facing voice instructions in `AGENTS.md`, or another Codex-loaded context file, so the model knows to emit `<voice>...</voice>` tags.
5. Use `PostToolUse` and `Stop` hooks to inspect the Codex transcript and drain newly observed voice chunks.
6. Keep drain state in an extension-owned state directory, keyed by transcript path or session id, so repeated hook calls do not re-speak old chunks.
7. Keep hook scripts quiet and resilient: read JSON from stdin, perform best-effort Loqui calls, then return `{}` so TTS failures do not break the Codex turn.

This approach is lightweight and easy to run repo-locally. Like Claude, it is transcript/lifecycle-oriented rather than truly streaming, so speech is generally emitted after tool-use boundaries or after the assistant response ends.

### Pi

For Pi, build the extension as a native TypeScript module using the `ExtensionAPI`.

A practical approach is:

1. Create a TypeScript extension that exports `default function (pi: ExtensionAPI)`.
2. Register event handlers directly with `pi.on(...)` instead of declaring shell commands in JSON.
3. Use `before_agent_start` to append voice instructions directly to the system prompt.
4. Use `message_start`, `message_update`, and `message_end` to parse assistant output while it streams.
5. Maintain parser state in memory, including whether the stream is currently inside a `<voice>` tag and any buffered speech text.
6. Send speech chunks to Loqui as soon as useful boundaries appear, such as sentence endings, then flush any remainder at message end.
7. Use `ctx.ui` for native UI integration, including notifications and status indicators.
8. Register commands with `pi.registerCommand(...)` for controls such as `/tts`, `/tts-stop`, `/tts-voice`, and `/tts-status`.
9. Use `session_start`, `session_switch`, and `session_shutdown` for setup, session id tracking, inbox watchers, and cleanup.

This is the most direct approach for a real-time TTS extension because Pi exposes in-process lifecycle events and streaming assistant message updates. It avoids transcript polling for speech extraction and can keep most state in memory.

## Summary

Use command hooks and transcript draining for Claude Code and Codex. Use a native event-driven extension for Pi. If the extension needs immediate streaming behavior, Pi’s `message_update` event is the best fit. If the harness only exposes lifecycle hooks, design the extension around reliable transcript parsing, dedupe state, and safe best-effort external scripts.
