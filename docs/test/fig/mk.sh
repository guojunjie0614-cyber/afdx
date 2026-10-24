#!/bin/sh
# 用法: sh mk.sh [图名 ...]   生成 v2/*.svg、pdf/*.pdf 和预览 v2/*.png（220 dpi）
set -e
cd "$(dirname "$0")"
command -v rsvg-convert >/dev/null
python3 -I tfigs.py v2 "$@"
for s in v2/*.svg; do
  n=$(basename "$s" .svg)
  if [ $# -gt 0 ]; then case " $* " in *" $n "*) ;; *) continue;; esac; fi
  rsvg-convert --format=pdf1.5 --output="pdf/$n.pdf" "$s"
  rsvg-convert --dpi-x=220 --dpi-y=220 --background-color=white --output="v2/$n.png" "$s"
done
