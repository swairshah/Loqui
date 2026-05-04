#!/usr/bin/env node

import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import path from "node:path";
import process from "node:process";

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const SERVER_PATH = path.resolve(SCRIPT_DIR, "../src/index.js");

const args = process.argv.slice(2);
const command = args[0] || "status";

async function main() {
  if (command === "help" || command === "--help" || command === "-h") {
    usage();
    return;
  }

  const client = new McpClient(process.execPath, [SERVER_PATH, "mcp"]);
  await client.start();

  try {
    const init = await client.request("initialize", {
      protocolVersion: "2025-06-18",
      clientInfo: {
        name: "loqui-mcp-test-client",
        version: "0.1.0",
      },
      capabilities: {},
    });

    console.log(`Connected to ${init.serverInfo.name} ${init.serverInfo.version}`);

    if (command === "tools") {
      const result = await client.request("tools/list", {});
      for (const tool of result.tools || []) {
        console.log(`${tool.name}: ${tool.description}`);
      }
      return;
    }

    if (command === "status") {
      printToolResult(await client.callTool("status", {}));
      return;
    }

    if (command === "voices") {
      printToolResult(await client.callTool("voices", {}));
      return;
    }

    if (command === "speak" || command === "say") {
      const { text, options } = parseSpeakArgs(args.slice(1));
      if (!text) throw new Error("Usage: test-mcp-client.js speak [--voice <name>] <text>");
      printToolResult(await client.callTool("speak", { text, ...options }));
      return;
    }

    if (command === "save") {
      const { text, output, options } = parseSaveArgs(args.slice(1));
      if (!text || !output) {
        throw new Error("Usage: test-mcp-client.js save --output <file> [--voice <name>] <text>");
      }
      printToolResult(await client.callTool("save_audio", { text, output, ...options }));
      return;
    }

    throw new Error(`Unknown command: ${command}`);
  } finally {
    await client.close();
  }
}

class McpClient {
  constructor(command, args) {
    this.command = command;
    this.args = args;
    this.nextId = 1;
    this.pending = new Map();
    this.buffer = "";
  }

  async start() {
    this.child = spawn(this.command, this.args, {
      stdio: ["pipe", "pipe", "pipe"],
      cwd: path.resolve(SCRIPT_DIR, ".."),
    });

    this.child.stdout.setEncoding("utf8");
    this.child.stderr.setEncoding("utf8");

    this.child.stdout.on("data", (chunk) => this.onData(chunk));
    this.child.stderr.on("data", (chunk) => {
      const text = chunk.trim();
      if (text) console.error(`[server] ${text}`);
    });
    this.child.on("exit", (code, signal) => {
      const error = new Error(`MCP server exited (${signal || code})`);
      for (const { reject } of this.pending.values()) reject(error);
      this.pending.clear();
    });
  }

  request(method, params) {
    const id = this.nextId++;
    const message = { jsonrpc: "2.0", id, method, params };
    const body = `${JSON.stringify(message)}\n`;

    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.child.stdin.write(body);
    });
  }

  callTool(name, toolArgs) {
    return this.request("tools/call", {
      name,
      arguments: toolArgs,
    });
  }

  onData(chunk) {
    this.buffer += chunk;

    while (true) {
      const newline = this.buffer.indexOf("\n");
      if (newline === -1) return;

      const line = this.buffer.slice(0, newline).trim();
      this.buffer = this.buffer.slice(newline + 1);
      if (!line) continue;

      let message;
      try {
        message = JSON.parse(line);
      } catch (error) {
        console.error(`Could not parse server response: ${error.message}`);
        continue;
      }

      const pending = this.pending.get(message.id);
      if (!pending) continue;
      this.pending.delete(message.id);

      if (message.error) pending.reject(new Error(message.error.message || "MCP request failed"));
      else pending.resolve(message.result);
    }
  }

  close() {
    return new Promise((resolve) => {
      if (!this.child || this.child.killed) {
        resolve();
        return;
      }

      this.child.once("exit", resolve);
      this.child.stdin.end();
      setTimeout(() => {
        if (!this.child.killed) this.child.kill();
      }, 250);
    });
  }
}

function printToolResult(result) {
  if (result?.isError) {
    console.error(result.content?.map((item) => item.text).join("\n") || "Tool failed");
    process.exitCode = 1;
    return;
  }
  console.log(result.content?.map((item) => item.text).join("\n") || JSON.stringify(result));
}

function parseSpeakArgs(parts) {
  const options = {};
  const text = [];
  for (let index = 0; index < parts.length; index += 1) {
    const part = parts[index];
    if (part === "--voice" || part === "-v") options.voice = parts[++index];
    else if (part === "--session-id" || part === "-S") options.sessionId = parts[++index];
    else if (part === "--source-app") options.sourceApp = parts[++index];
    else text.push(part);
  }
  return { text: text.join(" "), options };
}

function parseSaveArgs(parts) {
  const options = {};
  const text = [];
  let output = "";
  for (let index = 0; index < parts.length; index += 1) {
    const part = parts[index];
    if (part === "--voice" || part === "-v") options.voice = parts[++index];
    else if (part === "--output" || part === "-o") output = parts[++index];
    else text.push(part);
  }
  return { text: text.join(" "), output, options };
}

function usage() {
  console.log(`test-mcp-client.js - tiny stdio MCP client for Loqui

Usage:
  node examples/test-mcp-client.js tools
  node examples/test-mcp-client.js status
  node examples/test-mcp-client.js voices
  node examples/test-mcp-client.js speak [--voice <name>] <text>
  node examples/test-mcp-client.js save --output <file> [--voice <name>] <text>

Examples:
  node examples/test-mcp-client.js status
  node examples/test-mcp-client.js speak --voice alba "Testing Loqui through MCP."
`);
}

main().catch((error) => {
  console.error(error.message);
  process.exit(1);
});
