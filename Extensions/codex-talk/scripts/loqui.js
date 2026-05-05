import crypto from "node:crypto";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

export const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
export const EXTENSION_ROOT = path.resolve(SCRIPT_DIR, "..");
export const LOQUI_SOCKET = process.env.LOQUI_SOCKET || path.join(
  os.homedir(),
  "Library",
  "Application Support",
  "Loqui",
  "loqui.sock",
);
export const SOURCE_APP = process.env.LOQUI_CODEX_SOURCE_APP || "codex";
export const SESSION_ID_OVERRIDE = process.env.LOQUI_CODEX_SESSION_ID || "";

const STATE_DIR = process.env.LOQUI_CODEX_STATE_DIR || path.join(EXTENSION_ROOT, ".state");
const LOCK_STALE_MS = Number(process.env.LOQUI_CODEX_LOCK_STALE_MS || "10000");
const LOCK_WAIT_MS = Number(process.env.LOQUI_CODEX_LOCK_WAIT_MS || "1500");
const LOCK_POLL_MS = Number(process.env.LOQUI_CODEX_LOCK_POLL_MS || "50");

export function readStdinJson() {
  return new Promise((resolve) => {
    let input = "";
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", (chunk) => {
      input += chunk;
    });
    process.stdin.on("end", () => {
      try {
        resolve(input.trim() ? JSON.parse(input) : {});
      } catch {
        resolve({});
      }
    });
  });
}

export function sendLoqui(command, timeoutMs = 2500) {
  return new Promise((resolve, reject) => {
    let settled = false;
    let buffer = "";
    const socket = net.createConnection(LOQUI_SOCKET);

    const finish = (fn) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      socket.destroy();
      fn();
    };

    const timer = setTimeout(() => {
      finish(() => reject(new Error(`Loqui socket timeout: ${LOQUI_SOCKET}`)));
    }, timeoutMs);

    socket.setEncoding("utf8");
    socket.on("error", (error) => {
      finish(() => reject(error));
    });
    socket.on("connect", () => {
      socket.write(`${JSON.stringify(command)}\n`);
      socket.end();
    });
    socket.on("data", (chunk) => {
      buffer += chunk;
      const newline = buffer.indexOf("\n");
      if (newline === -1) return;
      parseLine(buffer.slice(0, newline));
    });
    socket.on("end", () => {
      if (!settled) parseLine(buffer);
    });

    function parseLine(raw) {
      const line = String(raw || "").trim();
      finish(() => {
        if (!line) {
          reject(new Error("Empty Loqui response"));
          return;
        }
        try {
          resolve(JSON.parse(line));
        } catch {
          reject(new Error("Invalid Loqui response"));
        }
      });
    }
  });
}

export async function health() {
  try {
    const response = await sendLoqui({ type: "health" }, 1200);
    return response?.ok === true;
  } catch {
    return false;
  }
}

export async function speak(text, sessionId) {
  const clean = String(text || "").replace(/<[^>]+>/g, " ").replace(/\s+/g, " ").trim();
  if (!clean) return false;

  try {
    const response = await sendLoqui({
      type: "speak",
      text: clean,
      sourceApp: SOURCE_APP,
      sessionId,
      pid: process.pid,
    });
    return response?.ok === true;
  } catch {
    return false;
  }
}

export async function stop(sessionId) {
  try {
    await sendLoqui({
      type: "stop",
      sourceApp: SOURCE_APP,
      sessionId,
    }, 1200);
  } catch {
    // Hooks should never disturb the Codex turn if Loqui is unavailable.
  }
}

function shortHash(value) {
  return crypto.createHash("sha256").update(String(value)).digest("hex").slice(0, 16);
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export function sessionIdFor(input) {
  if (SESSION_ID_OVERRIDE.trim()) return SESSION_ID_OVERRIDE.trim();

  const stableId =
    input?.session_id ||
    input?.sessionId ||
    input?.thread_id ||
    input?.threadId ||
    input?.conversation_id ||
    input?.conversationId;

  if (stableId) return `session:${stableId}`;

  const stablePath =
    input?.transcript_path ||
    input?.transcriptPath ||
    input?.cwd ||
    process.cwd();

  return `workspace:${shortHash(stablePath)}`;
}

export function extractVoiceTags(text) {
  const chunks = [];
  const re = /<voice>([\s\S]*?)<\/voice>/gi;
  let match;
  while ((match = re.exec(String(text || "")))) {
    const chunk = match[1].replace(/<[^>]+>/g, " ").replace(/\s+/g, " ").trim();
    if (chunk) chunks.push(chunk);
  }
  return chunks;
}

function drainKeyFor(input, sessionId) {
  const transcriptPath = input?.transcript_path || input?.transcriptPath;
  if (transcriptPath) return `transcript:${path.resolve(transcriptPath)}`;
  return `session:${sessionId}`;
}

function statePathFor(drainKey) {
  return path.join(STATE_DIR, `${shortHash(drainKey)}.json`);
}

function lockPathFor(drainKey) {
  return path.join(STATE_DIR, `${shortHash(drainKey)}.lock`);
}

function readDrainState(drainKey) {
  try {
    return JSON.parse(fs.readFileSync(statePathFor(drainKey), "utf8"));
  } catch {
    return { nextIndex: 0 };
  }
}

function writeDrainState(drainKey, state) {
  fs.mkdirSync(STATE_DIR, { recursive: true });
  fs.writeFileSync(statePathFor(drainKey), JSON.stringify(state), "utf8");
}

async function withDrainLock(drainKey, fn) {
  fs.mkdirSync(STATE_DIR, { recursive: true });
  const lockPath = lockPathFor(drainKey);
  const startedAt = Date.now();

  while (true) {
    try {
      fs.mkdirSync(lockPath);
      fs.writeFileSync(path.join(lockPath, "owner.json"), JSON.stringify({
        pid: process.pid,
        createdAt: new Date().toISOString(),
        drainKey,
      }));
      break;
    } catch (error) {
      if (error.code !== "EEXIST") throw error;

      try {
        const stat = fs.statSync(lockPath);
        if (Date.now() - stat.mtimeMs > LOCK_STALE_MS) {
          fs.rmSync(lockPath, { recursive: true, force: true });
          continue;
        }
      } catch {
        continue;
      }

      if (Date.now() - startedAt > LOCK_WAIT_MS) return { locked: false };
      await sleep(LOCK_POLL_MS);
    }
  }

  try {
    return { locked: true, value: await fn() };
  } finally {
    fs.rmSync(lockPath, { recursive: true, force: true });
  }
}

export function extractTranscriptVoiceTags(transcriptPath) {
  if (!transcriptPath) return [];

  const chunks = [];
  const text = fs.readFileSync(transcriptPath, "utf8");
  for (const line of text.split(/\r?\n/)) {
    if (!line.trim()) continue;

    let record;
    try {
      record = JSON.parse(line);
    } catch {
      continue;
    }

    const payload = record.payload;
    if (record.type === "event_msg" && payload?.type === "agent_message") {
      chunks.push(...extractVoiceTags(payload.message || ""));
    }
  }

  return chunks;
}

export async function drainTranscriptVoiceTags(input) {
  const sessionId = sessionIdFor(input);
  const transcriptPath = input?.transcript_path || input?.transcriptPath;
  if (!transcriptPath) return { sessionId, spoken: 0 };

  const drainKey = drainKeyFor(input, sessionId);
  const result = await withDrainLock(drainKey, async () => {
    let chunks;
    try {
      chunks = extractTranscriptVoiceTags(transcriptPath);
    } catch {
      return { sessionId, spoken: 0 };
    }

    const state = readDrainState(drainKey);
    const nextIndex = Number.isInteger(state.nextIndex) ? state.nextIndex : 0;
    let count = 0;

    for (const chunk of chunks.slice(nextIndex)) {
      await speak(chunk, sessionId);
      count += 1;
    }

    writeDrainState(drainKey, {
      nextIndex: chunks.length,
      updatedAt: new Date().toISOString(),
      sessionId,
    });
    return { sessionId, spoken: count };
  });

  if (!result.locked) return { sessionId, spoken: 0, skipped: "locked" };
  return result.value;
}
