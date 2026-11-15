#!/bin/bash
# Тестовый созвон для `Suflyor --e2e-call`: две дорожки 16 кГц моно в test-audio/ (в .gitignore).
# «Они» задают 4 вопроса с паузами, «я» коротко отвечаю между ними. Голос — русский из `say`
# (Milena; если найдётся мужской русский голос — им говорит «я»). Конвертация — afconvert.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=test-audio
mkdir -p "$OUT"
TMP="$(mktemp -d -t suflyor-call)"
trap 'rm -rf "$TMP"' EXIT

RU_VOICES=$(say -v '?' | awk '/ru_RU/ {print $1}')
[ -n "$RU_VOICES" ] || { echo "Нет русского голоса в say (Системные настройки → Универсальный доступ → Устная речь)" >&2; exit 1; }
THEY_VOICE=$(echo "$RU_VOICES" | head -1)
ME_VOICE=$(echo "$RU_VOICES" | grep -E '^(Yuri|Юрий)$' | head -1 || true)
ME_VOICE=${ME_VOICE:-$THEY_VOICE}
echo "голоса: они — $THEY_VOICE, я — $ME_VOICE"

# Порядок реплик: канал|текст. Между репликами — пауза.
SCRIPT=(
  "they|Добрый день. Расскажите, чем ваш продукт отличается от того, что у нас стоит сейчас?"
  "me|Да, сейчас расскажу."
  "they|Понятно. А сколько стоит подключение на команду из двадцати человек?"
  "me|Секунду, гляну цифры."
  "they|Хорошо. Сколько занимает внедрение и кто нам с ним поможет?"
  "me|Отвечу, да."
  "they|И последний вопрос. Можно сначала попробовать бесплатно, без договора?"
  "me|Понял, давайте разберём."
)

n=0
for line in "${SCRIPT[@]}"; do
  ch=${line%%|*}; text=${line#*|}
  voice=$THEY_VOICE; [ "$ch" = me ] && voice=$ME_VOICE
  say -v "$voice" -o "$TMP/$n.aiff" "$text"
  afconvert -f WAVE -d LEI16@16000 -c 1 "$TMP/$n.aiff" "$TMP/$n.wav"
  echo "$ch $TMP/$n.wav" >> "$TMP/list"
  n=$((n + 1))
done

# Склейка: пока говорит один канал, в другом тишина той же длины; между репликами пауза 1.5 с.
python3 -I - "$TMP/list" "$OUT/they.wav" "$OUT/me.wav" <<'PY'
import sys, wave
items = [l.split(" ", 1) for l in open(sys.argv[1]).read().splitlines()]
rate, gap = 16000, b"\0\0" * int(16000 * 1.5)
tracks = {"they": bytearray(gap), "me": bytearray(gap)}
for ch, path in items:
    with wave.open(path.strip()) as w:
        assert w.getframerate() == rate and w.getnchannels() == 1 and w.getsampwidth() == 2
        pcm = w.readframes(w.getnframes())
    other = "me" if ch == "they" else "they"
    tracks[ch] += pcm + gap
    tracks[other] += b"\0" * len(pcm) + gap
for name, out in (("they", sys.argv[2]), ("me", sys.argv[3])):
    with wave.open(out, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(rate)
        w.writeframes(bytes(tracks[name]))
    print(f"{out}: {len(tracks[name]) / 2 / rate:.1f} с")
PY
