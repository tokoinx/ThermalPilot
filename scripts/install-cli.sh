#!/bin/bash
# thermalctl を /usr/local/bin に入れる。アプリの「ファン全開 / 自動に戻す」ボタンはこれを探す。
#   sudo ./scripts/install-cli.sh
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "$(uname -s)" != "Darwin" ]]; then echo "macOS 専用" >&2; exit 1; fi
if [[ "$(id -u)" != "0" ]]; then echo "sudo で実行してください: sudo $0" >&2; exit 1; fi

BIN_DIR="$(sudo -u "${SUDO_USER:-$USER}" swift build -c release --product thermalctl --show-bin-path)"
sudo -u "${SUDO_USER:-$USER}" swift build -c release --product thermalctl
install -m 755 "$BIN_DIR/thermalctl" /usr/local/bin/thermalctl
echo "✅ /usr/local/bin/thermalctl をインストールしました"
echo "   試す: thermalctl status"
