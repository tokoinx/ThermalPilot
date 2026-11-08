#!/bin/bash
# 温度計モチーフの簡易アプリアイコン (.icns) を Swift スクリプトで描いて生成する。
# 使い方: ./scripts/make-icon.sh out/AppIcon.icns
set -euo pipefail
OUT="${1:?出力 .icns パスを指定}"
TMP="$(mktemp -d)"
ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"

cat > "$TMP/draw.swift" <<'EOF'
import AppKit

let size = 1024.0
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// 背景: 角丸の青→オレンジのグラデーション (冷→熱)
let rect = CGRect(x: 0, y: 0, width: size, height: size).insetBy(dx: 60, dy: 60)
let path = CGPath(roundedRect: rect, cornerWidth: 220, cornerHeight: 220, transform: nil)
ctx.addPath(path); ctx.clip()
let colors = [NSColor(calibratedRed: 0.16, green: 0.45, blue: 0.95, alpha: 1).cgColor,
              NSColor(calibratedRed: 0.98, green: 0.45, blue: 0.18, alpha: 1).cgColor] as CFArray
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: 0), end: CGPoint(x: size, y: size), options: [])

// 温度計: SF Symbol を白で中央に
let config = NSImage.SymbolConfiguration(pointSize: 560, weight: .medium)
if let symbol = NSImage(systemSymbolName: "thermometer.medium", accessibilityDescription: nil)?
    .withSymbolConfiguration(config) {
    let tinted = NSImage(size: symbol.size, flipped: false) { r in
        NSColor.white.set()
        r.fill()
        symbol.draw(in: r, from: .zero, operation: .destinationIn, fraction: 1)
        return true
    }
    let s = tinted.size
    let scale = min(620 / s.width, 620 / s.height)
    let w = s.width * scale, h = s.height * scale
    tinted.draw(in: CGRect(x: (size - w) / 2, y: (size - h) / 2, width: w, height: h))
}
image.unlockFocus()

let tiff = image.tiffRepresentation!
let png = NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
EOF

swift "$TMP/draw.swift" "$TMP/icon_1024.png"

for s in 16 32 128 256 512; do
  sips -z $s $s "$TMP/icon_1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d "$TMP/icon_1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$OUT"
rm -rf "$TMP"
echo "  アイコン: $OUT"
