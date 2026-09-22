#!/bin/bash
# Builds UnifiedUsageMonitor.app as a universal binary. No Xcode, no SwiftPM.
#
# SwiftPM is deliberately not used: on some Command Line Tools installs the
# PackageDescription swiftmodule's symbols are missing from the matching dylib,
# so every manifest fails to link. The app has no external dependencies, so
# compiling the sources directly with swiftc costs nothing.
#
# Environment:
#   ARCHS           architectures to build (default "arm64 x86_64")
#   MACOS_TARGET    deployment target (default 14.0)
#   SIGN_IDENTITY   codesign identity; falls back to .signing-identity, then ad-hoc
set -euo pipefail

cd "$(dirname "$0")"

APP="build/UnifiedUsageMonitor.app"
BIN="build/UnifiedUsageMonitor"
SDK="$(xcrun --show-sdk-path)"
ARCHS="${ARCHS:-arm64 x86_64}"
MACOS_TARGET="${MACOS_TARGET:-14.0}"
SOURCES=$(find Sources -name '*.swift' | sort)

mkdir -p build
SLICES=()
for arch in $ARCHS; do
    echo "▸ compiling $arch"
    swiftc -O \
        -target "${arch}-apple-macosx${MACOS_TARGET}" \
        -sdk "$SDK" \
        -swift-version 5 \
        -framework AppKit -framework SwiftUI -framework Combine \
        -o "build/UnifiedUsageMonitor-$arch" \
        $SOURCES
    SLICES+=("build/UnifiedUsageMonitor-$arch")
done

# One slice still goes through lipo, so the output is the same file either way.
echo "▸ lipo ($ARCHS)"
lipo -create -output "$BIN" "${SLICES[@]}"
rm -f "${SLICES[@]}"

echo "▸ assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/UnifiedUsageMonitor"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# The icon is a prebuilt .icns, rendered from Icon.icon by tools/make-icon.sh.
# Rendering it here would make Icon Composer a build requirement; copying it
# keeps the build on Command Line Tools alone.
if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/"
else
    echo "  note:     Resources/AppIcon.icns missing, building without an icon"
fi

# Localizations. Copying whole .lproj directories means a new language needs no
# change here: drop in the directory and list it in Info.plist.
for lproj in Resources/*.lproj; do
    [ -d "$lproj" ] || continue
    cp -R "$lproj" "$APP/Contents/Resources/"
done
echo "  languages: $(ls -d Resources/*.lproj 2>/dev/null | xargs -n1 basename 2>/dev/null | sed 's/\.lproj//' | tr '\n' ' ')"

# The signature is the app's keychain identity. Ad-hoc signing ("-") produces a
# new identity on every rebuild, so macOS re-asks for keychain access each time;
# a certificate keeps one identity across rebuilds, so it asks once.
#
# The certificate need not be trusted — codesign accepts an untrusted
# self-signed code-signing certificate, and nothing here goes through Gatekeeper.
# Order: $SIGN_IDENTITY, then .signing-identity, then ad-hoc.
# Trailing whitespace is invisible and fatal — codesign matches the identity
# name exactly, and a secret pasted into a web form easily carries a newline.
IDENTITY="$(printf '%s' "${SIGN_IDENTITY:-}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
if [ -z "$IDENTITY" ] && [ -f .signing-identity ]; then
    # Trim the ends only. Identity names contain spaces — "Developer ID
    # Application: Name (TEAMID)", or a self-signed name with words in it — and
    # squeezing those out yields a name codesign cannot find.
    IDENTITY="$(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d' .signing-identity | head -1)"
fi
IDENTITY="${IDENTITY:--}"
echo "▸ codesign ($IDENTITY)"
codesign --force --sign "$IDENTITY" "$APP"

echo "✓ $APP  ($(lipo -archs "$APP/Contents/MacOS/UnifiedUsageMonitor"))"

# Keep an installed copy in step with the build. Only refreshes a copy that is
# already there, so this never installs anything behind your back; pass
# --install once to create it.
INSTALLED="/Applications/UnifiedUsageMonitor.app"
# Outside the bundle on purpose. Writing this inside Contents/ after codesign
# adds a file the signature does not cover, and the installed copy then fails
# `codesign --verify` with "a sealed resource is missing or invalid" — which
# matters here more than usual, because keychain "Always Allow" grants are
# matched against the signature.
STAMP_DIR="$HOME/Library/Application Support/UnifiedUsageMonitor"
STAMP="$STAMP_DIR/installed-from"
LEGACY_STAMP="$INSTALLED/Contents/Resources/.installed-from"
HERE="$(pwd -P)"

# Only refresh an installed copy that THIS checkout installed. Without the
# check, building a copy of the project somewhere else (to test a release
# tarball, say) silently overwrites the real app — and since that copy has a
# different signature, macOS starts asking for keychain access all over again.
SHOULD_INSTALL=0
if [ "${1:-}" = "--install" ]; then
    SHOULD_INSTALL=1
elif [ -d "$INSTALLED" ] && {
        [ "$(cat "$STAMP" 2>/dev/null)" = "$HERE" ] ||
        # Installs made before the stamp moved out of the bundle.
        [ "$(cat "$LEGACY_STAMP" 2>/dev/null)" = "$HERE" ]
     }; then
    SHOULD_INSTALL=1
fi

if [ "$SHOULD_INSTALL" = "1" ]; then
    if pgrep -f "$INSTALLED/Contents/MacOS" >/dev/null 2>&1; then
        echo "▸ stopping the running copy"
        pkill -f "$INSTALLED/Contents/MacOS" || true
        sleep 1
    fi
    echo "▸ installing to $INSTALLED"
    rm -rf "$INSTALLED"
    cp -R "$APP" "$INSTALLED"
    mkdir -p "$STAMP_DIR"
    printf '%s\n' "$HERE" > "$STAMP"
    # The installed bundle must stay byte-identical to the one that was signed.
    codesign --verify --strict "$INSTALLED"
    echo "✓ $INSTALLED  (signature verified)"
    echo "  run:      open '$INSTALLED'"
else
    echo "  run:      open '$APP'"
    if [ -d "$INSTALLED" ]; then
        echo "  note:     the /Applications copy was installed from elsewhere, left untouched"
    else
        echo "  install:  ./build-app.sh --install   (later builds refresh it automatically)"
    fi
fi
echo "  quit:     right-click the menu bar icon → Quit"
