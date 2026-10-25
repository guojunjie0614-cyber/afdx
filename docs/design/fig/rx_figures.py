"""Receive-path examples: VLID 7 → idx 3, SN 17, four bytes at ring A[100:104].

Coordinates and strokes use print points. Every figure follows the same concrete
message; values are illustrative and the report captions state its assumptions.
"""
from jssc import Fig, T1, T2, PAL, tw

DATA = '#008DA5'
ACCEPT = '#507D26'
REJECT = '#755092'
NOTE = 6.7


def panel(f, y, text):
    f.tag(4, y, text, size=9, anchor='start')


def cells(f, x, y, widths, labels, kinds, h=18, size=7.3):
    xx=x
    for w,s,k in zip(widths,labels,kinds):
        f.rect(xx,y,w,h,PAL[k][0],'none',0)
        f.text(xx+w/2,y+h/2+size*.34,s,size,bold=True)
        xx+=w
    f.rect(x,y,sum(widths),h,'none','#000',1.4)
    xx=x
    for w in widths[:-1]:
        xx+=w
        f.arrow([(xx,y),(xx,y+h)],sw=.9,head=None,check=False)


def ptr(f,x,y,label,color='#000',side='top',anchor='middle'):
    if side=='top':
        f.tag(x,y-9,label,size=7.3,color=color,anchor=anchor,bg=True)
        f.arrow([(x,y-6),(x,y)],color=color)
    else:
        f.arrow([(x,y+15),(x,y)],color=color)
        f.tag(x,y+24,label,size=7.3,color=color,anchor=anchor)


def memory(f,x,y,start,kind='rx',free=False,w=40,h=20):
    for i in range(4):f.tag(x+(i+.5)*w,y-5,str(start+i),size=NOTE)
    cells(f,x,y,[w]*4,['—']*4 if free else ['p0','p1','p2','p3'],[kind]*4,h=h,size=8)


def f11_rx():
    f=Fig(450,258)
    panel(f,10,'(a) A wire VLID selects a map bank, then a compact VL index')
    # Actual descriptor fields stay visible while VLID is translated to idx.
    f.tag(8,29,'Parser A descriptor',anchor='start',size=8)
    cells(f,8,37,[46,74,62,82,74,104],['net A','VLID 7','SN 17','start 100','length 4','arrival 101'],['gray','ram','gray','rx','rx','gray'])
    f.tag(84,69,'7 = bank 0, row 7',size=7.3)
    f.arrow([(91,55),(91,59),(2,59),(2,115),(8,115)])
    f.tag(83,81,'rx_map · bank 0 / 32',size=8)
    cells(f,8,89,[40,44,66],['row','valid','idx'],['gray']*3,h=17,size=NOTE)
    cells(f,8,106,[40,44,66],['7','1','3'],['ram']*3,h=18,size=8)
    cells(f,8,124,[40,44,66],['8','0','—'],['white']*3,h=20,size=NOTE)
    f.tag(83,157,'2048 × 13 bits / bank',size=NOTE)
    # The map index addresses both configuration and state, rather than moving payload.
    f.arrow([(158,115),(176,115),(176,70),(438,70),(438,89)])
    f.arrow([(176,115),(176,70),(306,70),(306,89)])
    f.tag(176,106,'idx 3',size=7.3,bg=True)
    f.tag(253,83,'rx_cfg[3]',size=8)
    f.tag(385,83,'rx_state[3]',size=8)
    cells(f,194,89,[29.5]*4,['en','A','IC','RM'],['gray']*4,h=17,size=NOTE)
    cells(f,194,106,[29.5]*4,['1','1','1','1'],['cfg']*4,h=18)
    cells(f,194,124,[59,59],['max 1471','skew 4'],['cfg']*2,h=20,size=NOTE)
    cells(f,328,89,[57,57],['PSN_A','RM last'],['gray']*2,h=17,size=NOTE)
    cells(f,328,106,[57,57],['16','16'],['svcl']*2,h=18)
    cells(f,328,124,[114],['RM time 100'],['svcl'],h=20,size=NOTE)
    panel(f,174,'(b) Select the payload ring')
    f.arrow([(253,144),(253,166)])
    f.arrow([(385,144),(385,166)])
    # One compact predicate, with the passed condition attached to the enqueue edge.
    f.box(194,166,248,20,'pass','IC pass · new SN · queue has room',tsize=7.3,pad=2)
    f.arrow([(194,176),(190,176),(190,214)])
    f.tag(98,203,'rx_dq[tail] · metadata only',size=8)
    cells(f,8,214,[34,48,66,50],['A','idx 3','100','4'],['pass']*4,h=20,size=8)
    f.tag(107,247,'start',size=NOTE)
    f.tag(181,247,'length',size=NOTE)
    f.tag(349,198,'ring A · 4 KiB',size=8)
    # Descriptor A/start/length selects the already prewritten A-ring bytes.
    memory(f,270,214,100,'rx',w=43,h=20)
    f.arrow([(206,224),(270,224)],dash=True)
    f.tag(237,217,'A, 100, 4',size=NOTE,color=DATA)
    f.tag(350,252,'p0 → p1 → p2 → p3 to RX deliver',size=7.3,color=DATA)
    return f


def f12_ring():
    f=Fig(450,252)
    panel(f,10,'A four-byte trial: publish, consume, or release the same addresses')
    x,w=100,68
    # Every lane uses the same x(address), including the two alternative outcomes.
    for i in range(5):f.tag(x+i*w,29,str(100+i),size=NOTE)
    for xx in (x,x+4*w):f.arrow([(xx,33),(xx,232)],head=None,dash=True,color='#AAA',sw=.9,check=False)
    def row(y,name,k,vals,hatched=False):
        f.tag(8,y+13,name,size=8,anchor='start')
        cells(f,x,y,[w]*4+[70],(['']*4 if hatched else vals)+['free'],[k]*4+['white'],h=20,size=8)
        if hatched:
            # Released slots retain their bits; keep the hatching clear of their labels.
            for xx in range(102,357,10):
                f.arrow([(xx,y+19),(xx+16,y+1)],head=None,sw=.7,color='#999',check=False)
            for i,s in enumerate(vals):
                cx=x+(i+.5)*w
                width=tw(s,8,True)+3
                f.rect(cx-width/2,y+5,width,10,PAL[k][0],'none',0)
                f.text(cx,y+12.72,s,8)
    row(53,'1  Prewrite','rx',['p0','p1','p2','p3'])
    f.tag(96,45,'rd = commit = 100',size=7.3,anchor='end')
    f.arrow([(100,41),(100,53)])
    ptr(f,372,53,'trial = 104',DATA)
    # Accept and reject both start from the prewritten snapshot above.
    row(101,'2a  Accept','pass',['p0','p1','p2','p3'])
    f.arrow([(100,86),(372,86)],color=ACCEPT)
    f.tag(236,82,'commit 100 → 104',size=7.3,color=ACCEPT)
    f.arrow([(372,86),(372,101)],color=ACCEPT)
    f.tag(96,97,'rd = 100',size=NOTE,anchor='end')
    f.tag(405,96,'commit = trial',size=NOTE,color=ACCEPT)
    row(148,'3  Read A','gray',['p0','p1','p2','p3'],hatched=True)
    f.arrow([(100,134),(372,134)],color=DATA,sw=1.6)
    f.tag(236,129,'read p0, p1, p2, p3; rd 100 → 104',size=7.3,color=DATA)
    f.arrow([(372,134),(372,148)],color=DATA)
    f.tag(8,178,'After read: rd = commit = trial = 104; reusable slots, unchanged RAM bits.',anchor='start',size=7.3,bg=True)
    row(210,'2b  Reject','gray',['p0','p1','p2','p3'],hatched=True)
    f.arrow([(372,197),(100,197)],color=REJECT)
    f.tag(236,192,'trial 104 → 100; no descriptor queued',size=7.3,color=REJECT)
    f.arrow([(100,197),(100,210)],color=REJECT)
    f.tag(8,244,'Reject: rd = commit = trial = 100; old RAM bits remain until overwritten.',anchor='start',size=7.3)
    return f


def f23_parse():
    f=Fig(450,291)
    panel(f,10,'(a) A 4-byte payload in a minimum-size Ethernet frame')
    xs=[8,98,186,252,332,376,408]
    sizes=[90,88,66,80,44,32,34]
    for x,sz,pos in zip(xs,sizes,['0–13','14–33','34–41','42–45','46–58','59','60–63']):
        f.tag(x+sz/2,28,pos,size=NOTE)
    cells(f,8,35,[90,88,66],['DMAC … 00 07','IP length 32','UDP length 12'],['gray','rx','rx'],h=22,size=7.3)
    cells(f,252,35,[20]*4,['p0','p1','p2','p3'],['ram']*4,h=22,size=7.3)
    cells(f,332,35,[44,32,34],['pad ×13','SN 17','FCS'],['white','gray','gray'],h=22,size=NOTE)
    f.tag(53,70,'VLID = 7',size=NOTE)
    f.tag(142,70,'20-byte IP header',size=NOTE)
    f.tag(219,70,'8-byte UDP header',size=NOTE)
    f.tag(354,70,'not stored',size=NOTE,color=REJECT)
    f.tag(392,70,'captured',size=NOTE)
    f.tag(425,70,'MAC only',size=NOTE)
    panel(f,85,'(b) Length fields arrive before the first payload byte')
    cw=108
    for i,(pos,byte,kind) in enumerate([(39,'0x0C','gray'),(40,'UDP sum high','gray'),(41,'UDP sum low','gray'),(42,'p0','ram')]):
        x=8+i*110
        f.tag(x+54,100,'byte '+str(pos),size=7.3)
        cells(f,x,107,[108],[byte],[kind],h=18,size=7.3)
    # Show the computed quantities at each real byte position, not invented stages.
    for x,lines in [(62,['capture UDP len = 12','LEN_WAIT → SIZES']),
                    (172,['n = 12 − 8 = 4','IP expected = 12 + 20 = 32']),
                    (282,['end = 46; SN pos = 59','expected frame = 64 B']),
                    (392,['ring_wa = 100; data = p0','trial: 100 → 101'])]:
        for j,t in enumerate(lines):f.tag(x,139+11*j,t,size=NOTE)
    f.tag(172,167,'LEN_SIZES',size=7.3,color=DATA)
    f.tag(282,167,'LEN_LIMITS',size=7.3,color=DATA)
    f.tag(392,167,'first write request',size=7.3,color=DATA)
    # Four bytes become physical ring data; padding/SN stay outside the payload ring.
    f.tag(8,188,'ring A after four writes',anchor='start',size=8)
    memory(f,8,208,100,'rx',w=38,h=20)
    f.tag(84,242,'commit 100 · trial 104',size=7.3)
    f.arrow([(392,170),(392,178),(184,178),(184,218),(160,218)],color=DATA,sw=1.6)
    f.tag(230,188,'(c) Frame-end decision',anchor='start',size=9)
    f.tag(336,205,'f_end → SETTLE → REPORT',size=7.3)
    # Alternative outcomes occupy the spare area beside the prewritten bytes.
    cells(f,230,217,[56,156],['FCS bad','trial 104 → 100'],['svcl']*2,h=20,size=7.3)
    cells(f,230,256,[38,42,42,46,44],['good','VL 7','SN 17','100','n = 4'],['pass']*5,h=20,size=7.3)
    f.arrow([(160,221),(214,221),(214,266)],head=None)
    f.arrow([(214,227),(230,227)],color=REJECT)
    f.arrow([(214,266),(230,266)],color=ACCEPT)
    f.tag(336,248,'ev_fcs = 1; desc_valid = 0',size=NOTE,color=REJECT)
    f.tag(336,288,'ev_good = 1; desc_valid = 1',size=NOTE,color=ACCEPT)
    f.tag(8,262,'Bytes stay tentative until',anchor='start',size=7.3)
    f.tag(8,274,'the RX engine resolves the frame.',anchor='start',size=7.3)
    return f


def f24_rxeng():
    f=Fig(450,274)
    panel(f,10,'SN 17: field comparisons and gated state updates')
    bounds=[8,111,185,230,270,326,381,442]
    labels=['0–6 read','7–8 prepare','9 IC','10 RM','11 admit','12 state','13 resolve']
    f.arrow([(8,25),(442,25)],head=None,sw=.9)
    for x in bounds:f.arrow([(x,21),(x,29)],head=None,sw=.9)
    for a,b,s in zip(bounds,bounds[1:],labels):f.tag((a+b)/2,38,s,size=NOTE)

    def reg(x,y,w,s,kind='svcl'):
        f.rect(x,y,w,22,PAL[kind][0],'#000',1.4)
        f.text(x+w/2,y+13.5,s,7.3,bold=True)
        f.arrow([(x+w/2-3,y+22),(x+w/2,y+18),(x+w/2+3,y+22)],head=None,sw=.9,check=False)
    def cmp(x,y,op):
        f.rect(x,y,34,28,'white','#000',1.4)
        f.text(x+17,y+16.5,op,7.3,bold=True)
    def alu(x,y,op):
        f.body.append(f'<polygon points="{x},{y} {x+18},{y} {x+28},{y+11} {x+18},{y+22} {x},{y+22} {x+5},{y+11}" fill="white" stroke="black" stroke-width="1.4"/>')
        f.text(x+13,y+13.5,op,7.3,bold=True)

    # Equal-sized operators form aligned lanes; only the five control bits converge.
    f.tag(8,64,'n = 4',anchor='start',size=7.3)
    f.tag(8,82,'max = 1471',anchor='start',size=7.3)
    f.arrow([(50,61),(144,61)])
    f.arrow([(69,79),(144,79)])
    cmp(144,56,'≤')
    f.arrow([(178,70),(284,70),(284,100),(300,100)])
    f.tag(228,64,'length_ok = 1',size=NOTE,color=ACCEPT)
    f.tag(318,50,'PSN write from SN',anchor='start',size=NOTE)
    reg(318,56,124,'PSN_A: 16 → 17','pass')

    f.tag(8,99,'state[3] read',anchor='start',size=7.3)
    reg(8,105,66,'PSN_A 16')
    f.arrow([(74,116),(90,116)])
    alu(90,105,'+1')
    f.arrow([(118,116),(144,116)])
    f.tag(130,129,'17',size=NOTE)
    cmp(144,102,'=')
    f.tag(126,95,'SN 17',size=NOTE)
    f.arrow([(126,97),(126,108),(144,108)])
    f.arrow([(178,116),(300,116)])
    f.tag(215,111,'IC = 1',size=NOTE,color=ACCEPT)
    f.tag(8,141,'IC example: SN = PSN + 1',anchor='start',size=NOTE)

    reg(8,152,66,'RM last 16')
    f.arrow([(74,163),(84,163),(84,168),(95,168)])
    f.tag(108,145,'SN 17',size=NOTE)
    f.arrow([(87,147),(87,157),(95,157)],check=False)
    alu(90,152,'−')
    f.tag(105,185,'mod 255',size=NOTE)
    f.arrow([(118,163),(144,163)])
    f.tag(131,157,'1',size=NOTE)
    cmp(144,149,'1…127')
    f.arrow([(178,163),(228,163)])
    f.tag(203,157,'1',size=NOTE,color=ACCEPT)
    f.mux(228,151,16,38,'','RM expiry selector')
    f.text(232,165,'0',NOTE,'start',True)
    f.text(232,182,'1',NOTE,'start',True)
    f.arrow([(205,180),(228,180)])
    f.tag(205,194,'const 1',size=NOTE)
    f.arrow([(244,170),(264,170),(264,124),(300,124)])
    f.tag(270,165,'RM = 1',size=NOTE,color=ACCEPT,anchor='start')

    reg(8,205,66,'RM time 100')
    f.arrow([(74,216),(84,216),(84,221),(95,221)])
    f.tag(107,198,'arrival 101',size=NOTE)
    f.arrow([(87,200),(87,210),(95,210)],check=False)
    alu(90,205,'|−|')
    f.arrow([(118,216),(144,216)])
    f.tag(131,210,'1',size=NOTE)
    cmp(144,202,'>')
    f.tag(135,238,'skew 4',size=NOTE,anchor='end')
    f.arrow([(137,230),(137,224),(144,224)],check=False)
    f.arrow([(178,216),(236,216),(236,186)],check=False)
    f.tag(207,230,'expired = 0',size=NOTE)

    # A compact five-input AND has the same visual scale as the other operators.
    f.tag(312,91,'Admit',size=7.3)
    f.body.append('<path d="M 300 96 H 304 A 20 20 0 0 1 304 136 H 300 Z" fill="white" stroke="black" stroke-width="1.4"/>')
    f.text(310,119,'&',8,bold=True)
    f.arrow([(278,108),(300,108)],head=None)
    f.tag(275,106,'en_A = 1',anchor='end',size=NOTE)
    f.arrow([(278,132),(300,132)],head=None)
    f.tag(300,148,'DQ room = 1',size=NOTE)
    f.arrow([(324,116),(334,116),(334,164),(346,164)],color=ACCEPT)
    f.arrow([(334,164),(334,216),(346,216)],color=ACCEPT)
    f.body.append(f'<circle cx="334" cy="164" r="1.7" fill="{ACCEPT}"/>')
    f.tag(343,120,'admit = 1',anchor='start',size=7.3,color=ACCEPT)
    f.tag(346,146,'RM write',anchor='start',size=NOTE,color=ACCEPT)
    reg(346,153,96,'last 17 · time 101','pass')
    f.tag(346,198,'rx_dq[tail]',anchor='start',size=NOTE,color=ACCEPT)
    cells(f,346,205,[26,40,30],['A','100','4'],['pass']*3,h=22,size=7.3)

    f.tag(8,247,'IC-enabled PSN follows SN even on IC failure; RM and DQ writes require admit.',anchor='start',size=NOTE)
    f.tag(8,259,'phase 13: admit → commit=1; rejected → commit=0 (trial rollback).',anchor='start',size=NOTE)
    f.tag(8,271,'AGE 0–3 clears expired RM valid; any pending descriptor returns the engine to IDLE.',anchor='start',size=NOTE)
    return f


def f25_deliver():
    f=Fig(450,293)
    panel(f,10,'A four-byte read: startup latency, then one output byte per clock')
    f.tag(8,25,'rx_dq head',anchor='start',size=7.3)
    cells(f,8,31,[30,40,34],['A','100','4'],['pass']*3,h=19,size=7.3)
    x0,cw=120,29
    X=lambda t:x0+t*cw
    f.arrow([(X(0),30),(X(6),30)],head='both',sw=.9)
    f.tag((X(0)+X(6))/2,25,'6 clocks to first output',size=7.3)
    for t in range(11):
        f.tag(X(t),49,str(t),size=NOTE)
        f.arrow([(X(t),55),(X(t),277)],head=None,dash=True,sw=.5,color='#D0D0D0',check=False)
    f.tag(442,49,'t',size=NOTE)
    rows=[(82,'Read request','ring_re / address'),(108,'RAM result','ring_a_q'),(134,'Data register','data_a'),(160,'Output','d_data when valid')]
    for y,title,sub in rows:
        f.tag(8,y,title,anchor='start',size=8)
        f.tag(8,y+11,sub,anchor='start',size=NOTE)
        f.arrow([(X(0),y),(X(11),y)],head=None,color='#DDD',sw=.6,check=False)
    # Hardware symbols at the row origins identify the registered boundaries.
    for yy in (82,134,160):
        f.reg(105,yy-10,20)
        f.arrow([(111,yy),(120,yy)],head=None,sw=.9)
    f.cells(98,98,13,20,3,'ram')
    f.arrow([(111,108),(120,108)],head=None,sw=.9)
    f.tag(X(0)+2,69,'count = 1',anchor='start',size=NOTE,bg=True)
    f.tag(X(2),70,'latch head',size=NOTE,bg=True)
    f.arrow([(X(2),74),(X(3)-13,82)],color='#777',sw=.9,check=False)
    colors=[DATA,'#527C31','#AA6B25',REJECT]
    fills=['#DFF0F2','#E9F0DB','#F7E9D6','#EDE3F2']
    # The four diagonal trajectories are actual clock-to-clock propagation of
    # each byte. A RAM/reg hold is deliberately not shown as a new token.
    for i,(color,fill) in enumerate(zip(colors,fills)):
        positions=[(X(3+i),82),(X(4+i),108),(X(5+i),134),(X(6+i),160)]
        for (ax,ay),(bx,by) in zip(positions,positions[1:]):
            dx,dy=bx-ax,by-ay;length=(dx*dx+dy*dy)**.5
            f.arrow([(ax+dx*12.5/length,ay+dy*12.5/length),(bx-dx*12.5/length,by-dy*12.5/length)],color=color,sw=1.6,check=False)
        for j,(x,y) in enumerate(positions):
            # Timing-diagram bus segments retain the byte's identity across rows.
            f.body.append(f'<polygon points="{x-13},{y} {x-10},{y-8} {x+10},{y-8} {x+13},{y} {x+10},{y+8} {x-10},{y+8}" fill="{fill}" stroke="{color}" stroke-width="1.4"/>')
            f.text(x,y+2.5,str(100+i) if j==0 else 'p'+str(i),7.3,bold=True)
    f.arrow([(X(6),180),(X(9),180)],head='both',color=ACCEPT,sw=.9)
    f.tag((X(6)+X(9))/2,193,'1 byte / clock',size=8,color=ACCEPT,bg=True)
    # Real level waveforms share the token time axis. Values are after each edge.
    def bit(y,name,on,off):
        f.tag(8,y+3,name,anchor='start',size=8)
        lo,hi=y+6,y-6
        f.arrow([(X(0),lo),(X(on),lo),(X(on),hi),(X(off),hi),(X(off),lo),(X(11),lo)],head=None,sw=1.4,check=False)
    bit(211,'d_valid',6,10)
    bit(235,'d_last',9,10)
    # Read pointer changes when RAM accepts a registered read enable, one edge
    # after the request row, and before the corresponding output token.
    f.tag(8,266,'read_ptr_A',anchor='start',size=8)
    yy=265
    segments=[(0,4,'100'),(4,5,'101'),(5,6,'102'),(6,7,'103'),(7,11,'104')]
    for a,b,val in segments:
        xa,xb=X(a),X(b)
        f.body.append(f'<path d="M {xa+2} {yy-7} L {xb-2} {yy-7} L {xb+2} {yy+7} L {xa+2} {yy+7} L {xa-2} {yy-7} Z" fill="white" stroke="black" stroke-width="1"/>')
        f.text((xa+xb)/2,yy+2.5,val,7.3,bold=True)
    f.tag(8,289,'t9: p3 and d_last coincide; dq_req re-arms. Metadata stays fixed; ring B is not read.',anchor='start',size=NOTE)
    return f


FIGS={fn.__name__:fn for fn in (f11_rx,f12_ring,f23_parse,f24_rxeng,f25_deliver)}
