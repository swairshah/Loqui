#!/bin/bash
set -e

echo ""
echo "🔊 Loqui Installer"
echo "======================"
echo ""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Get project root (parent of scripts/)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
APP_PATH="$PROJECT_ROOT/.build/Loqui.app"
EXTENSION_SRC="$PROJECT_ROOT/Extensions/pi-talk"
CLI_SRC="$PROJECT_ROOT/.build/release/loqui-cli"
CODEX_AGENTS_FILE="$HOME/.codex/AGENTS.md"

CODEX_VOICE_PROMPT="$(cat <<'EOF'
You have text-to-speech support through PiTalk: any text inside <voice>...</voice> tags will be spoken aloud.
Use short, natural <voice> summaries when starting work, reaching an important finding, before or after long tool phases, when asking for input, and when finishing.
Keep spoken text conversational and concise; summarize files, commands, outputs, errors, and code instead of reading them verbatim.
Do not put Markdown, XML, SSML, code blocks, nested tags, or file dumps inside <voice>; use plain human speech only.
Text outside <voice> tags is normal Codex output and will not be spoken, so keep detailed technical content outside <voice> tags.
Avoid excessive narration: speak only when it helps the user follow progress or respond at the right time.
EOF
)"

# Check if running from the right directory
if [ ! -d "$SCRIPT_DIR" ]; then
    echo -e "${RED}Error: Could not determine script directory${NC}"
    exit 1
fi

# Step 1: Check for Homebrew
echo -e "${CYAN}[1/6]${NC} Checking for Homebrew..."
if command -v brew &> /dev/null; then
    echo -e "  ${GREEN}✓${NC} Homebrew is installed"
else
    echo -e "  ${YELLOW}Homebrew not found. Installing...${NC}"
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    
    # Add to path for Apple Silicon
    if [ -f "/opt/homebrew/bin/brew" ]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    fi
fi

# Step 2: Install ffmpeg (includes ffplay)
echo ""
echo -e "${CYAN}[2/6]${NC} Checking for ffmpeg..."
if command -v ffplay &> /dev/null; then
    echo -e "  ${GREEN}✓${NC} ffplay is installed ($(which ffplay))"
else
    echo -e "  ${YELLOW}Installing ffmpeg...${NC}"
    brew install ffmpeg
    echo -e "  ${GREEN}✓${NC} ffmpeg installed"
fi

# Step 3: Install Pi extension
echo ""
echo -e "${CYAN}[3/6]${NC} Installing Pi extension..."
PI_EXT_DIR="$HOME/.pi/agent/extensions/pi-tts"

if [ -d "$EXTENSION_SRC" ]; then
    mkdir -p "$PI_EXT_DIR"
    cp "$EXTENSION_SRC/index.ts" "$PI_EXT_DIR/"
    echo -e "  ${GREEN}✓${NC} Extension installed to $PI_EXT_DIR"
else
    echo -e "  ${YELLOW}⚠${NC} Extension source not found at $EXTENSION_SRC"
    echo -e "  ${YELLOW}  You may need to manually install the pi extension${NC}"
fi

# Step 4: Configure Codex AGENTS.md
echo ""
echo -e "${CYAN}[4/6]${NC} Configuring Codex voice instructions..."

mkdir -p "$(dirname "$CODEX_AGENTS_FILE")"
touch "$CODEX_AGENTS_FILE"

if grep -Fq "You have text-to-speech support through PiTalk:" "$CODEX_AGENTS_FILE"; then
    echo -e "  ${GREEN}✓${NC} Codex AGENTS.md already includes PiTalk voice instructions"
else
    {
        if [ -s "$CODEX_AGENTS_FILE" ]; then
            printf "\n"
        fi
        printf "%s\n" "$CODEX_VOICE_PROMPT"
    } >> "$CODEX_AGENTS_FILE"
    echo -e "  ${GREEN}✓${NC} Added PiTalk voice instructions to $CODEX_AGENTS_FILE"
fi

# Step 5: Install Loqui.app
echo ""
echo -e "${CYAN}[5/6]${NC} Installing Loqui.app..."

if [ -d "$APP_PATH" ]; then
    INSTALL_DIR="/Applications"
    INSTALLED_APP="$INSTALL_DIR/Loqui.app"
    
    # Remove old version if exists
    if [ -d "$INSTALLED_APP" ]; then
        echo -e "  Removing old version..."
        rm -rf "$INSTALLED_APP"
    fi
    
    # Copy to Applications
    cp -R "$APP_PATH" "$INSTALL_DIR/"
    echo -e "  ${GREEN}✓${NC} Installed to $INSTALLED_APP"
    
    # Start the app
    echo ""
    echo -e "${CYAN}Starting Loqui...${NC}"
    open "$INSTALLED_APP"
else
    echo -e "  ${YELLOW}⚠${NC} App not found at $APP_PATH"
    echo -e "  ${YELLOW}  Run ./scripts/build-app.sh first to build the app${NC}"
fi

# Step 6: Install loqui CLI
echo ""
echo -e "${CYAN}[6/6]${NC} Installing loqui CLI..."

if [ -f "$CLI_SRC" ]; then
    mkdir -p "$PROJECT_ROOT/bin"
    cp "$CLI_SRC" "$PROJECT_ROOT/bin/loqui"
    chmod +x "$PROJECT_ROOT/bin/loqui"
    echo -e "  ${GREEN}✓${NC} CLI installed to $PROJECT_ROOT/bin/loqui"
else
    echo -e "  ${YELLOW}⚠${NC} CLI not found at $CLI_SRC"
    echo -e "  ${YELLOW}  Run ./scripts/build-app.sh first to build${NC}"
fi

# Done
echo ""
echo -e "${GREEN}==============================${NC}"
echo -e "${GREEN}✓ Installation complete!${NC}"
echo -e "${GREEN}==============================${NC}"
echo ""
echo "Loqui should now be running in your menu bar."
echo "Look for the phone icon in the top-right of your screen."
echo ""
echo "To use with Pi:"
echo "  1. Restart Pi to load the extension"
echo "  2. The assistant will automatically use <voice> tags"
echo "  3. Use /tts-say to test: /tts-say Hello world"
echo ""
echo "Commands:"
echo "  /tts        - Toggle TTS on/off"
echo "  /tts-mute   - Mute audio (keeps voice tags)"
echo "  /tts-say    - Speak arbitrary text"
echo "  /tts-stop   - Stop current speech"
echo "  /tts-status - Show status"
echo ""
echo "CLI usage:"
echo "  ./bin/loqui say \"Hello world\"        # Speak text"
echo "  ./bin/loqui say -v alba \"Hello\"      # Different voice"
echo "  echo \"Hello\" | ./bin/loqui say       # Pipe text"
echo ""
echo "Global shortcut: Cmd+Shift+. to stop speech"
echo ""
