import fs from "node:fs/promises";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import process from "node:process";

export const DEFAULT_SOCKET_PATH = path.join(
  os.homedir(),
  "Library",
  "Application Support",
  "Loqui",
  "loqui.sock",
);

export const AVAILABLE_VOICES = [
  "alba",
  "vera",
  "paul",
  "charles",
  "michael",
  "anna",
  "fantine",
  "eponine",
  "cosette",
  "eve",
  "george",
  "mary",
  "marius",
  "javert",
  "azelma",
  "caro_davy",
  "peter_yearsley",
  "stuart_bell",
];

export function defaultSessionId() {
  return process.env.LOQUI_SESSION_ID || path.basename(process.cwd()) || "default";
}

export function defaultSourceApp(fallback = "loqui-mcp") {
  return process.env.LOQUI_SOURCE_APP || fallback;
}

export function cleanSpeechText(text) {
  return String(text || "")
    .replace(/<[^>]+>/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

export function sendLoqui(command, options = {}) {
  const socketPath = options.socketPath || process.env.LOQUI_SOCKET || DEFAULT_SOCKET_PATH;
  const timeoutMs = Number(options.timeoutMs || process.env.LOQUI_TIMEOUT_MS || 5000);

  return new Promise((resolve, reject) => {
    let settled = false;
    let buffer = "";
    const socket = net.createConnection(socketPath);

    const finish = (fn) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      socket.destroy();
      fn();
    };

    const timer = setTimeout(() => {
      finish(() => reject(new Error(`Loqui socket timeout: ${socketPath}`)));
    }, timeoutMs);

    socket.setEncoding("utf8");
    socket.on("error", (error) => {
      finish(() => reject(new Error(`Could not reach Loqui at ${socketPath}: ${error.message}`)));
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

export async function speak(text, options = {}) {
  const clean = cleanSpeechText(text);
  if (!clean) throw new Error("Text cannot be empty");

  const response = await sendLoqui(
    {
      type: "speak",
      text: clean,
      voice: normalizeVoice(options.voice),
      sourceApp: options.sourceApp || defaultSourceApp(),
      sessionId: options.sessionId || defaultSessionId(),
      pid: process.pid,
    },
    options,
  );
  assertOk(response, "Loqui rejected speech");
  return response;
}

export async function stop(options = {}) {
  const response = await sendLoqui(
    {
      type: "stop",
      sourceApp: options.sourceApp || defaultSourceApp(),
      sessionId: options.sessionId || defaultSessionId(),
    },
    options,
  );
  assertOk(response, "Loqui stop failed");
  return response;
}

export async function status(options = {}) {
  return sendLoqui({ type: "health" }, options);
}

export async function voices(options = {}) {
  const response = await sendLoqui({ type: "voices" }, options);
  assertOk(response, "Loqui voices failed");
  return response.voices || AVAILABLE_VOICES;
}

export async function generateWav(text, options = {}) {
  const clean = cleanSpeechText(text);
  if (!clean) throw new Error("Text cannot be empty");

  const response = await sendLoqui(
    {
      type: "generate",
      text: clean,
      voice: normalizeVoice(options.voice) || "fantine",
    },
    { ...options, timeoutMs: options.timeoutMs || 60000 },
  );
  assertOk(response, "Loqui generation failed");
  if (!response.audioBase64) throw new Error("Loqui did not return audio data");
  return Buffer.from(response.audioBase64, "base64");
}

export async function saveWav(text, output, options = {}) {
  if (!output) throw new Error("Output path is required");
  const resolved = path.resolve(String(output));
  const wav = await generateWav(text, options);
  await fs.mkdir(path.dirname(resolved), { recursive: true });
  await fs.writeFile(resolved, wav);
  return resolved;
}

export function normalizeVoice(voice) {
  if (!voice || voice === "auto") return undefined;
  return String(voice).trim() || undefined;
}

export function assertOk(response, message) {
  if (!response?.ok) {
    throw new Error(`${message}: ${response?.error || "unknown error"}`);
  }
}
