import { AVAILABLE_VOICES, defaultSessionId, saveWav, speak, status, stop, voices } from "./client.js";

const PROTOCOL_VERSION = "2025-06-18";
const SUPPORTED_PROTOCOL_VERSIONS = new Set(["2024-11-05", "2025-03-26", "2025-06-18"]);
const SERVER_INFO = { name: "@swairshah/loqui-mcp", version: "0.1.0" };
const CAPABILITIES = { tools: {} };

const TOOLS = [
  {
    name: "speak",
    description: "Speak short natural text aloud through the local Loqui app",
    inputSchema: {
      type: "object",
      properties: {
        text: {
          type: "string",
          description: "Plain text to speak. Keep it brief and conversational.",
        },
        voice: {
          type: "string",
          description: `Optional Loqui voice. Use one of: auto, ${AVAILABLE_VOICES.join(", ")}.`,
        },
        sourceApp: {
          type: "string",
          description: "Optional source app label shown in Loqui.",
        },
        sessionId: {
          type: "string",
          description: "Optional session queue identifier. Defaults to the workspace name.",
        },
      },
      required: ["text"],
    },
  },
  {
    name: "stop",
    description: "Stop current Loqui speech and clear queued speech",
    inputSchema: {
      type: "object",
      properties: {
        sourceApp: { type: "string", description: "Optional source app metadata." },
        sessionId: { type: "string", description: "Optional session metadata." },
      },
    },
  },
  {
    name: "status",
    description: "Check whether the local Loqui server is running",
    inputSchema: {
      type: "object",
      properties: {},
    },
  },
  {
    name: "voices",
    description: "List voices exposed by Loqui",
    inputSchema: {
      type: "object",
      properties: {},
    },
  },
  {
    name: "save_audio",
    description: "Generate speech with Loqui and save it as a WAV file",
    inputSchema: {
      type: "object",
      properties: {
        text: { type: "string", description: "Plain text to synthesize." },
        output: { type: "string", description: "Path to write the WAV file." },
        voice: {
          type: "string",
          description: `Optional Loqui voice. Use one of: ${AVAILABLE_VOICES.join(", ")}.`,
        },
      },
      required: ["text", "output"],
    },
  },
];

let clientName = "";

export async function serveMcp() {
  let buffer = Buffer.alloc(0);
  let queue = Promise.resolve();
  let outputMode = "line";

  const drain = async (flush = false) => {
    while (true) {
      const frame = readFrame(buffer, flush);
      if (!frame) break;
      buffer = buffer.subarray(frame.bytesConsumed);
      outputMode = frame.mode;
      if (!frame.body.trim()) continue;

      let msg;
      try {
        msg = JSON.parse(frame.body);
      } catch {
        send(errorResponse(null, -32700, "Parse error"), outputMode);
        continue;
      }

      if (!msg.method || !("id" in msg)) continue;
      send(await handleRequest(msg), outputMode);
    }
  };

  await new Promise((resolve, reject) => {
    const readBuffered = () => {
      const chunks = [];
      let chunk;
      while ((chunk = process.stdin.read()) !== null) {
        chunks.push(typeof chunk === "string" ? Buffer.from(chunk) : Buffer.from(chunk));
      }
      if (!chunks.length) return;
      const data = Buffer.concat(chunks);
      queue = queue.then(async () => {
        buffer = Buffer.concat([buffer, data]);
        await drain();
      });
    };

    process.stdin.on("readable", readBuffered);
    process.stdin.on("end", () => queue.then(() => drain(true)).then(resolve, reject));
    process.stdin.on("error", reject);
    readBuffered();
    if (process.stdin.readableEnded) {
      queue.then(() => drain(true)).then(resolve, reject);
    }
  });
}

async function handleRequest(req) {
  const { id, method, params } = req;

  switch (method) {
    case "initialize": {
      clientName = params?.clientInfo?.name || "";
      const requested = params?.protocolVersion;
      const protocolVersion = SUPPORTED_PROTOCOL_VERSIONS.has(requested)
        ? requested
        : PROTOCOL_VERSION;
      return response(id, {
        protocolVersion,
        capabilities: CAPABILITIES,
        serverInfo: SERVER_INFO,
        instructions:
          "Use Loqui for short spoken feedback through the local Mac TTS server. Speak proactively for progress, completion, blockers, or brief conversational responses. Send clean plain text only: no markdown, URLs, XML, SSML, or code. Keep speech concise and natural.",
      });
    }
    case "ping":
      return response(id, {});
    case "tools/list":
      return response(id, { tools: TOOLS });
    case "tools/call":
      return handleToolCall(id, params || {});
    default:
      return errorResponse(id, -32601, `Method not found: ${method}`);
  }
}

async function handleToolCall(id, params) {
  const args = params.arguments || {};
  try {
    switch (params.name) {
      case "speak":
        return response(id, await toolSpeak(args));
      case "stop":
        return response(id, await toolStop(args));
      case "status":
        return response(id, await toolStatus());
      case "voices":
        return response(id, await toolVoices());
      case "save_audio":
        return response(id, await toolSaveAudio(args));
      default:
        return response(id, toolError(`Unknown tool: ${params.name}`));
    }
  } catch (error) {
    return response(id, toolError(error.message));
  }
}

async function toolSpeak(args) {
  if (!args.text) throw new Error("text is required");
  const sourceApp = args.sourceApp || clientName || "loqui-mcp";
  const sessionId = args.sessionId || defaultSessionId();
  const result = await speak(args.text, { voice: args.voice, sourceApp, sessionId });
  return toolText(
    `Queued speech through Loqui (${result.queued ?? "unknown"} item(s) queued, session ${sessionId}).`,
  );
}

async function toolStop(args) {
  await stop({
    sourceApp: args.sourceApp || clientName || "loqui-mcp",
    sessionId: args.sessionId || defaultSessionId(),
  });
  return toolText("Stopped Loqui speech and cleared queued playback.");
}

async function toolStatus() {
  const result = await status();
  const bits = [`Loqui: ${result.ok ? "running" : "not running"}`];
  if (typeof result.pending === "number") bits.push(`pending: ${result.pending}`);
  if (typeof result.playing === "boolean") bits.push(`playing: ${result.playing}`);
  if (result.currentQueue) bits.push(`current queue: ${result.currentQueue}`);
  return toolText(bits.join(" | "));
}

async function toolVoices() {
  const list = await voices();
  return toolText(`Loqui voices:\n${list.map((voice) => `- ${voice}`).join("\n")}`);
}

async function toolSaveAudio(args) {
  if (!args.text) throw new Error("text is required");
  if (!args.output) throw new Error("output is required");
  const output = await saveWav(args.text, args.output, { voice: args.voice });
  return toolText(`Saved Loqui speech audio to ${output}.`);
}

function toolText(text) {
  return { content: [{ type: "text", text }] };
}

function toolError(text) {
  return { isError: true, content: [{ type: "text", text }] };
}

function send(msg, mode) {
  const body = JSON.stringify(msg);
  if (mode === "framed") {
    process.stdout.write(`Content-Length: ${Buffer.byteLength(body, "utf8")}\r\n\r\n${body}`);
  } else {
    process.stdout.write(`${body}\n`);
  }
}

function response(id, result) {
  return { jsonrpc: "2.0", id, result };
}

function errorResponse(id, code, message) {
  return { jsonrpc: "2.0", id, error: { code, message } };
}

function readFrame(buffer, flush = false) {
  const header = readHeader(buffer);
  if (header) {
    const bodyStart = header.headerEnd + header.separatorLength;
    const frameEnd = bodyStart + header.contentLength;
    if (buffer.length < frameEnd) return null;
    return {
      body: buffer.subarray(bodyStart, frameEnd).toString("utf8"),
      bytesConsumed: frameEnd,
      mode: "framed",
    };
  }

  const newline = buffer.indexOf("\n");
  if (newline === -1) {
    if (!flush || !buffer.length) return null;
    return { body: buffer.toString("utf8"), bytesConsumed: buffer.length, mode: "line" };
  }

  const line = buffer.subarray(0, newline).toString("utf8").trim();
  if (!line) return { body: "", bytesConsumed: newline + 1, mode: "line" };
  if (!line.startsWith("{")) return null;
  return { body: line, bytesConsumed: newline + 1, mode: "line" };
}

function readHeader(buffer) {
  const crlfIndex = buffer.indexOf("\r\n\r\n");
  const lfIndex = buffer.indexOf("\n\n");
  let headerEnd = -1;
  let separatorLength = 0;

  if (crlfIndex !== -1 && (lfIndex === -1 || crlfIndex < lfIndex)) {
    headerEnd = crlfIndex;
    separatorLength = 4;
  } else if (lfIndex !== -1) {
    headerEnd = lfIndex;
    separatorLength = 2;
  } else {
    return null;
  }

  let contentLength = null;
  const headerText = buffer.subarray(0, headerEnd).toString("utf8");
  for (const line of headerText.split(/\r?\n/)) {
    const sep = line.indexOf(":");
    if (sep === -1) continue;
    const key = line.slice(0, sep).trim().toLowerCase();
    const value = line.slice(sep + 1).trim();
    if (key === "content-length") {
      const parsed = Number.parseInt(value, 10);
      if (!Number.isFinite(parsed) || parsed < 0) return null;
      contentLength = parsed;
    }
  }
  if (contentLength == null) return null;
  return { headerEnd, separatorLength, contentLength };
}
