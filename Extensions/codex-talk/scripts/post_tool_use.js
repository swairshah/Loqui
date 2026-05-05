#!/usr/bin/env node

import { drainTranscriptVoiceTags, readStdinJson } from "./loqui.js";

const input = await readStdinJson();
await drainTranscriptVoiceTags(input);
process.stdout.write(JSON.stringify({}));
