#!/bin/bash
# Запуск через open: так разрешения (микрофон, запись экрана) выдаются самому Suflyor.app,
# а не терминалу. Аргументы пробрасываются, например: scripts/run.sh --selftest-capture
set -euo pipefail
cd "$(dirname "$0")/.."
APP=build/Suflyor.app
[ -d "$APP" ] || scripts/build-app.sh
if [ $# -gt 0 ]; then
  # Для selftest нужен вывод в терминал — запускаем бинарь напрямую.
  exec "$APP/Contents/MacOS/Suflyor" "$@"
fi
open "$APP"
