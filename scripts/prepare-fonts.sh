#!/bin/sh
# Build the nand_font set the stock firmware loads from /mnt/nand_font (18 files).
#   scripts/prepare-fonts.sh <RayNeo-AI-app-or-fonts-dir> [out-dir]
# Four files ship unchanged inside the official RayNeo AI phone app
# (Runner.app/Frameworks/App.framework/flutter_assets/assets/fonts): SourceHanSansCN_Regular,
# RobotoCondensed-Light/-Regular and iosevka_term_reg_en_sub. The others are the same
# open-source families (Noto, Vazirmatn, Source Han Sans KR) fetched from their upstream
# repositories and stored under the factory file names; pixel_monospaced_latin_sub is
# a stand-in (VT323) because the factory face is not identified.
set -eu
cd "$(dirname "$0")/.."
src=${1:?RayNeo AI app bundle (.app/.ipa payload) or a folder with its fonts}
out=${2:-.local/fonts-factory}
venv=${RAYNEO_VENV:-.local/venv}
cache=.local/fonts-src
mkdir -p "$out" "$cache"
app_fonts=$(find "$src" -path '*flutter_assets/assets/fonts' -type d 2>/dev/null | head -1)
[ -n "$app_fonts" ] || app_fonts=$src
for f in SourceHanSansCN_Regular.ttf RobotoCondensed-Light.ttf RobotoCondensed-Regular.ttf iosevka_term_reg_en_sub.ttf; do
    [ -f "$app_fonts/$f" ] || { echo "missing $f in $app_fonts" >&2; exit 1; }
done
cp "$app_fonts/SourceHanSansCN_Regular.ttf" "$app_fonts/RobotoCondensed-Light.ttf" "$app_fonts/iosevka_term_reg_en_sub.ttf" "$out/"
# Factory "_sub" English face: the app's Roboto Condensed Regular.
cp "$app_fonts/RobotoCondensed-Regular.ttf" "$out/roboto_condensed_reg_en_sub.ttf"
get() { [ -s "$cache/$1" ] || curl -fsSL -o "$cache/$1" "$2"; }
noto=https://github.com/notofonts/notofonts.github.io/raw/main/fonts
for s in Bengali Devanagari Georgian Hebrew Khmer Lao Myanmar Tamil Telugu ThaiLooped; do
    get "NotoSans$s-Regular.ttf" "$noto/NotoSans$s/hinted/ttf/NotoSans$s-Regular.ttf"
    cp "$cache/NotoSans$s-Regular.ttf" "$out/Noto${s}_safe_sub.ttf"
done
get Vazirmatn-Regular.ttf https://github.com/rastikerdar/vazirmatn/raw/master/fonts/ttf/Vazirmatn-Regular.ttf
cp "$cache/Vazirmatn-Regular.ttf" "$out/Vazirmatn_Regular_sub.ttf"
get VT323-Regular.ttf https://github.com/google/fonts/raw/main/ofl/vt323/VT323-Regular.ttf
cp "$cache/VT323-Regular.ttf" "$out/pixel_monospaced_latin_sub.ttf"
get SourceHanSansKR-VF.ttf https://github.com/adobe-fonts/source-han-sans/raw/release/Variable/TTF/Subset/SourceHanSansKR-VF.ttf
# The nand_font partition is 20 MiB: keep Hangul, Latin and CJK punctuation of the KR face,
# and a GB2312-sized subset of the CN face for the preloaded CN_* fonts.
"$venv/bin/pyftsubset" "$cache/SourceHanSansKR-VF.ttf" --layout-features='*' \
    --unicodes='U+0020-007E,U+00A0-00FF,U+1100-11FF,U+2010-206F,U+3000-303F,U+3130-318F,U+AC00-D7A3,U+FF00-FFEF' \
    --output-file="$out/SourceHanSansKRVF.ttf"
"$venv/bin/python" - "$app_fonts/SourceHanSansCN_Regular.ttf" "$out/sh_sans_cn_reg_sub.ttf" <<'EOF'
import sys
from fontTools import subset
from fontTools.ttLib import TTFont
chars = set(range(0x20, 0x7f)) | set(range(0xa0, 0x180)) | set(range(0x2000, 0x2070)) | set(range(0x3000, 0x3040)) | set(range(0xff00, 0xfff0))
for hi in range(0xb0, 0xf8):           # GB2312 hanzi rows
    for lo in range(0xa1, 0xff):
        try: chars.add(ord(bytes([hi, lo]).decode('gb2312')))
        except UnicodeDecodeError: pass
font = TTFont(sys.argv[1])
s = subset.Subsetter(subset.Options(layout_features=['*']))
s.populate(unicodes=sorted(chars)); s.subset(font); font.save(sys.argv[2])
EOF
echo "$(ls "$out" | wc -l | tr -d ' ') fonts -> $out ($(du -sh "$out" | cut -f1))"
