# Build commands for CodexSwitcher app

# Default recipe: build the app bundle
default: app

# Build CodexSwitcher.app bundle to ./build/
app:
    @mkdir -p build
    xcodebuild -project CodexSwitcher.xcodeproj -scheme CodexSwitcher -configuration Debug -destination 'platform=macOS,arch=arm64' -quiet
    @rm -rf build/CodexSwitcher.app
    @cp -R ~/Library/Developer/Xcode/DerivedData/CodexSwitcher-*/Build/Products/Debug/CodexSwitcher.app build/

# Build release app bundle
app-release:
    @mkdir -p build
    xcodebuild -project CodexSwitcher.xcodeproj -scheme CodexSwitcher -configuration Release -destination 'platform=macOS,arch=arm64' -quiet
    @rm -rf build/CodexSwitcher.app
    @cp -R ~/Library/Developer/Xcode/DerivedData/CodexSwitcher-*/Build/Products/Release/CodexSwitcher.app build/

# Regenerate Xcode project from project.yml
gen:
    xcodegen generate

# Clean build artifacts
clean:
    rm -rf build .build
    xcodebuild -project CodexSwitcher.xcodeproj -scheme CodexSwitcher clean -quiet 2>/dev/null || true

# Run the app
run: app
    open build/CodexSwitcher.app

# Run tests via swift test (faster than xcodebuild for non-UI work)
test:
    swift test

# Run tests via Xcode (full app context, includes UI tests)
test-xcode:
    xcodebuild test -project CodexSwitcher.xcodeproj -scheme CodexSwitcher -destination 'platform=macOS,arch=arm64'

# Print version from Info.plist
version:
    @/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist

# Create DMG from release build
dmg: app-release
    #!/usr/bin/env bash
    set -euo pipefail
    VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
    DMG="build/CodexSwitcher_${VERSION}.dmg"
    rm -f "$DMG"
    hdiutil create "$DMG" -volname "CodexSwitcher" -srcfolder build/CodexSwitcher.app -ov -format UDZO
    echo "$DMG"

# Create GitHub release with DMG
release: dmg
    #!/usr/bin/env bash
    set -euo pipefail
    VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
    DMG="build/CodexSwitcher_${VERSION}.dmg"
    SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
    gh release create "v${VERSION}" "$DMG" --title "CodexSwitcher v${VERSION}" --notes "See assets to download and install."
    echo ""
    echo "SHA256: ${SHA}"
