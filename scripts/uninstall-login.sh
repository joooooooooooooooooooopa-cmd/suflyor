#!/bin/bash
# Убрать автозапуск Суфлёра. Само приложение, если запущено, не трогаем — выход кнопкой в панели.
set -euo pipefail
LABEL=com.danila-builds.suflyor
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$PLIST"
echo "Автозапуск убран: $PLIST"
