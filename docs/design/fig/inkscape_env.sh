# 由导出入口 source；在生成文件和启动 Inkscape 前检查执行环境。
if [ "${CODEX_SANDBOX:-}" = seatbelt ]; then
  printf '%s\n' 'Inkscape 导出需要正常 macOS 图形会话。请在沙箱外的正常系统环境中重新运行同一命令。' >&2
  exit 2
fi

INK=/Applications/Inkscape.app/Contents/MacOS/inkscape
if [ ! -x "$INK" ]; then
  printf '%s\n' "Inkscape 可执行文件不存在：$INK" >&2
  exit 127
fi
