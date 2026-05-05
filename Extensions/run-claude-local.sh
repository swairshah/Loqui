#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$SCRIPT_DIR/claude-code-talk"
LOCAL_CONTEXT="$SCRIPT_DIR/CLAUDE.md"

cd "$SCRIPT_DIR"

if [[ "${LOQUI_CLAUDE_BARE:-0}" == "1" ]]; then
  exec claude --bare --plugin-dir "$PLUGIN_DIR" --append-system-prompt "$(cat "$LOCAL_CONTEXT")" "$@"
fi

exec claude --plugin-dir "$PLUGIN_DIR" --append-system-prompt "$(cat "$LOCAL_CONTEXT")" "$@"
