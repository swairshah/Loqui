#!/usr/bin/env node

import {
  drainTranscriptVoiceTags,
  extractVoiceTags,
  readStdinJson,
  sessionIdFor,
  speak,
} from "./loqui.js";

const input = await readStdinJson();
const sessionId = sessionIdFor(input);
await drainTranscriptVoiceTags(input);

const chunks = input.transcript_path || input.transcriptPath
  ? []
  : extractVoiceTags(input.last_assistant_message || "");

for (const chunk of chunks) {
  await speak(chunk, sessionId);
}

process.stdout.write(JSON.stringify({}));
