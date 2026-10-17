#!/bin/sh
# 用法: sh mk2.sh [图名 ...]   生成 v2/*.svg、pdf/*.pdf 和预览 png/*.png（220 dpi）
set -e
cd "$(dirname "$0")"
INK=/Applications/Inkscape.app/Contents/MacOS/inkscape
python3 -I figs.py v2 "$@"
for s in v2/*.svg; do
  n=$(basename "$s" .svg)
  if [ $# -gt 0 ]; then case " $* " in *" $n "*) ;; *) continue;; esac; fi
  $INK "$s" --export-area-drawing --export-margin=1 --export-type=pdf --export-filename="pdf/$n.pdf" 2>/dev/null
  $INK "$s" --export-area-drawing --export-margin=1 --export-type=png --export-dpi=220 --export-background=white --export-filename="v2/$n.png" 2>/dev/null
done
