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

LOQUI_SOCKET = os.path.expanduser("~/Library/Application Support/Loqui/loqui.sock")
STATE_FILE = "/tmp/loqui-tts-state.json"
INBOX_BASE_DIR = os.path.expanduser("~/.pi/agent/pitalk-inbox")
WATCHER_PID_FILE = "/tmp/loqui-inbox-watcher.pid"

VOICE_PROMPT_SUCCINCT = """
## Voice Output

You have text-to-speech capabilities. When responding, include brief spoken summaries using <voice> tags.

Guidelines for <voice> content:
- Keep it brief and conversational (1-2 sentences)
- Summarize what you're doing or what you found, not full details
- Use natural speech patterns, contractions, casual tone
- Use ONLY <voice>...</voice> tags for speech
- Never use other tags anywhere (no <emphasis>, <strong>, SSML, XML, or HTML)
- Never nest tags inside <voice>; keep voice text plain
- For code: describe what it does, don't read the code itself
- For errors: summarize the issue conversationally
- For confirmations: keep it simple like "Done!" or "Got it."

Examples:
- Starting work: <voice>Okay, let me look into that.</voice>
- Found something: <voice>Found the issue — typo in the config file.</voice>
- Completed task: <voice>All done.</voice>

The text outside <voice> tags shows normally in the terminal. Only <voice> content is spoken.
"""

VOICE_PROMPT_VERBOSE = """
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

VOICE_PROMPT_CHATTY = """
## Voice Output

You have text-to-speech capabilities. Use <voice> tags liberally — narrate everything you'd say to a colleague pair-programming with you. The user wants to hear you think out loud.

Guidelines for <voice> content:
- Narrate intent BEFORE acting: announce what you're about to do and why
- Comment on findings as you discover them, not just at the end
- Speak tradeoffs, hunches, and uncertainty out loud
- React to surprises — "huh, that's not what I expected"
- Multiple <voice> tags throughout each response (3-6+ is normal)
- Speak any clarifying questions immediately, don't bury them
- Use natural speech patterns, contractions, casual tone
- Use ONLY <voice>...</voice> tags for speech
- Never use other tags anywhere (no <emphasis>, <strong>, SSML, XML, or HTML tags)
- Never nest tags inside <voice>; keep voice text plain
- For code: describe what it does and why it matters, don't read the code itself
- For file contents: summarize what you saw and what stood out
- For errors: explain what went wrong conversationally and your hypothesis
- For decisions: explain the tradeoff out loud

Examples:
- Announcing intent: <voice>Okay, I'm gonna check the auth config first since that's where the timeout is configured.</voice>
- Mid-investigation: <voice>Hmm, the timeout's set to thirty seconds here, but the error says it's firing at five. Something else is overriding this.</voice>
- Reacting to surprise: <voice>Oh interesting — there's a middleware doing its own timeout. That's the culprit.</voice>
- Explaining tradeoff: <voice>I could either bump the middleware timeout or remove it. Bumping is safer but the middleware's there for a reason — let me check why it exists before removing.</voice>
- Wrapping up: <voice>Okay, fixed it by raising the middleware timeout to match the auth config. Both are now thirty seconds. Should be good — try it and let me know.</voice>

The text outside <voice> tags shows normally in the terminal. Only <voice> content is spoken.
Speak freely and abundantly — the user prefers hearing your full thought process.
"""

VOICE_PROMPTS = {
    "succinct": VOICE_PROMPT_SUCCINCT,
    "verbose": VOICE_PROMPT_VERBOSE,
    "chatty": VOICE_PROMPT_CHATTY,
}


def check_health():
    """Check if Loqui broker is up."""
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(2)
        sock.connect(LOQUI_SOCKET)
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
        return {"enabled": True, "voice": "vera"}


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

    # Pick the voice prompt matching the configured style (default: verbose)
    style = state.get("style", "verbose")
    prompt = VOICE_PROMPTS.get(style, VOICE_PROMPT_VERBOSE)

    # Inject voice prompt as additional context
    output = {
        "hookSpecificOutput": {
            "hookEventName": "SessionStart",
            "additionalContext": prompt
        }
    }

    if not healthy:
        output["systemMessage"] = "PiTalk TTS broker not running. Start PiTalk.app or install: brew install swairshah/tap/pitalk"

    print(json.dumps(output))
    sys.exit(0)


if __name__ == "__main__":
    main()
