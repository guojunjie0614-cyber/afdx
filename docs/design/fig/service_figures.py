"""Service mechanisms illustrated with concrete, RTL-consistent transactions.

Examples are explanatory inputs, not captured simulation traces. Coordinates are pt.
"""
from jssc import Fig, T1, T2, PAL

DATA = '#008CA6'
GOOD = '#527D27'
CTRL = '#78529A'


def title(f, y, text):
    f.text(0, y, text, 8.5, 'start', True)


def strip(f, x, y, widths, labels, kinds=None, h=20, size=7.3):
    """An addressable record / payload, with visible field boundaries."""
    for i, (w, text) in enumerate(zip(widths, labels)):
        kind = kinds[i] if kinds else 'white'
        f.rect(x, y, w, h, PAL[kind][0], '#111', 1.4)
        f.text(x + w / 2, y + h / 2 + size * .34, text, size, bold=True)
        x += w


def table(f, y, widths, header, rows, colors=None, h=19, size=7):
    strip(f, 0, y, widths, header, ['gray'] * len(widths), h, size)
    for i, row in enumerate(rows):
        kinds = colors[i] if colors else ['white'] * len(widths)
        strip(f, 0, y + (i + 1) * h, widths, row, kinds, h, size)


def dot(f, x, y, color='#111'):
    f.body.append(f'<circle cx="{x}" cy="{y}" r="2.3" fill="{color}"/>')


def op(f, x, y, label, r=11, color='#111'):
    f.body.append(f'<circle cx="{x}" cy="{y}" r="{r}" fill="white" stroke="{color}" stroke-width="1.4"/>')
    f.text(x,y+2.7,label,8.5,color=color)


def trace(f, x, y, values, step=50, color='#111'):
    pts=[]
    for i,v in enumerate(values):
        xx=x+i*step; yy=y+(0 if v else 9)
        pts.append((xx,yy));pts.append((xx+step,yy))
    f.arrow(pts,head=None,sw=1.6,color=color,check=False)


def bus(f, x, y, segments, step=50, h=19):
    for a,b,label,kind in segments:
        strip(f,x+a*step,y,[(b-a)*step],[label],[kind],h,7.3)


def clock_pin(f, x, y, w, h):
    px=x+11; bottom=y+h
    f.arrow([(px-3,bottom),(px,bottom-4),(px+3,bottom)],head=None,sw=1.0,check=False)
    f.arrow([(px,bottom+4),(px,bottom)],head=None,sw=1.0,check=False)


def f14_rtc():
    f = Fig(450, 271)
    title(f, 9, '(a) Four samples of one exchange · illustrative timestamps')
    f.box(0, 24, 113, 29, 'svc', 'Slave clock', 'TX / RX first-byte capture')
    f.box(221, 24, 113, 29, 'svc', 'Master clock', 'TX / RX first-byte capture')
    for x in (56, 277):
        f.arrow([(x, 53), (x, 148)], dash=True, head=None, sw=.9, color='#777')
    f.arrow([(56, 76), (277, 94)], sw=1.6, color=DATA)
    f.tag(163, 69, 'mode 3 · Transmit = t1', color=DATA)
    f.arrow([(277, 121), (56, 143)], sw=1.6, color=DATA)
    f.tag(163, 114, 'mode 4 · Originate = t1', color=DATA)
    for x,y,label in ((56,76,'t1'),(277,94,'t2'),(277,121,'t3'),(56,143,'t4')):
        dot(f,x,y)
        f.text(x-8 if x==56 else x+8,y+2.5,label,7.3,'end' if x==56 else 'start')
    f.text(164,151,'Reply fields: Receive = t2 · Transmit = t3',7.3)
    f.text(395,33,'Local (s, ns)',7.3)
    for i,(label,val) in enumerate((('t1','11, 800'),('t2','11, 20400'),('t3','11, 30000'),('t4','11, 50600'))):
        strip(f,345,44+i*27,[24,81],[label,val],['gray','rx'],23)
    title(f, 171, '(b) Match, subtract, then correct a running-clock sample')
    f.box(0,185,111,39,'cfg','Originate = saved t1','accept this response','old response → reject',ssize=6.7,pad=2)
    f.box(132,185,158,39,'svcl','offset = (19600 − 20600) / 2','−500 ns = (−1 s, 999999500 ns)',ssize=6.7,pad=2)
    f.arrow([(111,204),(132,204)])
    f.box(314,185,136,39,'pass','Correct current time','11 s + 2000000 ns','→ 11 s + 1999500 ns',ssize=6.7,pad=2)
    f.arrow([(290,204),(314,204)],color=GOOD)
    strip(f,0,239,[111,179,160],['ADD_OFFSET sample','pipeline latency: 5 × 8 ns','APPLY: 11 s + 1999540 ns'],['gray','cfg','pass'],24,6.7)
    return f


def f15_snmp():
    f=Fig(450,291)
    title(f,9,'(a) Set USER_ID = 42 · SNMPv2c / request-id 7 / community public')
    f.text(0,25,'OID 1.3.6.1.4.1.424242.3.2.0 · request sent to UDP 161',7.3,'start')
    f.text(0,44,'Request RAM · 44 B (selected fields)',8,'start')
    strip(f,0,51,[47,45,77,45,49,113,74],['30 2A','02 01 01','public','A3 1D','id = 7','OID (11 B)','42 01 2A'],['gray','gray','cfg','svc','gray','ram','rx'],23,6.7)
    f.text(23,85,'0–1',6.7);f.text(70,85,'2–4',6.7);f.text(130,85,'5–12',6.7)
    f.text(192,85,'13–14',6.7);f.text(238,85,'15–17',6.7);f.text(320,85,'30–40',6.7);f.text(413,85,'41–43',6.7)
    f.box(0,103,108,35,'svc','BER decode','A3 → Set; 42 → Gauge32',ssize=6.7,pad=2)
    f.box(145,103,133,35,'svc','Object index = 3','private arc 2 → USER_ID',ssize=6.7,pad=2)
    f.box(315,103,135,35,'cfg','Set checks pass','writable · 0 ≤ 42 ≤ 65535',ssize=6.7,pad=2)
    f.arrow([(108,120),(145,120)],sw=1.6,color=DATA)
    f.arrow([(278,120),(315,120)],sw=1.6,color=DATA)
    f.arrow([(100,74),(100,103)],sw=1.6,color=DATA)
    title(f,151,'(b) Commit the value, then build the response from readback')
    f.box(333,176,117,32,'cfg','Configuration bus','address 0x00002',ssize=7)
    f.box(173,176,123,32,'ram','USER_ID register','0x0000 → 0x002A',ssize=7)
    f.box(0,176,136,32,'svc','VALUE_PREP','readback = 42',ssize=7)
    f.arrow([(382,138),(382,176)],dash=True,color=CTRL)
    f.arrow([(333,188),(296,188)],sw=1.6,color=DATA)
    f.tag(314,183,'write',size=6.7)
    f.arrow([(173,193),(136,193)],sw=1.6,color=GOOD)
    f.tag(154,187,'read',size=6.7)
    f.text(50,226,'Response RAM → afdx_mgmt_tx → requester',8,'start')
    strip(f,0,236,[47,45,77,45,49,113,74],['30 2A','02 01 01','public','A2 1D','id = 7','same OID','42 01 2A'],['gray','gray','cfg','pass','gray','ram','pass'],23,6.7)
    f.arrow([(23,208),(23,236)],sw=1.6,color=GOOD)
    f.text(0,280,'A3 Set → A2 GetResponse · error-status = 0 · error-index = 0',7.3,'start')
    return f


def f28_snmpfsm():
    f=Fig(450,278)
    title(f,9,'SNMP Set 42: decode the enterprise arc, select USER_ID, read it back')
    f.text(0,28,'Request RAM[35:37]: enterprise arc in OID 1.3.6.1.4.1.424242.3.2.0',7.3,'start')
    for x,hx,cont,bits in ((0,'99','1','0011001'),(157,'F2','1','1110010'),(314,'32','0','0110010')):
        f.text(x+68,45,'0x'+hx,7.3)
        strip(f,x,51,[22,114],[cont,bits],['gray','ram'],22,8)
    f.text(0,86,'MSB: more bytes',6.7,'start');f.text(314,86,'MSB = 0: arc complete',6.7,'start')
    f.text(0,104,'byte[6:0]',7.3,'start')
    f.text(0,121,'25 / 114 / 50',7.3,'start')
    # Standard two-input OR outline; each input lands on the concave edge.
    f.body.append('<path d="M 181 107 Q 199 107 209 119 Q 199 131 181 131 Q 190 119 181 107 Z" fill="white" stroke="#111" stroke-width="1.4"/>')
    f.arrow([(114,104),(170,104),(170,113),(184.375,113)],color=DATA,sw=1.6)
    f.box(240,104,138,30,'cfg','acc','0 → 25 → 3314 → 424242',ssize=7.3,pad=2)
    f.arrow([(209,119),(240,119)],color=DATA,sw=1.6)
    f.arrow([(378,119),(394,119),(394,144),(170,144),(170,125),(184.375,125)],color=DATA,sw=1.6)
    f.text(215,155,'acc << 7',6.7)
    f.text(0,148,'same register',6.7,'start')
    f.text(0,164,'Decoded: 1.3.6.1.4.1.424242.3.2.0',7.3,'start')
    f.text(0,187,'Candidate 3: 1.3.6.1.4.1.424242.3.2.0',7.3,'start')
    f.rect(316,163,22,22,'white','#111',1.4)
    f.text(327,177,'=',8.5)
    f.arrow([(268,162),(305,162),(305,168),(316,168)],color=DATA)
    f.arrow([(278,187),(305,187),(305,180),(316,180)],color=CTRL)
    f.box(367,158,83,32,'cfg','USER_ID','cfg address = 2',ssize=7,pad=2)
    f.arrow([(338,174),(367,174)],color=GOOD,sw=1.6)
    f.text(0,203,'Set value: Gauge32',7.3,'start')
    strip(f,0,213,[91],['42 01 2A'],['rx'],26,7.3)
    f.box(146,213,100,26,'ram','USER_ID: 0 → 42',tsize=7.3,pad=2)
    strip(f,297,213,[58],['42'],['pass'],26,7.3)
    strip(f,391,213,[59],['42 01 2A'],['pass'],26,7)
    f.arrow([(91,226),(146,226)],color=DATA,sw=1.6);f.text(118,218,'write',6.7)
    f.arrow([(246,226),(297,226)],color=GOOD,sw=1.6);f.text(271,218,'read',6.7)
    f.arrow([(355,226),(391,226)],color=GOOD,sw=1.6);f.text(373,218,'encode',6.7)
    f.arrow([(409,190),(409,199),(196,199),(196,213)],dash=True,color=CTRL)
    f.text(0,262,'A2 GetResponse: request-id 7 · same OID · actual readback 42',7.3,'start')
    clock_pin(f,240,104,138,30)
    clock_pin(f,146,213,100,26)
    clock_pin(f,297,213,58,26)
    return f


def f26_svc():
    f=Fig(450,326)
    title(f,9,'(a) TX arbitration: hold the message owner through back-pressure')
    f.text(0,28,'App: a0 a1 a2(last)     RTC: r0 r1(last), requesting from cycle 1',7.3,'start')
    x,step=120,53
    f.rect(x+step,43,step,117,'#F1F1F1','none',0)
    for i in range(6):f.text(x+(i+.5)*step,40,str(i),6.7)
    for yy,label in ((54,'m_ready'),(82,'m_data'),(111,'m_last'),(140,'granted source')):f.text(0,yy+6,label,7.3,'start')
    trace(f,x,54,[1,0,1,1,1,1],step)
    bus(f,x,76,[(0,1,'a0','tx'),(1,3,'a1 held','tx'),(3,4,'a2','tx'),(4,5,'r0','svc'),(5,6,'r1','svc')],step)
    trace(f,x,111,[0,0,0,1,0,1],step)
    bus(f,x,132,[(0,4,'App owner · served = 0001','tx'),(4,6,'RTC · 0010','svc')],step,23)
    f.arrow([(x+4*step,46),(x+4*step,161)],dash=True,head=None,sw=.9,color=CTRL)
    f.text(x+2.5*step,176,'RTC waits',7.3,color=CTRL)
    f.arrow([(x+step,165),(x+4*step,165)],head='both',sw=1.1,color=CTRL)
    f.text(0,194,'Cycle 1: a1 stalls. End of cycle 3: a2/last handshakes; RTC starts at cycle 4.',6.7,'start')
    title(f,216,'(b) RX port claim: a live first-byte decision becomes a held mask')
    rx=156;rw=70
    for yy,label in ((241,'d_data (valid = 1)'),(269,'effective claim'),(296,'App valid')):f.text(0,yy,label,7.3,'start')
    bus(f,rx,228,[(0,1,'p0','rx'),(1,2,'p1','rx'),(2,3,'p2 / last','rx'),(3,4,'q0','pass')],rw,20)
    trace(f,rx,260,[1,1,1,0],rw,CTRL)
    trace(f,rx,288,[0,0,0,1],rw,GOOD)
    f.text(rx+rw*.5,280,'live: port 123',6.7,color=CTRL)
    f.text(rx+rw*2,280,'rx_claimed = 1',6.7,color=CTRL)
    f.text(rx+rw*3.5,280,'unused port',6.7,color=GOOD)
    f.arrow([(rx+rw,250),(rx+rw,308)],dash=True,head=None,sw=.9,color='#888')
    f.arrow([(rx+3*rw,250),(rx+3*rw,308)],dash=True,head=None,sw=.9,color='#888')
    f.text(rx+1.5*rw,319,'p0 … p2 masked from App',7.3,color=CTRL)
    f.text(rx+3.5*rw,319,'q0 delivered',7.3,color=GOOD)
    return f


def f27_rtc():
    f=Fig(450,280)
    title(f,9,'RTC correction · local borrow/carry selection on (seconds, ns)')
    f.text(0,31,'t2−t1: (0,19600)',7.3,'start')
    f.text(0,67,'t3−t4: (0,−20600)',7.3,'start')
    op(f,104,45,'+',10)
    f.arrow([(89,28),(104,28),(104,35)],color=DATA,sw=1.6)
    f.arrow([(91,64),(104,64),(104,55)],color=DATA,sw=1.6)
    op(f,142,45,'÷2',10)
    f.arrow([(114,45),(132,45)],color=DATA,sw=1.6)
    f.box(175,32,109,26,'cfg','raw: (0, −500)',tsize=7.3,pad=2)
    f.arrow([(152,45),(175,45)],color=DATA,sw=1.6)
    op(f,317,45,'±',10)
    f.arrow([(284,45),(307,45)],color=DATA,sw=1.6)
    f.box(350,32,100,26,'cfg','(−1, 999999500)',tsize=7.3,pad=2)
    f.arrow([(327,45),(350,45)],color=GOOD,sw=1.6)
    f.text(317,24,'s−1; ns+10^9',6.7)
    f.text(0,85,'SUM = (0, −1000)',7.3,'start')
    f.text(0,103,'HALF_SECOND: even seconds → +0',6.7,'start')
    f.mux(300,86,18,44,'',name='offset normalisation select')
    f.arrow([(400,58),(400,75),(290,75),(290,98),(300,98)],color=GOOD,sw=1.6)
    f.arrow([(229,58),(229,116),(300,116)],color='#888',sw=1.1)
    f.box(350,94,100,28,'pass','offset: −500 ns','(−1, 999999500)',tsize=7.3,ssize=6.7,pad=2)
    f.arrow([(318,108),(350,108)],color=GOOD,sw=1.6)
    f.text(307,145,'ns < 0 = 1',6.7,color=CTRL)
    f.arrow([(309,136),(309,125)],color=CTRL,check=False)
    f.text(0,135,'OFFSET_CANDIDATES → NORMALIZE_OFFSET',6.7,'start')
    f.text(400,139,'offset',7.3,color=GOOD)
    f.arrow([(400,122),(400,129)],color=GOOD,sw=1.6)
    # The named offset net joins the two arithmetic stages without a page-wide return.
    f.box(0,176,112,30,'gray','Current clock','(11, 2000000)',tsize=7.3,ssize=7.3,pad=2)
    op(f,147,191,'+',10)
    f.arrow([(112,191),(137,191)],color=DATA,sw=1.6)
    f.text(147,169,'offset',7.3,color=GOOD)
    f.arrow([(147,173),(147,181)],color=GOOD,sw=1.6)
    f.box(175,178,116,26,'cfg','(10, 1001999500)',tsize=7.3,pad=2)
    f.arrow([(157,191),(175,191)],color=DATA,sw=1.6)
    f.text(233,171,'ADD_OFFSET',6.7)
    op(f,320,191,'±',10)
    f.arrow([(291,191),(310,191)],color=DATA,sw=1.6)
    f.text(321,169,'s+1; ns−10^9',6.7)
    f.box(350,178,100,26,'cfg','(11, 1999500)',tsize=7.3,pad=2)
    f.arrow([(330,191),(350,191)],color=GOOD,sw=1.6)
    f.mux(300,218,18,44,'',name='time carry select')
    f.arrow([(400,204),(400,211),(289,211),(289,230),(300,230)],color=GOOD,sw=1.6)
    f.arrow([(233,204),(233,252),(300,252)],color='#888',sw=1.1)
    f.text(0,232,'TIME_CANDIDATES',6.7,'start')
    f.text(325,219,'ns ≥ 10^9 = 1',7.3,color=CTRL,anchor='start')
    f.arrow([(309,214),(309,222)],color=CTRL,check=False)
    op(f,347,240,'+40',13,color=GOOD)
    f.arrow([(318,240),(334,240)],color=GOOD,sw=1.6)
    f.box(380,225,70,30,'pass','APPLY','(11, 1999540)',tsize=7.3,ssize=6.7,pad=2)
    f.arrow([(360,240),(380,240)],color=GOOD,sw=1.6)
    f.text(0,274,'NORMALIZE_TIME → LATENCY (+40 ns) → APPLY',6.7,'start')
    for x,y,w,h in ((175,32,109,26),(350,32,100,26),(350,94,100,28),(0,176,112,30),(175,178,116,26),(350,178,100,26),(380,225,70,30)):
        clock_pin(f,x,y,w,h)
    return f


def f30_cfg():
    f=Fig(450,300)
    title(f,9,'(a) One table write: T0 = rx_cfg[7] at 0x20007; W0 = 0x0018001F')
    f.box(0,26,99,32,'ext','Host cfg_*','wr = 1, ready = 1',ssize=6.7)
    strip(f,128,25,[83,112],['T0 = 0x20007','W0 = 0x0018001F'],['cfg','ram'],21,6.7)
    f.text(225,59,'hold address / data / write-enable',6.7)
    f.arrow([(99,42),(128,42)],color=DATA,sw=1.6)
    f.box(358,26,92,32,'rx','RX write register','cfg_ok permits capture',ssize=6.7,pad=2)
    f.arrow([(323,36),(358,36)],color=DATA,sw=1.6)
    table(f,76,[114,67,67,67,67,68],['Cycle / edge','t','t+1 …','u','u+1','u+2'],[
        ['bus ready (RX)','','','','',''],
        ['held write','capture','T0, W0','T0, W0','clear','—'],
        ['core cfg_ok','','','','',''],
        ['RX RAM[7]','old','old','old','W0 written','W0'],
        ['bus ready (TX)','','','','',''],
    ],colors=[['white']*6,['gray','cfg','cfg','cfg','white','white'],['white']*6,['gray','white','white','white','pass','pass'],['white']*6],h=17,size=6.7)
    for r,values,color in ((0,[1,0,0,1,1],GOOD),(2,[0,0,1,1,1],CTRL),(4,[1,0,0,0,1],DATA)):
        yy=76+(r+1)*17
        pts=[]
        for j,v in enumerate(values):
            x=114+j*67; level=yy+(5 if v else 13)
            if j:pts.append((x,level))
            else:pts.append((x+2,level))
            pts.append((x+67,level))
        f.arrow(pts,head=None,sw=1.4,color=color,check=False)
    f.text(0,190,'u: capture by core; TX comparison uses tx_cfg (e.g. 0x01038) and rearms ready one cycle later.',6.7,'start')
    title(f,206,'(b) Read A0 = 0x00002 after SNMP Set: USER_ID = 0x002A')
    f.box(0,221,107,31,'cfg','t: cfg_rd = 1','addr = A0',ssize=7)
    f.box(139,221,139,31,'ram','t+1: candidate registers','read_regs = 0x002A',ssize=7)
    f.box(310,221,140,31,'pass','t+2: group select','D(A0) = 0x0000002A',ssize=7)
    f.arrow([(107,236),(139,236)],color=DATA,sw=1.6)
    f.arrow([(278,236),(310,236)],color=GOOD,sw=1.6)
    f.text(53,270,'word = addr[2:0] = 2',6.7)
    f.text(208,270,'group = addr[17:3] = 0',6.7)
    f.text(380,270,'cfg_rvalid = 1; value = 42',6.7)
    clock_pin(f,139,221,139,31)
    clock_pin(f,310,221,140,31)
    f.text(0,292,'Host and SNMP share this bus; same-address reads can be combined.',7.3,'start')
    return f


def f16_615a():
    f=Fig(450,337)
    title(f,9,'600-byte file · byte[i] = i mod 256 · expected CRC-16 = B166')
    f.text(0,27,'Upload setup: LUI 0001 → initial LUS → LUR → LUS 0002 → LUH → LUS progress',6.7,'start')
    f.text(0,46,'(a) Upload: after valid LUH',8,'start')
    f.text(235,46,'(b) Download: after LNS 0002',8,'start')
    for x,name,kind in ((0,'Loader','ext'),(160,'615A','svc'),(235,'Loader','ext'),(392,'615A','svc')):
        f.box(x,57,58,24,kind,name,tsize=7.3)
    for x in (29,189,264,421):f.arrow([(x,81),(x,247)],dash=True,head=None,sw=.9,color='#888')
    up=[(189,29,96,'RRQ data file',False),(29,189,114,'DATA1 · 512 B',False),
        (189,29,132,'LUS progress · 85%',False),(189,29,150,'ACK1',True),
        (29,189,168,'DATA2 · 88 B (last)',False),(189,29,186,'ACK2 · length / CRC pass',True),
        (189,29,204,'LUS 0003 · 100%',False),(29,189,222,'final status ACK',True)]
    down=[(421,264,96,'WRQ MEMORY.BIN',False),(264,421,114,'ACK0 · peer TID',True),
          (421,264,132,'DATA1 · 512 B',False),(264,421,150,'ACK1',True),
          (421,264,168,'LNS progress · 85%',False),(421,264,186,'DATA2 · 88 B (last)',False),
          (264,421,204,'ACK2',True),(421,264,222,'LNS 0003 · 100%',False),
          (264,421,240,'final status ACK',True)]
    for a,b,y,label,dashed in up+down:
        col=DATA if label.startswith('DATA') else '#111'
        f.arrow([(a,y),(b,y)],dash=dashed,sw=1.4 if dashed else 1.6,color=col)
        f.text((a+b)/2,y-4,label,6.7)
    f.text(0,266,'Load RAM · 8 KiB',8,'start')
    f.arrow([(189,114),(220,114),(220,273),(112,273),(112,282)],color=DATA,sw=1.6)
    f.arrow([(189,168),(220,168)],head=None,color=DATA,sw=1.6)
    dot(f,220,168,DATA)
    f.arrow([(337,282),(337,263),(446,263),(446,132),(421,132)],color=GOOD,sw=1.6)
    f.arrow([(446,186),(421,186)],color=GOOD,sw=1.6)
    dot(f,446,186,GOOD)
    f.text(382,259,'read addr 0 … 599',6.7,color=GOOD)
    strip(f,0,282,[225,225],['RAM[0:511] · DATA1 (512 B)','RAM[512:599] · DATA2 (88 B)'],['rx','pass'],22,7.3)
    strip(f,0,304,[225,225],['00 … FF twice · CRC = 56EE','00 … 57 · cumulative CRC = B166'],['rx','pass'],22,7)
    return f


def f29_615a():
    f=Fig(450,337)
    title(f,9,'(a) Lost ACK1: resend the block, never append it twice')
    f.box(0,25,92,24,'ext','Data loader',tsize=7.3)
    f.box(210,25,102,24,'svc','afdx_615a',tsize=7.3)
    for x in (46,261):f.arrow([(x,49),(x,186)],dash=True,head=None,sw=.9,color='#777')
    f.arrow([(46,70),(261,70)],color=DATA,sw=1.6);f.tag(153,65,'DATA1: block = 1, 512 B',size=6.7)
    f.arrow([(261,99),(143,99)],dash=True);f.tag(186,93,'ACK1 lost',size=6.7)
    f.text(135,103,'×',14,color=CTRL)
    f.arrow([(46,130),(261,130)],color=CTRL,sw=1.6);f.tag(153,125,'timeout → repeat DATA1',size=6.7)
    f.arrow([(261,156),(46,156)],dash=True);f.tag(153,151,'ACK1 again',size=6.7)
    f.arrow([(46,182),(261,182)],color=DATA,sw=1.6);f.tag(153,177,'DATA2: 88 B (last)',size=6.7)
    f.text(385,38,'Block comparison',8)
    strip(f,330,53,[62,58],['expected','received'],['gray','gray'],19,6.7)
    strip(f,330,72,[62,58],['1','1'],['rx','rx'],19)
    strip(f,330,110,[62,58],['2','1 = previous'],['cfg','drop'],19,6.7)
    strip(f,330,164,[62,58],['2','2'],['pass','pass'],19)
    f.arrow([(261,70),(318,70),(318,82),(330,82)],color=DATA,sw=1.6)
    f.arrow([(261,130),(318,130),(318,120),(330,120)],color=CTRL)
    f.arrow([(261,182),(318,182),(318,174),(330,174)],color=DATA,sw=1.6)
    title(f,213,'(b) DATA_DISPATCH selects copying or acknowledgment only')
    table(f,225,[85,106,106,83,70],['Arrival','FSM action','RAM write','loaded','CRC (hex)'],[
        ['DATA1','DATA_COPY','[0:511] ← 512 B','0 → 512','56EE'],
        ['repeat DATA1','ACK → WAIT_PACKET','none','512 → 512','56EE'],
        ['DATA2','COPY → file check','[512:599] ← 88 B','512 → 600','B166'],
    ],colors=[['rx']*5,['drop']*5,['pass']*5],h=21,size=6.7)
    f.text(0,327,'DATA1 progress status completes before ACK1; final length / CRC checks precede ACK2.',6.7,'start')
    return f


FIGS={fn.__name__:fn for fn in (f14_rtc,f15_snmp,f16_615a,f26_svc,f27_rtc,f28_snmpfsm,f29_615a,f30_cfg)}
