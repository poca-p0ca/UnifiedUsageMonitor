#!/bin/bash
# Renders Icon.icon into Resources/AppIcon.icns.
#
# Icon.icon is an Icon Composer document: layered artwork plus the gradients,
# blend modes, shadow and glass material that Icon Composer itself knows how to
# render. Xcode would compile it with `actool`, but this project builds without
# Xcode — so the rendering is done by `ictool`, the command-line renderer that
# ships inside Icon Composer.app, and the result is committed as a plain .icns.
#
# That is why AppIcon.icns is in the repository rather than generated at build
# time: building the app needs only Command Line Tools, and only someone
# changing the artwork needs Icon Composer.
#
#     ./tools/make-icon.sh        # after editing Icon.icon
set -euo pipefail

cd "$(dirname "$0")/.."

SOURCE="Icon.icon"
OUTPUT="Resources/AppIcon.icns"
ICTOOL="/Applications/Icon Composer.app/Contents/Executables/ictool"

if [ ! -d "$SOURCE" ]; then
    echo "✗ $SOURCE not found"
    exit 1
fi

if [ ! -x "$ICTOOL" ]; then
    echo "✗ Icon Composer is not installed, so $SOURCE cannot be rendered."
    echo "  It is a free download from Apple; Xcode also includes it."
    echo "  You do not need it to build the app — $OUTPUT is committed."
    exit 1
fi

WORK="$(mktemp -d)"
STAGE="$WORK/AppIcon.iconset"
mkdir -p "$STAGE"
trap 'rm -rf "$WORK"' EXIT

# ictool writes 16 bits per channel, which triples the .icns for no visible
# gain — the artwork is gradients, not measurement data. Re-encoding at 8 bits
# keeps the Display P3 profile (dropping it would desaturate the arc on a
# wide-gamut screen, which is most of them now).
cat > "$WORK/depth8.swift" <<'SWIFT'
import AppKit
let (inp, outp) = (CommandLine.arguments[1], CommandLine.arguments[2])
guard let src = NSBitmapImageRep(data: try! Data(contentsOf: URL(fileURLWithPath: inp))) else { exit(1) }
let w = src.pixelsWide, h = src.pixelsHigh
guard let base = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let dst = base.retagging(with: src.colorSpace) else { exit(1) }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: dst)
src.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
NSGraphicsContext.restoreGraphicsState()
try! dst.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outp))
SWIFT
swiftc -O -sdk "$(xcrun --show-sdk-path)" -framework AppKit \
    -o "$WORK/depth8" "$WORK/depth8.swift"

# Each size is rendered at its own dimensions rather than downscaled from one
# large export: Icon Composer applies size-dependent treatment, and a 16pt icon
# resampled from 1024 loses it.
render() { # <points> <scale> <filename>
    "$ICTOOL" "$SOURCE" --export-image \
        --output-file "$WORK/raw.png" \
        --platform macOS --rendition Default \
        --width "$1" --height "$1" --scale "$2" >/dev/null
    "$WORK/depth8" "$WORK/raw.png" "$STAGE/$3"
    printf '  %-24s %4spx  %5sKB\n' "$3" \
        "$(sips -g pixelWidth "$STAGE/$3" | tail -1 | tr -d ' ' | cut -d: -f2)" \
        "$(( $(stat -f%z "$STAGE/$3") / 1024 ))"
}

echo "▸ rendering $SOURCE"
for points in 16 32 128 256 512; do
    render "$points" 1 "icon_${points}x${points}.png"
    render "$points" 2 "icon_${points}x${points}@2x.png"
done

echo "▸ building $OUTPUT"
iconutil --convert icns --output "$OUTPUT" "$STAGE"
echo "✓ $OUTPUT  ($(du -h "$OUTPUT" | cut -f1))"
echo
echo "  Commit it: the build copies this file and never runs Icon Composer."
