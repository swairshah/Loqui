#!/usr/bin/env python3
"""
Stop hook: Reads the transcript, extracts <voice> tags from the last assistant
message, and sends them to the Loqui broker for TTS playback.
"""

import json
import os
import re
import socket
import sys
import time
from datetime import datetime

LOQUI_SOCKET = os.path.expanduser("~/Library/Application Support/Loqui/loqui.sock")
STATE_FILE = "/tmp/loqui-tts-state.json"
DEBUG_LOG = "/tmp/loqui-tts-debug.log"

# Track what we've already spoken to avoid re-speaking on resume/compact
SPOKEN_FILE = "/tmp/loqui-tts-spoken.json"


def debug(msg):
    try:
        with open(DEBUG_LOG, "a") as f:
            f.write(f"[{datetime.now().strftime('%H:%M:%S.%f')[:-3]}] {msg}\n")
    except:
        pass


def load_state():
    try:
        with open(STATE_FILE, "r") as f:
            return json.load(f)
    except Exception:
        return {"enabled": True, "voice": "vera"}


def load_spoken():
    """Load set of already-spoken message UUIDs."""
    try:
        with open(SPOKEN_FILE, "r") as f:
            return set(json.load(f))
    except Exception:
        return set()


def save_spoken(spoken):
    try:
        with open(SPOKEN_FILE, "w") as f:
            json.dump(list(spoken), f)
    except Exception:
        pass


def send_to_broker(text, voice="auto", session_id="unknown", pid=None):
    """Send a speak command to the Loqui broker via Unix socket NDJSON."""
    try:
        command = {
            "type": "speak",
            "text": text,
            "sourceApp": "claude-code",
            "sessionId": session_id,
        }
        if voice and voice != "auto":
            command["voice"] = voice
        if pid:
            command["pid"] = pid

        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(3)
        sock.connect(LOQUI_SOCKET)
        sock.sendall(json.dumps(command).encode() + b"\n")

        # Read response
        data = b""
        while b"\n" not in data:
            chunk = sock.recv(1024)
            if not chunk:
                break
            data += chunk
        sock.close()

        resp = json.loads(data.decode().strip())
        return resp.get("ok", False)
    except Exception:
        return False


def extract_voice_tags(text):
    """Extract all <voice>...</voice> content from text."""
    pattern = re.compile(r"<voice>(.*?)</voice>", re.DOTALL)
    matches = pattern.findall(text)
    # Strip any accidental nested markup
    cleaned = []
    for m in matches:
        clean = re.sub(r"<[^>]+>", " ", m).strip()
        clean = re.sub(r"\s+", " ", clean)
        if clean:
            cleaned.append(clean)
    return cleaned


def get_last_assistant_messages(transcript_path):
    """Read the transcript and get the last assistant message(s)."""
    if not transcript_path or not os.path.exists(transcript_path):
        return []

    messages = []
    try:
        with open(transcript_path, "r") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                    if obj.get("type") == "assistant":
                        messages.append(obj)
                except json.JSONDecodeError:
                    continue
    except Exception:
        return []

    return messages


def main():
    debug("=== speak-response.py START ===")

    # Read hook input
    try:
        input_data = json.loads(sys.stdin.read())
    except Exception:
        input_data = {}

    debug(f"input keys: {list(input_data.keys())}")

    state = load_state()

    # Check if TTS is enabled
    if not state.get("enabled", True):
        debug("TTS disabled, exiting")
        sys.exit(0)

    # Skip stop-hook continuations to avoid duplicate speech
    if input_data.get("stop_hook_active"):
        debug("stop_hook_active=True, skipping")
        sys.exit(0)

    session_id = state.get("session_id", input_data.get("session_id", "unknown"))
    voice = state.get("voice", "auto")
    pid = state.get("claude_pid", os.getpid())
    transcript_path = input_data.get("transcript_path", "")

    # Prefer last_assistant_message — it's exactly the message that triggered this Stop hook,
    # so there's no replay-history risk and no transcript-flush race.
    last_msg = input_data.get("last_assistant_message")
    full_text = ""

    if isinstance(last_msg, str) and last_msg.strip():
        full_text = last_msg
        debug(f"using last_assistant_message (str, {len(full_text)} chars)")
    elif isinstance(last_msg, dict):
        content = last_msg.get("content")
        if content is None:
            content = last_msg.get("message", {}).get("content", "")
        if isinstance(content, list):
            full_text = " ".join(
                p.get("text", "") for p in content
                if isinstance(p, dict) and p.get("type") == "text"
            )
        elif isinstance(content, str):
            full_text = content
        debug(f"using last_assistant_message (dict, {len(full_text)} chars)")
    else:
        # Fallback: poll the transcript for the latest assistant message.
        debug("no last_assistant_message; falling back to transcript")
        for attempt in range(8):
            messages = get_last_assistant_messages(transcript_path)
            if messages:
                content = messages[-1].get("message", {}).get("content", "")
                if isinstance(content, list):
                    full_text = " ".join(
                        p.get("text", "") for p in content
                        if isinstance(p, dict) and p.get("type") == "text"
                    )
                elif isinstance(content, str):
                    full_text = content
                if full_text:
                    break
            time.sleep(0.15 if attempt < 3 else 0.3)

    if not full_text:
        debug("no text to speak")
        sys.exit(0)

    voice_chunks = extract_voice_tags(full_text)
    debug(f"{len(voice_chunks)} voice chunks")

    for chunk in voice_chunks:
        ok = send_to_broker(chunk, voice=voice, session_id=session_id, pid=pid)
        debug(f"  sent '{chunk[:60]}' ok={ok}")

    print(json.dumps({"spoken": len(voice_chunks)}))
    sys.exit(0)


if __name__ == "__main__":
    main()
