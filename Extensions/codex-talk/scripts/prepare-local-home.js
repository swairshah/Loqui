#!/usr/bin/env node

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const extensionRoot = path.resolve(scriptDir, "..");
const repoRoot = path.resolve(extensionRoot, "..", "..");
const extensionsRoot = path.resolve(extensionRoot, "..");
const workspaceRoot = path.resolve(process.env.LOQUI_CODEX_CWD || extensionsRoot);
const localRoot = process.env.LOQUI_EXTENSIONS_LOCAL_DIR || path.join(repoRoot, "Extensions", ".local");
const codexHome = process.env.LOQUI_CODEX_HOME || path.join(localRoot, "codex-home");
const globalCodexHome = process.env.CODEX_HOME && path.resolve(process.env.CODEX_HOME) !== path.resolve(codexHome)
  ? process.env.CODEX_HOME
  : path.join(os.homedir(), ".codex");

function shellQuote(value) {
  return `'${String(value).replace(/'/g, "'\\''")}'`;
}

function writeFileChanged(file, content) {
  const previous = fs.existsSync(file) ? fs.readFileSync(file, "utf8") : "";
  if (previous === content) return false;
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, content);
  return true;
}

function symlinkIfPresent(name) {
  const source = path.join(globalCodexHome, name);
  const target = path.join(codexHome, name);
  if (!fs.existsSync(source) || fs.existsSync(target)) return false;
  fs.symlinkSync(source, target);
  return true;
}

function hookCommand(scriptName) {
  return [
    shellQuote(process.execPath),
    shellQuote(path.join(extensionRoot, "scripts", scriptName)),
  ].join(" ");
}

const hooks = {
  hooks: {
    UserPromptSubmit: [
      {
        hooks: [
          {
            type: "command",
            command: hookCommand("user_prompt_submit.js"),
            timeout: 5,
            statusMessage: "Checking Loqui",
          },
        ],
      },
    ],
    PostToolUse: [
      {
        matcher: ".*",
        hooks: [
          {
            type: "command",
            command: hookCommand("post_tool_use.js"),
            timeout: 5,
          },
        ],
      },
    ],
    Stop: [
      {
        hooks: [
          {
            type: "command",
            command: hookCommand("stop.js"),
            timeout: 10,
            statusMessage: "Sending voice output",
          },
        ],
      },
    ],
  },
};

const voiceInstructions = `You have text-to-speech support through Loqui: any text inside <voice>...</voice> tags will be spoken aloud.
Every conversational response MUST include at least one literal <voice>...</voice> tag.
Use short, natural <voice> summaries when starting work, reaching an important finding, before or after long tool phases, when asking for input, and when finishing.
Keep spoken text conversational and concise; summarize files, commands, outputs, errors, and code instead of reading them verbatim.
Do not put Markdown, XML, SSML, code blocks, nested tags, or file dumps inside <voice>; use plain human speech only.
Text outside <voice> tags is normal Codex output and will not be spoken, so keep detailed technical content outside <voice> tags.
Do not repeat the same sentence both inside and outside a <voice> tag. If a sentence is only meant to be spoken, put it only in <voice>. If it is important for the written transcript, write it once outside <voice> and use a shorter spoken summary.
For simple greetings or short questions, put the whole conversational sentence only inside <voice> and do not add a visible duplicate line.
Correct greeting: <voice>Hi! How can I help?</voice>
Incorrect greeting: <voice>Hi! How can I help?</voice> followed by "Hi! How can I help?" outside the tag.
Avoid excessive narration: speak only when it helps the user follow progress or respond at the right time.
`;

const config = `[features]
codex_hooks = true

[projects.${JSON.stringify(workspaceRoot)}]
trust_level = "trusted"
`;

fs.mkdirSync(codexHome, { recursive: true });
const hooksChanged = writeFileChanged(path.join(codexHome, "hooks.json"), `${JSON.stringify(hooks, null, 2)}\n`);
const configChanged = writeFileChanged(path.join(codexHome, "config.toml"), config);
const homeAgentsChanged = writeFileChanged(path.join(codexHome, "AGENTS.md"), voiceInstructions);
const workspaceAgentsChanged = writeFileChanged(path.join(extensionsRoot, "AGENTS.md"), voiceInstructions);

let linkedAuth = false;
if (process.env.LOQUI_CODEX_REUSE_AUTH !== "0") {
  linkedAuth = symlinkIfPresent("auth.json");
}

console.log(`Codex local home: ${codexHome}`);
console.log(`${hooksChanged ? "Wrote" : "No change"} hooks.json`);
console.log(`${configChanged ? "Wrote" : "No change"} config.toml`);
console.log(`${homeAgentsChanged ? "Wrote" : "No change"} AGENTS.md in local Codex home`);
console.log(`${workspaceAgentsChanged ? "Wrote" : "No change"} Extensions/AGENTS.md`);
if (linkedAuth) console.log(`Linked auth.json from ${globalCodexHome}`);
console.log(`Run with: CODEX_HOME=${shellQuote(codexHome)} codex -C ${shellQuote(workspaceRoot)}`);
