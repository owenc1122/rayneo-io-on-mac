#!/bin/sh
# Wake-word enrolment recordings for the HiFi4 stand-in's keyword spotter (BES1700_HiFi4Kws.cs):
#   scripts/make-kws-templates.sh [out-dir]   (default .local/kws)
# Speaks the wake words with every macOS Chinese / US English voice at three rates (16 kHz mono WAV,
# one folder per hifi wake event the firmware knows: 4 = 小雷小雷, 2 = "OK RayNeo", 3 = "Hey RayNeo").
# Recordings of your own voice can be added to these folders. Nothing leaves the Mac.
set -eu
cd "$(dirname "$0")/.."
out=${1:-.local/kws}
mkdir -p "$out/4" "$out/2" "$out/3"
tmp=$(mktemp -d)
speak() { # <locale regexp> <folder> <text>
    # novelty voices (Bells, Zarvox, Whisper, ...) are not human speech and make poor templates
    say -v '?' | grep -E " $1 " | grep -v -E '^(Albert|Bad News|Bahh|Bells|Boing|Bubbles|Cellos|Wobble|Good News|Jester|Organ|Superstar|Trinoids|Whisper|Zarvox) ' | sed -E 's/^(.*[^ ]) +([a-z]{2}_[A-Z]+) .*/\1|\2/' | sort -u | while IFS='|' read -r voice locale; do
        for rate in 150 0 230; do
            name=$(printf '%s_%s_%s' "${voice%% *}" "$locale" "$rate")
            [ -f "$out/$2/$name.wav" ] && continue
            if [ "$rate" = 0 ]; then say -v "$voice" -o "$tmp/a.aiff" "$3" 2>/dev/null || continue
            else say -v "$voice" -r "$rate" -o "$tmp/a.aiff" "$3" 2>/dev/null || continue; fi
            afconvert -f WAVE -d LEI16@16000 -c 1 "$tmp/a.aiff" "$out/$2/$name.wav"
        done
    done
}
speak 'zh_(CN|TW|HK)' 4 '小雷小雷'
speak 'en_US' 2 'OK, Ray Neo'
speak 'en_US' 3 'Hey, Ray Neo'
rm -rf "$tmp"
for d in 4 2 3; do printf 'event %s: %s templates\n' "$d" "$(ls "$out/$d" | wc -l | tr -d ' ')"; done
