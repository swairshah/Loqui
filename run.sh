#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

APP_PATH=".build/Loqui.app"
APP_BIN="$APP_PATH/Contents/MacOS/Loqui"
CLI_BIN="bin/loqui"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}=== Loqui Build & Run ===${NC}"

# Kill existing Loqui + old embedded server
pkill -f "$APP_BIN" 2>/dev/null || true
pkill -f "pocket-tts-cli serve --port 18080" 2>/dev/null || true

# Build debug binaries
echo -e "${YELLOW}Building (swift build)...${NC}"
swift build --product Loqui
swift build --product loqui-cli

# Ensure app bundle exists (created by scripts/build-app.sh)
if [ ! -d "$APP_PATH" ]; then
  echo -e "${RED}Missing $APP_PATH${NC}"
  echo -e "Create it once with: ${YELLOW}./scripts/build-app.sh${NC}"
  exit 1
fi

# Replace app bundle binaries with fresh debug builds
echo -e "${YELLOW}Updating app bundle binaries...${NC}"
cp .build/debug/Loqui "$APP_BIN"
mkdir -p bin
cp .build/debug/loqui-cli "$CLI_BIN"
chmod +x "$CLI_BIN"

# Launch app
echo -e "${GREEN}Launching Loqui...${NC}"
open "$APP_PATH"
sleep 2

# Quick health checks
if pgrep -f "$APP_BIN" >/dev/null; then
  echo -e "${GREEN}Loqui process: running${NC}"
else
  echo -e "${RED}Loqui process: not running${NC}"
fi

if "$CLI_BIN" status >/dev/null 2>&1; then
  echo -e "${GREEN}Loqui socket: healthy${NC}"
else
  echo -e "${RED}Loqui socket: not healthy yet${NC}"
fi

echo -e "${GREEN}Done.${NC}"
