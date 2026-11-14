#!/bin/sh
# 用法: sh build_fig.sh <type> <name>   例: sh build_fig.sh architecture f01_system
set -e
cd "$(dirname "$0")"
AR=${ARCHIFY_BIN:?请将 ARCHIFY_BIN 设为 archify.mjs 的路径}
node $AR deliver "$1" "src/$2.$1.json" "html/$2.html" --quality showcase --json > "html/$2.receipt.json" || { python3 -I -c "import json;d=json.load(open('html/$2.receipt.json'));print(json.dumps([c for c in d.get('checks',[]) if not c['ok']],indent=1)[:3000]);print(d.get('composition',{}).get('diagnostics',d.get('composition'))) " ; exit 1; }
python3 -I jssc_svg.py "html/$2.html" "pdf/$2.svg"
sh svg2pdf.sh "pdf/$2.svg" "pdf/$2.pdf" "png/$2.png"
echo "OK $2"
