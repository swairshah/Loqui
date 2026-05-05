#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec pi --no-extensions -e "$SCRIPT_DIR/pi-talk/index.ts" "$@"
