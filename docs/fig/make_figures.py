"""Generate the README overview, resource, and latency figures as SVG.

Render PNGs at 2x with:
    rsvg-convert -z 2 -b white overview.svg -o overview.png
    rsvg-convert -z 2 -b white resource.svg -o resource.png
    rsvg-convert -z 2 -b white latency.svg -o latency.png
"""

from html import escape
from pathlib import Path

INK = "#17202A"
SLATE = "#334155"
MUTED = "#64748B"
BORDER = "#CBD5E1"
OUTER_BORDER = "#E2E8F0"
GRID = "#E2E6EA"
TRACK = "#EEF2F6"
AXIS = "#94A3B8"
ACCENT = "#1D4ED8"
ACCENT_SOFT = "#EFF6FF"
ACCENT_BORDER = "#93C5FD"
TEAL = "#0F766E"
TEAL_SOFT = "#F0FDFA"
TEAL_BORDER = "#5EEAD4"
AMBER = "#B45309"
AMBER_SOFT = "#FFFBEB"
AMBER_BORDER = "#FCD34D"
CARD_BG = "#F8FAFC"
FONT = "PingFang SC, Hiragino Sans GB, Microsoft YaHei, Arial, sans-serif"
MONO = "Menlo, Consolas, Monaco, monospace"
OUT = Path(__file__).resolve().parent


def text(x, y, value, size=14, color=INK, anchor="start", weight=400, mono=False):
    family = MONO if mono else FONT
    return (
        f'<text x="{x:.1f}" y="{y:.1f}" font-family="{family}" '
        f'font-size="{size}" font-weight="{weight}" fill="{color}" '
        f'text-anchor="{anchor}">{escape(str(value))}</text>'
    )


def box(x, y, w, h, fill="#FFFFFF", stroke=BORDER, sw=1.5, rx=8):
    return (
        f'<rect x="{x:.1f}" y="{y:.1f}" width="{w:.1f}" height="{h:.1f}" '
        f'rx="{rx}" fill="{fill}" stroke="{stroke}" stroke-width="{sw}"/>'
    )


def arrow_h(x1, y, x2, color=SLATE, sw=2.0, bidir=False):
    parts = [f'<line x1="{x1:.1f}" y1="{y:.1f}" x2="{x2:.1f}" y2="{y:.1f}" stroke="{color}" stroke-width="{sw}"/>']
    if x2 >= x1:
        parts.append(f'<polygon points="{x2:.1f},{y:.1f} {x2-8:.1f},{y-4.5:.1f} {x2-8:.1f},{y+4.5:.1f}" fill="{color}"/>')
        if bidir:
            parts.append(f'<polygon points="{x1:.1f},{y:.1f} {x1+8:.1f},{y-4.5:.1f} {x1+8:.1f},{y+4.5:.1f}" fill="{color}"/>')
    else:
        parts.append(f'<polygon points="{x2:.1f},{y:.1f} {x2+8:.1f},{y-4.5:.1f} {x2+8:.1f},{y+4.5:.1f}" fill="{color}"/>')
        if bidir:
            parts.append(f'<polygon points="{x1:.1f},{y:.1f} {x1-8:.1f},{y-4.5:.1f} {x1-8:.1f},{y+4.5:.1f}" fill="{color}"/>')
    return "\n".join(parts)


def document(width, height, body):
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" '
        f'height="{height}" viewBox="0 0 {width} {height}">\n'
        f'<rect width="{width}" height="{height}" fill="#FFFFFF"/>\n'
        f'<rect x="0.75" y="0.75" width="{width-1.5}" height="{height-1.5}" '
        f'rx="8" fill="none" stroke="{OUTER_BORDER}" stroke-width="1.5"/>\n'
        + "\n".join(body)
        + "\n</svg>\n"
    )


def overview():
    width, height = 1200, 504
    parts = [
        text(32, 40, "AFDX_top 端系统硬件边界与核心架构总览", 20, INK, "start", 700),
        text(1168, 40, "EQ6HL130-CSG484_H · 单 125 MHz 时钟域 (8.000 ns) · 172 用户引脚", 13, MUTED, "end", 500),
        f'<line x1="32" y1="56" x2="1168" y2="56" stroke="{OUTER_BORDER}" stroke-width="1.2"/>',
    ]

    # Left column: User & Host interfaces (x=28..312, width=284)
    parts += [
        box(28, 82, 284, 118, ACCENT_SOFT, ACCENT_BORDER, 1.5, 8),
        text(44, 108, "应用发送流 (tx_*)", 15, ACCENT, "start", 700),
        text(44, 134, "tx_data[7:0] / tx_valid / tx_ready", 11.2, SLATE, "start", 500, True),
        text(44, 158, "• 格式: [2 B 大端 VLID] + [1~8192 B]", 12.2, INK),
        text(44, 180, "• 契约: 帧内连续，帧间至少空 1 拍", 12.2, MUTED),

        box(28, 218, 284, 118, TEAL_SOFT, TEAL_BORDER, 1.5, 8),
        text(44, 244, "应用接收流 (rx_*)", 15, TEAL, "start", 700),
        text(44, 270, "rx_data[7:0] / rx_valid（无反压）", 11.2, SLATE, "start", 500, True),
        text(44, 294, "• 格式: [2 B 大端 VLID] + [完整载荷]", 12.2, INK),
        text(44, 316, "• 保证: 冗余去重、重组后恰好交付一次", 12.2, MUTED),

        box(28, 354, 284, 118, CARD_BG, BORDER, 1.5, 8),
        text(44, 380, "主机配置与监控口", 15, INK, "start", 700),
        text(44, 406, "cfg_wr/rd · addr[17:0] · 32b data", 11.2, SLATE, "start", 500, True),
        text(44, 430, "• 读写 TX/RX VL 表与 MIB 统计", 12.2, INK),
        text(44, 452, "ev_tx/a/b · rm_drop/deliver/app", 11.2, MUTED, "start", 400, True),
    ]

    # Center container: AFDX_top (x=352..896, width=544)
    parts += [
        box(352, 74, 544, 406, "#FFFFFF", SLATE, 2.0, 10),
        text(372, 102, "AFDX_top（可综合 Verilog-2001 · 34 模块 · 无外部 CPU / 商业 IP）", 14.2, INK, "start", 700),

        # App adaptation layer
        box(372, 118, 504, 52, CARD_BG, BORDER, 1.2, 6),
        text(624, 140, "应用流适配层 (afdx_app_tx / afdx_app_rx)", 13.5, INK, "middle", 700),
        text(624, 159, "32 KiB 弹性切片缓存 · 128 TX VLID 并行反查 · 4096 RX VLID 反向映射", 12, MUTED, "middle"),

        # TX core
        box(372, 184, 244, 126, ACCENT_SOFT, ACCENT_BORDER, 1.4, 8),
        text(494, 208, "发送核心 (afdx_tx_core)", 13.8, ACCENT, "middle", 700),
        text(384, 232, "• 128 条 TX VL · Lookahead BAG", 11.8, INK),
        text(384, 254, "• 256×512 B (128 KiB) 链式页池", 11.8, INK),
        text(384, 276, "• 自动 IPv4 分片 (至 8192 B) + SN", 11.8, INK),
        text(384, 298, "• 仲裁: START > ENQ > GRANT > SCAN", 11.2, MUTED),

        # RX core
        box(632, 184, 244, 126, TEAL_SOFT, TEAL_BORDER, 1.4, 8),
        text(754, 208, "接收核心 (afdx_rx_core)", 13.8, TEAL, "middle", 700),
        text(644, 232, "• 4096 VL 映射 (32 Bank 同步 RAM)", 11.8, INK),
        text(644, 254, "• 双 4 KiB 试写环 · 坏帧零残留回退", 11.8, INK),
        text(644, 276, "• 共享 IC 序号检查 + RM Skew 去重", 11.8, INK),
        text(644, 298, "• 16 上下文 (128 KiB) IPv4 重组", 11.2, MUTED),

        # On-chip network services
        box(372, 324, 504, 86, AMBER_SOFT, AMBER_BORDER, 1.4, 8),
        text(384, 345, "片上机载网络服务 (afdx_svc 整包仲裁 · 控制面引擎 CE_DIV=2 16 ns 多周期)", 12.5, AMBER, "start", 700),

        box(384, 356, 152, 44, "#FFFFFF", AMBER_BORDER, 1.0, 5),
        text(460, 375, "RTC (SNTPv4)", 12.2, INK, "middle", 700),
        text(460, 392, "硬件打标 · 0 ns 误差", 11.2, MUTED, "middle"),

        box(548, 356, 152, 44, "#FFFFFF", AMBER_BORDER, 1.0, 5),
        text(624, 375, "SNMP v1/v2c", 12.2, INK, "middle", 700),
        text(624, 392, "BER 编解码 · MIB/Trap", 11.2, MUTED, "middle"),

        box(712, 356, 152, 44, "#FFFFFF", AMBER_BORDER, 1.0, 5),
        text(788, 375, "ARINC 615A", 12.2, INK, "middle", 700),
        text(788, 392, "TFTP A3/A4 · 8 KiB", 11.2, MUTED, "middle"),

        # Dual MAC bottom strip
        box(372, 422, 504, 44, CARD_BG, SLATE, 1.4, 6),
        text(624, 441, "自研双网千兆 MAC (afdx_mac_tx / afdx_mac_rx)", 13, INK, "middle", 700),
        text(624, 458, "同拍前导码发送 · 独立 CRC-32 校验 · 4 字节滑动剥离 · 12 拍 IFG", 11.8, MUTED, "middle"),
    ]

    # Right column: Dual GMII (x=936..1172, width=236)
    parts += [
        box(936, 118, 236, 148, ACCENT_SOFT, ACCENT_BORDER, 1.5, 8),
        text(952, 146, "A 网千兆接口 (GMII A)", 14.5, ACCENT, "start", 700),
        text(952, 174, "TX: gmii_txd_a / tx_en_a", 11.2, SLATE, "start", 500, True),
        text(952, 196, "RX: gmii_rxd_a / rx_dv_a", 11.2, SLATE, "start", 500, True),
        text(952, 224, "• 1000 Mbps（每拍 1 字节）", 12.2, INK),
        text(952, 246, "• 独立源 MAC 标识与 FCS", 12.2, MUTED),

        box(936, 290, 236, 148, TEAL_SOFT, TEAL_BORDER, 1.5, 8),
        text(952, 318, "B 网千兆接口 (GMII B)", 14.5, TEAL, "start", 700),
        text(952, 346, "TX: gmii_txd_b / tx_en_b", 11.2, SLATE, "start", 500, True),
        text(952, 368, "RX: gmii_rxd_b / rx_dv_b", 11.2, SLATE, "start", 500, True),
        text(952, 396, "• 双网同时冗余收发", 12.2, INK),
        text(952, 418, "• 先到交付，晚到副本去重", 12.2, MUTED),
    ]

    # Connecting arrows
    parts += [
        arrow_h(312, 141, 352, ACCENT, 2.2),
        arrow_h(352, 277, 312, TEAL, 2.2),
        arrow_h(312, 413, 352, SLATE, 2.0, bidir=True),
        arrow_h(896, 192, 936, ACCENT, 2.2, bidir=True),
        arrow_h(896, 364, 936, TEAL, 2.2, bidir=True),
    ]

    return document(width, height, parts)


def resource():
    rows = [
        ("查找表  LUT", 62274, 136160, 45.74),
        ("触发器  FF", 35597, 136160, 26.14),
        ("逻辑块  CLB", 10230, 13616, 75.13),
        ("片上存储  M4K", 814, 1200, 67.83),
        ("用户引脚  I/O", 172, 339, 50.74),
    ]
    width, height = 1200, 346
    x0, x1, value_x = 228, 880, 904
    parts = [
        text(32, 38, "EQ6HL130-CSG484_H 布线后资源占用", 17, INK, "start", 700),
        text(1168, 38, "专用 DSP：0 / 48 (0.00%) · PLL：0 / 8 (0.00%)", 13, MUTED, "end", 500),
        f'<line x1="32" y1="54" x2="1168" y2="54" stroke="{OUTER_BORDER}" stroke-width="1"/>',
        text(x0, 80, "0%", 12.5, MUTED, "middle"),
        text((x0 + x1) / 2, 80, "50%", 12.5, MUTED, "middle"),
        text(x1, 80, "100%", 12.5, MUTED, "middle"),
        f'<line x1="{(x0+x1)/2}" y1="88" x2="{(x0+x1)/2}" y2="316" stroke="{GRID}" stroke-dasharray="4 4" stroke-width="1"/>',
    ]
    for index, (label, used, total, pct) in enumerate(rows):
        y = 104 + index * 44
        parts.append(text(204, y + 13, label, 15, INK, "end", 500))
        parts.append(f'<rect x="{x0}" y="{y}" width="{x1 - x0}" height="14" rx="3" fill="{TRACK}"/>')
        bar_color = ACCENT if pct < 70 else "#1E40AF"
        parts.append(
            f'<rect x="{x0}" y="{y}" width="{(x1 - x0) * pct / 100:.2f}" '
            f'height="14" rx="3" fill="{bar_color}"/>'
        )
        parts.append(
            text(value_x, y + 13, f"{used:,} / {total:,}  ({pct:.2f}%)", 14.5, INK, "start", 600, True)
        )
    return document(width, height, parts)


def latency():
    points = [
        ("1 B", 1.056),
        ("17 B", 1.136),
        ("18 B", 1.152),
        ("511 B", 9.040),
        ("1471 B", 24.400),
    ]
    width, height = 1200, 440
    x0, x1, y0, y1 = 110, 1140, 88, 344
    ymax = 28.0
    xs = [215, 410, 605, 800, 995]
    bar_w = 68

    def py(value):
        return y1 - value / ymax * (y1 - y0)

    parts = [
        text(32, 38, "端到端传输时延（125 MHz 轻载单帧）", 17, INK, "start", 700),
        text(1168, 38, "注：63 VL 满载时 Lmax=1471 B 核心流水线时延为 24.424 µs（3,053 拍）", 13, MUTED, "end", 500),
        f'<line x1="32" y1="54" x2="1168" y2="54" stroke="{OUTER_BORDER}" stroke-width="1"/>',
        text(32, 84, "时延 / µs", 13, MUTED),
    ]

    for tick in (0, 5, 10, 15, 20, 25):
        y = py(tick)
        parts.append(
            f'<line x1="{x0}" y1="{y:.2f}" x2="{x1}" y2="{y:.2f}" '
            f'stroke="{GRID if tick > 0 else AXIS}" stroke-width="1"/>'
        )
        parts.append(text(x0 - 14, y + 5, str(tick), 13, MUTED, "end"))

    # Callout highlighting 17 B -> 18 B minimum 64B Ethernet padding boundary
    parts += [
        box(248, 126, 440, 68, ACCENT_SOFT, ACCENT_BORDER, 1.2, 6),
        text(468, 152, "17 B → 18 B 为以太网 64 B 最小帧补零边界", 13.5, ACCENT, "middle", 700),
        text(468, 174, "1~17 B 均填充至 64 B，线上耗时恒定；≥18 B 随载荷线性增长", 12.5, SLATE, "middle"),
        f'<line x1="410" y1="194" x2="410" y2="296" stroke="{ACCENT_BORDER}" stroke-dasharray="4 3" stroke-width="1.3"/>',
        f'<line x1="605" y1="194" x2="605" y2="296" stroke="{ACCENT_BORDER}" stroke-dasharray="4 3" stroke-width="1.3"/>',
    ]

    for x, (label, value) in zip(xs, points):
        top = py(value)
        h = max(4.0, y1 - top)
        parts.append(
            f'<rect x="{x - bar_w/2:.1f}" y="{top:.2f}" width="{bar_w}" '
            f'height="{h:.2f}" rx="4" fill="{ACCENT}"/>'
        )
        parts.append(text(x, top - 12, f"{value:.3f} µs", 14.5, INK, "middle", 700))
        parts.append(text(x, y1 + 26, label, 14.5, INK, "middle", 600))

    parts.append(text(x1, y1 + 58, "应用消息载荷长度（8 样本均值，正反方向与双链路延迟一致）", 13, MUTED, "end"))
    return document(width, height, parts)


for name, figure in (("overview", overview), ("resource", resource), ("latency", latency)):
    path = OUT / f"{name}.svg"
    path.write_text(figure(), encoding="utf-8")
    print(path)
