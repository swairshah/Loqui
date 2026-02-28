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

TTS_HOST = "127.0.0.1"
BROKER_PORT = 18081
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
        return {"enabled": True, "voice": "auto"}


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
    """Send a speak command to the Loqui broker via TCP/NDJSON."""
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

        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(3)
        sock.connect((TTS_HOST, BROKER_PORT))
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

    # Check if server was healthy at session start
    if not state.get("server_ready", False):
        debug("Server not ready, exiting")
        sys.exit(0)

    session_id = state.get("session_id", input_data.get("session_id", "unknown"))
    voice = state.get("voice", "auto")
    transcript_path = input_data.get("transcript_path", "")

    debug(f"transcript: {transcript_path}")
    debug(f"session_id: {session_id}")

    # Load already-spoken messages
    spoken = load_spoken()
    debug(f"already spoken: {len(spoken)}")

    # Wait for the transcript to be written — Claude Code flushes AFTER the Stop hook fires.
    # Retry a few times with short delays to catch the new assistant message.
    assistant_messages = []
    new_messages = []
    for attempt in range(8):
        assistant_messages = get_last_assistant_messages(transcript_path)
        new_messages = [m for m in assistant_messages if m.get("uuid", "") not in spoken]
        if new_messages:
            debug(f"attempt {attempt}: found {len(new_messages)} new messages (total {len(assistant_messages)})")
            break
        delay = 0.15 if attempt < 3 else 0.3
        debug(f"attempt {attempt}: no new messages yet ({len(assistant_messages)} total), waiting {delay}s...")
        time.sleep(delay)

    debug(f"assistant messages found: {len(assistant_messages)}, new: {len(new_messages)}")

    if not new_messages:
        debug("No new assistant messages after retries, exiting")
        sys.exit(0)

    # Use Claude Code's PID (stored by session-start) so PiTalk can send voice input back
    pid = state.get("claude_pid", os.getpid())

    new_spoken = 0
    for msg in assistant_messages:
        msg_uuid = msg.get("uuid", "")
        if not msg_uuid or msg_uuid in spoken:
            continue

        # Extract text content
        content = msg.get("message", {}).get("content", "")
        if isinstance(content, list):
            text_parts = []
            for part in content:
                if isinstance(part, dict) and part.get("type") == "text":
                    text_parts.append(part.get("text", ""))
            full_text = " ".join(text_parts)
        elif isinstance(content, str):
            full_text = content
        else:
            continue

        # Extract voice tags
        voice_chunks = extract_voice_tags(full_text)
        debug(f"  uuid={msg_uuid[:16]}: {len(voice_chunks)} voice chunks")

        if voice_chunks:
            # Send each voice chunk to the broker
            for chunk in voice_chunks:
                ok = send_to_broker(chunk, voice=voice, session_id=session_id, pid=pid)
                debug(f"    sent '{chunk[:60]}...' ok={ok}")

            # Mark as spoken
            spoken.add(msg_uuid)
            new_spoken += 1

    save_spoken(spoken)
    debug(f"done. new spoken: {new_spoken}")
    
    # Print result so Claude Code logs it
    print(json.dumps({"spoken": new_spoken}))
    sys.exit(0)


if __name__ == "__main__":
    main()
