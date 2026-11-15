#!/bin/bash
# Xcode нет, только CommandLineTools: Swift Testing там лежит вне путей поиска SwiftPM.
# Голый `swift test` в таком окружении либо не находит модуль Testing, либо (если подсунуть
# флаги только тестовому таргету) молча прогоняет 0 тестов — поэтому пути отдаём всем модулям.
set -euo pipefail
cd "$(dirname "$0")/.."
CLT=/Library/Developer/CommandLineTools/Library/Developer
exec swift test \
  -Xswiftc -F -Xswiftc "$CLT/Frameworks" \
  -Xlinker -rpath -Xlinker "$CLT/Frameworks" \
  -Xlinker -rpath -Xlinker "$CLT/usr/lib" \
  "$@"
