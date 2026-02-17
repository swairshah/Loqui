#!/bin/bash
set -e

# Release script for Loqui
# Usage: ./release.sh 1.0.0

VERSION=$1

if [ -z "$VERSION" ]; then
    echo "Usage: ./release.sh <version>"
    echo "Example: ./release.sh 1.0.0"
    exit 1
fi

echo "🚀 Releasing Loqui v${VERSION}"
echo ""

# 1. Update version in build script
echo "📝 Updating version in build-app.sh..."
sed -i '' "s/CFBundleShortVersionString<\/key>.*<string>[^<]*<\/string>/CFBundleShortVersionString<\/key>\n    <string>${VERSION}<\/string>/" build-app.sh

# 2. Build
echo "🔨 Building..."
./build-app.sh

# 3. Create dist
echo "📦 Creating distribution..."
mkdir -p dist
rm -f dist/Loqui-${VERSION}.zip dist/pi-extension-${VERSION}.zip

ditto -c -k --keepParent .build/Loqui.app dist/Loqui-${VERSION}.zip
zip -j dist/pi-extension-${VERSION}.zip pi-extension/index.ts

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
