#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
EXTENSIONS_DIR="$PROJECT_ROOT/Extensions"
CLAUDE_PLUGIN_DIR="$EXTENSIONS_DIR/claude-code-talk"
CODEX_TALK_DIR="$EXTENSIONS_DIR/codex-talk"
PI_TALK_DIR="$EXTENSIONS_DIR/pi-talk"
LOQUI_MCP_ENTRY="$EXTENSIONS_DIR/loqui-mcp/src/index.js"

DRY_RUN=0
SKIP_MCP=0
SKIP_BREW=0
SCOPE="user"
INTERACTIVE="auto"
TARGETS="all"

DO_CLAUDE=1
DO_CODEX=1
DO_PI=1

usage() {
  cat <<'EOF'
Usage: scripts/setup-agent-extensions.sh [options]

Sets up Loqui speech integrations for Claude Code, Codex, and Pi.

Options:
  --interactive   Always run interactive setup prompts.
  --non-interactive
                  Never prompt; rely on flags/defaults.
  --targets LIST  Comma-separated targets: all,claude-code,codex,pi
                  (aliases: claude,claudecode).
  --dry-run       Print what would change without writing configs or installing.
  --skip-mcp      Skip Loqui MCP registration for explicit agent tools.
  --skip-brew     Do not install the Loqui Homebrew formula if loqui is missing.
  --scope SCOPE   Claude plugin scope: user, project, or local. Default: user.
  -h, --help      Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --interactive)
      INTERACTIVE="1"
      ;;
    --non-interactive)
      INTERACTIVE="0"
      ;;
    --targets)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --targets" >&2
        exit 2
      fi
      TARGETS="$2"
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      ;;
    --skip-mcp)
      SKIP_MCP=1
      ;;
    --skip-brew)
      SKIP_BREW=1
      ;;
    --scope)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --scope" >&2
        exit 2
      fi
      SCOPE="$2"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

if [[ "$SCOPE" != "user" && "$SCOPE" != "project" && "$SCOPE" != "local" ]]; then
  echo "Invalid --scope value: $SCOPE" >&2
  exit 2
fi

log() {
  printf '%s\n' "$*"
}

warn() {
  printf 'warning: %s\n' "$*" >&2
}

have() {
  command -v "$1" >/dev/null 2>&1
}

run() {
  if [[ "$DRY_RUN" == "1" ]]; then
    printf 'dry-run:'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

backup_file() {
  local file="$1"
  if [[ "$DRY_RUN" == "1" || ! -f "$file" ]]; then
    return 0
  fi

  local stamp backup
  stamp="$(date +%Y%m%d-%H%M%S)"
  backup="${file}.bak-${stamp}"
  cp "$file" "$backup"
  log "Backed up $file to $backup"
}

normalize_target() {
  local value
  value="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$value" in
    all)
      printf 'all'
      ;;
    claude|claude-code|claudecode)
      printf 'claude'
      ;;
    codex)
      printf 'codex'
      ;;
    pi)
      printf 'pi'
      ;;
    *)
      return 1
      ;;
  esac
}

apply_targets() {
  local raw="$1"
  local normalized item

  DO_CLAUDE=0
  DO_CODEX=0
  DO_PI=0

  IFS=',' read -r -a items <<< "$raw"
  for item in "${items[@]}"; do
    item="$(printf '%s' "$item" | xargs)"
    [[ -z "$item" ]] && continue

    if ! normalized="$(normalize_target "$item")"; then
      echo "Invalid target in --targets: $item" >&2
      exit 2
    fi

    if [[ "$normalized" == "all" ]]; then
      DO_CLAUDE=1
      DO_CODEX=1
      DO_PI=1
      return 0
    fi

    case "$normalized" in
      claude) DO_CLAUDE=1 ;;
      codex) DO_CODEX=1 ;;
      pi) DO_PI=1 ;;
    esac
  done

  if [[ "$DO_CLAUDE" == "0" && "$DO_CODEX" == "0" && "$DO_PI" == "0" ]]; then
    echo "No valid targets selected. Use --targets all,claude-code,codex,pi" >&2
    exit 2
  fi
}

prompt_yes_no() {
  local question="$1"
  local default="$2"
  local reply

  while true; do
    if [[ "$default" == "y" ]]; then
      read -r -p "$question [Y/n] " reply || return 1
      reply="${reply:-y}"
    else
      read -r -p "$question [y/N] " reply || return 1
      reply="${reply:-n}"
    fi

    case "$(printf '%s' "$reply" | tr '[:upper:]' '[:lower:]')" in
      y|yes) return 0 ;;
      n|no) return 1 ;;
      *) echo "Please answer y or n." ;;
    esac
  done
}

interactive_setup() {
  local choice

  log ""
  log "Loqui setup"
  log "Choose what to configure:"
  log "  1) All (Claude Code + Codex + Pi)"
  log "  2) Claude Code"
  log "  3) Codex"
  log "  4) Pi"
  log "  5) Custom mix"

  while true; do
    read -r -p "Select an option [1-5] (default 1): " choice || break
    choice="${choice:-1}"
    case "$choice" in
      1)
        DO_CLAUDE=1
        DO_CODEX=1
        DO_PI=1
        break
        ;;
      2)
        DO_CLAUDE=1
        DO_CODEX=0
        DO_PI=0
        break
        ;;
      3)
        DO_CLAUDE=0
        DO_CODEX=1
        DO_PI=0
        break
        ;;
      4)
        DO_CLAUDE=0
        DO_CODEX=0
        DO_PI=1
        break
        ;;
      5)
        if prompt_yes_no "Set up Claude Code?" "y"; then DO_CLAUDE=1; else DO_CLAUDE=0; fi
        if prompt_yes_no "Set up Codex?" "y"; then DO_CODEX=1; else DO_CODEX=0; fi
        if prompt_yes_no "Set up Pi?" "y"; then DO_PI=1; else DO_PI=0; fi
        if [[ "$DO_CLAUDE" == "0" && "$DO_CODEX" == "0" && "$DO_PI" == "0" ]]; then
          echo "You must choose at least one target."
          continue
        fi
        break
        ;;
      *)
        echo "Please choose 1, 2, 3, 4, or 5."
        ;;
    esac
  done

  if [[ "$DO_CLAUDE" == "1" ]]; then
    while true; do
      read -r -p "Claude plugin scope (user/project/local) [${SCOPE}]: " choice || break
      choice="${choice:-$SCOPE}"
      case "$choice" in
        user|project|local)
          SCOPE="$choice"
          break
          ;;
        *)
          echo "Scope must be user, project, or local."
          ;;
      esac
    done
  fi

  if prompt_yes_no "Register Loqui MCP server as part of setup?" "$([[ "$SKIP_MCP" == "1" ]] && echo n || echo y)"; then
    SKIP_MCP=0
  else
    SKIP_MCP=1
  fi

  if prompt_yes_no "Auto-install Loqui with Homebrew if missing?" "$([[ "$SKIP_BREW" == "1" ]] && echo n || echo y)"; then
    SKIP_BREW=0
  else
    SKIP_BREW=1
  fi

  log ""
  log "Summary:"
  log "  Claude Code: $([[ "$DO_CLAUDE" == "1" ]] && echo yes || echo no)"
  log "  Codex:       $([[ "$DO_CODEX" == "1" ]] && echo yes || echo no)"
  log "  Pi:          $([[ "$DO_PI" == "1" ]] && echo yes || echo no)"
  log "  Claude scope: $SCOPE"
  log "  Register MCP: $([[ "$SKIP_MCP" == "1" ]] && echo no || echo yes)"
  log "  Brew install fallback: $([[ "$SKIP_BREW" == "1" ]] && echo no || echo yes)"
  log ""
}

check_paths() {
  local missing=0
  local required=()

  [[ "$DO_CLAUDE" == "1" ]] && required+=("$CLAUDE_PLUGIN_DIR")
  [[ "$DO_CODEX" == "1" ]] && required+=("$CODEX_TALK_DIR")
  [[ "$DO_PI" == "1" ]] && required+=("$PI_TALK_DIR")
  [[ "$SKIP_MCP" == "0" ]] && required+=("$LOQUI_MCP_ENTRY")

  for path in "${required[@]}"; do
    if [[ ! -e "$path" ]]; then
      warn "missing expected path: $path"
      missing=1
    fi
  done
  if [[ "$missing" == "1" ]]; then
    exit 1
  fi
}

ensure_loqui() {
  log ""
  log "[1/6] Checking Loqui"

  if have loqui; then
    log "loqui CLI found: $(command -v loqui)"
    return 0
  fi

  if [[ -x "$PROJECT_ROOT/bin/loqui" ]]; then
    log "repo loqui CLI found: $PROJECT_ROOT/bin/loqui"
    return 0
  fi

  if [[ "$SKIP_BREW" == "1" ]]; then
    warn "loqui command not found; install Loqui.app or run brew install swairshah/tap/loqui"
    return 0
  fi

  if have brew; then
    log "loqui command not found; installing Homebrew formula swairshah/tap/loqui"
    run brew install swairshah/tap/loqui
  else
    warn "loqui command not found and Homebrew is unavailable; install Loqui.app separately"
  fi
}

install_claude() {
  if [[ "$DO_CLAUDE" != "1" ]]; then
    log ""
    log "[2/6] Skipping Claude Code plugin (not selected)"
    return 0
  fi

  log ""
  log "[2/6] Setting up Claude Code plugin"

  if ! have claude; then
    warn "claude CLI not found; skipping Claude Code plugin"
    return 0
  fi

  run claude plugin validate "$CLAUDE_PLUGIN_DIR"

  if [[ "$DRY_RUN" == "1" ]]; then
    run claude plugin install --scope "$SCOPE" "$CLAUDE_PLUGIN_DIR"
    return 0
  fi

  if claude plugin install --scope "$SCOPE" "$CLAUDE_PLUGIN_DIR"; then
    log "Installed Claude Code plugin from $CLAUDE_PLUGIN_DIR"
  else
    warn "Claude plugin install failed; if it is already installed, run: claude plugin update claude-talk"
  fi
}

install_codex() {
  if [[ "$DO_CODEX" != "1" ]]; then
    log ""
    log "[3/6] Skipping Codex setup (not selected)"
    return 0
  fi

  log ""
  log "[3/6] Setting up Codex hooks and voice instructions"

  if ! have node; then
    warn "node is required for Codex hook scripts; skipping Codex setup"
    return 0
  fi

  local codex_home config_file hooks_file agents_file
  codex_home="${CODEX_HOME:-$HOME/.codex}"
  config_file="$codex_home/config.toml"
  hooks_file="$codex_home/hooks.json"
  agents_file="$codex_home/AGENTS.md"

  backup_file "$config_file"
  backup_file "$hooks_file"
  backup_file "$agents_file"

  if [[ "$DRY_RUN" != "1" ]]; then
    mkdir -p "$codex_home"
  fi

  LOQUI_PROJECT_ROOT="$PROJECT_ROOT" \
  LOQUI_CODEX_HOME_TARGET="$codex_home" \
  LOQUI_DRY_RUN="$DRY_RUN" \
    node <<'NODE'
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const process = require("node:process");

const projectRoot = path.resolve(process.env.LOQUI_PROJECT_ROOT);
const codexHome = path.resolve(process.env.LOQUI_CODEX_HOME_TARGET || path.join(os.homedir(), ".codex"));
const dryRun = process.env.LOQUI_DRY_RUN === "1";
const codexTalkRoot = path.join(projectRoot, "Extensions", "codex-talk");

const hooksFile = path.join(codexHome, "hooks.json");
const configFile = path.join(codexHome, "config.toml");
const agentsFile = path.join(codexHome, "AGENTS.md");

const managedStart = "<!-- LOQUI_CODEX_VOICE_START -->";
const managedEnd = "<!-- LOQUI_CODEX_VOICE_END -->";
const voiceInstructions = `${managedStart}
You have text-to-speech support through Loqui: any text inside <voice>...</voice> tags will be spoken aloud.
Every conversational response MUST include at least one literal <voice>...</voice> tag.
Use short, natural <voice> summaries when starting work, reaching an important finding, before or after long tool phases, when asking for input, and when finishing.
Keep spoken text conversational and concise; summarize files, commands, outputs, errors, and code instead of reading them verbatim.
Do not put Markdown, XML, SSML, code blocks, nested tags, or file dumps inside <voice>; use plain human speech only.
Text outside <voice> tags is normal Codex output and will not be spoken, so keep detailed technical content outside <voice> tags.
Do not repeat the same sentence both inside and outside a <voice> tag.
Avoid excessive narration: speak only when it helps the user follow progress or respond at the right time.
${managedEnd}
`;

function shellQuote(value) {
  const text = String(value);
  if (/^[A-Za-z0-9_./:@%+=,-]+$/.test(text)) return text;
  return `'${text.replace(/'/g, "'\\''")}'`;
}

function readText(file) {
  try {
    return fs.readFileSync(file, "utf8");
  } catch {
    return "";
  }
}

function readJson(file) {
  const text = readText(file);
  if (!text.trim()) return {};
  try {
    return JSON.parse(text);
  } catch (error) {
    throw new Error(`${file} is not valid JSON: ${error.message}`);
  }
}

function writeIfChanged(file, next) {
  const previous = readText(file);
  if (previous === next) {
    console.log(`No change ${displayPath(file)}`);
    return;
  }
  if (dryRun) {
    console.log(`Would write ${displayPath(file)}`);
    return;
  }
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, next);
  console.log(`Wrote ${displayPath(file)}`);
}

function displayPath(file) {
  const home = os.homedir();
  return file.startsWith(`${home}/`) ? `~/${file.slice(home.length + 1)}` : file;
}

function hookCommand(scriptName) {
  return [
    shellQuote(process.execPath),
    shellQuote(path.join(codexTalkRoot, "scripts", scriptName)),
  ].join(" ");
}

function commandLooksManaged(command) {
  const value = String(command || "");
  return value.includes("/Extensions/codex-talk/scripts/")
    || value.includes("\\/Extensions\\/codex-talk\\/scripts\\/")
    || value.includes("codex-talk-native/scripts/");
}

function managedHook(scriptName, extra = {}) {
  return {
    type: "command",
    command: hookCommand(scriptName),
    ...extra,
  };
}

function mergeEvent(existing, entry) {
  const current = Array.isArray(existing) ? existing : [];
  const cleaned = [];

  for (const matcher of current) {
    const hooks = Array.isArray(matcher?.hooks)
      ? matcher.hooks.filter((hook) => !commandLooksManaged(hook?.command))
      : [];
    if (hooks.length > 0) {
      cleaned.push({ ...matcher, hooks });
    }
  }

  cleaned.push(entry);
  return cleaned;
}

function updateHooks() {
  const config = readJson(hooksFile);
  const hooks = config.hooks && typeof config.hooks === "object" ? config.hooks : {};

  hooks.UserPromptSubmit = mergeEvent(hooks.UserPromptSubmit, {
    hooks: [
      managedHook("user_prompt_submit.js", {
        timeout: 5,
        statusMessage: "Checking Loqui",
      }),
    ],
  });

  hooks.PostToolUse = mergeEvent(hooks.PostToolUse, {
    matcher: ".*",
    hooks: [
      managedHook("post_tool_use.js", {
        timeout: 5,
      }),
    ],
  });

  hooks.Stop = mergeEvent(hooks.Stop, {
    hooks: [
      managedHook("stop.js", {
        timeout: 10,
        statusMessage: "Sending voice output",
      }),
    ],
  });

  writeIfChanged(hooksFile, `${JSON.stringify({ ...config, hooks }, null, 2)}\n`);
}

function updateConfigToml() {
  const text = readText(configFile);
  const lines = text ? text.split(/\r?\n/) : [];
  if (lines.length && lines.at(-1) === "") lines.pop();

  const featureStart = lines.findIndex((line) => line.trim() === "[features]");
  if (featureStart === -1) {
    const next = [
      ...lines,
      ...(lines.length ? [""] : []),
      "[features]",
      "codex_hooks = true",
    ].join("\n") + "\n";
    writeIfChanged(configFile, next);
    return;
  }

  let sectionEnd = lines.length;
  for (let i = featureStart + 1; i < lines.length; i += 1) {
    if (/^\s*\[/.test(lines[i])) {
      sectionEnd = i;
      break;
    }
  }

  let found = false;
  const nextLines = [...lines];
  for (let i = featureStart + 1; i < sectionEnd; i += 1) {
    if (/^\s*codex_hooks\s*=/.test(nextLines[i])) {
      nextLines[i] = "codex_hooks = true";
      found = true;
    }
  }
  if (!found) {
    nextLines.splice(sectionEnd, 0, "codex_hooks = true");
  }

  writeIfChanged(configFile, `${nextLines.join("\n")}\n`);
}

function updateAgents() {
  const previous = readText(agentsFile);
  const blockPattern = new RegExp(`${escapeRegExp(managedStart)}[\\s\\S]*?${escapeRegExp(managedEnd)}\\n?`);
  let next;

  if (blockPattern.test(previous)) {
    next = previous.replace(blockPattern, voiceInstructions);
  } else {
    next = `${previous.trimEnd()}${previous.trim() ? "\n\n" : ""}${voiceInstructions}`;
  }

  writeIfChanged(agentsFile, next);
}

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

updateHooks();
updateConfigToml();
updateAgents();
NODE
}

install_pi() {
  if [[ "$DO_PI" != "1" ]]; then
    log ""
    log "[4/6] Skipping Pi extension (not selected)"
    return 0
  fi

  log ""
  log "[4/6] Setting up Pi extension"

  if ! have pi; then
    warn "pi CLI not found; skipping Pi extension"
    return 0
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    run pi install "$PI_TALK_DIR"
  elif pi install "$PI_TALK_DIR"; then
    log "Installed Pi extension from $PI_TALK_DIR"
  else
    warn "Pi extension install failed; if it is already installed, restart Pi or reinstall with: pi install $PI_TALK_DIR"
  fi
}

install_mcp() {
  log ""

  if [[ "$SKIP_MCP" == "1" ]]; then
    log "[5/6] Skipping Loqui MCP registration"
    return 0
  fi

  log "[5/6] Registering Loqui MCP"

  if ! have node; then
    warn "node is required for Loqui MCP; skipping MCP registration"
    return 0
  fi

  local args=(node "$LOQUI_MCP_ENTRY" mcp --install --local)
  if [[ "$DRY_RUN" == "1" ]]; then
    args+=(--dry-run)
  fi
  run "${args[@]}"
}

finish() {
  log ""
  log "[6/6] Done"

  local selected=()
  [[ "$DO_CLAUDE" == "1" ]] && selected+=("Claude Code")
  [[ "$DO_CODEX" == "1" ]] && selected+=("Codex")
  [[ "$DO_PI" == "1" ]] && selected+=("Pi")

  if [[ ${#selected[@]} -gt 0 ]]; then
    log "Configured: ${selected[*]}"
    log "Restart selected tools so they reload plugins/hooks."
  fi

  log ""
  log "Quick tests:"
  [[ "$DO_CLAUDE" == "1" ]] && log "  Claude Code: /claude-talk:tts-status"
  [[ "$DO_CODEX" == "1" ]] && log "  Codex: start a new turn that includes <voice>Hello from Codex.</voice>"
  [[ "$DO_PI" == "1" ]] && log "  Pi: /tts-status"
  log "  Loqui CLI: loqui say \"Hello from Loqui\""
}

apply_targets "$TARGETS"

if [[ "$INTERACTIVE" == "auto" ]]; then
  if [[ -t 0 ]]; then
    INTERACTIVE="1"
  else
    INTERACTIVE="0"
  fi
fi

if [[ "$INTERACTIVE" == "1" ]]; then
  interactive_setup
fi

check_paths
ensure_loqui
install_claude
install_codex
install_pi
install_mcp
finish
