/**
 * pi-talk - Text-to-speech extension for Pi
 *
 * Adds text-to-speech capabilities to Pi using <voice> tags.
 * Speaks only <voice> tagged content from assistant responses.
 *
 * Requires Loqui.app (TTS server at localhost:18080).
 * Install with: brew install swairshah/tap/loqui
 *
 * Commands:
 *   /tts        - Toggle TTS on/off
 *   /tts-mute   - Mute audio (keeps voice tags in responses)
 *   /tts-style  - Toggle voice style (succinct/verbose)
 *   /tts-voice  - Change TTS voice
 *   /tts-say    - Speak arbitrary text
 *   /tts-stop   - Stop current speech
 *   /tts-status - Show status
 *
 * Global shortcut (via Loqui.app): Cmd+. to stop speech
 */

import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import { spawn, type ChildProcess } from "node:child_process";

// Configuration - matches PocketTTS.app defaults
const TTS_PORT = 18080;
const TTS_HOST = "127.0.0.1";
const DEFAULT_VOICE = "fantine";
const AVAILABLE_VOICES = ["alba", "marius", "javert", "fantine", "cosette", "eponine", "azelma"];

// System prompt injection for voice tags - succinct style
const VOICE_PROMPT_SUCCINCT = `
## Voice Output

You have text-to-speech capabilities. When responding, include natural spoken summaries using <voice> tags.

Guidelines for <voice> content:
- Keep it brief and conversational (1-3 sentences)
- Summarize what you're doing or found, don't read code/details verbatim
- Use natural speech patterns, contractions, casual tone
- Place <voice> tags at natural pause points in your response
- For code: describe what it does, don't read the code itself
- For errors: summarize the issue conversationally
- For confirmations: keep it simple like "Done!" or "Got it, working on that."

Examples:
- Starting work: <voice>Okay, let me look into that for you.</voice>
- Found something: <voice>Found the issue. Looks like there's a typo in the config file.</voice>
- Completed task: <voice>All done! Created the new component with the props you asked for.</voice>
- Explaining code: <voice>This function takes a list of users and filters out the inactive ones.</voice>

The text outside <voice> tags shows normally in the terminal. Only <voice> content is spoken.
`;

// System prompt injection for voice tags - verbose/conversational style
const VOICE_PROMPT_VERBOSE = `
## Voice Output

You have text-to-speech capabilities. When responding, use <voice> tags liberally to speak conversationally with the user.

Guidelines for <voice> content:
- Speak most of your conversational responses - questions, comments, reactions, explanations
- Use natural speech patterns, contractions, casual tone
- Multiple <voice> tags per response is encouraged
- Speak your thinking process, questions, and follow-ups
- For code: describe what it does (don't read the code itself)
- For file contents and technical details: summarize rather than read verbatim
- For errors: explain what went wrong conversationally
- For questions to the user: always speak them

Examples:
- Starting work: <voice>Okay, let me look into that for you.</voice>
- Thinking aloud: <voice>Hmm, this looks like it might be a permissions issue. Let me check the file ownership.</voice>
- Asking questions: <voice>Do you want me to fix this automatically, or would you rather review it first?</voice>
- Casual remarks: <voice>Nice! That test is passing now.</voice>
- Explaining findings: <voice>So I found the bug. Basically the loop was off by one, so it was skipping the last item in the array. Pretty common mistake actually.</voice>
- Follow-ups: <voice>That should do it! Let me know if you want me to add any tests for this.</voice>

The text outside <voice> tags shows normally in the terminal. Only <voice> content is spoken.
Speak freely and conversationally - the user prefers hearing your responses.
`;

export default function (pi: ExtensionAPI) {
  let ttsEnabled = true;       // Master switch - controls everything
  let ttsMuted = false;        // Just mute audio, keep voice tags
  let serverReady = false;
  let serverWarningShown = false;  // Only show server warning once per session
  let voiceStyle: "succinct" | "verbose" = "verbose";  // Voice prompt style
  let currentVoice = DEFAULT_VOICE;  // Current TTS voice
  
  // Streaming state
  let voiceBuffer = "";
  let processedUpTo = 0;
  let audioQueue: Promise<void> = Promise.resolve();
  let currentPlayer: ChildProcess | null = null;

  // Check if server is running (Loqui.app)
  async function checkServer(): Promise<boolean> {
    try {
      const res = await fetch(`http://${TTS_HOST}:${TTS_PORT}/health`);
      serverReady = res.ok;
      return serverReady;
    } catch {
      serverReady = false;
      return false;
    }
  }

  // Extract <voice> tags from text
  function extractVoiceTags(text: string, fromIndex: number): { content: string; endIndex: number }[] {
    const results: { content: string; endIndex: number }[] = [];
    const regex = /<voice>([\s\S]*?)<\/voice>/g;
    regex.lastIndex = fromIndex;
    
    let match;
    while ((match = regex.exec(text)) !== null) {
      results.push({
        content: match[1].trim(),
        endIndex: match.index + match[0].length,
      });
    }
    
    return results;
  }

  // Stream audio using PCM piped to ffplay
  async function speakStreaming(text: string): Promise<void> {
    if (!text.trim()) return;

    // console.log("[TTS] Speaking:", text.slice(0, 50));

    // Create abort controller with timeout
    const abortController = new AbortController();
    const fetchTimeout = setTimeout(() => abortController.abort(), 5000);

    try {
      const res = await fetch(`http://${TTS_HOST}:${TTS_PORT}/stream`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ text, voice: currentVoice }),
        signal: abortController.signal,
      });
      clearTimeout(fetchTimeout);

      if (!res.ok || !res.body) {
        console.log("[TTS] Server response not ok:", res.status);
        return;
      }
      // console.log("[TTS] Got stream, spawning ffplay");

      const player = spawn("/opt/homebrew/bin/ffplay", [
        "-f", "s16le",
        "-ar", "24000",
        "-ch_layout", "mono",
        "-nodisp",
        "-autoexit",
        "-loglevel", "quiet",
        "-i", "pipe:0"
      ], {
        stdio: ["pipe", "ignore", "ignore"],
      });
      
      let playerExited = false;

      // Handle player errors gracefully
      player.on("error", () => {
        playerExited = true;
        currentPlayer = null;
      });
      
      player.on("exit", () => {
        playerExited = true;
        currentPlayer = null;
      });

      // Handle stdin errors (EPIPE when player exits early)
      if (player.stdin) {
        player.stdin.on("error", () => {
          // Ignore EPIPE errors - player may have exited
        });
      }

      currentPlayer = player;

      const reader = res.body.getReader();
      
      // Stream timeout - abort if no data for 10 seconds
      let streamTimeout: ReturnType<typeof setTimeout>;
      const resetStreamTimeout = () => {
        clearTimeout(streamTimeout);
        streamTimeout = setTimeout(() => {
          reader.cancel().catch(() => {});
          if (!playerExited) player.kill();
        }, 10000);
      };
      resetStreamTimeout();
      
      try {
        while (!playerExited) {
          const { done, value } = await reader.read();
          if (done) break;
          
          resetStreamTimeout();
          
          // Check if player is still alive before writing
          if (player.stdin && !player.stdin.destroyed && !player.killed) {
            try {
              player.stdin.write(Buffer.from(value));
            } catch {
              // Player died, stop trying to write
              break;
            }
          } else {
            break;
          }
        }
      } finally {
        clearTimeout(streamTimeout);
        try {
          reader.cancel().catch(() => {});
          if (player.stdin && !player.stdin.destroyed) {
            player.stdin.end();
          }
        } catch {
          // Ignore errors on cleanup
        }
      }

      // Wait for player to exit (ffplay with -autoexit will exit when done)
      if (!playerExited) {
        await new Promise<void>((resolve) => {
          const exitHandler = () => {
            playerExited = true;
            currentPlayer = null;
            resolve();
          };
          player.on("exit", exitHandler);
          player.on("error", exitHandler);
          // Long timeout fallback (60s) - ffplay should exit on its own with -autoexit
          setTimeout(() => {
            if (!playerExited) {
              player.kill();
            }
            currentPlayer = null;
            resolve();
          }, 60000);
        });
      }

    } catch (err) {
      clearTimeout(fetchTimeout);
      if ((err as Error).name === "AbortError") {
        console.log("[TTS] Fetch timed out");
      } else {
        console.log("[TTS] Error:", err);
      }
    }
  }

  function queueSpeech(text: string) {
    audioQueue = audioQueue.then(() => speakStreaming(text)).catch(() => {});
  }

  // Process streaming text for voice tags
  function processStreamingText(fullText: string) {
    if (!ttsEnabled || !serverReady) return;

    voiceBuffer = fullText;
    
    // Find complete <voice> tags we haven't processed yet
    const voiceTags = extractVoiceTags(voiceBuffer, processedUpTo);
    
    for (const tag of voiceTags) {
      if (tag.content) {
        queueSpeech(tag.content);
      }
      processedUpTo = tag.endIndex;
    }
  }

  function resetStreamingState() {
    voiceBuffer = "";
    processedUpTo = 0;
  }

  // Inject voice prompt into system prompt (only if TTS enabled)
  pi.on("before_agent_start", async (event) => {
    if (!ttsEnabled) return; // Don't inject voice prompt if disabled
    const prompt = voiceStyle === "verbose" ? VOICE_PROMPT_VERBOSE : VOICE_PROMPT_SUCCINCT;
    return {
      systemPrompt: event.systemPrompt + "\n" + prompt,
    };
  });

  // Check server on session start
  pi.on("session_start", async (_event, ctx) => {
    serverWarningShown = false;  // Reset for new session
    const ready = await checkServer();
    if (ttsEnabled) {
      if (ready) {
        ctx.ui.notify("🔊 TTS connected", "info");
        ctx.ui.setStatus("tts", "🔊");
      } else {
        if (!serverWarningShown) {
          ctx.ui.notify("⚠️ TTS server not running. Start Loqui.app or install with: brew install swairshah/tap/loqui", "warning");
          serverWarningShown = true;
        }
        ctx.ui.setStatus("tts", "⚠️");
      }
    } else {
      ctx.ui.setStatus("tts", "🔇 off");
    }
  });

  pi.on("session_shutdown", async () => {
    if (currentPlayer) {
      currentPlayer.kill();
    }
  });

  pi.on("message_start", async (event) => {
    if (event.message.role === "assistant") {
      resetStreamingState();
      // Re-check server in case it was started/stopped
      await checkServer();
    }
  });

  pi.on("message_update", async (event) => {
    if (!ttsEnabled || ttsMuted) return;
    
    const msg = event.message;
    if (msg.role !== "assistant") return;

    const textParts = msg.content
      .filter((c): c is { type: "text"; text: string } => c.type === "text")
      .map((c) => c.text);

    const fullText = textParts.join(" ");
    processStreamingText(fullText);
  });

  pi.on("message_end", async (event) => {
    if (event.message.role === "assistant") {
      resetStreamingState();
    }
  });

  // Helper to update status display
  function updateStatus(ctx: { ui: { setStatus: (id: string, text: string) => void } }) {
    if (!ttsEnabled) {
      ctx.ui.setStatus("tts", "🔇 off");
    } else if (ttsMuted) {
      ctx.ui.setStatus("tts", "🔇");
    } else if (serverReady) {
      ctx.ui.setStatus("tts", voiceStyle === "verbose" ? "🔊+" : "🔊");
    } else {
      ctx.ui.setStatus("tts", "⚠️");
    }
  }

  // Commands
  pi.registerCommand("tts", {
    description: "Toggle TTS completely on/off (includes voice prompt injection)",
    handler: async (_args, ctx) => {
      ttsEnabled = !ttsEnabled;
      ttsMuted = false; // Reset mute when toggling master
      ctx.ui.notify(
        ttsEnabled 
          ? "🔊 TTS enabled - I'll include voice summaries" 
          : "🔇 TTS disabled - normal text responses",
        "info"
      );
      updateStatus(ctx);
    },
  });

  pi.registerCommand("tts-mute", {
    description: "Mute/unmute TTS audio (keeps voice tags in responses)",
    handler: async (_args, ctx) => {
      if (!ttsEnabled) {
        ctx.ui.notify("TTS is disabled. Use /tts to enable first.", "warning");
        return;
      }
      ttsMuted = !ttsMuted;
      ctx.ui.notify(ttsMuted ? "🔇 TTS muted" : "🔊 TTS unmuted", "info");
      updateStatus(ctx);
    },
  });

  pi.registerCommand("tts-style", {
    description: "Toggle voice style: succinct (brief summaries) or verbose (more conversational)",
    handler: async (_args, ctx) => {
      voiceStyle = voiceStyle === "verbose" ? "succinct" : "verbose";
      ctx.ui.notify(
        voiceStyle === "verbose"
          ? "🔊+ Voice style: verbose (more conversational)"
          : "🔊 Voice style: succinct (brief summaries)",
        "info"
      );
      updateStatus(ctx);
    },
  });

  pi.registerCommand("tts-voice", {
    description: `Change TTS voice (${AVAILABLE_VOICES.join(", ")})`,
    handler: async (args, ctx) => {
      if (!args) {
        ctx.ui.notify(`Current voice: ${currentVoice}\nAvailable: ${AVAILABLE_VOICES.join(", ")}`, "info");
        return;
      }
      const voice = args.trim().toLowerCase();
      if (!AVAILABLE_VOICES.includes(voice)) {
        ctx.ui.notify(`Unknown voice: ${voice}\nAvailable: ${AVAILABLE_VOICES.join(", ")}`, "warning");
        return;
      }
      currentVoice = voice;
      ctx.ui.notify(`🎤 Voice changed to: ${voice}`, "info");
    },
  });

  pi.registerCommand("tts-say", {
    description: "Speak arbitrary text",
    handler: async (args, ctx) => {
      if (!args) {
        ctx.ui.notify("Usage: /tts-say <text>", "warning");
        return;
      }
      if (!serverReady) {
        const ready = await checkServer();
        if (!ready) {
          ctx.ui.notify("TTS server not running", "error");
          return;
        }
      }
      queueSpeech(args);
    },
  });

  pi.registerCommand("tts-stop", {
    description: "Stop current speech",
    handler: async (_args, ctx) => {
      if (currentPlayer) {
        currentPlayer.kill();
        currentPlayer = null;
        ctx.ui.notify("Speech stopped", "info");
      }
    },
  });

  pi.registerCommand("tts-status", {
    description: "Show TTS status",
    handler: async (_args, ctx) => {
      const ready = await checkServer();
      const status = [
        `Server: ${ready ? "running ✓" : "not running ✗"}`,
        `TTS: ${ttsEnabled ? "enabled" : "disabled"}`,
        `Audio: ${ttsMuted ? "muted" : "on"}`,
        `Voice: ${currentVoice}`,
        `Style: ${voiceStyle}`,
      ].join(" | ");
      ctx.ui.notify(status, "info");
      updateStatus(ctx);
    },
  });
}
