#!/usr/bin/env node

import { health, readStdinJson, sessionIdFor, stop } from "./loqui.js";

const input = await readStdinJson();
const sessionId = sessionIdFor(input);

// Loqui currently treats stop as a global clear. Keep automatic stop opt-in
// until the broker supports scoped stop by sourceApp/sessionId.
if (process.env.LOQUI_CODEX_STOP_ON_PROMPT === "1") {
  await stop(sessionId);
}

await health();
process.stdout.write(JSON.stringify({}));
