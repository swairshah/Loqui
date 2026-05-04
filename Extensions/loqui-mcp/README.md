# loqui-mcp

MCP server and CLI bridge for [Loqui](../../README.md), the local macOS TTS service.

Loqui must be installed and running:

```sh
brew install swairshah/tap/loqui
open -a Loqui
```

## Install To Agents

Auto-register the MCP server with detected agents:

```sh
npx -y @swairshah/loqui-mcp@latest mcp --install
```

Detected targets:

- Claude Code
- Codex
- Cursor
- Windsurf
- OpenCode
- Pi, through `pi-mcp-adapter`

Preview changes:

```sh
npx -y @swairshah/loqui-mcp@latest mcp --install --dry-run
```

From this repository before publishing to npm:

```sh
node Extensions/loqui-mcp/src/index.js mcp --install --local
```

## MCP Tools

- `speak` - speak short text through Loqui
- `stop` - stop current and queued speech
- `status` - check Loqui server health
- `voices` - list Loqui voices
- `save_audio` - generate a WAV file

This MCP server is for tool-based speech. Automatic narration from assistant output still needs an app-specific hook or extension, such as `@swairshah/pi-talk` for Pi or the bundled Claude Code plugin.

## CLI

```sh
loqui-mcp say "Hello from Loqui"
loqui-mcp say --voice alba "Using a specific voice"
loqui-mcp save --output ./hello.wav "Save this as audio"
loqui-mcp voices
loqui-mcp status
loqui-mcp stop
```

## Tiny MCP Client For Testing

This package includes a small dependency-free MCP client example that spawns the local MCP server over stdio and calls tools through JSON-RPC:

```sh
cd Extensions/loqui-mcp
node examples/test-mcp-client.js tools
node examples/test-mcp-client.js status
node examples/test-mcp-client.js voices
node examples/test-mcp-client.js speak --voice alba "Testing Loqui through MCP."
node examples/test-mcp-client.js save --output ./hello.wav "Testing saved audio."
```

## Standalone Chat CLI

`examples/loqui-chat.py` is a tiny Claude/Codex-like chat loop modeled after `nanocode.py`. It calls OpenAI's Responses API directly, exposes the Loqui MCP tools to the model, and speaks through MCP.

```sh
export OPENAI_API_KEY=...
cd Extensions/loqui-mcp
python3 examples/loqui-chat.py
```

The default model is `gpt-5-mini` for faster, cheaper smoke tests. Override it with `--model gpt-5` or `LOQUI_CHAT_MODEL`.

Commands inside the chat:

- `/say <text>` - speak directly through Loqui MCP
- `/tools` - list available MCP tools
- `/c` - clear conversation
- `/q` - quit

By default, if the model forgets to call `speak`, the CLI speaks the visible answer through MCP as a fallback. Use `--no-auto-speak` to disable that fallback.

## Manual MCP Config

Use this server command:

```sh
npx -y @swairshah/loqui-mcp@latest mcp
```

Typical JSON config:

```json
{
  "mcpServers": {
    "loqui": {
      "command": "sh",
      "args": ["-lc", "npx -y @swairshah/loqui-mcp@latest mcp"]
    }
  }
}
```

## Environment

- `LOQUI_SOCKET` - override the Loqui Unix socket path
- `LOQUI_SOURCE_APP` - default source app label
- `LOQUI_SESSION_ID` - default queue session ID
- `LOQUI_TIMEOUT_MS` - socket timeout in milliseconds
