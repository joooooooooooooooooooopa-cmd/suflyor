#!/bin/bash
# Автозапуск Суфлёра при входе в систему: LaunchAgent, который один раз открывает build/Suflyor.app.
# Запуск через open, как в run.sh: так разрешения (микрофон, звук системы) выдаются самому приложению.
# KeepAlive=false: если выйти кнопкой в панели, launchd не поднимет приложение заново.
# --dry-run — только показать plist и проверить его, ничего не устанавливая.
set -euo pipefail
cd "$(dirname "$0")/.."
LABEL=com.danila-builds.suflyor
APP="$(pwd)/build/Suflyor.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

render() {
  cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/open</string>
    <string>$APP</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <false/>
</dict>
</plist>
PLIST
}

if [ "${1:-}" = "--dry-run" ]; then
  TMP="$(mktemp -t suflyor-plist)"
  trap 'rm -f "$TMP"' EXIT
  render > "$TMP"
  plutil -lint "$TMP"
  cat "$TMP"
  exit 0
fi

[ -d "$APP" ] || { echo "Нет $APP — сначала scripts/build-app.sh" >&2; exit 1; }
mkdir -p "$HOME/Library/LaunchAgents"
render > "$PLIST"
plutil -lint "$PLIST"
# Повторная установка: сначала выгрузить старую версию, иначе bootstrap ругается.
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Установлено: $PLIST (Суфлёр стартует при входе и спит до ⌃⌥⌘)"
