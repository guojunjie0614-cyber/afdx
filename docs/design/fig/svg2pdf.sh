#!/bin/sh
# 用法: sh svg2pdf.sh in.svg out.pdf [preview.png]  按绘图区域裁边
set -e
INK=/Applications/Inkscape.app/Contents/MacOS/inkscape
$INK "$1" --export-area-drawing --export-margin=2 --export-type=pdf --export-filename="$2" 2>/dev/null
[ -n "$3" ] && $INK "$1" --export-area-drawing --export-margin=2 --export-type=png --export-dpi=130 --export-background=white --export-filename="$3" 2>/dev/null
exit 0
