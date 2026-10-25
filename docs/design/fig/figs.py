"""JSSC 风格框图与流程图（坐标单位为印刷 pt，插入时不缩放）。

用法: python3 figs.py <输出目录> [图名 ...]
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


BYTE = '#008AA6'
STATE = '#79539C'
ACCEPT = '#557D2D'


def strip(f, x, y, labels, widths, kinds, h=18, size=7.3):
    """Fields or memory cells with a common outer boundary."""
    xx=x
    for label,w,kind in zip(labels,widths,kinds):
        f.rect(xx,y,w,h,PAL[kind][0],'none',0)
        f.text(xx+w/2,y+h/2+size*.34,label,size)
        xx+=w
    f.rect(x,y,sum(widths),h,'none','#000',1.4)
    xx=x
    for w in widths[:-1]:
        xx+=w
        f.arrow([(xx,y),(xx,y+h)],head=None,sw=.9,check=False)


def heading(f,y,label):
    f.tag(4,y,label,size=9,anchor='start')


def bytepath(f,pts):
    f.arrow(pts,sw=1.6,color=BYTE)


@fig
def f01_system():
    f=Fig(450,327)
    heading(f,10,'(a) TX: one shared payload store feeds two network copies')
    # Each entry is a complete-message source; only the selected owner advances.
    for y,t,k in [(26,'App M0','ext'),(47,'RTC M1','svc'),(68,'SNMP','svc'),(89,'615A','svc')]:
        f.tag(7,y+12,t,anchor='start',size=8)
        f.arrow([(63,y+8.5),(82,y+8.5)])
    f.mux(82,27,15,78)
    f.tag(89,118,'owner',size=6.7)
    f.box(116,48,70,35,'white','Page writer','tx_buf',ssize=7.3)
    bytepath(f,[(97,66),(116,66)])
    f.tag(109,42,'M0',color=BYTE)
    f.rect(209,25,106,76,PAL['gray'][0],'#000',1.4)
    f.text(262,37,'128 KiB page RAM',8)
    strip(f,216,45,['p0','p1','p2','p3'],[23]*4,['rx']*4)
    f.text(262,77,'page 12 · offsets 0…3',6.7)
    f.text(262,91,'256 pages × 512 B',7.3)
    bytepath(f,[(186,66),(209,66)])
    f.rect(335,25,111,76,PAL['txl'][0],'#000',1.4)
    f.text(390.5,37,'VL scheduler',8)
    strip(f,342,45,['VL7','12','4'],[32,32,33],['cfg','ram','ram'])
    f.text(390.5,77,'head=12 · length=4',6.7)
    f.text(390.5,91,'SN=17 · next_time=T',7.3)
    f.arrow([(154,83),(154,109),(358,109),(358,101)])
    f.tag(190,118,'enqueue descriptor',size=6.7)
    f.box(209,134,106,27,'white','Header / payload / SN','tx_builder',ssize=7.3)
    bytepath(f,[(262,101),(262,134)])
    f.arrow([(390,101),(390,122),(301,122),(301,134)])
    f.tag(342,131,'grant',size=6.7)
    f.box(335,134,111,27,'white','Dual-net MAC','separate A / B CRC32',ssize=6.7)
    bytepath(f,[(315,147),(335,147)])
    f.tag(4,141,'Before allocation',anchor='start')
    strip(f,4,148,['…','12','37','84'],[25]*4,['ram']*4,h=16)
    f.arrow([(116,75),(109,75),(109,156),(104,156)],head='both',color=ACCEPT)
    f.tag(4,176,'allocate / return',anchor='start',size=6.7,color=ACCEPT)
    f.tag(337,177,'A: H_A | P17 | SN17 | FCS_A',anchor='start',size=6.7)
    f.tag(337,189,'B: H_B | P17 | SN17 | FCS_B',anchor='start',size=6.7)
    f.arrow([(390,161),(390,166)])

    heading(f,206,'(b) RX: store both copies; publish one descriptor')
    for x,net in [(4,'A'),(94,'B')]:
        f.box(x,218,74,24,'white',f'MAC + parser {net}',tsize=7.3,pad=2)
        strip(f,x,251,['p0','p1','p2','p3'],[18.5]*4,['rx']*4)
        bytepath(f,[(x+37,242),(x+37,251)])
        f.tag(x+37,281,f'ring {net}: 4 KiB',size=6.7)
    f.box(201,218,100,31,'rx','Shared RX engine','VL → IC → RM',ssize=7.3)
    f.arrow([(78,230),(85,230),(85,211),(190,211),(190,228),(201,228)])
    f.arrow([(168,230),(181,230),(181,240),(201,240)])
    strip(f,325,221,['A','100','4'],[38,43,40],['pass']*3)
    f.tag(385,215,'rx_dq',size=7.3)
    f.arrow([(301,233),(325,233)])
    f.box(325,257,121,24,'white','Deliver p0…p3 once',tsize=8)
    f.arrow([(385,239),(385,257)])
    bytepath(f,[(78,261),(85,261),(85,289),(313,289),(313,269),(325,269)])
    f.tag(252,278,'descriptor selects ring',size=6.7)
    f.box(201,257,100,14,'cfg','map / config / state',tsize=6.7,pad=2)
    f.arrow([(251,257),(251,249)],head='both',sw=.9)
    f.tag(4,311,'Host → configuration / counters',anchor='start',size=8)
    f.arrow([(4,318),(214,318)],head=None,dash=True,sw=.9,check=False)
    f.tag(4,327,'controlled table writes',anchor='start',size=6.7)
    f.arrow([(232,317),(238,317),(238,307),(244,307),(244,317),(250,317),(250,307),(256,307),(256,317)],head=None,sw=1.1,check=False)
    f.tag(267,311,'125 MHz · shared timebase',anchor='start',size=8)
    f.tag(267,325,'now: 8 ns; now_c: 32.768 us',anchor='start',size=6.7)
    return f


@fig
def f02_path():
    f=Fig(450,290)
    heading(f,10,'ES1: page RAM → byte FIFO → frame-source MUX → dual-net MAC')
    f.tag(4,39,'Header byte 11: IF A=20 / B=40',anchor='start',size=6.7)
    f.tag(4,63,'App M0 in page 12',anchor='start',size=8)
    strip(f,4,70,['p0','p1','p2','p3'],[23]*4,['rx']*4)
    f.tag(4,105,'VL7 · n=4 · SN17',anchor='start',size=7.3)
    f.tag(4,120,'tx_desc[12]: length + ports',anchor='start',size=6.7)
    f.tag(218,24,'42-byte header shift register',size=8)
    strip(f,154,30,['H0','H1','…','H41'],[32]*4,['cfg']*4,h=20)
    f.arrow([(158,50),(161,46),(164,50)],head=None,sw=.9,check=False)
    f.tag(218,63,'8-byte payload FIFO',size=8)
    strip(f,154,70,['p0','p1','p2','p3','','','',''],[16]*8,['rx']*4+['white']*4,h=18,size=6.7)
    bytepath(f,[(96,79),(154,79)])
    f.tag(124,73,'read',size=6.7,color=BYTE)
    f.tag(218,103,'Tail generator',size=7.3)
    strip(f,154,108,['pad: 13 × 0','SN17'],[83,45],['gray','tx'],h=17)
    f.mux(304,52,16,54)
    bytepath(f,[(282,40),(294,40),(294,61),(304,61)])
    bytepath(f,[(282,79),(304,79)])
    bytepath(f,[(282,116),(294,116),(294,97),(304,97)])
    f.reg(308,114,12)
    f.arrow([(311,114),(311,104)],sw=.9,check=False)
    f.tag(320,124,'part',anchor='start',size=6.7)
    f.box(365,59,81,40,'white','Dual-net MAC','preamble + FCS','CRC32 A / B',ssize=6.7)
    f.cells(333,70,12,18,2,'gray')
    bytepath(f,[(320,79),(333,79)])
    bytepath(f,[(345,79),(365,79)])
    f.tag(339,64,'stream',size=6.7)
    f.tag(339,102,'2 slots',size=6.7)
    # The packet strips are wire-format views, so they need no perimeter wire.
    f.tag(4,143,'MAC outputs',anchor='start',size=7.3)
    for yy,net in [(151,'A'),(177,'B')]:
        f.tag(4,yy+12,net,anchor='start',size=8)
        f.arrow([(20,yy+9),(34,yy+9)])
        strip(f,34,yy,[f'H_{net} 42 B','p0','p1','p2','p3','pad 13 B','17',f'FCS_{net}'],
              [94,29,29,29,29,88,29,49],['cfg']+['rx']*4+['gray','tx','cfg'],h=18)

    heading(f,213,'ES2: descriptors select a source ring; payload bypasses the decision engine')
    f.box(4,225,83,26,'white','MAC / parser ×2','strip framing',ssize=6.7,pad=2)
    f.mux(109,222,12,32)
    f.arrow([(87,232),(109,232)])
    f.arrow([(87,246),(109,246)])
    f.box(144,225,91,26,'rx','Shared IC / RM','accept A; reject B',ssize=6.7,pad=2)
    f.arrow([(121,238),(144,238)])
    strip(f,257,229,['A','100','4'],[24,33,24],['pass']*3,h=18)
    f.tag(297,222,'rx_dq',size=7.3)
    f.arrow([(235,238),(257,238)])
    f.box(369,225,77,26,'white','RX deliver','ring read',ssize=6.7)
    f.arrow([(338,238),(369,238)])
    f.tag(4,278,'Accepted ring A @100',anchor='start',size=7.3)
    strip(f,144,267,['p0','p1','p2','p3'],[22.75]*4,['rx']*4)
    bytepath(f,[(235,276),(355,276),(355,246),(369,246)])
    strip(f,369,267,['p0','p1','p2','p3'],[19.25]*4,['pass']*4)
    bytepath(f,[(407.5,251),(407.5,267)])
    f.tag(356,287,'One delivery',size=6.7,color=ACCEPT,anchor='end')
    return f


@fig
def f06_frame():
    f=Fig(450,245)
    heading(f,10,'(a) Wire format: payload and framing have different lengths')
    widths=[35,22,41,41,28,48,43,62,29,23,37,33]
    labels=['55 ×7','D5','Dst','Src','Type','IPv4','UDP','Payload','Pad','SN','FCS','IFG']
    kinds=['white','white','cfg','cfg','gray','cfg','cfg','rx','gray','tx','cfg','white']
    strip(f,4,29,labels,widths,kinds,h=23,size=7.3)
    xx=4
    for w,n in zip(widths,['7','1','6','6','2','20','8','n','p','1','4','≥12']):
        f.tag(xx+w/2,65,n,size=7.3);xx+=w
    f.tag(4,82,'Length in bytes',anchor='start',size=6.7)
    f.tag(260,82,'Frame = 47 + max(n,17) B; p = max(17−n,0)',size=7.3)
    heading(f,106,'(b) n = 4: the payload ends at byte 45; SN stays at byte 59')
    widths=[85,30,30,30,30,123,32,82]
    strip(f,4,124,['header','p0','p1','p2','p3','13 zero bytes','17','FCS'],widths,
          ['cfg']+['rx']*4+['gray','tx','cfg'],h=23)
    xx=4
    for w,pos in zip(widths,['0…41','42','43','44','45','46…58','59','60…63']):
        f.tag(xx+w/2,119,pos,size=6.7);xx+=w
    f.arrow([(89,159),(209,159)],head='both',sw=.9,color=BYTE)
    f.tag(149,172,'4-B application payload',size=7.3,color=BYTE)
    f.tag(332,163,'UDP = 12 B · IP = 32 B · frame = 64 B',size=6.7)
    heading(f,194,'(c) VL7 / USER_ID 0x1234: A and B differ in the interface byte')
    f.tag(4,214,'Dst MAC',anchor='start',size=7.3)
    strip(f,60,202,['03','00','00','00','00','07'],[23]*6,['cfg']*5+['tx'],h=18)
    f.tag(4,238,'Src MAC',anchor='start',size=7.3)
    strip(f,60,226,['02','00','00','12','34'],[23]*5,['cfg']*5,h=18)
    strip(f,175,226,['20 A / 40 B'],[74],['tx'],h=18)
    f.tag(327,215,'UDP checksum sent as zero',size=7.3)
    f.tag(327,238,'CRC32: Dst MAC through SN',size=7.3)
    return f


@fig
def f10_macfsm():
    f=Fig(450,269)
    heading(f,10,'(a) One CRC datapath per network: independent state for A and B')
    f.tag(4,28,'s_data_a / s_data_b · 8 bit',anchor='start',size=7.3)
    strip(f,4,38,['H_A/B','payload','pad / SN'],[42,44,48],['cfg','rx','tx'],h=22,size=6.7)
    f.box(160,38,73,34,'white','CRC32_d8','8-bit update',ssize=6.7)
    bytepath(f,[(138,49),(160,49)])
    state=f.reg(264,39,32)
    f.arrow([(233,55),(264,55)])
    f.tag(248,47,'32',size=6.7)
    f.arrow([(270,55),(287,55),(287,23),(195,23),(195,38)],sw=1.1)
    f.tag(242,20,'crc_a / crc_b',size=6.7)
    f.tag(269,82,'state',size=6.7)
    f.body.append('<circle cx="287" cy="55" r="1.8" fill="#000"/>')
    f.arrow([(287,55),(303,55)])
    f.body.append('<path d="M303 46 L303 64 L320 55 Z" fill="white" stroke="#000" stroke-width="1.4"/>')
    f.body.append('<circle cx="322.5" cy="55" r="2.5" fill="white" stroke="#000" stroke-width="1.4"/>')
    f.arrow([(325,55),(343,55)],sw=1.1)
    strip(f,343,44,['F0','F1','F2','F3'],[25]*4,['cfg']*4,h=22,size=7.3)
    f.arrow([(347,66),(350,62),(353,66)],head=None,sw=.9,check=False)
    f.tag(393,35,'FCS shift register',size=7.3)
    f.tag(393,82,'4 × 8-bit output',size=7.3)
    f.tag(4,82,'Init = FFFFFFFF; IF byte differs: 20 / 40',anchor='start',size=6.7)
    f.tag(4,97,'GAP → PREAMBLE → DATA → FCS → GAP',anchor='start',size=7.3)
    strip(f,4,105,['7 ×55 + D5','frame bytes incl. SN','FCS 4 B','IFG ≥12'],[91,181,75,95],['gray','rx','cfg','white'],h=21)
    f.tag(4,139,'Underrun: finish bad-FCS frame → DRAIN remaining s_* → GAP',anchor='start',size=7.3,color=STATE)
    heading(f,159,'(b) RX: the four-byte tail is held back, so FCS never reaches the parser')
    f.tag(4,178,'Process F3',anchor='start',size=7.3)
    f.tag(156,178,'Before shift: delay0 → delay3',size=7.3)
    strip(f,83,185,['F2','F1','F0','SN17'],[40]*4,['cfg','cfg','cfg','tx'],h=20)
    f.arrow([(73,195),(83,195)],sw=1.6,color=BYTE)
    f.tag(38,199,'F3',size=8,color=BYTE)
    f.arrow([(243,195),(278,195)],sw=1.6,color=BYTE)
    strip(f,278,185,['SN17'],[52],['tx'],h=20)
    f.tag(368,198,'m_valid=1',size=7.3,color=ACCEPT)
    f.tag(4,227,'After shift',anchor='start',size=7.3)
    strip(f,83,214,['F3','F2','F1','F0'],[40]*4,['cfg']*4,h=20)
    f.tag(345,226,'valid_q falls: no more m_valid',size=7.3)
    for y in (185,214):
        for x in (83,123,163,203):
            f.arrow([(x+3,y+20),(x+6,y+16),(x+9,y+20)],head=None,sw=.9,check=False)
    f.tag(4,253,'Frame end → length 64…1518 B AND CRC residue 0xDEBB20E3',anchor='start',size=7.3)
    f.tag(4,267,'Bad prefix → BAD_PRE; invalid length / CRC → f_err; otherwise f_err = 0',anchor='start',size=7.3)
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
        f.tag(x0 + c * cw, y0 - 2.5, str(c), size=6.7)
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
def f20_pipe():
    f=Fig(450,248)
    heading(f,10,'(a) TX: from the last application byte to the SFD byte')
    x0,cw=77,8.4
    ys=gantt(f,x0,28,cw,40,[
        ('tx_buf',[(0,1,'gray',''),(1,4,'txl','desc')]),
        ('tx_engine',[(4,10,'txl','ENQ'),(10,19,'tx','GRANT')]),
        ('tx_builder',[(19,30,'txl','IP sum / header'),(30,31,'tx','')]),
        ('mac_tx',[(31,32,'tx',''),(32,40,'cfg','55 ×7 | D5')]),
    ],rh=13,gap=7,tick=4)
    for c,r in [(4,0),(19,1),(31,2)]:
        f.arrow([(x0+c*cw,ys[r]+13),(x0+c*cw,ys[r+1])],sw=1.1)
    f.tag(x0-8,23,'last byte',anchor='end',size=6.7)
    f.tag(x0+32*cw,122,'SOF 32',size=7.3,color=BYTE)
    f.tag(x0+39*cw,122,'SFD 39',size=7.3,color=BYTE)
    heading(f,145,'(b) RX: from the last FCS byte to the first delivered payload byte')
    ys=gantt(f,x0,163,cw,32,[
        ('mac_rx',[(0,3,'rx','end')]),
        ('rx_parse',[(3,6,'pass','class')]),
        ('rx_engine',[(6,20,'rx','take · check · enqueue')]),
        ('rx_deliver',[(20,26,'pass','read'),(26,30,'pass','p0…')]),
    ],rh=13,gap=5,tick=4)
    for c,r in [(3,0),(6,1),(20,2)]:
        f.arrow([(x0+c*cw,ys[r]+13),(x0+c*cw,ys[r+1])],sw=1.1)
    f.tag(x0+3*cw+3,ys[0]+9,'f_end',anchor='start',size=6.7)
    f.tag(x0+6*cw+3,ys[1]+9,'desc_valid',anchor='start',size=6.7)
    f.tag(x0+20*cw+3,ys[2]+9,'dq_count++',anchor='start',size=6.7)
    f.tag(x0+30*cw+4,ys[3]+9,'d_valid at 26',anchor='start',size=7.3,color=ACCEPT)
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
    path = lambda pts, c='#000', w=1.2: f.body.append(
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
                path([(a, yb), (a, yt), (m, yt), (m, yb), (b, yb)], w=0.9)
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
                f.body.append(f'<polygon points="{pts}" fill="{fills[k]}" stroke="#000" stroke-width="0.9"/>')
                if text:
                    if tw(text, 6.7, bold=True) > xb - xa - 2 * s - 1:
                        f.warn.append(f'bus label "{text}" too wide')
                    f.text((xa + xb) / 2, ym + 2.3, text, 6.7)
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
    f.tag((xa + xb) / 2, y - 2.5 if above else y + 7.5, text, size=6.7)


def guide(f, x, y0, y1):
    f.body.append(f'<line x1="{x:.2f}" y1="{y0:.2f}" x2="{x:.2f}" y2="{y1:.2f}" stroke="#777" stroke-width="0.5" stroke-dasharray="2 1.5"/>')


def cycles(f, xs, y, labels):
    """在拍中心标拍号：labels = {拍序号: 文字}。"""
    for i, t in labels.items():
        f.tag((xs[i] + xs[i + 1]) / 2, y, t, size=6.7)


@fig
def f31_wgmii():
    f=Fig(450,210)
    heading(f,10,'(a) Both GMII ports carry B0 / SN17 in the same byte cycles')
    labels=['0','1–6','7','8–18','19','20–49','50','51–66','67','68–71','72–83','84']
    widths=[22,28,22,34,25,40,25,40,25,42,40,22]
    xs=slots(77,widths)
    f.tag(69,29,'cycle',anchor='end',size=7.3)
    for i,lab in enumerate(labels):f.tag((xs[i]+xs[i+1])/2,29,lab,size=6.7)
    f.tag(69,52,'tx_valid A/B',anchor='end',size=7.3)
    f.arrow([(77,42),(xs[10],42),(xs[10],54),(xs[11],54),(xs[11],42),(xs[12],42)],head=None,sw=1.4,check=False)
    for yy,net,iface in [(69,'A','20'),(101,'B','40')]:
        f.tag(69,yy+12,'data '+net,anchor='end',size=7.3)
        strip(f,77,yy,['55','55 ×6','D5','H0…10',iface,'H12…41','B0','0 ×16','17','FCS_'+net,'idle','55'],
              widths,['white','white','white','cfg','tx','cfg','rx','gray','tx','cfg','gray','white'],h=20,size=6.7)
    f.tag(77,136,'Source IF byte: A = 0x20; B = 0x40',anchor='start',size=7.3,color=STATE)
    heading(f,158,'(b) Framing length and per-network checksum')
    strip(f,4,171,['preamble + SFD','42-B header + B0 + pad16 + SN','FCS','IFG'],[93,231,48,70],['gray','rx','cfg','white'],h=20)
    f.tag(50.5,204,'8 cycles',size=7.3)
    f.tag(235,204,'60 + 4 = 64 B frame',size=7.3)
    f.tag(411,204,'12 cycles',size=7.3)
    return f


@fig
def f32_wapp():
    f = Fig(450, 271)
    cw, bw = 20, 9
    B = (10, 14)
    xs = slots(100, [bw if i in B else 27 if i == 11 else cw for i in range(17)])
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
    xr = slots(100, [bw if i == 5 else 27 if i == 6 else cw for i in range(8)])
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
    f.text((xr[1] + xr[5]) / 2, ys2[-1] + 6.8, 'constant', 6.7)
    dim(f, xr[1], xr[7], yb2 + 14, 'n consecutive cycles, no back-pressure', above=False)
    f.tag(225, yb2 + 34, '(b) Deliver', bold=True, size=T1)
    f.tag(354,y2+10,'Same message, consecutive bytes',size=7.3)
    strip(f,279,y2+20,['D0','D1','…','Dn−1'],[35,35,29,48],['pass']*4,h=18,size=7.3)
    f.tag(352,y2+53,'VL / ports / net stay fixed',size=7.3)
    f.tag(352,y2+69,'d_last = 1 only on Dn−1',size=7.3)
    f.tag(352,y2+85,'No receive-side ready signal',size=6.7)
    return f


@fig
def f33_wcfg():
    f = Fig(450, 248)
    cw, bw = 22, 10
    B = (13,)
    xs = slots(78, [bw if i in B else 25 if i in (3,4) else cw for i in range(17)])
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
    f.tag(xs[5] + 0, yb + 21.5, 'register write', size=6.7, italic=True)
    heading(f,198,'RX table write: the same T1 / W1 survives the blocked interval')
    strip(f,4,209,['accepted at 10','pending while cfg_ok = 0','permit at u','ready at u+1'],
          [101,157,91,93],['gray']*4,h=17,size=6.7)
    strip(f,4,226,['{T1, W1}','{T1, W1, enable=1}','write T1 ← W1','enable=0'],
          [101,157,91,93],['cfg','cfg','pass','white'],h=19,size=7.3)
    return f

from tx_figures import FIGS as TX_FIGS
from rx_figures import FIGS as RX_FIGS
FIGS.update(TX_FIGS)
FIGS.update(RX_FIGS)
from service_figures import FIGS as SERVICE_FIGS
FIGS.update(SERVICE_FIGS)
def approved_dual_rx():
    from proposals.dual_rx_mechanism.draw import build
    return build()

FIGS['f13_decide'] = approved_dual_rx

if __name__ == '__main__':
    out = sys.argv[1]
    names = sys.argv[2:] or list(FIGS)
    for n in names:
        drawing = FIGS[n]()
        path = os.path.join(out, n + '.svg')
        if n == 'f13_decide':
            drawing.savefig(path, format='svg', facecolor='white')
        else:
            drawing.save(path)
