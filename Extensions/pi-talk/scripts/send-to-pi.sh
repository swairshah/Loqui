#!/bin/bash
set -euo pipefail

# Usage: ./scripts/send-to-pi.sh <pi-pid> <text> [deliverAs]
# Sends one message to an existing pi-talk inbox using an atomic temp-file-then-mv write.

PID="${1:-}"
TEXT="${2:-}"
DELIVER_AS="${3:-followUp}"

if [ -z "$PID" ] || [ -z "$TEXT" ]; then
    echo "Usage: $0 <pi-pid|πidPID> <text> [deliverAs]" >&2
    exit 1
fi

PID="${PID#πid}"

INBOX="$HOME/.pi/agent/pitalk-inbox/$PID"

if [ ! -d "$INBOX" ]; then
    echo "Error: inbox does not exist: $INBOX" >&2
    echo "The PID may be wrong, or pi-talk may not be running for that Pi session." >&2
    exit 1
fi

STAMP="$(date +%s)"
TMP="$INBOX/msg-$STAMP-$$.tmp"
FINAL="$INBOX/msg-$STAMP-$$.json"

TEXT_JSON="$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$TEXT")"
DELIVER_AS_JSON="$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$DELIVER_AS")"

printf '{"text":%s,"deliverAs":%s}\n' "$TEXT_JSON" "$DELIVER_AS_JSON" > "$TMP"
mv "$TMP" "$FINAL"

echo "Wrote $FINAL"
