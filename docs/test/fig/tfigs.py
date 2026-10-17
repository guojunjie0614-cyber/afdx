"""测试报告插图。样式与绘图函数沿用设计文档的 jssc.py、figs.py，不复制。

用法：python3 -I tfigs.py <输出目录> [图名 ...]
"""
import os
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'design', 'fig'))
from jssc import Fig, T1, T2, tw, PAL  # noqa: E402
from figs import seq, gantt, slots, wave, dim, guide, cycles, WGRAY  # noqa: E402

FIGS = {}


def fig(fn):
    FIGS[fn.__name__] = fn
    return fn


# 图名约定（章节已按这些名字引用）：
# t01_platform  验证平台结构            第 2 章
# t02_criteria  通过判据流程            第 2 章
# t10_w_tx      波形示意：一帧发送      第 4 章（最终换 ModelSim 截图）
# t11_w_rm      波形示意：双网去重      第 4 章（同上）
# t12_w_fault   波形示意：FCS 错帧被拒  第 5 章（同上）
# t13_w_bag     波形示意：BAG 间隔      第 6 章（同上）
# t14_w_snmp    波形示意：SNMP Get      第 4 章（同上）
# t15_w_615a    波形示意：TFTP 数据块   第 4 章（同上）
# t16_w_rtc     波形示意：SNTP 交换     第 4 章（同上）
# t20_thru      吞吐随 VL 数            第 6 章
# t21_lat       端到端时延随消息长度    第 6 章


@fig
def t01_platform():
    # tb/lib/sys_suite.v:18–21；sys_endpoint.v:46–97、240–246、304–369。
    f = Fig(450, 240)
    stimulus = f.box(130, 2, 190, 30, 'cfg', 'Python stimulus generation',
                     '*_cases.py / *_ref.py')
    left = f.box(5, 66, 105, 40, 'tx', 'ES1: AFDX_top', 'RTL or netlist')
    right = f.box(340, 66, 105, 40, 'rx', 'ES2: AFDX_top', 'RTL or netlist')
    link = f.box(155, 59, 140, 54, 'svc', 'Link model', '4 one-way GMII links',
                 'delay / drop / byte XOR / replay')
    for x in (left.cx, right.cx):
        f.arrow([(stimulus.cx, stimulus.b), (stimulus.cx, 43), (x, 43), (x, 66)])
    f.tag(70, 39, 'app / cfg vectors')
    f.tag(380, 39, 'app / cfg vectors')
    f.arrow([(stimulus.cx, stimulus.b), (link.cx, link.t)])
    f.tag(link.cx + 7, 54, 'link ops', anchor='start')
    for y, head in ((77, 'end'), (96, 'start')):
        f.arrow([(left.r, y), (link.l, y)], head=head)
        f.arrow([(link.r, y), (right.l, y)], head=head)
    f.tag(132, 72, 'A / B')
    f.tag(318, 72, 'A / B')
    monitor = f.box(130, 140, 190, 30, 'ram', 'Port monitors',
                    'GMII / app / events / cfg reads')
    for endpoint, x in ((left, 175), (right, 275)):
        f.arrow([(endpoint.cx, endpoint.b), (endpoint.cx, 127), (x, 127),
                 (x, monitor.t)], dash=True)
    checker = f.box(100, 198, 220, 36, 'white', 'Independent Python checker',
                    'reads text records; no RTL access')
    f.arrow([(monitor.cx, monitor.b), (monitor.cx, checker.t)])
    f.tag(230, 187, 'dump_*.txt / events / sys_events', anchor='start', size=6.5)
    verdict = f.box(365, 202, 80, 28, 'pass', 'Verdict', 'PASS / FAIL')
    f.arrow([(checker.r, checker.cy), (verdict.l, checker.cy)])
    return f


@fig
def t02_criteria():
    # sim/run.ps1 调用 tools/eda.py；eda.py:187–229；sys_run_checks.py:43、49。
    f = Fig(330, 200)
    a = f.box(5, 2, 205, 32, 'cfg', 'Testbench self-check',
              '[RESULT] PASS, errors=0')
    b = f.box(5, 58, 205, 32, 'white', 'Independent reference check',
              'checker passes, errors=0')
    c = f.box(5, 114, 205, 32, 'cfg', 'Netlist only: exact external records',
              'byte-for-byte equality with RTL reference')
    passed = f.box(67.5, 172, 80, 24, 'rx', 'PASS')
    failed = f.box(265, 58, 60, 32, 'tx', 'FAIL')
    for top, bottom in ((a, b), (b, c)):
        f.arrow([(top.cx, top.b), (bottom.cx, bottom.t)])
        f.tag(top.cx + 8, top.b + 15, 'yes', anchor='start')
    f.arrow([(c.cx, c.b), (passed.cx, passed.t)])
    f.tag(c.cx + 8, 162, 'yes', anchor='start')
    for gate in (a, b, c):
        f.arrow([(gate.r, gate.cy), (240, gate.cy), (240, failed.cy),
                 (failed.l, failed.cy)])
        f.tag(224, gate.cy - 5, 'no', size=6.5)
    return f


def timing(widths, rows, brk):
    """沿用设计文档的波形元素；断拍只表示省略时间，不指定内部延迟。"""
    f = Fig(450, 18 + 16 * len(rows))
    f.body.append('<style>path, line, polygon { stroke-width: 1.0; }</style>')
    xs = slots(94, widths)
    ys = wave(f, xs, 18, rows, brk=brk)
    return f, xs, ys


@fig
def t10_w_tx():
    # AFDX_top.v:14、16–24、27–34。单字节消息；两网首字节同拍。
    rows = [
        ('clk', 'clk', None),
        ('app_tx_valid', 'bit', '0100000000000000'),
        ('app_tx_ready', 'bit', '1100111111111111'),
        ('app_tx_data', 'bus', [(0, 1, '', 'x'), (1, 2, 'B0', 'g'), (2, 16, '', 'x')]),
        ('app_tx_last', 'bit', '0100000000000000'),
        ('app_tx_vl', 'bus', [(0, 2, 'VL 0', 'v'), (2, 16, '', 'x')]),
        ('tx_valid', 'bit', '0000001111111100'),
        ('tx_data', 'bus', [(0, 6, '', 'x'), (6, 7, '55', 'v'), (7, 8, '', 'v'),
                            (8, 9, 'D5', 'v'), (9, 10, '', 'v'),
                            (10, 12, 'Frame', 'h'), (12, 13, '', 'h'),
                            (13, 14, 'FCS', 'h'), (14, 16, '', 'x')]),
        ('tx_valid_b', 'bit', '0000001111111100'),
        ('tx_data_b', 'bus', [(0, 6, '', 'x'), (6, 7, '55', 'v'), (7, 8, '', 'v'),
                              (8, 9, 'D5', 'v'), (9, 10, '', 'v'),
                              (10, 12, 'Frame', 'h'), (12, 13, '', 'h'),
                              (13, 14, 'FCS', 'h'), (14, 16, '', 'x')]),
    ]
    f, xs, ys = timing([22] * 16, rows, (3, 5, 7, 9, 12))
    guide(f, xs[6], 5, ys[-1] + 12)
    return f


@fig
def t11_w_rm():
    # AFDX_top.v:17–26、37–46、55–60；afdx_rx_core.v:123–126。
    # engine:329 发接纳事件；deliver:139–179 取队首并流水读出，应用数据在后。
    # afdx_svc.v:135 与 AFDX_top.v:232、247 将 d_valid 组合连接到应用口。
    rows = [
        ('clk', 'clk', None),
        ('rx_valid', 'bit', '011100000000000000'),
        ('rx_data', 'bus', [(0, 1, '', 'x'), (1, 2, '55', 'v'), (2, 3, '', 'v'),
                            (3, 4, '', 'v'), (4, 18, '', 'x')]),
        ('ev_deliver', 'bit', '000000100000000000'),
        ('app_rx_valid', 'bit', '000000001000000000'),
        ('app_rx_data', 'bus', [(0, 8, '', 'x'), (8, 9, 'B0', 'g'), (9, 18, '', 'x')]),
        ('app_rx_last', 'bit', '000000001000000000'),
        ('app_rx_net', 'bit', '000000000000000000'),
        ('rx_valid_b', 'bit', '000000000011100000'),
        ('rx_data_b', 'bus', [(0, 10, '', 'x'), (10, 11, '55', 'v'), (11, 12, '', 'v'),
                              (12, 13, '', 'v'), (13, 18, '', 'x')]),
        ('ev_rm_drop', 'bit', '000000000000000100'),
    ]
    f, xs, ys = timing([19.5] * 18, rows, (2, 5, 7, 11, 14))
    dim(f, xs[1], xs[4], 11, 'A first')
    dim(f, xs[10], xs[13], 11, 'B duplicate')
    return f


@fig
def t12_w_fault():
    # AFDX_top.v:17–19、41、48–60；afdx_cfg.v:37、66、147、262。
    # afdx_rx_parse.v:55、265：EV_FCS=8'h02；core:123、top:325 保持位编码。
    # GROUP_A_COUNT * 8 + 1 = 0x49（字地址）；两次配置读均为 t+2 返回。
    rows = [
        ('clk', 'clk', None),
        ('rx_valid', 'bit', '000001111000000000'),
        ('rx_data', 'bus', [(0, 5, '', 'x'), (5, 6, '55', 'v'), (6, 7, '', 'v'),
                            (7, 9, 'FCS tail', 'h'), (9, 18, '', 'x')]),
        ('ev_a[1]', 'bit', '000000000010000000'),
        ('ev_deliver', 'bit', '000000000000000000'),
        ('app_rx_valid', 'bit', '000000000000000000'),
        ('cfg_rd', 'bit', '010000000000010000'),
        ('cfg_addr', 'bus', [(0, 1, '', 'x'), (1, 2, '0x49', 'v'), (2, 13, '', 'x'),
                             (13, 14, '0x49', 'v'), (14, 18, '', 'x')]),
        ('cfg_rvalid', 'bit', '000100000000000100'),
        ('cfg_rdata', 'bus', [(0, 3, '', 'x'), (3, 4, 'n', 'v'), (4, 15, '', 'x'),
                              (15, 16, 'n+1', 'g'), (16, 18, '', 'x')]),
    ]
    f, xs, ys = timing([19.5] * 18, rows, (4, 6, 9, 12))
    dim(f, xs[1], xs[3], 11, 'read +2')
    dim(f, xs[13], xs[15], 11, 'read +2')
    return f


@fig
def t13_w_bag():
    # AFDX_top.v:14、16、18、23–24；起点取 GMII 前导码首字节。
    valid = '0111100000111100'
    data = [(0, 1, '', 'x'), (1, 2, '55', 'v'), (2, 3, '', 'v'),
            (3, 5, 'Frame 1', 'h'), (5, 10, '', 'x'), (10, 11, '55', 'v'),
            (11, 12, '', 'v'), (12, 14, 'Frame 2', 'h'), (14, 16, '', 'x')]
    rows = [('clk', 'clk', None), ('tx_valid', 'bit', valid), ('tx_data', 'bus', data),
            ('tx_valid_b', 'bit', valid), ('tx_data_b', 'bus', data)]
    f, xs, ys = timing([22] * 16, rows, (2, 7, 11))
    for i in (1, 10):
        guide(f, xs[i], 10, ys[-1] + 12)
    dim(f, xs[1], xs[10], 10, 'Start-to-start = BAG = 1 ms = 125000 cycles')
    return f


@fig
def t14_w_snmp():
    # AFDX_top.v:16–26、125–126、151–180、222–223。
    # 仅画公开 GMII 端口；SNMP 服务内部处理时长用断拍省略。
    response = [(0, 11, '', 'x'), (11, 12, '55', 'v'), (12, 13, '', 'v'),
                (13, 16, 'GetResponse', 'h'), (16, 17, '', 'h'), (17, 18, '', 'x')]
    rows = [
        ('clk', 'clk', None),
        ('rx_valid', 'bit', '011111000000000000'),
        ('rx_data', 'bus', [(0, 1, '', 'x'), (1, 2, '55', 'v'), (2, 3, '', 'v'),
                            (3, 5, 'Get', 'g'), (5, 6, '', 'g'), (6, 18, '', 'x')]),
        ('tx_valid', 'bit', '000000000001111110'),
        ('tx_data', 'bus', response),
        ('tx_valid_b', 'bit', '000000000001111110'),
        ('tx_data_b', 'bus', response),
    ]
    f, xs, ys = timing([19.5] * 18, rows, (2, 5, 8, 12, 16))
    dim(f, xs[1], xs[6], 11, 'UDP destination 161')
    dim(f, xs[11], xs[17], 11, 'UDP source 161')
    return f


@fig
def t15_w_615a():
    # 被测端公开 GMII 端口：收到加载端的 DATA 块，在两网回 ACK；末块短于 512 字节结束传输。
    rx = [(0, 1, '', 'x'), (1, 2, '55', 'v'), (2, 3, '', 'v'), (3, 6, 'DATA n', 'g'),
          (6, 10, '', 'x'), (10, 11, '55', 'v'), (11, 12, '', 'v'), (12, 15, 'DATA n+1', 'g'),
          (15, 20, '', 'x')]
    ack = [(0, 6, '', 'x'), (6, 7, '55', 'v'), (7, 10, 'ACK n', 'h'), (10, 15, '', 'x'),
           (15, 16, '55', 'v'), (16, 19, 'ACK n+1', 'h'), (19, 20, '', 'x')]
    tv = '00000011110000011110'
    rows = [
        ('clk', 'clk', None),
        ('rx_valid', 'bit', '01111100001111100000'),
        ('rx_data', 'bus', rx),
        ('tx_valid', 'bit', tv),
        ('tx_data', 'bus', ack),
        ('tx_valid_b', 'bit', tv),
        ('tx_data_b', 'bus', ack),
    ]
    f, xs, ys = timing([17.5] * 20, rows, (2, 11))
    dim(f, xs[1], xs[6], 11, '512-byte block')
    dim(f, xs[10], xs[15], 11, 'last block < 512')
    return f


@fig
def t16_w_rtc():
    # 从端公开 GMII 端口：发出时间请求，收到主端回应；回应的 Originate 须等于请求的 Transmit。
    req = [(0, 1, '', 'x'), (1, 2, '55', 'v'), (2, 3, '', 'v'), (3, 6, 'Request', 'h'), (6, 7, '', 'h'), (7, 18, '', 'x')]
    rsp = [(0, 10, '', 'x'), (10, 11, '55', 'v'), (11, 12, '', 'v'), (12, 15, 'Response', 'g'), (15, 16, '', 'g'), (16, 18, '', 'x')]
    rows = [
        ('clk', 'clk', None),
        ('tx_valid', 'bit', '011111100000000000'),
        ('tx_data', 'bus', req),
        ('tx_valid_b', 'bit', '011111100000000000'),
        ('tx_data_b', 'bus', req),
        ('rx_valid', 'bit', '000000000011111100'),
        ('rx_data', 'bus', rsp),
    ]
    f, xs, ys = timing([19.5] * 18, rows, (2, 8, 11, 17))
    dim(f, xs[1], xs[7], 11, 'Transmit = T1')
    dim(f, xs[10], xs[16], 11, 'Originate = T1')
    return f


@fig
def t20_thru():
    # docs/evidence/performance.json：delivered_mbps，每方向，不将 A/B 相加。
    f = Fig(400, 208)
    x0, x1, y0, scale = 42, 385, 175, 0.15
    f.tag(x0, 11, 'Mbps', anchor='start')
    f.arrow([(x0, 17), (x0, y0), (x1, y0)], head=None)
    for value in range(0, 1001, 200):
        y = y0 - value * scale
        f.arrow([(x0 - 3, y), (x0, y)], head=None)
        f.tag(x0 - 7, y + 2, str(value), size=6.5, anchor='end')
    for x, vl, value in ((92, 10, 117.680), (182, 77, 906.136), (272, 81, 953.208)):
        h = value * scale
        f.rect(x - 27, y0 - h, 54, h, PAL['rx'][0], '#000', 1.0)
        f.text(x, y0 - h - 6, f'{value:.3f}', T2, bold=True)
        f.arrow([(x, y0), (x, y0 + 3)], head=None)
        f.tag(x, y0 + 13, str(vl))
    y = y0 - 100 * scale
    f.arrow([(x0, y), (x1, y)], dash=True, head=None)
    f.tag(x1, y - 5, '100 Mbps requirement', size=6.5, anchor='end')
    f.tag(214, 202, 'Active VLs per direction')
    return f


@fig
def t21_lat():
    # docs/FACTS_DETAIL.md:108、132–140：轻载，每组 8 样本，最大值等于均值。
    f = Fig(450, 208)
    x0, x1, y0 = 40, 436, 175
    y = lambda us: y0 - us * 6
    f.tag(x0, 11, 'Latency (µs)', anchor='start')
    f.arrow([(x0, 18), (x0, y0), (x1, y0)], head=None)
    for value in range(0, 26, 5):
        f.arrow([(x0 - 3, y(value)), (x0, y(value))], head=None)
        f.tag(x0 - 7, y(value) + 2, str(value), size=6.5, anchor='end')
    points = [(1, 1.056), (17, 1.136), (18, 1.152), (511, 9.040), (1471, 24.400)]
    for i, (n, us) in enumerate(points):
        x = 78 + i * 80
        f.rect(x - 23, y(us), 46, y0 - y(us), PAL['rx'][0], '#000', 1.0)
        f.text(x, y(us) - 6, f'{us:.3f}', T2, bold=True)
        f.arrow([(x, y0), (x, y0 + 3)], head=None)
        f.tag(x, y0 + 13, str(n), size=6.5)
    f.tag(238, 202, 'Application message length (bytes)')
    return f


if __name__ == '__main__':
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    names = sys.argv[2:] or list(FIGS)
    for n in names:
        FIGS[n]().save(os.path.join(out, n + '.svg'))
