#!/usr/bin/env node

import process from "node:process";
import { installMcp } from "./install.js";
import { saveWav, speak, status, stop, voices } from "./client.js";
import { serveMcp } from "./mcp.js";

const args = process.argv.slice(2);

main().catch((error) => {
  console.error(error.message);
  process.exit(1);
});

async function main() {
  const command = args[0];

  if (!command || command === "help" || command === "--help" || command === "-h") {
    usage();
    return;
  }

  if (command === "mcp") {
    if (args.includes("--install") || args[1] === "install") {
      await installMcp({
        global: !args.includes("--no-global"),
        dryRun: args.includes("--dry-run"),
        local: args.includes("--local"),
      });
      return;
    }
    await serveMcp();
    return;
  }

  if (command === "install") {
    await installMcp({
      global: !args.includes("--no-global"),
      dryRun: args.includes("--dry-run"),
      local: args.includes("--local"),
    });
    return;
  }

  if (command === "say" || command === "speak") {
    const { text, options } = parseSayArgs(args.slice(1));
    await speak(text, options);
    console.error("Queued speech.");
    return;
  }

  if (command === "stop") {
    await stop();
    console.error("Speech stopped.");
    return;
  }

  if (command === "status" || command === "health") {
    const result = await status();
    console.log(`Loqui: ${result.ok ? "running" : "not running"}`);
    if (typeof result.pending === "number") console.log(`Pending: ${result.pending}`);
    if (typeof result.playing === "boolean") console.log(`Playing: ${result.playing}`);
    if (result.currentQueue) console.log(`Current queue: ${result.currentQueue}`);
    return;
  }

  if (command === "voices") {
    const list = await voices();
    for (const voice of list) console.log(voice);
    return;
  }

  if (command === "save") {
    const { text, output, options } = parseSaveArgs(args.slice(1));
    const saved = await saveWav(text, output, options);
    console.log(saved);
    return;
  }

  await speak(args.join(" "));
  console.error("Queued speech.");
}

function usage() {
  console.log(`loqui-mcp - MCP and CLI bridge for Loqui

Usage:
  loqui-mcp mcp
  loqui-mcp mcp --install [--local] [--no-global] [--dry-run]
  loqui-mcp say [--voice <name>] [--session-id <id>] <text>
  loqui-mcp save [--voice <name>] --output <file> <text>
  loqui-mcp voices
  loqui-mcp status
  loqui-mcp stop
`);
}

function parseSayArgs(parts) {
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
