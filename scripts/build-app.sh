#!/bin/bash
# Сборка build/Suflyor.app: release-бинарь + Info.plist + prompts/ и briefs/ в Resources + подпись.
# Подпись — постоянным локальным сертификатом «Suflyor Local», если он есть в связке ключей:
# тогда designated requirement не меняется от сборки к сборке и macOS не теряет выданные доступы.
# Нет сертификата — ad-hoc, как раньше: после каждой пересборки доступы могут слететь (см. README).
#
# Брифы берутся из BRIEFS_DIR (свои, не из git), иначе ./briefs рядом с репо (в git — только пример).
# Не нашлось — собираем без них, с предупреждением.
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="Suflyor Local"

swift build -c release --product Suflyor
BIN="$(swift build -c release --show-bin-path)/Suflyor"

APP=build/Suflyor.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Suflyor"
cp Resources/Info.plist "$APP/Contents/Info.plist"

if [ -d prompts ]; then
  cp -R prompts "$APP/Contents/Resources/prompts"
else
  echo "ВНИМАНИЕ: нет папки prompts/ — в бандл не попала" >&2
fi

if [ -n "${BRIEFS_DIR:-}" ]; then
  BRIEFS="$BRIEFS_DIR"
else
  BRIEFS=briefs
fi
if [ -d "$BRIEFS" ]; then
  cp -R "$BRIEFS" "$APP/Contents/Resources/briefs"
  echo "Брифы: $BRIEFS"
else
  echo "ВНИМАНИЕ: брифы не найдены ($BRIEFS) — подсказки пойдут без фактов" >&2
fi

# Подпись — после копирования ресурсов: иначе печать не покроет их, и codesign --verify упадёт.
# Без --options runtime: hardened runtime без entitlement audio-input молча отрезает микрофон,
# а нотаризация локальной сборке не нужна.
if security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
  codesign --force --deep -s "$IDENTITY" "$APP"
else
  echo "ВНИМАНИЕ: сертификат «$IDENTITY» не найден — подпись ad-hoc, доступы macOS могут слететь после пересборки" >&2
  codesign -s - --force --deep "$APP"
fi
codesign --verify --verbose=1 "$APP"
echo "Designated requirement:"
codesign -dr - "$APP" 2>&1 | sed -n 's/^designated => /  /p'
echo "Готово: $APP"
