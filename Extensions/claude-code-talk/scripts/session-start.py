#!/usr/bin/env python3
"""
SessionStart hook: Injects the voice prompt and checks Loqui broker health.
Outputs JSON with additionalContext to teach Claude about <voice> tags.
"""

import json
import os
import socket
import subprocess
import sys
import urllib.request

TTS_HOST = "127.0.0.1"
TTS_PORT = 18080
BROKER_PORT = 18081
STATE_FILE = "/tmp/loqui-tts-state.json"
INBOX_BASE_DIR = os.path.expanduser("~/.pi/agent/pitalk-inbox")
WATCHER_PID_FILE = "/tmp/loqui-inbox-watcher.pid"

VOICE_PROMPT = """
## Voice Output

You have text-to-speech capabilities. When responding, use <voice> tags to speak conversationally with the user.

Guidelines for <voice> content:
- Speak most of your conversational responses - questions, comments, reactions, explanations
- Use natural speech patterns, contractions, casual tone
- Multiple <voice> tags per response is encouraged
- Speak your thinking process, questions, and follow-ups
- Use ONLY <voice>...</voice> tags for speech
- Never use other tags anywhere (no <emphasis>, <strong>, SSML, XML, or HTML tags)
- Never nest tags inside <voice>; keep voice text plain
- For code: describe what it does (don't read the code itself)
- For file contents and technical details: summarize rather than read verbatim
- For errors: explain what went wrong conversationally
- For questions to the user: always speak them

Examples:
- Starting work: <voice>Okay, let me look into that for you.</voice>
- Thinking aloud: <voice>Hmm, this looks like it might be a permissions issue. Let me check the file ownership.</voice>
- Asking questions: <voice>Do you want me to fix this automatically, or would you rather review it first?</voice>
- Casual remarks: <voice>Nice! That test is passing now.</voice>
- Explaining findings: <voice>So I found the bug. Basically the loop was off by one, so it was skipping the last item in the array.</voice>
- Follow-ups: <voice>That should do it! Let me know if you want me to add any tests for this.</voice>

The text outside <voice> tags shows normally in the terminal. Only <voice> content is spoken.
Speak freely and conversationally - the user prefers hearing your responses.
"""


def check_health():
    """Check if Loqui health endpoint and broker are up."""
    try:
        req = urllib.request.Request(f"http://{TTS_HOST}:{TTS_PORT}/health", method="GET")
        with urllib.request.urlopen(req, timeout=2) as resp:
            if resp.status != 200:
                return False
    except Exception:
        return False

    # Check broker
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(2)
        sock.connect((TTS_HOST, BROKER_PORT))
        sock.sendall(json.dumps({"type": "health"}).encode() + b"\n")
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


def load_state():
    """Load TTS state (enabled/muted/voice)."""
    try:
        with open(STATE_FILE, "r") as f:
            return json.load(f)
    except Exception:
        return {"enabled": True, "voice": "auto"}


def save_state(state):
    """Persist TTS state."""
    try:
        with open(STATE_FILE, "w") as f:
            json.dump(state, f)
    except Exception:
        pass


def find_claude_pid():
    """Walk up the process tree to find the claude process PID."""
    pid = os.getpid()
    for _ in range(10):
        try:
            result = subprocess.run(
                ["ps", "-o", "ppid=", "-p", str(pid)],
                capture_output=True, text=True, timeout=2
            )
            ppid = int(result.stdout.strip())
            if ppid <= 1:
                break
            # Check if this parent is claude
            comm_result = subprocess.run(
                ["ps", "-o", "comm=", "-p", str(ppid)],
                capture_output=True, text=True, timeout=2
            )
            comm = comm_result.stdout.strip().lower()
            if "claude" in comm or "bun" in comm:
                return ppid
            pid = ppid
        except Exception:
            break
    # Fallback: use grandparent (claude -> sh -> python3)
    try:
        result = subprocess.run(
            ["ps", "-o", "ppid=", "-p", str(os.getppid())],
            capture_output=True, text=True, timeout=2
        )
        return int(result.stdout.strip())
    except Exception:
        return os.getppid()


def kill_old_watcher():
    """Kill any previously running inbox watcher."""
    try:
        if os.path.exists(WATCHER_PID_FILE):
            with open(WATCHER_PID_FILE) as f:
                old_pid = int(f.read().strip())
            try:
                os.kill(old_pid, 9)
            except ProcessLookupError:
                pass
            os.unlink(WATCHER_PID_FILE)
    except Exception:
        pass


def start_inbox_watcher(claude_pid):
    """Start a background process that watches the inbox for voice input."""
    inbox_dir = os.path.join(INBOX_BASE_DIR, str(claude_pid))
    os.makedirs(inbox_dir, exist_ok=True)

    # Kill old watcher first
    kill_old_watcher()

    # Find the watcher script relative to this script
    script_dir = os.path.dirname(os.path.abspath(__file__))
    watcher_script = os.path.join(script_dir, "inbox-watcher.sh")

    if not os.path.exists(watcher_script):
        return

    # Launch watcher as a detached background process
    subprocess.Popen(
        ["bash", watcher_script, inbox_dir, WATCHER_PID_FILE, "0.5"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        stdin=subprocess.DEVNULL,
        start_new_session=True,
    )


def main():
    # Read hook input from stdin
    try:
        input_data = json.loads(sys.stdin.read())
    except Exception:
        input_data = {}

    session_id = input_data.get("session_id", "unknown")
    cwd = input_data.get("cwd", "")
    state = load_state()

    if not state.get("enabled", True):
        # TTS disabled, don't inject voice prompt
        sys.exit(0)

    healthy = check_health()

    # Find Claude Code's actual PID by walking up the process tree.
    # Hook runs as: claude -> sh -> python3, so we need grandparent or higher.
    claude_pid = find_claude_pid()

    # Use project directory name as display-friendly session ID (like Pi does)
    # instead of the raw UUID, so PiTalk shows e.g. "pi-talk-app" not "214f591-bfdc-..."
    display_session_id = os.path.basename(cwd) if cwd else session_id

    # Save session info into state
    state["session_id"] = display_session_id
    state["raw_session_id"] = session_id
    state["server_ready"] = healthy
    state["claude_pid"] = claude_pid
    state["cwd"] = cwd
    save_state(state)

    # Start inbox watcher for voice input
    start_inbox_watcher(claude_pid)

    # Inject voice prompt as additional context
    output = {
        "hookSpecificOutput": {
            "hookEventName": "SessionStart",
            "additionalContext": VOICE_PROMPT
        }
    }

    if not healthy:
        output["systemMessage"] = "⚠️ Loqui TTS broker not running. Start Loqui.app or install: brew install swairshah/tap/loqui"

    print(json.dumps(output))
    sys.exit(0)


if __name__ == "__main__":
    main()
