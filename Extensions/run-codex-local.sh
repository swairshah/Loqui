#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODEX_CWD="${LOQUI_CODEX_CWD:-$SCRIPT_DIR}"
CODEX_HOME_LOCAL="${LOQUI_CODEX_HOME:-$SCRIPT_DIR/.local/codex-home}"

LOQUI_CODEX_HOME="$CODEX_HOME_LOCAL" node "$SCRIPT_DIR/codex-talk/scripts/prepare-local-home.js" >/dev/null

exec env CODEX_HOME="$CODEX_HOME_LOCAL" codex -C "$CODEX_CWD" "$@"
