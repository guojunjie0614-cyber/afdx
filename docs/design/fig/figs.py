"""JSSC 风格框图与流程图（坐标单位为印刷 pt，插入时不缩放）。

用法: python3 -I figs.py <输出目录> [图名 ...]
内容依据 docs/ARCH.md 与 rtl/ 当前实现。
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from jssc import Fig, T1, T2, tw, PAL

FIGS = {}


def fig(fn):
    FIGS[fn.__name__] = fn
    return fn


@fig
def f01_system():
    f = Fig(450, 300)
    f.group(70, 0, 316, 300, 'gray', 'AFDX_top  (125 MHz, single clock)', dash='3 2', label_color='#333')
    svc = f.group(78, 16, 146, 92, 'cfg', 'afdx_svc')
    mx = f.mux(164, 32, 18, 40, '4:1', name='TX message arbiter')
    for i, label in enumerate(('app', 'RTC', 'SNMP', '615A')):
        yy = 37 + i * 10
        f.tag(143, yy - 3, label, anchor='end', size=6.5)
        f.arrow([(svc.l if i == 0 else 146, yy), (mx.l, yy)])
    f.tag(184, 38, 'TX arbiter', anchor='start', size=6.5)
    dispatch = f.box(82, 82, 92, 22, 'cfg', 'RX dispatch', 'port claim', tsize=T2)
    svcs = [('afdx_rtc', 'SNTPv4 sync'), ('afdx_snmp', 'v1/v2c agent'), ('afdx_615a', '615A target')]
    sb = [f.box(258, 18 + i * 30, 120, 26, 'svc', t, s) for i, (t, s) in enumerate(svcs)]
    for b in sb:
        f.arrow([(b.l, b.t + 7), (svc.r, b.t + 7)])
        f.arrow([(svc.r, b.b - 7), (b.l, b.b - 7)])
        f.tag(241, b.cy + 2, 'tx / rx', size=6.5)
    def core(y, kind, label, chips):
        f.group(74, y, 308, 70, kind, label)
        return [f.box(x, y + 14, w, 22, kind, c, tsize=T2, pad=2)
                for (x, w), c in zip(((78, 62), (146, 104), (256, 70), (332, 46)), chips)]
    tb = core(118, 'tx', 'afdx_tx_core', ['tx_buf', 'tx_engine', 'tx_builder', 'mac_tx'])
    f.box(78, 160, 62, 22, 'ram', 'tx_free', '256-page FIFO', tsize=T2)
    f.box(146, 160, 104, 22, 'ram', 'cfg · state', 'mnext · desc', tsize=T2)
    f.box(256, 160, 70, 22, 'ram', 'payload 128 KiB', 'pnext', tsize=T2)
    rb = core(196, 'rx', 'afdx_rx_core', ['rx_deliver', 'rx_engine', 'rx_parse ×2', 'mac_rx ×2'])
    f.box(146, 238, 104, 22, 'ram', 'map 65536 × 13', 'cfg · state', tsize=T2)
    f.box(256, 238, 70, 22, 'ram', 'ring_a / b', '2 × 4 KiB', tsize=T2)
    app = f.box(0, 28, 62, 76, 'ext', 'Application', 'app_tx_*', 'app_rx_*')
    net = f.box(394, 132, 56, 100, 'ext', 'Network', 'A / B', '8-bit GMII')
    host = f.box(0, 274, 62, 24, 'ext', 'Host', 'cfg_* bus')
    f.arrow([(app.r, 37), (svc.l, 37)], head=None)
    f.arrow([(dispatch.l, 93), (app.r, 93)])
    f.arrow([(mx.r, mx.cy), (196, mx.cy), (196, 116), (132, 116), (132, tb[0].t)])
    f.arrow([(rb[0].l, rb[0].cy), (66, rb[0].cy), (66, 110), (178, 110), (178, 93), (dispatch.r, 93)])
    f.arrow([(tb[3].r, tb[3].cy), (net.l, tb[3].cy)])
    f.arrow([(net.l, rb[3].cy), (rb[3].r, rb[3].cy)])
    f.box(78, 274, 184, 24, 'cfg', 'afdx_cfg', 'registers · 27 counters · table writes')
    f.box(268, 274, 114, 24, 'cfg', 'afdx_timebase', 'now[31:0] · now_c[15:0]')
    f.arrow([(host.r, 286), (78, 286)], head='both')
    return f


def seq(f, x0, y0, xs, parts, msgs, phases=(), pw=70, row=13, xend=None, label_x=None):
    """时序交互图。parts: (标题, 副标题, 颜色)；msgs: (起, 止, 文字, 样式, 注释)。
    样式 req 粗实线、data 实线、ret 虚线。phases: (首条序号, 末条序号, 名称)。"""
    hb = 24
    ys, y = [], y0 + hb + 6
    for m in msgs:
        y += row
        ys.append(y)
        if m[4]:
            y += 8
    ybot = y + 7
    xend = xend if xend is not None else max(xs) + pw / 2
    for a, b, name in phases:
        top = ys[a] - row + 3
        bot = ys[b] + (8 if msgs[b][4] else 0) + 4
        f.rect(x0, top, xend - x0, bot - top - 1.5, '#F2F2F2', 'none', 0)
        f.tag(label_x if label_x is not None else x0 + 2, (top + bot) / 2 + 2.3, name, anchor='start', bold=True, color='#444')
    for x, (t, sub, kind) in zip(xs, parts):
        f.box(x - pw / 2, y0, pw, hb, kind, t, sub)
        f.arrow([(x, y0 + hb), (x, ybot)], dash=True, head=None, sw=0.5, color='#777')
    for (i, j, text, style, note), yy in zip(msgs, ys):
        sw = 1.1 if style == 'req' else 0.75
        f.arrow([(xs[i], yy), (xs[j], yy)], dash=(style == 'ret'), sw=sw)
        f.tag((xs[i] + xs[j]) / 2, yy - 2.6, text)
        if note:
            f.tag((xs[i] + xs[j]) / 2, yy + 7.2, note, size=6.5, italic=True, color='#333')
    return ybot


@fig
def f02_path():
    f = Fig(450, 100)
    w, g = 66, 8
    xs = [62 + i * (w + g) for i in range(4)]
    tg = f.group(58, 0, 300, 46, 'tx', 'ES1  afdx_tx_core')
    tb = [f.box(x, 14, w, 28, 'tx', t, s) for x, (t, s) in zip(xs, [
        ('tx_buf', 'page store'), ('tx_engine', 'BAG schedule'), ('tx_builder', 'header + SN'), ('mac_tx', 'preamble + FCS')])]
    rg = f.group(58, 52, 300, 46, 'rx', 'ES2  afdx_rx_core')
    rb = [f.box(x, 66, w, 28, 'rx', t, s) for x, (t, s) in zip(xs, [
        ('rx_deliver', '1 B / cycle'), ('rx_engine', 'IC + RM'), ('rx_parse ×2', 'header check'), ('mac_rx ×2', 'strip FCS')])]
    a1 = f.box(0, 14, 50, 28, 'ext', 'App', 'm_* msg')
    a2 = f.box(0, 66, 50, 28, 'ext', 'App', 'd_* msg')
    net = f.box(372, 14, 78, 80, 'ext', 'Network', 'A + B copies', 'GMII, 1 B / cycle')
    f.arrow([(a1.r, 28), (tb[0].l, 28)])
    for a, b in zip(tb, tb[1:]):
        f.arrow([(a.r, 28), (b.l, 28)])
    f.arrow([(tb[3].r, 28), (net.l, 28)])
    f.arrow([(net.l, 80), (rb[3].r, 80)])
    for a, b in zip(rb[1:], rb):
        f.arrow([(a.l, 80), (b.r, 80)])
    f.arrow([(rb[0].l, 80), (a2.r, 80)])
    return f


@fig
def f06_frame():
    f = Fig(450, 106)
    fields = [('Preamble', '7', 'ext', 40), ('SFD', '1', 'ext', 22), ('Dst MAC', '6', 'cfg', 44), ('Src MAC', '6', 'cfg', 44),
              ('Type', '2', 'cfg', 28), ('IPv4 hdr', '20', 'gray', 46), ('UDP hdr', '8', 'gray', 42), ('Payload', 'n = 1…1471', 'ram', 70),
              ('Pad', 'p', 'white', 30), ('SN', '1', 'tx', 22), ('FCS', '4', 'cfg', 30), ('IFG', '12', 'ext', 26)]
    x, B = 3, {}
    yf = 28
    for name, sub, kind, w in fields:
        B[name] = f.box(x, yf, w, 26, kind, name, sub, tsize=T2, pad=2)
        x += w
    # 上方括号：帧长与 CRC 覆盖范围
    def bracket(xa, xb, y, text):
        f.arrow([(xa, y + 5), (xa, y), (xb, y), (xb, y + 5)], head=None, sw=0.6)
        f.tag((xa + xb) / 2, y + 2.4, text, bg=True)
    bracket(B['Dst MAC'].l, B['FCS'].r, 5, 'Frame incl. FCS: 47 + max(n, 17) = 64 … 1518 B')
    bracket(B['Dst MAC'].l, B['SN'].r, 18, 'CRC32 coverage')
    # 下方展开 MAC 地址
    ye = 78
    d1 = f.box(3, ye, 56, 26, 'white', '03 00 00 00', 'fixed', tsize=T2, pad=2)
    d2 = f.box(59, ye, 34, 26, 'white', 'VLID', '2 B', tsize=T2, pad=2)
    s1 = f.box(103, ye, 44, 26, 'white', '02 00 00', 'fixed', tsize=T2, pad=2)
    s2 = f.box(147, ye, 40, 26, 'white', 'User ID', '2 B', tsize=T2, pad=2)
    s3 = f.box(187, ye, 54, 26, 'white', 'IF', '20h A / 40h B', tsize=T2, pad=2)
    for src, (l, r) in ((B['Dst MAC'], (d1, d2)), (B['Src MAC'], (s1, s3))):
        f.arrow([(src.l, src.b), (l.l, l.t)], head=None, sw=0.5, color='#666')
        f.arrow([(src.r, src.b), (r.r, r.t)], head=None, sw=0.5, color='#666')
    f.tag(B['IPv4 hdr'].cx + 26, 64, 'TTL 1 · proto 17 · UDP cksum 0', anchor='start')
    f.tag(B['IPv4 hdr'].cx + 26, 73, 'IP len n + 28 · UDP len n + 8', anchor='start')
    f.tag(B['SN'].cx, 64, 'SN: 0 after reset,', anchor='middle')
    f.tag(B['SN'].cx, 73, 'then 1 … 255, 1 …', anchor='middle')
    f.tag(340, 94, 'Pad length: p = max(17 − n, 0) B')
    return f


@fig
def f07_tx():
    f = Fig(450, 140)
    y0, y1, y2 = 0, 40, 96
    buf = f.box(30, y1, 70, 40, 'tx', 'afdx_tx_buf', 'page alloc,', 'payload write')
    eng = f.box(126, y1, 92, 40, 'tx', 'afdx_tx_engine', 'BAG scan,', 'LOOKAHEAD = 512')
    bld = f.box(244, y1, 70, 40, 'tx', 'afdx_tx_builder', '42-B header,', 'prefetch')
    mac = f.box(340, y1, 70, 40, 'tx', 'afdx_mac_tx', 'preamble, FCS,', 'A/B CRC32')
    ya, yb = 52, 70
    f.arrow([(0, ya), (buf.l, ya)])
    f.tag(15, ya - 3, 'm_*')
    for a, b, go, back in ((buf, eng, 'enq', 'result'), (eng, bld, 'grant', 't_start')):
        f.arrow([(a.r, ya), (b.l, ya)])
        f.tag((a.r + b.l) / 2, ya - 3, go)
        f.arrow([(b.l, yb), (a.r, yb)])
        f.tag((a.r + b.l) / 2, yb + 8, back)
    f.arrow([(bld.r, ya), (mac.l, ya)])
    f.tag((bld.r + mac.l) / 2, ya - 3, 's_*')
    f.arrow([(mac.r, 60), (450, 60)])
    f.tag(430, 56, 'GMII')
    f.tag(430, 70.5, 'A / B')
    desc = f.box(30, y0, 62, 24, 'ram', 'tx_desc', '256 × 44')
    st = f.box(142, y0, 60, 24, 'ram', 'tx_state', '+ tx_mnext')
    cfg = f.box(208, y0, 62, 24, 'ram', 'tx_cfg', '1024 × 32')
    f.arrow([(60, buf.t), (60, desc.b)])
    f.arrow([(desc.r, 12), (134, 12), (134, eng.t)])
    f.arrow([(171, st.b), (171, eng.t)], head='both')
    f.arrow([(212, cfg.b), (212, eng.t)])
    f.arrow([(300, 12), (cfg.r, 12)], dash=True)
    f.tag(303, 14.5, 'cfg bus (afdx_cfg)', anchor='start')
    fr = f.box(28, y2, 58, 24, 'ram', 'tx_free', '256-page FIFO')
    pl = f.box(126, y2, 188, 24, 'ram', 'tx_payload + tx_pnext', '128 KiB = 256 pages × 512 B')
    f.arrow([(48, buf.b), (48, fr.t)], head='both')
    f.tag(51, 91, 'page', anchor='start')
    f.arrow([(94, buf.b), (94, 108), (pl.l, 108)])
    f.tag(110, 105, 'wr')
    f.arrow([(296, pl.t), (296, bld.b)])
    f.tag(293, 91, 'prefetch', anchor='end')
    # 组帧器读完一页即归还
    f.arrow([(bld.r, 74), (326, 74), (326, 128), (57, 128), (57, fr.b)])
    f.tag(190, 137, 'page returned after read')
    return f


@fig
def f08_txfsm():
    f = Fig(350, 166)
    init = f.box(0, 74, 52, 26, 'gray', 'INIT', 'clear tables', rx=4)
    idle = f.box(94, 66, 64, 42, 'tx', 'IDLE', 'scan 1 VL', 'per 2 cycles', rx=4)
    st = f.box(230, 18, 120, 26, 'txl', '(1) START', 'next_time = t + BAG', rx=4)
    enq = f.box(230, 74, 120, 26, 'txl', '(2) ENQ', 'check, link to queue', rx=4)
    gr = f.box(230, 130, 120, 26, 'txl', '(3) GRANT', 'read cfg, dequeue, SN', rx=4)
    f.arrow([(init.r, 87), (idle.l, 87)])
    f.tag(73, 84, 'init')
    f.tag(162, 64, 'START > ENQ > GRANT', size=6.5, anchor='start')
    # START：外圈去、内圈回
    f.arrow([(110, idle.t), (110, 25), (st.l, 25)])
    f.tag(172, 12, 'ack_pending', size=6.5)
    f.tag(172, 22, '(t_start latched)', size=6.5)
    f.arrow([(st.l, 37), (138, 37), (138, idle.t)])
    f.tag(184, 47, 'next_time written, 3 cycles', size=6.5)
    f.arrow([(idle.r, 81), (enq.l, 81)])
    f.tag(194, 78, 'want_enq', size=6.5)
    f.arrow([(enq.l, 93), (idle.r, 93)])
    f.tag(194, 104, 'enq_ack, 5 cycles', size=6.5)
    f.arrow([(110, idle.b), (110, 149), (gr.l, 149)])
    f.tag(184, 162, 'want_grant', size=6.5)
    f.arrow([(gr.l, 137), (138, 137), (138, idle.b)])
    f.tag(184, 133, 'grant_valid, 8 cycles', size=6.5)
    return f


@fig
def f10_macfsm():
    f = Fig(450, 257)
    f.tag(0, 8, '(a) afdx_mac_tx', bold=True, size=T1, anchor='start')
    gap = f.box(10, 43, 48, 20, 'gray', 'GAP', rx=4)
    pre = f.box(135, 43, 70, 20, 'txl', 'PREAMBLE', rx=4)
    data = f.box(277, 43, 48, 20, 'txl', 'DATA', rx=4)
    fcs = f.box(392, 43, 48, 20, 'txl', 'FCS', rx=4)
    drain = f.box(350, 99, 68, 20, 'drop', 'DRAIN', rx=4)
    for a, b, labels in [(gap, pre, ('gap_left == 0', '&& s_valid')),
                          (pre, data, ('pre_index == 7', '&& s_valid')),
                          (data, fcs, ('last_byte', '|| !s_valid'))]:
        f.arrow([(a.r, a.cy), (b.l, b.cy)])
        for i, label in enumerate(labels):
            f.tag((a.r + b.l) / 2, 39 + i * 8, label, size=6.5)
    f.arrow([(416, 43), (416, 22), (34, 22), (34, 43)])
    f.tag(225, 19, 'fcs_index == 3 && !discard_tail: start 12-cycle IFG', size=6.5)
    f.arrow([(170, 63), (170, 81), (403, 81), (403, 63)], dash=True)
    f.tag(280, 77, 'pre_index == 7 && !s_valid: underrun', size=6.5)
    f.arrow([(430, 63), (430, 109), (418, 109)], dash=True)
    f.tag(427, 91, 'fcs_index == 3 && discard_tail', size=6.5, anchor='end')
    f.arrow([(350, 109), (34, 109), (34, 63)], dash=True)
    f.tag(175, 105, 's_valid && s_last: tail consumed', size=6.5)

    f.tag(0, 138, '(b) afdx_mac_rx', bold=True, size=T1, anchor='start')
    idle = f.box(10, 173, 48, 20, 'gray', 'IDLE', rx=4)
    rp = f.box(165, 173, 70, 20, 'pass', 'PREAMBLE', rx=4)
    frame = f.box(370, 173, 70, 20, 'pass', 'FRAME', rx=4)
    bad = f.box(165, 224, 70, 20, 'drop', 'BAD_PRE', rx=4)
    f.arrow([(58, 183), (165, 183)])
    f.tag(111, 179, 'armed && valid_q', size=6.5)
    f.tag(111, 169, '&& data_q == 55h', size=6.5)
    f.arrow([(235, 183), (370, 183)])
    f.tag(302, 179, 'valid_q && data_q == D5h', size=6.5)
    f.arrow([(44, 173), (44, 153), (405, 153), (405, 173)])
    f.tag(225, 150, 'armed && valid_q && data_q == D5h', size=6.5)
    f.arrow([(58, 189), (76, 189), (76, 234), (165, 234)])
    f.tag(80, 216, 'armed && valid_q', size=6.5, anchor='start')
    f.tag(80, 224, '&& data_q not 55h / D5h', size=6.5, anchor='start')
    f.arrow([(200, 193), (200, 224)])
    f.tag(204, 207, 'valid_q && data_q not 55h / D5h', size=6.5, anchor='start')
    f.arrow([(175, 173), (175, 161), (50, 161), (50, 173)])
    f.tag(110, 159, '!valid_q', size=6.5)
    f.arrow([(405, 193), (405, 253), (22, 253), (22, 193)])
    f.tag(325, 249, '!valid_q: f_end, check length / FCS', size=6.5)
    f.arrow([(165, 240), (46, 240), (46, 193)])
    f.tag(105, 249, '!valid_q', size=6.5)

    return f


@fig
def f11_rx():
    f = Fig(450, 124)
    y0, y1, y2 = 0, 40, 98
    mac = f.box(28, y1, 62, 40, 'rx', 'mac_rx ×2', 'SFD, CRC32,', 'strip FCS')
    prs = f.box(120, y1, 66, 40, 'rx', 'rx_parse ×2', 'header check,', 'trial write')
    eng = f.box(216, y1, 92, 40, 'rx', 'afdx_rx_engine', 'map, IC, RM,', 'aging')
    dlv = f.box(338, y1, 66, 40, 'rx', 'rx_deliver', '1 B / cycle,', 'no backpressure')
    ya = 56
    f.arrow([(0, ya), (mac.l, ya)])
    f.tag(14, ya - 3, 'GMII')
    f.tag(14, ya + 11, 'A / B')
    f.arrow([(mac.r, ya), (prs.l, ya)])
    f.tag(105, ya - 3, 'm_*')
    f.arrow([(prs.r, ya), (eng.l, ya)])
    f.tag(201, ya - 3, 'desc')
    f.arrow([(eng.r, ya), (dlv.l, ya)])
    f.tag(323, ya - 3, 'rx_dq')
    f.arrow([(dlv.r, ya), (450, ya)])
    f.tag(428, ya - 3, 'd_*')
    # 提交或回退：引擎回到解析器
    f.arrow([(262, eng.b), (262, 89), (170, 89), (170, prs.b)], dash=True)
    f.tag(216, 86, 'commit / rollback')
    m = f.box(124, y0, 66, 24, 'ram', 'rx_map', '65536 × 13')
    c = f.box(232, y0, 60, 24, 'ram', 'rx_cfg', '4096 × 32')
    s = f.box(298, y0, 60, 24, 'ram', 'rx_state', '4096 × 44')
    f.arrow([(m.r, 12), (222, 12), (222, eng.t)])
    f.arrow([(250, c.b), (250, eng.t)])
    f.arrow([(302, s.b), (302, eng.t)], head='both')
    f.arrow([(70, 12), (m.l, 12)], dash=True)
    f.tag(66, 14.5, 'cfg bus', anchor='end')
    ring = f.box(120, y2, 284, 24, 'ram', 'rx_ring_a / rx_ring_b', '2 × 4 KiB · trial write, commit on accept')
    f.arrow([(140, prs.b), (140, ring.t)])
    f.tag(143, 94, 'wr', anchor='start')
    f.arrow([(370, ring.t), (370, dlv.b)])
    f.tag(373, 94, 'rd', anchor='start')
    return f


@fig
def f12_ring():
    f = Fig(450, 75)
    y = 30
    segs = [('free', 'white', 60), ('committed, waiting for rx_deliver', 'pass', 170), ('current frame (trial)', 'ram', 110), ('free', 'white', 70)]
    x = 20
    xs = [x]
    for t, k, w in segs:
        f.box(x, y, w, 20, k, t, tsize=T2)
        x += w
        xs.append(x)
    for xp, name, own in ((xs[1], 'rd', 'rx_deliver'), (xs[2], 'wr_commit', 'rx_parse'), (xs[3], 'wr_trial', 'rx_parse')):
        f.arrow([(xp, 16), (xp, y)])
        f.tag(xp, 6.5, name, bold=True, size=T1)
        f.tag(xp + 3, 14.5, own, anchor='start', color='#444')
    f.arrow([(xs[-1], 40), (444, 40), (444, 62), (8, 62), (8, 40), (20, 40)], sw=0.6)
    f.tag(226, 71, 'wrap: 2^RX_RING_AW = 4096 B per network; pointers carry one extra bit', italic=True)
    f.tag(xs[1] + 5, 59, 'free = 4096 − (wr_commit − rd)', anchor='start')
    return f


@fig
def f13_decide():
    f = Fig(450, 96)
    w, g = 66, 10
    xs = [i * (w + g) for i in range(6)]
    steps = [('ext', 'Good frame', 'rx_parse A / B'), ('rx', 'rx_map[VLID]', 'valid?'), ('rx', 'rx_cfg[idx]', 'en, net, len'),
             ('rx', 'Integrity', 'SN vs PSN'), ('rx', 'Redundancy', 'processing order'), ('pass', 'Commit', 'ring + rx_dq')]
    B = [f.box(x, 6, w, 30, k, t, s) for x, (k, t, s) in zip(xs, steps)]
    for a, b in zip(B, B[1:]):
        f.arrow([(a.r, 21), (b.l, 21)])
    drops = [('Unknown VL', 'a/b_unk', 'miss'), ('Config reject', 'a/b_cfg', 'deny'), ('IC drop', 'a/b_ic', 'fail'),
             ('RM drop', 'rm_drop', 'dup'), ('Queue full', 'a/b_ovf', 'full')]
    for b, (t, s, why) in zip(B[1:], drops):
        d = f.box(b.l, 66, w, 26, 'drop', t, s)
        f.arrow([(b.cx, b.b), (b.cx, d.t)], dash=True)
        f.tag(b.cx + 3, 54, why, anchor='start')
    f.tag(0, 54, 'ic_en / rm_en = 0', anchor='start', color='#444')
    f.tag(0, 62, 'skips that step', anchor='start', color='#444')
    return f


@fig
def f14_rtc():
    f = Fig(450, 152)
    f.rect(130, 0, 190, 150, '#E6E6E6', 'none', 0)
    f.text(225, 12, 'tx / rx cores + AFDX network (UDP 123)', T2)
    for x, title, mode in ((54, 'Slave afdx_rtc', 0), (396, 'Master afdx_rtc', 1)):
        f.box(x - 50, 0, 100, 26, 'svc', title, f'CTRL.master = {mode}')
        f.arrow([(x, 26), (x, 150)], dash=True, head=None, sw=0.5, color='#777')
    f.arrow([(54, 50), (130, 50), (320, 72), (396, 72)], sw=1.1)
    f.tag(225, 45, 'mode 3: Transmit = t1')
    f.arrow([(396, 104), (320, 104), (130, 128), (54, 128)], sw=1.1)
    f.tag(225, 99, 'mode 4: Originate = t1, Receive = t2, Transmit = t3')
    for x, y, stamp in ((54, 50, 't1'), (396, 72, 't2'), (396, 104, 't3'), (54, 128, 't4')):
        f.body.append(f'<circle cx="{x}" cy="{y}" r="2.2" fill="#000"/>')
        f.tag(x - 7 if x < 225 else x + 7, y + 2, stamp,
              anchor='end' if x < 225 else 'start', bold=True)
    return f


@fig
def f16_615a():
    f = Fig(450, 10)
    up = [(0, 1, 'RRQ DEMC3_1.LUI', 'req', None), (1, 0, 'DATA1: LUI, status 0001', 'data', None),
          (1, 0, 'WRQ DEMC3_1.LUS', 'req', None), (1, 0, 'DATA1: LUS 0001', 'data', None),
          (0, 1, 'WRQ DEMC3_1.LUR', 'req', None),
          (0, 1, 'DATA: LUR (LUH name, PN)', 'data', None), (1, 0, 'LUS 0002', 'data', None),
          (1, 0, 'RRQ header file .LUH', 'req', None), (0, 1, 'DATA: LUH (CRC-16)', 'data', None),
          (1, 0, 'LUS progress (LUH ready)', 'data', None),
          (1, 0, 'RRQ data file', 'req', None), (0, 1, 'DATA1: 512 B → load RAM', 'data', None),
          (1, 0, 'LUS progress', 'data', None), (1, 0, 'ACK1', 'ret', None),
          (0, 1, 'DATA n … short last block', 'data', None),
          (1, 0, 'ACK n (length, CRC ok)', 'ret', None), (1, 0, 'LUS 0003, ratio 100', 'data', None)]
    dn = [(0, 1, 'RRQ DEMC3_1.LND', 'req', None), (1, 0, 'DATA1: LND, status 0001', 'data', None),
          (1, 0, 'WRQ DEMC3_1.LNS', 'req', None), (1, 0, 'DATA1: LNS 0001', 'data', None),
          (0, 1, 'WRQ DEMC3_1.LNR', 'req', None),
          (0, 1, 'DATA1: LNR (MEMORY.BIN)', 'data', None), (1, 0, 'LNS 0002', 'data', None),
          (1, 0, 'WRQ MEMORY.BIN', 'req', None), (0, 1, 'ACK0 (new TID)', 'ret', None),
          (1, 0, 'DATA n: 0…512 B from RAM', 'data', None), (0, 1, 'ACK n', 'ret', None),
          (1, 0, 'LNS progress (1st full block)', 'data', None), (1, 0, 'LNS 0003, ratio 100', 'data', None)]
    parts = [('Data loader', 'TFTP peer', 'ext'), ('afdx_615a', 'DEMC3_1', 'svc')]
    w = 222
    def phased(x0, xs, msgs, phases, xend):
        ys, y = [], 30
        starts = {a for a, _, _ in phases if a}
        for i in range(len(msgs)):
            y += 13 + (7 if i in starts else 0)
            ys.append(y)
        for a, b, name in phases:
            top, bottom = ys[a] - 10, ys[b] + 3
            f.rect(x0, top, xend - x0, bottom - top, '#F2F2F2', 'none', 0)
            f.tag(x0 + 2, (top + bottom) / 2 + 2.3, name, anchor='start', bold=True, color='#444')
        for x, (title, sub, kind) in zip(xs, parts):
            f.box(x - 33, 0, 66, 24, kind, title, sub)
            f.arrow([(x, 24), (x, y + 7)], dash=True, head=None, sw=0.5, color='#777')
        for (i, j, label, style, _), yy in zip(msgs, ys):
            f.arrow([(xs[i], yy), (xs[j], yy)], dash=style == 'ret', sw=1.1 if style == 'req' else 0.75)
            f.tag(sum(xs) / 2, yy - 2.6, label)
        return y + 7
    yb1 = phased(0, [70, 186], up, [(0, 3, 'Init'), (4, 6, 'List'), (7, 9, 'LUH'), (10, 15, 'Data'), (16, 16, 'End')], w)
    yb2 = phased(228, [298, 414], dn, [(0, 3, 'Init'), (4, 6, 'List'), (7, 11, 'Data'), (12, 12, 'End')], 450)
    yb = max(yb1, yb2)
    f.tag(111, yb + 13, '(a) Upload', bold=True, size=T1)
    f.tag(339, yb + 13, '(b) Media-defined download', bold=True, size=T1)
    f.h = yb + 17
    return f


@fig
def f15_snmp():
    f = Fig(450, 174)
    w, g = 70, 6
    xs = [i * (w + g) for i in range(6)]
    f.group(xs[1] - 5, 0, xs[4] + w - xs[1] + 10, 166, 'svc', 'afdx_snmp')
    main = [('ext', 'UDP 161', 'claimed by svc'), ('svc', 'BER decode', '256 B request RAM'), ('svc', 'Community', '1–16 B compare'),
            ('svc', 'PDU dispatch', 'Get / GetNext / Set'), ('svc', 'GetResponse', 'response RAM'), ('ext', 'Service port 2', 'to afdx_svc')]
    B = [f.box(x, 14, w, 28, k, t, s, pad=3) for x, (k, t, s) in zip(xs, main)]
    for a, b in zip(B, B[1:]):
        f.arrow([(a.r, 28), (b.l, 28)])
    bad = f.box(xs[2], 74, w, 28, 'drop', 'Bad community', 'count, no reply')
    trap = f.box(xs[1], 130, 146, 28, 'svcl', 'SNMPv2-Trap', 'coldStart / authenticationFailure')
    mib = f.box(xs[3], 74, xs[4] + w - xs[3], 28, 'ram', 'MIB access', '36 objects · cfg read · Set USER_ID')
    f.arrow([(B[2].cx, B[2].b), (B[2].cx, bad.t)], dash=True)
    f.tag(B[2].cx + 3, 58, 'mismatch', anchor='start')
    f.arrow([(bad.cx, bad.b), (bad.cx, trap.t)], dash=True)
    f.tag(bad.cx + 3, 116, 'trap_enabled: auth_pending', anchor='start', size=6.5)
    cold = f.box(0, 130, 62, 28, 'cfg', 'cfg_activate', 'if trap_enabled', pad=2)
    f.arrow([(cold.r, cold.cy), (trap.l, cold.cy)], dash=True)
    f.arrow([(trap.r, trap.cy), (B[5].cx, trap.cy), (B[5].cx, B[5].b)])
    f.tag(300, 141, 'pending Trap served in IDLE', size=6.5)
    f.arrow([(B[3].cx, B[3].b), (B[3].cx, mib.t)])
    f.tag(B[3].cx + 3, 66, 'OID', anchor='start')
    f.arrow([(B[4].cx + 12, mib.t), (B[4].cx + 12, B[4].b)])
    f.tag(B[4].cx + 15, 66, 'value', anchor='start')
    return f


@fig
def f18_tb():
    f = Fig(450, 148)
    d1 = f.box(10, 0, 90, 24, 'ext', 'Driver ES1', 'app / cfg stimulus')
    d2 = f.box(350, 0, 90, 24, 'ext', 'Driver ES2', 'app / cfg stimulus')
    e1 = f.box(0, 42, 110, 30, 'gray', 'ES1: AFDX_top', 'RTL or netlist')
    lk = f.box(165, 40, 120, 36, 'cfg', 'Link model', '4 one-way GMII links', 'delay, drop, xor, replay')
    e2 = f.box(340, 42, 110, 30, 'gray', 'ES2: AFDX_top', 'RTL or netlist')
    f.arrow([(55, d1.b), (55, e1.t)])
    f.arrow([(395, d2.b), (395, e2.t)])
    f.arrow([(e1.r, 52), (lk.l, 52)])
    f.arrow([(lk.l, 62), (e1.r, 62)])
    f.arrow([(lk.r, 52), (e2.l, 52)])
    f.arrow([(e2.l, 62), (lk.r, 62)])
    f.tag(137.5, 49, 'GMII A/B')
    f.tag(312.5, 49, 'GMII A/B')
    f.arrow([(225, lk.b), (225, 100)])
    f.tag(228, 90, 'frames', anchor='start')
    mon = f.box(165, 100, 120, 28, 'ram', 'Port monitors', 'dump · events · sys_events')
    ref = f.box(0, 100, 110, 28, 'white', 'Python reference', 'afdx_ref, sys_ref')
    ver = f.box(340, 100, 110, 28, 'pass', 'Verdict', '[RESULT] + [CHECK]')
    f.arrow([(30, e1.b), (30, 90), (190, 90), (190, mon.t)], dash=True)
    f.arrow([(420, e2.b), (420, 90), (260, 90), (260, mon.t)], dash=True)
    f.tag(64, 86, 'ports, cfg reads')
    f.arrow([(mon.l, 114), (ref.r, 114)])
    f.tag(137.5, 111, 'text logs')
    f.arrow([(ref.cx, ref.b), (ref.cx, 134), (395, 134), (395, ver.b)])
    f.tag(225, 144, 'items checked independently of RTL')
    return f


def gantt(f, x0, y0, cw, ncyc, rows, rh=13, gap=8, lw=72, tick=4):
    """逐拍时序条：rows = [(行名, [(起拍, 止拍, kind, 文字), ...])]。返回各行顶部 y。"""
    # 刻度轴
    f.rect(x0, y0, cw * ncyc, 0.01, 'none', '#000', 0.5)
    for c in range(0, ncyc + 1, tick):
        f.body.append(f'<line x1="{x0 + c * cw:.2f}" y1="{y0:.2f}" x2="{x0 + c * cw:.2f}" y2="{y0 + 3:.2f}" stroke="#000" stroke-width="0.5"/>')
        f.tag(x0 + c * cw, y0 - 2.5, str(c), size=6.5)
    ys = []
    y = y0 + 8
    for name, bars in rows:
        f.tag(x0 - 6, y + rh / 2 + 2.5, name, anchor='end')
        for a, b, kind, text in bars:
            f.box(x0 + a * cw, y, (b - a) * cw, rh, kind, text, tsize=T2, pad=1.5)
        ys.append(y)
        y += rh + gap
    return ys


@fig
def f19_txbuf():
    f = Fig(432, 198)
    S = lambda x, y, k, t, s, w=56: f.box(x, y, w, 30, k, t, s, rx=4, pad=2)
    r1, r2, r3 = 28, 104, 166
    idle = S(0, r1, 'gray', 'IDLE', 'hold 1st byte')
    alloc = S(96, r1, 'txl', 'ALLOC', 'pop_req')
    wait = S(192, r1, 'txl', 'WAIT_PAGE', 'write byte 0', w=70)
    recv = S(302, r1, 'txl', 'RECV', '1 B / cycle')
    ev = S(0, r2, 'gray', 'EVENT', 'one ev pulse')
    rep = S(96, r2, 'txl', 'REPLY', 'wait enq_ack')
    enq = S(192, r2, 'txl', 'ENQUEUE', 'enq_valid', w=70)
    desc = S(302, r2, 'txl', 'DESC', 'write tx_desc')
    drain = S(96, r3, 'drop', 'DRAIN', 'eat to m_last')
    ret = S(192, r3, 'drop', 'RETURN', 'pages → free')
    for b in (idle, recv, drain):
        f.outline(b)
    c1, c2, c3 = r1 + 15, r2 + 15, r3 + 15
    # 主路径
    f.arrow([(idle.r, c1), (alloc.l, c1)])
    f.tag(76, c1 - 3, 'take')
    f.arrow([(alloc.r, c1), (wait.l, c1)])
    f.tag(172, c1 - 3, '1 cycle')
    f.arrow([(wait.r, c1), (recv.l, c1)])
    f.tag(282, c1 - 3, 'pop_ok')
    f.arrow([(340, recv.b), (340, desc.t)])
    f.tag(343, 86, 'm_last', anchor='start')
    f.arrow([(310, recv.b), (310, 74), (124, 74), (124, alloc.b)])
    f.tag(178, 70, 'boundary: next byte')
    # 暂存字节就是末字节：取到页后直接写描述
    f.arrow([(250, wait.b), (250, 86), (320, 86), (320, desc.t)])
    f.tag(285, 96, 'held_last')
    f.arrow([(desc.l, c2), (enq.r, c2)])
    f.arrow([(enq.l, c2), (rep.r, c2)])
    f.arrow([(rep.l, c2), (ev.r, c2)])
    f.tag(76, c2 - 3, 'accept')
    f.arrow([(28, ev.t), (28, idle.b)])
    f.tag(31, 86, 'next msg', anchor='start')
    f.stub(recv.r, c1, 'r', '→ RETURN')
    f.tag(389, c1 - 9, '> 1471 B', size=6.5)
    f.stub(227, wait.t, 'u', '→ RETURN')
    f.tag(222, 21, 'pop_ack, !pop_ok', size=6.5, anchor='end')
    f.arrow([(124, rep.b), (124, 146), (227, 146), (227, ret.t)])
    f.tag(178, 142, 'reject', size=6.5)
    f.arrow([(ret.l, c3), (drain.r, c3)])
    f.tag(172, c3 - 3, 'not ended', size=6.5)
    f.arrow([(202, ret.t), (202, 154), (40, 154), (40, ev.b)])
    f.tag(76, 151, 'ended', size=6.5)
    f.arrow([(drain.l, c3), (14, c3), (14, ev.b)])
    f.tag(52, c3 - 3, 'm_last', size=6.5)
    return f


@fig
def f20_pipe():
    f = Fig(450, 212)
    cw, x0 = 11.0, 80
    ys = gantt(f, x0, 14, cw, 32, [
        ('tx_buf', [(1, 3, 'txl', 'desc')]),
        ('tx_engine', [(3, 9, 'txl', 'ENQ'), (9, 18, 'tx', 'GRANT')]),
        ('tx_builder', [(18, 29, 'txl', 'IP checksum, 10 steps'), (29, 30, 'tx', '')]),
        ('mac_tx', [(30, 31, 'tx', '')]),
    ])
    for c, ra in ((3, 0), (18, 1), (30, 2)):
        x = x0 + c * cw
        f.arrow([(x, ys[ra] + 13), (x, ys[ra + 1])], sw=0.6)
    f.tag(x0 + 31 * cw + 2, ys[3] + 9, 'tx_sof', anchor='start', bold=True)
    f.tag(x0 + 3 * cw + 3, ys[0] + 9.5, 'enq_valid', anchor='start')
    f.tag(x0 + 18 * cw - 3, ys[2] + 9.5, 'grant_valid', anchor='end')
    f.tag(x0 + 30 * cw - 3, ys[3] + 9.5, 's_valid', anchor='end')
    f.tag(225, 104, '(a) Transmit', bold=True, size=T1)
    y1 = 122
    ys = gantt(f, x0, y1, cw, 32, [
        ('mac_rx', [(0, 3, 'rx', 'end')]),
        ('rx_parse', [(3, 6, 'pass', 'class')]),
        ('rx_engine', [(6, 18, 'rx', 'FRAME phases 0–9')]),
        ('rx_deliver', [(18, 24, 'pass', 'select, read')]),
    ], gap=5)
    for c, ra in ((3, 0), (6, 1), (18, 2)):
        x = x0 + c * cw
        f.arrow([(x, ys[ra] + 13), (x, ys[ra + 1])], sw=0.6)
    f.tag(x0 + 24 * cw + 2, ys[3] + 9, 'd_valid', anchor='start', bold=True)
    f.tag(x0 + 3 * cw + 3, ys[0] + 9.5, 'f_end', anchor='start')
    f.tag(x0 + 6 * cw + 3, ys[1] + 9.5, 'desc_valid', anchor='start')
    f.tag(x0 + 18 * cw + 3, ys[2] + 9.5, 'dq_count', anchor='start')
    f.tag(225, 208, '(b) Receive', bold=True, size=T1)
    return f


@fig
def f21_scan():
    f = Fig(450, 94)
    w, g = 65, 12
    xs = [i * (w + g) for i in range(6)]
    st = [('txl', 'Issue', 'state_re, scan_vl0'), ('ram', 'tx_state', 'sync read'), ('txl', 'Capture', 's0 ← state_q'),
          ('txl', 'Subtract', 'd = now − next'), ('txl', 'Window', 'd + 512 ≥ 0 ?'), ('tx', 'Decide', 'candidate')]
    B = [f.box(x, 22, w, 32, k, t, s, pad=2) for x, (k, t, s) in zip(xs, st)]
    for i, (a, b) in enumerate(zip(B, B[1:])):
        f.arrow([(a.r, 38), (b.l, 38)])
    for i, b in enumerate(B):
        f.tag(b.cx, 14, f'cycle c+{i}' if i else 'cycle c', size=6.5, color='#444')
    for i, b in enumerate(B[1:]):
        f.tag(b.cx, 66, f'scan_valid[{i}]', size=6.5)
    # 队列空且到期：写回清 timer_active
    f.arrow([(B[5].l + 6, B[5].b), (B[5].l + 6, 80), (B[1].l + 6, 80), (B[1].l + 6, B[1].b)], dash=True)
    f.tag(B[3].cx, 90, 'queue empty and due: write back timer_active = 0')
    return f


@fig
def f22_builder():
    f = Fig(450, 170)
    g = f.box(0, 8, 82, 34, 'tx', 'Grant regs', 'p_* fields')
    pr = f.box(112, 8, 82, 34, 'txl', 'Prepare', 'lengths, IP sum')
    hd = f.box(224, 8, 82, 34, 'txl', 'Header shift', '336 b, 1 B / cycle')
    mx = f.mux(334, 20, 18, 76, 'sel')
    mac = f.box(368, 41, 82, 34, 'tx', 'afdx_mac_tx', 's_data_a / b')
    f.arrow([(g.r, 25), (pr.l, 25)])
    f.arrow([(pr.r, 25), (hd.l, 25)])
    f.tag(209, 22, 'start')
    f.arrow([(hd.r, 32), (mx.l, 32)])
    f.tag(320, 29, 'hdr')
    f.arrow([(mx.r, 58), (mac.l, 58)])
    f.tag(360, 55, 's_*', size=6.5)
    # 载荷预读
    fa = f.box(0, 74, 82, 34, 'txl', 'Fetch addr', '{page, offset}')
    ram = f.box(112, 74, 82, 34, 'ram', 'tx_payload', '128 KiB')
    f.tag(265, 79, 'Byte FIFO', bold=True)
    fifo = f.cells(224, 85, 82, 12, 8, 'txl')
    f.tag(265, 106, '8 entries, stop at 5', size=6.5)
    f.arrow([(fa.r, 91), (ram.l, 91)])
    f.arrow([(ram.r, 91), (fifo.l, 91)])
    f.tag(209, 88, 'q reg')
    f.arrow([(fifo.r, fifo.cy), (320, fifo.cy), (320, 84), (mx.l, 84)])
    f.tag(320, 81, 'data')
    sn = f.box(224, 52, 82, 15, 'txl', 'SN · pad 0', tsize=T2)
    f.arrow([(sn.r, 59.5), (mx.l, 59.5)])
    f.arrow([(41, g.b), (41, fa.t)])
    f.tag(44, 60, 'first page', anchor='start')
    pn = f.box(0, 132, 82, 34, 'ram', 'tx_pnext', 'next page')
    f.arrow([(41, pn.t), (41, fa.b)])
    f.tag(265, 137, 'Return FIFO', bold=True)
    rf = f.cells(224, 143, 82, 12, 4, 'txl')
    f.tag(265, 164, '4 entries', size=6.5)
    meta = f.box(112, 132, 82, 34, 'gray', 'Page metadata', 'read pipeline')
    f.arrow([(fa.r, 103), (97, 103), (97, 149), (meta.l, 149)], dash=True)
    f.arrow([(meta.r, 149), (rf.l, 149)], dash=True)
    f.tag(209, 146, 'end')
    fr = f.box(368, 132, 82, 34, 'ram', 'afdx_tx_free', 'ret1 port')
    f.arrow([(rf.r, 149), (fr.l, 149)])
    f.tag(337, 146, 'ret_*', size=6.5)
    return f


@fig
def f23_parse():
    f = Fig(450, 168)
    bw = 7.6
    fields = [(0, 6, 'gray', 'DMAC'), (6, 12, 'white', 'SMAC'), (12, 14, 'gray', 'T'), (14, 34, 'rx', 'IPv4 header'),
              (34, 42, 'rx', 'UDP header')]
    y = 16
    X = 4
    for a, b, k, t in fields:
        f.box(X + a * bw, y, (b - a) * bw, 18, k, t, tsize=T2, pad=1)
    pl = f.box(X + 42 * bw, y, 72, 18, 'ram', 'payload n B', tsize=T2, pad=1)
    sn = f.box(pl.r, y, 44, 18, 'gray', 'pad · SN', tsize=T2, pad=1)
    for b in (0, 6, 12, 14, 34, 42):
        f.tag(X + b * bw, 10, str(b), size=6.5)
    rows = [(X + 3 * bw, ['03 00 00 00', 'VLID']), (X + 9 * bw, ['ignored']), (X + 24 * bw, ['45, no fragment, proto 11,', 'IP length, sum = FFFF']),
            (X + 38 * bw, ['ports, n = len − 8', 'UDP sum ≠ 0 → check']), (pl.cx, ['space ≥ n ?', 'trial write']),
            (sn.cx, ['SN at', '42 + max(n,17)'])]
    for x, ls in rows:
        for i, t in enumerate(ls):
            f.tag(x, 45 + i * 8.5, t, size=6.5)
    f.tag(X + 13 * bw, 45, '08 00', size=6.5)
    f.tag(225, 70, '(a) Streaming checks', bold=True, size=T1)
    # (b) length_phase
    S = lambda x, yy, k, t, sub, w=62: f.box(x, yy, w, 28, k, t, sub, rx=4, pad=2, tsize=T2, ssize=6.5)
    yb = 88
    lw = S(0, yb, 'gray', 'LEN_WAIT', 'until byte 39')
    ls = S(96, yb, 'pass', 'LEN_SIZES', 'n, n_ok, IP len')
    ll = S(192, yb, 'pass', 'LEN_LIMITS', 'end, SN pos, space', w=70)
    f.arrow([(lw.r, 102), (ls.l, 102)])
    f.arrow([(ls.r, 102), (ll.l, 102)])
    f.arrow([(ll.cx, ll.b), (ll.cx, 126), (lw.cx, 126), (lw.cx, lw.b)])
    f.tag(79, 99, 'UDP len')
    f.tag(131, 140, '(b) length_phase', bold=True, size=T1)
    # (c) finish_phase
    fw = S(290, yb, 'gray', 'FIN_WAIT', 'frame body', w=56)
    fs = S(388, yb, 'pass', 'FIN_SETTLE', 'UDP sum final', w=60)
    fr = S(388, 136, 'rx', 'FIN_REPORT', 'class, desc', w=60)
    f.arrow([(fw.r, 102), (fs.l, 102)])
    f.tag(367, 99, 'f_end')
    f.arrow([(fs.cx, fs.b), (fs.cx, fr.t)])
    f.arrow([(fr.l, 150), (fw.cx, 150), (fw.cx, fw.b)])
    f.tag(290, 165, '(c) finish_phase', bold=True, size=T1, anchor='start')
    f.tag(353, 146, 'one ev pulse', size=6.5)
    return f


@fig
def f24_rxeng():
    f = Fig(450, 280)
    init = f.box(15, 12, 52, 20, 'gray', 'INIT', rx=4)
    idle = f.box(240, 12, 60, 20, 'gray', 'IDLE', rx=4)
    f.arrow([(init.r, 22), (idle.l, 22)])
    f.tag(150, 16, 'clear 4096 entries, flush final write', size=6.5)
    f.arrow([(275, 32), (275, 62), (45, 62), (45, 88)])
    f.tag(160, 58, 'enable && desc: A before B; issue map read', size=6.5)
    f.arrow([(250, 32), (250, 44), (3, 44), (3, 249), (15, 249)])
    f.tag(126, 40, 'enable && !desc && (age_pending || now_c tick)', size=6.5)
    names = ['map pending', 'save map', 'read cfg/state', 'wait', 'save cfg/state', 'en, net, length',
             'delta, SN dist.', 'IC', 'RM', 'rx_dq', 'write state', 'resolve, event']
    P = []
    for i, sub in enumerate(names):
        x = 15 + (i if i < 6 else 11 - i) * 72
        y = 88 if i < 6 else 158
        kind = 'pass' if i in (7, 8) else 'ram' if i in (0, 2) else 'gray'
        P.append(f.box(x, y, 60, 28, kind, f'FRAME {i}', sub, pad=2, tsize=T2, ssize=6.5, rx=4))
    for i, (a, b) in enumerate(zip(P, P[1:])):
        if i == 5:
            f.arrow([(a.r, a.cy), (440, a.cy), (440, b.cy), (b.r, b.cy)])
        elif i < 5:
            f.arrow([(a.r, a.cy), (b.l, b.cy)])
        else:
            f.arrow([(a.l, a.cy), (b.r, b.cy)])
    f.stub(P[2].cx, P[2].b, 'd', '→ FRAME 11')
    f.tag(P[2].cx, 150, 'unmapped', size=6.5)
    f.stub(P[5].cx, P[5].b, 'd', '→ FRAME 11')
    f.tag(P[5].cx, 150, 'config reject', size=6.5)
    f.stub(P[7].cx, P[7].b, 'd', '→ FRAME 10')
    f.tag(P[7].cx - 30, 204, 'IC fail', size=6.5, anchor='end')
    f.arrow([(45, 186), (45, 219), (446, 219), (446, 22), (300, 22)])
    f.tag(240, 215, 'resolve / commit, one event pulse', size=6.5)
    ag = [f.box(15 + i * 110, 236, 90, 26, 'pass', f'AGE {i}', sub, rx=4)
          for i, sub in enumerate(['read pending', 'save state', 'delta time', 'clear expired'])]
    for a, b in zip(ag, ag[1:]):
        f.arrow([(a.r, a.cy), (b.l, b.cy)])
    # AGE 的四条抢占边汇入同一 IDLE 回路，不复制 IDLE。
    f.arrow([(60, 276), (446, 276), (446, 219)], head='end')
    for i, a in enumerate(ag):
        f.arrow([(a.cx, a.b), (a.cx, 276)], head=None)
        f.tag(a.cx + 4, 271, 'done / desc' if i == 3 else 'desc', anchor='start', size=6.5)
    return f


@fig
def f25_deliver():
    f = Fig(450, 134)
    for x, label in ((99, 'C1'), (173, 'C2'), (245, 'C3'), (315, 'C4'), (357, 'C5'), (423, 'C6')):
        f.stage_line(x, 16, 132, label)
    banks = [f.box(0, 26 + i * 26, 40, 18, 'gray', f'bank {i}', tsize=T2, pad=1) for i in range(4)]
    m8 = [f.mux(56, 26 + i * 26, 18, 18, '8:1', name=f'm8_{i}') for i in range(4)]
    gr = [f.reg(96, 26 + i * 26, 18, f'group{i}') for i in range(4)]
    for b, m, g in zip(banks, m8, gr):
        f.arrow([(b.r, b.cy), (m.l, b.cy)])
        f.arrow([(m.r, b.cy), (g.l, b.cy)])
    m4 = f.mux(128, 26, 18, 96, '4:1', name='m4')
    for g in gr:
        f.arrow([(g.r, g.cy), (m4.l, g.cy)])
    dq = f.reg(170, 62, 24, 'dq_data')
    f.arrow([(m4.r, 74), (dq.l, 74)])
    ctl = f.box(196, 58, 46, 32, 'rx', 'Read ctrl', 'addr, left', tsize=T2, pad=2)
    f.arrow([(dq.r, 74), (ctl.l, 74)])
    ra = f.box(270, 32, 42, 24, 'ram', 'ring A', tsize=T2)
    rb = f.box(270, 92, 42, 24, 'ram', 'ring B', tsize=T2)
    f.arrow([(ctl.r, 66), (254, 66), (254, 44), (ra.l, 44)])
    f.arrow([(ctl.r, 82), (254, 82), (254, 104), (rb.l, 104)])
    da = f.reg(354, 32, 24, 'data_a')
    db = f.reg(354, 92, 24, 'data_b')
    f.arrow([(ra.r, ra.cy), (da.l, da.cy)])
    f.arrow([(rb.r, rb.cy), (db.l, db.cy)])
    m2 = f.mux(382, 48, 16, 52, '2:1', name='m2')
    f.arrow([(da.r, da.cy), (372, da.cy), (372, 61), (m2.l, 61)])
    f.arrow([(db.r, db.cy), (372, db.cy), (372, 87), (m2.l, 87)])
    out = f.reg(420, 62, 24)
    f.arrow([(m2.r, 74), (out.l, 74)])
    f.arrow([(out.r, 74), (450, 74)])
    f.tag(439, 71, 'd_*')
    f.tag(390, 117, 'd_net', size=6.5)
    f.arrow([(390, 108), (390, 100)])
    f.arrow([(390, 100), (390, 95.32)], check=False)
    return f


@fig
def f26_svc():
    f = Fig(450, 160)
    # (a) 发送仲裁
    src = [('ext', 'Application'), ('svcl', 'afdx_rtc'), ('svcl', 'afdx_snmp'), ('svcl', 'afdx_615a')]
    S = [f.box(0, 4 + i * 22, 62, 18, k, t, tsize=T2, pad=2) for i, (k, t) in enumerate(src)]
    mx = f.mux(96, 12, 18, 72, '4:1', name='arb')
    for b in S:
        f.arrow([(b.r, b.cy), (mx.l, b.cy)])
    ctl = f.box(56, 104, 98, 22, 'cfg', 'busy · owner · turn', tsize=T2, pad=2)
    f.arrow([(ctl.cx, ctl.t), (mx.cx, mx.b)], head=None)
    f.arrow([(mx.cx, mx.b), (mx.cx, mx.b - mx.h * 0.09)], check=False)
    core = f.box(140, 33, 60, 30, 'tx', 'tx_core', 'm_*', pad=2)
    f.arrow([(mx.r, 48), (core.l, 48)])
    f.tag(127, 45, 'm_*')
    f.tag(100, 156, '(a) Transmit arbitration', bold=True, size=T1)
    # (b) 接收分发
    rc = f.box(228, 4, 62, 22, 'rx', 'rx_core', 'd_*', tsize=T2, pad=2)
    sv = f.box(388, 4, 62, 22, 'svcl', 'Services', tsize=T2)
    cl = f.box(228, 52, 78, 30, 'svcl', 'Port claim', 'RTC · SNMP · 615A', tsize=T2, ssize=6.5, pad=2)
    f.arrow([(rc.r, 15), (sv.l, 15)])
    f.tag(338, 12, 'broadcast', size=6.5)
    f.arrow([(296, 15), (296, 44), (240, 44), (240, cl.t)])
    f.tag(264, 41, 'd_dport', size=6.5)
    hold = f.reg(328, 86, 20)
    f.tag(334, 83, 'Hold claim', size=6.5)
    claim = f.mux(360, 42, 14, 42, '2:1', name='claim select')
    f.arrow([(cl.r, 67), (346, 67), (346, 50), (claim.l, 50)])
    f.tag(326, 64, 'claim (OR)', size=6.5)
    f.arrow([(314, 67), (314, 92), (hold.l, 92)])
    f.arrow([(hold.r, 96), (352, 96), (352, 74), (claim.l, 74)])
    f.tag(354, 47, '0', anchor='end', size=6.5)
    f.tag(357, 71, '1', anchor='end', size=6.5)
    f.arrow([(340, 96), (340, 114), (320, 114), (320, 100), (hold.l, 100)])
    f.arrow([(claim.cx, 124), (claim.cx, claim.b)], head=None)
    f.arrow([(claim.cx, claim.b), (claim.cx, claim.b - claim.h * 0.09)], check=False)
    f.tag(373, 137, 'rx_active', anchor='end', size=6.5)
    gate = f.gate_and(390, 34, 24, inv_inputs=(1,))
    f.arrow([(302, 15), (302, 40), gate.inputs[0]])
    f.tag(346, 37, 'd_valid', size=6.5)
    f.arrow([(claim.r, claim.cy), (378, claim.cy), (378, 52), gate.inputs[1]])
    ap = f.box(420, 34, 30, 24, 'ext', 'App', tsize=T2)
    f.arrow([gate.output, (ap.l, ap.cy)])
    for x, y in ((296, 15), (302, 15), (314, 67), (340, 96)):
        f.body.append(f'<circle cx="{x}" cy="{y}" r="1.2" fill="#000"/>')
    f.tag(343, 156, '(b) Receive dispatch', bold=True, size=T1)
    return f


@fig
def f27_rtc():
    f = Fig(450, 341)
    S = lambda x, y, k, t, sub, w=62: f.box(x, y, w, 28, k, t, sub, rx=4, pad=2, tsize=T2, ssize=6.5)
    # (a) 发送字节状态机
    ti = S(0, 26, 'gray', 'TX_IDLE', 'reply or period')
    tg = S(92, 26, 'svcl', 'TX_GROUPS', 'two 8:1 / 4:1')
    tw_ = S(184, 26, 'svcl', 'TX_WORD', 'pick word')
    tb = S(276, 26, 'svcl', 'TX_BYTE', 'pick byte')
    th = S(368, 26, 'svc', 'TX_HANDSHAKE', 'tx_ready', w=78)
    for a, b in ((ti, tg), (tg, tw_), (tw_, tb), (tb, th)):
        f.arrow([(a.r, 40), (b.l, 40)])
    f.arrow([(403, th.b), (403, 68), (123, 68), (123, tg.b)])
    f.tag(263, 65, 'tx_ready && tx_index < 47')
    f.arrow([(th.r - 4, th.t), (th.r - 4, 12), (31, 12), (31, ti.t)])
    f.tag(240, 9, 'tx_ready && tx_index == 47', size=6.5)
    f.tag(225, 83, '(a) Transmit', bold=True, size=T1)
    # (b) 校时计算
    names = [('IDLE', 'await matched reply'), ('START_T2', 'decode_start'), ('WAIT_T2', 'wait decode_done'),
             ('START_T3', 'decode_start'), ('WAIT_T3', 'wait decode_done'), ('DIFFERENCES', 't2−t1, t3−t4'),
             ('SUM', 'seconds, nanoseconds'), ('HALF', '>>> 1'), ('HALF_SECOND', '+0.5 s if odd'),
             ('NORMALIZE_OFFSET', 'borrow / carry'), ('ADD_OFFSET', 'clock + offset'),
             ('NORMALIZE_TIME', 'carry'), ('LATENCY', '+32 ns'), ('APPLY', 'load, count')]
    B = []
    for i, (name, sub) in enumerate(names):
        row, col = divmod(i, 4)
        x = 12 + (col if row % 2 == 0 else 3 - col) * 110
        kind = 'gray' if name in ('IDLE', 'APPLY') else 'svcl'
        B.append(S(x, 118 + row * 58, kind, name, sub, w=98))
    for i, (a, b) in enumerate(zip(B, B[1:])):
        if i % 4 == 3:
            f.arrow([(a.cx, a.b), (b.cx, b.t)])
        elif (i // 4) % 2 == 0:
            f.arrow([(a.r, a.cy), (b.l, b.cy)])
        else:
            f.arrow([(a.l, a.cy), (b.r, b.cy)])
        if i in (0, 2, 4):
            f.tag((a.cx + b.cx) / 2, a.t - 4, 'matched reply' if i == 0 else 'decode_done', size=6.5)
    f.arrow([(B[-1].l, B[-1].cy), (5, B[-1].cy), (5, B[0].cy), (B[0].l, B[0].cy)])
    f.tag(225, 337, '(b) Offset calculation', bold=True, size=T1)
    return f


@fig
def f28_snmpfsm():
    f = Fig(450, 196)
    receive = f.box(22, 44, 64, 26, 'gray', 'Receive', rx=4)
    decode = f.box(140, 44, 64, 26, 'svcl', 'Decode', rx=4)
    lookup = f.box(260, 44, 64, 26, 'svcl', 'Lookup', rx=4)
    value = f.box(382, 44, 64, 26, 'svcl', 'Value', rx=4)
    encode = f.box(382, 144, 64, 26, 'svc', 'Encode', rx=4)
    send = f.box(22, 144, 64, 26, 'svc', 'Send', rx=4)
    fetch = f.box(140, 100, 72, 28, 'gray', 'Fetch', '(shared)', rx=4, ssize=6.5)
    f.arrow([(receive.r, 57), (decode.l, 57)])
    f.tag(113, 53, 'last byte', size=6.5)
    f.arrow([(decode.r, 57), (lookup.l, 57)])
    f.tag(232, 53, 'valid binding', size=6.5)
    f.arrow([(lookup.r, 53), (value.l, 53)])
    f.tag(353, 49, 'hit', size=6.5)
    f.arrow([(lookup.r, 65), (value.l, 65)])
    f.tag(353, 61, 'bad / missed Set', size=6.5)
    f.arrow([(292, lookup.b), (292, 100), (390, 100), (390, encode.t)])
    f.tag(341, 96, 'miss (Get)', size=6.5)
    f.arrow([(436, value.b), (436, encode.t)])
    f.tag(432, 127, 'ready / error', size=6.5, anchor='end')
    f.arrow([(encode.l, 163), (send.r, 163)])
    f.tag(234, 159, 'encoded', size=6.5)
    f.arrow([(35, send.t), (35, receive.b)])
    f.tag(39, 110, 'last byte', size=6.5, anchor='start')
    f.arrow([(74, receive.b), (74, 136), (374, 136), (374, 157), (encode.l, 157)])
    f.tag(280, 132, 'trap pending', size=6.5)
    f.stub(172, decode.t, 'u', '→ Receive')
    f.tag(172, 12, 'bad BER / version / community', size=6.5)
    f.stub(292, lookup.t, 'u', '→ Receive')
    f.tag(292, 12, 'bad OID', size=6.5)
    f.stub(414, encode.b, 'd', '→ Receive')
    f.tag(405, 180, 'bad encoding', size=6.5, anchor='end')
    f.arrow([(155, decode.b), (155, fetch.t)], dash=True)
    f.tag(159, 84, 'call', size=6.5, anchor='start')
    f.arrow([(190, fetch.t), (190, decode.b)], dash=True)
    f.tag(186, 96, 'return', size=6.5, anchor='end')
    f.stub(fetch.r, fetch.cy, 'r', '→ Receive')
    f.tag(246, 105, 'short request', size=6.5)
    return f


@fig
def f29_615a():
    f = Fig(450, 228)
    f.group(12, 12, 426, 212, 'svc', 'ARINC 615A session')
    wait = f.box(30, 80, 65, 32, 'gray', 'Wait', rx=4)
    dispatch = f.box(160, 80, 80, 32, 'svc', 'Dispatch', rx=4)
    transfer = f.box(314, 80, 108, 46, 'svcl', 'Transfer / status', '', '', '', ssize=6.5, rx=4)
    for x, y, w, label in [(324, 100, 20, 'List'), (347, 100, 31, 'Header'),
                            (381, 100, 24, 'Data'), (328, 113, 43, 'Download'),
                            (375, 113, 32, 'Status')]:
        f.rect(x, y, w, 10, '#E6E6E6', 'none', 0, rx=3)
        f.text(x + w / 2, y + 7.2, label, size=6.5)
    end = f.box(160, 164, 80, 28, 'drop', 'End', rx=4)
    shared = f.group(296, 174, 134, 44, 'gray', 'Shared subroutines', dash='3 2', label_color='#444')
    f.box(302, 192, 69, 20, 'gray', 'Read / get_byte', tsize=6.5, rx=4)
    f.box(377, 192, 47, 20, 'svc', 'Packet out', tsize=T2, rx=4)
    f.arrow([(wait.r, 96), (dispatch.l, 96)])
    f.tag(127, 92, 'packet pending', size=6.5)
    f.arrow([(dispatch.r, 96), (transfer.l, 96)])
    f.tag(277, 76, 'request / DATA / ACK', size=6.5)
    f.arrow([(400, transfer.t), (400, 40), (50, 40), (50, wait.t)])
    f.tag(225, 36, 'exchange complete', size=6.5)
    f.arrow([(200, dispatch.t), (200, 61), (80, 61), (80, wait.t)])
    f.tag(135, 57, 'unmatched packet', size=6.5)
    f.arrow([(55, wait.b), (55, 132), (85, 132), (85, wait.b)])
    f.tag(85, 143, 'timeout, retries left', size=6.5)
    f.arrow([(40, wait.b), (40, 175), (end.l, 175)])
    f.tag(100, 171, 'retries exhausted', size=6.5)
    f.arrow([(200, dispatch.b), (200, end.t)])
    f.tag(204, 135, 'peer error / done', size=6.5, anchor='start')
    f.arrow([(transfer.l, 120), (282, 120), (282, 188), (end.r, 188)])
    f.tag(286, 159, 'invalid file', size=6.5, anchor='start')
    f.arrow([(end.r, 176), (270, 176), (270, 110), (transfer.l, 110)])
    f.tag(266, 153, 'failure sent', size=6.5, anchor='end')
    f.stub(end.l, 186, 'l', '→ Wait')
    f.tag(151, 202, 'done', size=6.5)
    f.arrow([(338, transfer.b), (338, shared.t)], dash=True)
    f.tag(342, 150, 'call', size=6.5, anchor='start')
    f.arrow([(408, shared.t), (408, transfer.b)], dash=True)
    f.tag(404, 162, 'return', size=6.5, anchor='end')
    return f

@fig
def f30_cfg():
    f = Fig(450, 166)
    host = f.box(0, 8, 66, 24, 'ext', 'Host cfg_*', tsize=T2, pad=2)
    snmp = f.box(0, 44, 66, 24, 'svcl', 'SNMP mib_*', tsize=T2, pad=2)
    mx = f.mux(84, 8, 16, 60, '', name='bus')
    f.arrow([(host.r, 20), (mx.l, 20)])
    f.arrow([(snmp.r, 56), (mx.l, 56)])
    f.tag(92, 78, 'host first', size=6.5)
    dec = f.box(118, 24, 70, 28, 'cfg', 'Decode', 'addr[17:0]', pad=2)
    f.arrow([(mx.r, 38), (dec.l, 38)])
    hold = f.box(226, 0, 92, 30, 'cfg', 'Table write hold', 'until core cfg_ok', pad=2, tsize=T2, ssize=6.5)
    core = f.box(366, 0, 84, 30, 'gray', 'tx / rx core', 'write reg → RAM', pad=2, tsize=T2, ssize=6.5)
    regs = f.box(226, 40, 92, 22, 'cfg', 'Registers', 'local regs / USER_ID', pad=2, tsize=T2, ssize=6.5)
    s1 = f.box(226, 76, 92, 30, 'cfg', 'Read stage 1', 'capture 4 groups', pad=2, tsize=T2, ssize=6.5)
    s2 = f.mux(340, 76, 16, 42, '', name='s2')
    out = f.box(380, 78, 70, 26, 'ext', 'cfg_rdata', 'cfg_rvalid', pad=2, tsize=T2, ssize=6.5)
    cnt = f.box(118, 82, 70, 30, 'gray', 'Counters', '27 × 32 b', pad=2, tsize=T2, ssize=6.5)
    f.arrow([(dec.r, 30), (206, 30), (206, 12), (hold.l, 12)])
    f.arrow([(dec.r, 44), (206, 44), (206, 51), (regs.l, 51)])
    f.arrow([(dec.r - 10, dec.b), (dec.r - 10, 70), (214, 70), (214, 86), (s1.l, 86)])
    f.arrow([(cnt.r, 98), (s1.l, 98)])
    f.arrow([(272, regs.b), (272, s1.t)])
    f.arrow([(0, 98), (cnt.l, 98)])
    f.tag(32, 95, 'ev_* pulses')
    f.arrow([(hold.r, 10), (core.l, 10)])
    f.arrow([(core.l, 22), (hold.r, 22)], dash=True)
    f.tag(342, 32.5, 'cfg_ok', size=6.5)
    f.arrow([(s1.r, 91), (s2.l, 91)])
    f.arrow([(s2.r, 91), (out.l, 91)])
    svc = f.box(226, 132, 92, 30, 'svcl', 'Service read regs', 'RTC · SNMP · 615A', pad=2, tsize=T2, ssize=6.5)
    f.arrow([(svc.r, svc.cy), (330, svc.cy), (330, 110), (s2.l, 110)])
    f.tag(0, 140, 'Read group: addr[17:3]', size=6.5, anchor='start')
    f.tag(0, 151, 'Word within group: addr[2:0]', size=6.5, anchor='start')
    f.tag(348, 72, 'select', size=6.5)
    return f

# ---------- 接口时序图 ----------
WGRAY = PAL['gray'][0]


def slots(x0, widths):
    """各拍左边界 x，长度为拍数 + 1。"""
    xs = [x0]
    for w in widths:
        xs.append(xs[-1] + w)
    return xs


def wave(f, xs, y0, rows, rh=9, gap=7, brk=(), lx=None):
    """理想时序图。rows = [(名称, 类型, 数据)]：
    'clk'：数据忽略；'bit'：每拍一个字符 0/1/x；'bus'：[(起拍, 止拍, 文字, 底色)]，底色 'v' 白、'h' 浅橙、'x' 灰。
    brk 为压缩拍序号，画断开记号。返回各行顶部 y。"""
    lx = xs[0] - 6 if lx is None else lx
    s = 1.6
    ys, y = [], y0
    path = lambda pts, c='#000', w=0.75: f.body.append(
        '<path d="' + ' '.join(('M' if i == 0 else 'L') + f' {a:.2f} {b:.2f}' for i, (a, b) in enumerate(pts))
        + f'" fill="none" stroke="{c}" stroke-width="{w}"/>')
    for name, kind, data in rows:
        yt, yb, ym = y, y + rh, y + rh / 2
        f.tag(lx, ym + 2.5, name, anchor='end')
        if kind == 'clk':
            for i in range(len(xs) - 1):
                if i in brk:
                    continue
                a, b = xs[i], xs[i + 1]
                m = (a + b) / 2
                path([(a, yb), (a, yt), (m, yt), (m, yb), (b, yb)], w=0.6)
        elif kind == 'bit':
            lv = {'0': yb, '1': yt}
            pts = []
            for i, c in enumerate(data):
                a, b = xs[i], xs[i + 1]
                if c == 'x':
                    f.rect(a, yt, b - a, rh, WGRAY, 'none', 0)
                    if pts:
                        path(pts)
                    pts = []
                    continue
                if pts and pts[-1][1] != lv[c]:
                    pts.append((a, lv[c]))
                pts += [(a, lv[c]), (b, lv[c])]
            if pts:
                path(pts)
        else:
            fills = {'v': '#FFFFFF', 'h': PAL['txl'][0], 'x': WGRAY, 'g': PAL['pass'][0]}
            for a, b, text, k in data:
                xa, xb = xs[a], xs[b]
                pts = f'{xa:.2f},{ym:.2f} {xa + s:.2f},{yt:.2f} {xb - s:.2f},{yt:.2f} {xb:.2f},{ym:.2f} {xb - s:.2f},{yb:.2f} {xa + s:.2f},{yb:.2f}'
                f.body.append(f'<polygon points="{pts}" fill="{fills[k]}" stroke="#000" stroke-width="0.6"/>')
                if text:
                    if tw(text, 6.5) > xb - xa - 2 * s - 1:
                        f.warn.append(f'bus label "{text}" too wide')
                    f.text((xa + xb) / 2, ym + 2.3, text, 6.5)
        ys.append(y)
        y += rh + gap
    # 断开记号：每行两条斜线，中间白底
    for i in brk:
        m = (xs[i] + xs[i + 1]) / 2
        for yt in ys:
            a, b = yt - 2, yt + rh + 2
            f.body.append(f'<polygon points="{m - 3:.2f},{b:.2f} {m:.2f},{a:.2f} {m + 3:.2f},{a:.2f} {m:.2f},{b:.2f}" fill="#fff" stroke="none"/>')
            path([(m - 3, b), (m, a)], w=0.6)
            path([(m, b), (m + 3, a)], w=0.6)
    return ys


def dim(f, xa, xb, y, text, above=True):
    """尺寸标注：两端短竖线的水平线和文字。"""
    f.body.append(f'<path d="M {xa:.2f} {y - 2:.2f} L {xa:.2f} {y + 2:.2f} M {xb:.2f} {y - 2:.2f} L {xb:.2f} {y + 2:.2f} '
                  f'M {xa:.2f} {y:.2f} L {xb:.2f} {y:.2f}" fill="none" stroke="#000" stroke-width="0.5"/>')
    f.tag((xa + xb) / 2, y - 2.5 if above else y + 7.5, text, size=6.5)


def guide(f, x, y0, y1):
    f.body.append(f'<line x1="{x:.2f}" y1="{y0:.2f}" x2="{x:.2f}" y2="{y1:.2f}" stroke="#777" stroke-width="0.5" stroke-dasharray="2 1.5"/>')


def cycles(f, xs, y, labels):
    """在拍中心标拍号：labels = {拍序号: 文字}。"""
    for i, t in labels.items():
        f.tag((xs[i] + xs[i + 1]) / 2, y, t, size=6.5)


@fig
def f31_wgmii():
    f = Fig(450, 114)
    cw, bw = 14, 9
    B = (11, 15, 22)
    xs = slots(78, [bw if i in B else cw for i in range(25)])
    pre = [(i, i + 1, '55', 'v') for i in range(2, 9)]

    def data(n11, fcs):
        return ([(0, 2, '00', 'x')] + pre + [(9, 10, 'D5', 'v'), (10, 11, '03', 'v'), (11, 12, '', 'v'),
                (12, 13, 'uid', 'v'), (13, 14, n11, 'h'), (14, 15, '08', 'v'), (15, 16, '', 'v'), (16, 17, 'SN', 'v'),
                (17, 21, fcs, 'v'), (21, 24, '', 'x'), (24, 25, '55', 'v')])
    valid = '00' + '1' * 19 + '000' + '1'
    ys = wave(f, xs, 14, [
        ('clk', 'clk', None),
        ('tx_valid', 'bit', valid),
        ('tx_data', 'bus', data('20', 'FCS (A)')),
        ('tx_valid_b', 'bit', valid),
        ('tx_data_b', 'bus', data('40', 'FCS (B)')),
    ], brk=B)
    cycles(f, xs, 9, {2: '0', 9: '7', 10: '8', 13: '19', 16: '67', 17: '68', 20: '71', 21: '72', 24: '84'})
    yb = ys[-1] + 9
    for i in (2, 10, 21, 24):
        guide(f, xs[i], 2, yb + 4)
    dim(f, xs[2], xs[10], yb + 14, 'preamble 7 B + SFD', above=False)
    dim(f, xs[10], xs[21], yb + 14, 'frame 64 B (1-byte message)', above=False)
    dim(f, xs[21], xs[24], yb + 14, 'IFG ≥ 12 cycles', above=False)
    return f


@fig
def f32_wapp():
    f = Fig(450, 271)
    cw, bw = 20, 9
    B = (10, 14)
    xs = slots(100, [bw if i in B else cw for i in range(17)])
    ys = wave(f, xs, 14, [
        ('clk', 'clk', None),
        ('app_tx_valid', 'bit', '0' + '1' * 11 + '0' * 4 + '1'),
        ('app_tx_ready', 'bit', '11' + '0' * 6 + '1' * 4 + '0' * 4 + '1'),
        ('app_tx_data', 'bus', [(0, 1, '', 'x'), (1, 2, 'B0', 'g'), (2, 8, 'B1 (held)', 'v'), (8, 9, 'B1', 'g'), (9, 10, 'B2', 'g'),
                                (10, 11, '', 'v'), (11, 12, 'Bn−1', 'g'), (12, 16, '', 'x'), (16, 17, 'C0', 'g')]),
        ('app_tx_last', 'bit', '0' * 11 + '1' + '0' * 5),
        ('app_tx_vl, port', 'bus', [(0, 1, '', 'x'), (1, 2, 'VL', 'v'), (2, 16, '', 'x'), (16, 17, 'VL', 'v')]),
    ], brk=B)
    cycles(f, xs, 9, {1: '0', 2: '1', 7: '6', 8: '7', 9: '8', 11: 'L', 12: 'L+1', 15: 'L+10', 16: 'L+11'})
    yb = ys[-1] + 9
    for i in (2, 8, 12, 16):
        guide(f, xs[i], 2, yb + 4)
    dim(f, xs[2], xs[8], yb + 14, '6 cycles: page allocation', above=False)
    dim(f, xs[12], xs[16], yb + 14, '10 cycles: descriptor + enqueue', above=False)
    f.tag(225, yb + 34, '(a) Submit', bold=True, size=T1)
    xr = slots(100, [bw if i in (5,) else cw for i in range(8)])
    y2 = yb + 53
    ys2 = wave(f, xr, y2, [
        ('clk', 'clk', None),
        ('app_rx_valid', 'bit', '01111110'[:8]),
        ('app_rx_data', 'bus', [(0, 1, '', 'x'), (1, 2, 'D0', 'g'), (2, 3, 'D1', 'g'), (3, 4, 'D2', 'g'), (4, 5, 'D3', 'g'),
                                (5, 6, '', 'g'), (6, 7, 'Dn−1', 'g'), (7, 8, '', 'x')]),
        ('app_rx_last', 'bit', '00000010'),
        ('app_rx_vl, port, net', 'bus', [(0, 1, '', 'x'), (1, 7, '', 'v'), (7, 8, '', 'x')]),
    ], brk=(5,))
    yb2 = ys2[-1] + 9
    f.text((xr[1] + xr[5]) / 2, ys2[-1] + 6.8, 'constant', 6.5)
    dim(f, xr[1], xr[7], yb2 + 14, 'n consecutive cycles, no back-pressure', above=False)
    f.tag(225, yb2 + 34, '(b) Deliver', bold=True, size=T1)
    return f


@fig
def f33_wcfg():
    f = Fig(450, 176)
    cw, bw = 22, 10
    B = (13,)
    xs = slots(78, [bw if i in B else cw for i in range(17)])
    X = lambda segs: [(a, b, t, k) for a, b, t, k in segs]
    ys = wave(f, xs, 14, [
        ('clk', 'clk', None),
        ('cfg_rd', 'bit', '01100000000000000'),
        ('cfg_wr', 'bit', '00000101001000000'),
        ('cfg_addr', 'bus', X([(0, 1, '', 'x'), (1, 2, 'A0', 'v'), (2, 3, 'A1', 'v'), (3, 5, '', 'x'), (5, 6, 'R', 'v'),
                               (6, 7, '', 'x'), (7, 8, 'T0', 'v'), (8, 10, '', 'x'), (10, 11, 'T1', 'v'), (11, 17, '', 'x')])),
        ('cfg_wdata', 'bus', X([(0, 5, '', 'x'), (5, 6, 'W', 'v'), (6, 7, '', 'x'), (7, 8, 'W0', 'v'), (8, 10, '', 'x'),
                                (10, 11, 'W1', 'v'), (11, 17, '', 'x')])),
        ('cfg_ready', 'bit', '11111111011' + '0' * 4 + '11'),
        ('cfg_rvalid', 'bit', '00011000000000000'),
        ('cfg_rdata', 'bus', X([(0, 3, '', 'x'), (3, 4, 'D(A0)', 'v'), (4, 5, 'D(A1)', 'v'), (5, 17, '', 'x')])),
        ('cfg_ok (internal)', 'bit', 'xxxxxxxx1xx0001xx'),
    ], brk=B)
    cycles(f, xs, 9, {i: str(i) for i in range(13)} | {14: 'u', 15: 'u+1'})
    yb = ys[-1] + 9
    for i in (1, 3, 8, 9, 11, 15):
        guide(f, xs[i], 2, yb + 4)
    dim(f, xs[1], xs[3], yb + 14, 'read t → t+2', above=False)
    dim(f, xs[8], xs[9], yb + 14, '1', above=False)
    dim(f, xs[11], xs[15], yb + 14, 'blocked: ≤ 64 cycles', above=False)
    f.tag(xs[5] + 0, yb + 21.5, 'register write', size=6.5, italic=True)
    return f

if __name__ == '__main__':
    out = sys.argv[1]
    names = sys.argv[2:] or list(FIGS)
    for n in names:
        FIGS[n]().save(os.path.join(out, n + '.svg'))
