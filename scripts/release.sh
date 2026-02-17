#!/bin/bash
set -e

# Change to project root (parent of scripts/)
cd "$(dirname "$0")/.."

# Release script for Loqui
# Usage: ./scripts/release.sh 1.0.0
#
# Prerequisites:
#   Store your Apple ID credentials in keychain:
#   xcrun notarytool store-credentials "AC_PASSWORD" \
#     --apple-id "your@email.com" \
#     --team-id "8B9YURJS4G" \
#     --password "app-specific-password"

VERSION=$1
APPLE_ID="swairshah@gmail.com"
TEAM_ID="8B9YURJS4G"
KEYCHAIN_PROFILE="AC_PASSWORD"

if [ -z "$VERSION" ]; then
    echo "Usage: ./scripts/release.sh <version>"
    echo "Example: ./scripts/release.sh 1.0.0"
    exit 1
fi

echo "🚀 Releasing Loqui v${VERSION}"
echo ""

# 1. Update version in build script
echo "📝 Updating version in build-app.sh..."
sed -i '' "s/<string>[0-9]*\.[0-9]*\.[0-9]*<\/string>/<string>${VERSION}<\/string>/g" scripts/build-app.sh

# 2. Build (includes signing)
echo "🔨 Building..."
./scripts/build-app.sh

# 3. Create zip for notarization
echo "📦 Creating distribution..."
mkdir -p dist
rm -f dist/Loqui-${VERSION}.zip dist/pi-extension-${VERSION}.zip

ditto -c -k --keepParent .build/Loqui.app dist/Loqui-${VERSION}.zip

# 4. Notarize
echo "📤 Submitting for notarization..."
xcrun notarytool submit dist/Loqui-${VERSION}.zip \
    --keychain-profile "$KEYCHAIN_PROFILE" \
    --wait

# 5. Staple the app
echo "📎 Stapling notarization ticket..."
xcrun stapler staple .build/Loqui.app

# 6. Re-create zip with stapled app
echo "📦 Re-packaging with stapled ticket..."
rm -f dist/Loqui-${VERSION}.zip
ditto -c -k --keepParent .build/Loqui.app dist/Loqui-${VERSION}.zip

# Also create pi-extension zip
zip -j dist/pi-extension-${VERSION}.zip Extensions/pi/index.ts

# 4. Calculate SHA
echo ""
echo "📋 SHA256 for Homebrew cask:"
SHA=$(shasum -a 256 dist/Loqui-${VERSION}.zip | cut -d' ' -f1)
echo "   $SHA"

# 5. Update Homebrew cask
CASK_FILE=~/work/projects/homebrew-tap/Casks/loqui.rb
if [ -f "$CASK_FILE" ]; then
    echo ""
    echo "📝 Updating Homebrew cask..."
    sed -i '' "s/version \"[^\"]*\"/version \"${VERSION}\"/" "$CASK_FILE"
    sed -i '' "s/sha256 \"[^\"]*\"/sha256 \"${SHA}\"/" "$CASK_FILE"
    echo "   Updated $CASK_FILE"
fi

echo ""
echo "✅ Build complete!"
echo ""
echo "Next steps:"
echo "  1. Test the app: open dist/Loqui-${VERSION}.zip"
echo "  2. Create GitHub release:"
echo ""
echo "     git tag -a v${VERSION} -m \"Release v${VERSION}\""
echo "     git push origin v${VERSION}"
echo ""
echo "     gh release create v${VERSION} \\"
echo "       dist/Loqui-${VERSION}.zip \\"
echo "       dist/pi-extension-${VERSION}.zip \\"
echo "       --title \"Loqui v${VERSION}\" \\"
echo "       --notes \"Release notes\""
echo ""
echo "  3. Push Homebrew tap:"
echo ""
echo "     cd ~/work/projects/homebrew-tap"
echo "     git add Casks/loqui.rb"
echo "     git commit -m \"Update loqui to ${VERSION}\""
echo "     git push"
echo ""
