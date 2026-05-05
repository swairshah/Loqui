# Loqui Agent Extensions

Repo-local extensions for making coding agents speak `<voice>` tagged output through Loqui.

These commands do not install global plugins, mutate `~/.codex/hooks.json`, or register MCP servers.

## Codex

The Codex hook extension lives in `Extensions/codex-talk`.

Run Codex with a repo-local `CODEX_HOME`:

```sh
./Extensions/run-codex-local.sh
```

The launcher prepares `Extensions/.local/codex-home` with:

- `config.toml` enabling `codex_hooks`
- `hooks.json` pointing at the local Codex Talk hook scripts
- local voice instructions in `Extensions/AGENTS.md` and the isolated Codex home
- a symlink to `~/.codex/auth.json` when present, so the isolated home can reuse auth without copying secrets

To avoid auth reuse and log in separately:

```sh
LOQUI_CODEX_REUSE_AUTH=0 ./Extensions/codex-talk/scripts/prepare-local-home.js
CODEX_HOME="$PWD/Extensions/.local/codex-home" codex login
CODEX_HOME="$PWD/Extensions/.local/codex-home" codex -C "$PWD/Extensions"
```

## Claude Code

The Claude plugin lives in `Extensions/claude-code-talk`.

Run with only this plugin:

```sh
./Extensions/run-claude-local.sh
```

By default the launcher does not use `--bare`, because Claude Code bare mode skips hooks and the Loqui speech plugin depends on hooks. It loads the local plugin with `--plugin-dir` and appends `Extensions/CLAUDE.md` explicitly.

```sh
./Extensions/run-claude-local.sh
```

The launcher runs from `Extensions/`. If you set `LOQUI_CLAUDE_BARE=1`, Claude will run in bare mode for prompt testing, but speech hooks will not fire.

## Pi

The Pi extension lives in `Extensions/pi-talk`.

Run Pi with extension discovery disabled and only this local extension loaded:

```sh
./Extensions/run-pi-local.sh
```

Equivalent direct command:

```sh
pi --no-extensions -e ./Extensions/pi-talk/index.ts
```

## Notes

- The Pi extension streams speech as assistant messages update.
- Claude Code hooks flush voice tags before and after tool use, then drain leftovers at turn end.
- Codex hooks drain new voice tags from the Codex transcript after tool use and at turn end.
- Loqui currently treats `stop` as a global queue clear. Prompt-start auto-stop is therefore opt-in for Codex and Claude via `LOQUI_CODEX_STOP_ON_PROMPT=1` or `LOQUI_CLAUDE_STOP_ON_PROMPT=1`.
