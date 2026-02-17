# Releasing Loqui

## 1. Bump version

Update `build-app.sh` Info.plist section:
- `CFBundleShortVersionString` — user-facing version (e.g., `1.0.0`)
- `CFBundleVersion` — increment build number

## 2. Build

```bash
cd PocketTTSApp
./build-app.sh
```

## 3. Create distribution zip

```bash
VERSION="1.0.0"  # Update this

# Create dist directory
mkdir -p dist

# Zip the app
ditto -c -k --keepParent .build/Loqui.app dist/Loqui-${VERSION}.zip

# Also include the pi extension in a separate zip
zip -j dist/pi-extension-${VERSION}.zip pi-extension/index.ts
```

## 4. (Optional) Sign & Notarize

If you have a Developer ID:

```bash
# Sign
codesign --force --deep --options runtime --timestamp \
  --sign "Developer ID Application" \
  .build/Loqui.app

# Notarize
xcrun notarytool submit dist/Loqui-${VERSION}.zip \
  --apple-id "$APPLE_EMAIL" \
  --team-id "$APPLE_TEAM_ID" \
  --password "$APPLE_APP_PASSWORD" \
  --wait

# Staple & re-zip
xcrun stapler staple .build/Loqui.app
rm dist/Loqui-${VERSION}.zip
ditto -c -k --keepParent .build/Loqui.app dist/Loqui-${VERSION}.zip
```

## 5. GitHub release

```bash
VERSION="1.0.0"

git tag -a v${VERSION} -m "Release v${VERSION}"
git push origin v${VERSION}

gh release create v${VERSION} \
  dist/Loqui-${VERSION}.zip \
  dist/pi-extension-${VERSION}.zip \
  --title "Loqui v${VERSION}" \
  --notes "Release notes here"
```

## 6. Update Homebrew tap

```bash
# Get SHA
shasum -a 256 dist/Loqui-${VERSION}.zip

# Update ~/work/projects/homebrew-tap/Casks/loqui.rb with new version and SHA

cd ~/work/projects/homebrew-tap
git add Casks/loqui.rb
git commit -m "Update loqui to ${VERSION}"
git push
```

## Post-install

After `brew install loqui`, users should:
1. Open Loqui.app (it will appear in menubar)
2. Restart Pi to load the extension (if Pi is installed)
