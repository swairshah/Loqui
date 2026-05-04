# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///

#!/usr/bin/env python3
"""loqui-chat - tiny standalone OpenAI chat CLI that speaks through Loqui MCP.

Set OPENAI_API_KEY, keep Loqui.app running, then run:

    python3 examples/loqui-chat.py
"""

import argparse
import json
import os
import queue
import re
import subprocess
import sys
import threading
from pathlib import Path

API_URL = "https://api.openai.com/v1/responses"
DEFAULT_MODEL = "gpt-5-mini"
DEFAULT_VOICE = "vera"

RESET = "\033[0m"
BOLD = "\033[1m"
DIM = "\033[2m"
BLUE = "\033[34m"
CYAN = "\033[36m"
GREEN = "\033[32m"
RED = "\033[31m"


class McpStdioClient:
    def __init__(self, command):
        self.command = command
        self.proc = None
        self.next_id = 1
        self.responses = queue.Queue()
        self.lock = threading.Lock()

    def start(self):
        self.proc = subprocess.Popen(
            self.command,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        threading.Thread(target=self._read_stdout, daemon=True).start()
        threading.Thread(target=self._read_stderr, daemon=True).start()
        return self.request(
            "initialize",
            {
                "protocolVersion": "2025-06-18",
                "clientInfo": {"name": "loqui-chat", "version": "0.1.0"},
                "capabilities": {},
            },
        )

    def close(self):
        if not self.proc:
            return
        try:
            self.proc.stdin.close()
        except Exception:
            pass
        try:
            self.proc.terminate()
            self.proc.wait(timeout=1)
        except Exception:
            self.proc.kill()

    def request(self, method, params=None):
        if not self.proc or not self.proc.stdin:
            raise RuntimeError("MCP server is not running")
        with self.lock:
            request_id = self.next_id
            self.next_id += 1

        message = {"jsonrpc": "2.0", "id": request_id, "method": method, "params": params or {}}
        self.proc.stdin.write(json.dumps(message) + "\n")
        self.proc.stdin.flush()

        while True:
            response = self.responses.get(timeout=30)
            if response.get("id") != request_id:
                continue
            if "error" in response:
                raise RuntimeError(response["error"].get("message", "MCP request failed"))
            return response.get("result")

    def call_tool(self, name, arguments):
        return self.request("tools/call", {"name": name, "arguments": arguments})

    def list_tools(self):
        return self.request("tools/list", {}).get("tools", [])

    def _read_stdout(self):
        assert self.proc and self.proc.stdout
        for line in self.proc.stdout:
            line = line.strip()
            if not line:
                continue
            try:
                self.responses.put(json.loads(line))
            except json.JSONDecodeError:
                print(f"{DIM}[mcp stdout] {line}{RESET}", file=sys.stderr)

    def _read_stderr(self):
        assert self.proc and self.proc.stderr
        for line in self.proc.stderr:
            line = line.strip()
            if line:
                print(f"{DIM}[mcp] {line}{RESET}", file=sys.stderr)


def openai_tool_schema(mcp_tools):
    tools = []
    for tool in mcp_tools:
        tools.append(
            {
                "type": "function",
                "name": tool["name"],
                "description": tool.get("description", ""),
                "parameters": tool.get("inputSchema", {"type": "object", "properties": {}}),
            }
        )
    return tools


def call_openai(model, input_items, instructions, tools, previous_response_id=None):
    api_key = os.environ.get("OPENAI_API_KEY", "")
    if not api_key:
        raise RuntimeError("OPENAI_API_KEY is not set")

    body = {
        "model": model,
        "instructions": instructions,
        "input": input_items,
        "tools": tools,
        "tool_choice": "auto",
    }
    if previous_response_id:
        body["previous_response_id"] = previous_response_id

    result = subprocess.run(
        [
            "curl",
            "-sS",
            "--fail-with-body",
            API_URL,
            "-H",
            "Content-Type: application/json",
            "-H",
            f"Authorization: Bearer {api_key}",
            "-d",
            json.dumps(body),
        ],
        capture_output=True,
        text=True,
        timeout=120,
    )
    if result.returncode != 0:
        detail = result.stdout.strip() or result.stderr.strip()
        raise RuntimeError(f"OpenAI API request failed: {detail}")
    return json.loads(result.stdout)


def response_text(response):
    parts = []
    for item in response.get("output", []):
        if item.get("type") != "message":
            continue
        for content in item.get("content", []):
            if content.get("type") in ("output_text", "text"):
                parts.append(content.get("text", ""))
    return "\n".join(part for part in parts if part).strip()


def function_calls(response):
    return [item for item in response.get("output", []) if item.get("type") == "function_call"]


def render_text(text):
    return re.sub(r"\*\*(.+?)\*\*", f"{BOLD}\\1{RESET}", text)


def content_text(tool_result):
    content = tool_result.get("content", [])
    if isinstance(content, list):
        return "\n".join(str(item.get("text", "")) for item in content if item.get("type") == "text")
    return str(content)


def separator():
    try:
        columns = os.get_terminal_size().columns
    except OSError:
        columns = 80
    return f"{DIM}{'-' * min(columns, 80)}{RESET}"


def resolve_server_command(raw):
    if raw:
        return raw
    node = os.environ.get("NODE") or "node"
    server = Path(__file__).resolve().parents[1] / "src" / "index.js"
    return [node, str(server), "mcp"]


def parse_args():
    parser = argparse.ArgumentParser(description="Tiny OpenAI chat CLI that speaks through Loqui MCP")
    parser.add_argument("--model", default=os.environ.get("LOQUI_CHAT_MODEL", DEFAULT_MODEL))
    parser.add_argument(
        "--server",
        nargs=argparse.REMAINDER,
        help="MCP server command. Defaults to: node ../src/index.js mcp",
    )
    parser.add_argument(
        "--no-auto-speak",
        action="store_true",
        help="Do not automatically speak assistant text if the model skipped the speak tool.",
    )
    return parser.parse_args()


def main():
    args = parse_args()
    mcp = McpStdioClient(resolve_server_command(args.server))
    init = mcp.start()
    mcp_tools = mcp.list_tools()
    tools = openai_tool_schema(mcp_tools)

    print(f"{BOLD}loqui-chat{RESET} | {DIM}{args.model} | {init['serverInfo']['name']}{RESET}")
    print(f"{DIM}Commands: /q exit, /c clear, /tools list, /say <text> direct Loqui speech{RESET}\n")

    instructions = f"""You are loqui-chat, a concise conversational CLI assistant.

You have MCP tools from Loqui, a local Mac text-to-speech server.
Use the `speak` tool proactively to speak brief natural summaries, greetings, completions, blockers, and questions.
When calling `speak`, set `voice` to "{DEFAULT_VOICE}".
Keep spoken text short and plain. Do not send markdown, code, URLs, XML, SSML, or angle-bracket tags to speech.
For normal visible answers, be concise.
"""

    previous_response_id = None

    try:
        while True:
            try:
                print(separator())
                user_input = input(f"{BOLD}{BLUE}loqui>{RESET} ").strip()
                print(separator())
            except (EOFError, KeyboardInterrupt):
                print()
                break

            if not user_input:
                continue
            if user_input in ("/q", "quit", "exit"):
                break
            if user_input == "/c":
                previous_response_id = None
                print(f"{GREEN}cleared{RESET}")
                continue
            if user_input == "/tools":
                for tool in mcp_tools:
                    print(f"{GREEN}{tool['name']}{RESET}: {tool.get('description', '')}")
                continue
            if user_input.startswith("/say "):
                result = mcp.call_tool("speak", {"text": user_input[5:], "voice": DEFAULT_VOICE})
                print(f"{DIM}{content_text(result)}{RESET}")
                continue

            input_items = [{"role": "user", "content": user_input}]
            assistant_spoke = False

            while True:
                response = call_openai(
                    args.model,
                    input_items,
                    instructions,
                    tools,
                    previous_response_id=previous_response_id,
                )
                previous_response_id = response.get("id") or previous_response_id

                text = response_text(response)
                if text:
                    print(f"\n{CYAN}assistant{RESET} {render_text(text)}")

                calls = function_calls(response)
                if not calls:
                    if text and not assistant_spoke and not args.no_auto_speak:
                        # The model is instructed to use the tool, but this keeps the CLI useful
                        # even when it answers directly.
                        mcp.call_tool("speak", {"text": text[:350], "voice": DEFAULT_VOICE})
                    break

                input_items = []
                for call in calls:
                    tool_name = call["name"]
                    try:
                        tool_args = json.loads(call.get("arguments") or "{}")
                    except json.JSONDecodeError:
                        tool_args = {}

                    preview = json.dumps(tool_args, ensure_ascii=False)[:90]
                    print(f"\n{GREEN}tool{RESET} {tool_name}({DIM}{preview}{RESET})")
                    result = mcp.call_tool(tool_name, tool_args)
                    if tool_name == "speak":
                        assistant_spoke = True
                    result_text = content_text(result) or json.dumps(result)
                    print(f"  {DIM}{result_text.splitlines()[0][:100] if result_text else 'ok'}{RESET}")
                    input_items.append(
                        {
                            "type": "function_call_output",
                            "call_id": call["call_id"],
                            "output": result_text,
                        }
                    )

            print()
    finally:
        mcp.close()


if __name__ == "__main__":
    main()
