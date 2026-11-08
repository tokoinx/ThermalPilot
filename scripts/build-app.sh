#!/bin/bash
# ThermalPilot.app を SwiftPM からビルドして .app バンドルに組み立てる。
#
#   ./scripts/build-app.sh            # dist/ThermalPilot.app を作る (ad-hoc 署名)
#   SIGN_IDENTITY="Developer ID Application: ..." ./scripts/build-app.sh
#
# 必要: macOS 14+, Xcode 16+ (Swift 5.10+)。Xcode 26 / Swift 6 でも可。
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
DIST="$ROOT/dist"
APP="$DIST/ThermalPilot.app"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "このスクリプトは macOS 上で実行してください (IOKit / SwiftUI が必要)。" >&2
  exit 1
fi

# zip で持ってきた場合に付く隔離属性を外す (付いたままだとスクリプトや .app が Gatekeeper に kill される)
xattr -dr com.apple.quarantine "$ROOT" 2>/dev/null || true

# 署名 ID: 指定が無ければ Xcode の無料 "Apple Development" 証明書を探し、無ければ ad-hoc ("-")
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -E 'Developer ID Application|Apple Development' | head -1 | sed -E 's/.*"(.*)".*/\1/' || true)"
  SIGN_IDENTITY="${SIGN_IDENTITY:--}"
fi

echo "▶ swift build -c release"
swift build -c release --product ThermalPilot
swift build -c release --product thermalctl
BIN_DIR="$(swift build -c release --show-bin-path)"

echo "▶ バンドル組み立て: $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/ThermalPilot" "$APP/Contents/MacOS/ThermalPilot"
cp "$BIN_DIR/thermalctl"   "$APP/Contents/MacOS/thermalctl"
cp "$ROOT/scripts/Info.plist" "$APP/Contents/Info.plist"
echo -n "APPL????" > "$APP/Contents/PkgInfo"

# アイコン: SF Symbols ベースの簡易アイコンを生成 (SKIP_ICON=1 で省略)
if [[ -z "${SKIP_ICON:-}" ]] && command -v iconutil >/dev/null 2>&1 && command -v sips >/dev/null 2>&1; then
  "$ROOT/scripts/make-icon.sh" "$APP/Contents/Resources/AppIcon.icns" || echo "  (アイコン生成をスキップ)"
fi

echo "▶ codesign ($SIGN_IDENTITY)"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  # ad-hoc: hardened runtime や entitlements を付けると起動時に kill されることがあるので素の署名のみ
  codesign --force --deep --sign - "$APP"
else
  codesign --force --deep --options runtime --sign "$SIGN_IDENTITY" \
    --entitlements "$ROOT/scripts/ThermalPilot.entitlements" "$APP"
fi

echo
echo "✅ 完成: $APP"
echo "   起動:            open \"$APP\""
echo "   「開発元を確認できない」と出たら: システム設定 → プライバシーとセキュリティ → 「このまま開く」"
echo "   /Applications へ: cp -R \"$APP\" /Applications/"
echo "   CLI も入れる:     sudo ./scripts/install-cli.sh"
