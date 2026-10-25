"""Concrete TX message, storage and scheduling examples (print-point coordinates)."""
from jssc import Fig, PAL, BW

DATA = '#13899A'
QUEUE = '#79539C'
RETURN = '#628D36'
BYTE = '#DEF1F3'
GREEN = '#E8F0DC'
PURPLE = '#EEE6F3'
GRAY = '#F0F0F0'


def title(f, y, text):
    f.tag(4, y, text, size=9, anchor='start')


def data(f, pts, color=DATA):
    f.arrow(pts, sw=1.6, color=color)


def strip(f, x, y, widths, labels, fills=None, h=19, size=7.3):
    """Actual fields / memory slots; outlines do not stand for processing stages."""
    xx=x
    for i,(w,label) in enumerate(zip(widths,labels)):
        fill=(fills[i] if fills else BYTE)
        f.rect(xx,y,w,h,fill,'#000',BW)
        if label.startswith('p') and label[1:].isdigit():
            sub=label[1:]
            f.body.append(f'<text x="{xx+w/2}" y="{y+h/2+2}" text-anchor="middle" font-family="Times New Roman" font-style="italic" font-size="9">p<tspan baseline-shift="sub" font-size="6.2">{sub}</tspan></text>')
        else:
            f.text(xx+w/2,y+h/2+size*.34,label,size,bold=True)
        xx+=w
    return xx


def table(f,x,y,widths,headers,rows,rowh=20,fills=None,size=7.3):
    strip(f,x,y,widths,headers,[GRAY]*len(widths),h=rowh,size=size)
    for i,row in enumerate(rows):
        strip(f,x,y+(i+1)*rowh,widths,row,
              fills[i] if fills else ['#fff']*len(widths),h=rowh,size=size)


def f07_tx():
    f=Fig(450,253)
    title(f,9,'M0: one descriptor selects a 1200-B message already stored in pages')
    strip(f,4,27,[40,39,49],['VL 7','M0','1200 B'],[GRAY,GRAY,GRAY])
    strip(f,4,46,[43,42,43],['p0','…','p1199'])
    data(f,[(68,65),(68,78)])
    f.box(4,78,124,29,'white','afdx_tx_buf','allocate pages; write bytes')
    f.tag(216,24,'tx_state[7]',size=7.3)
    strip(f,154,29,[45,40,39],['head 12','count 2','SN 17'],[GRAY]*3,size=6.7)
    f.arrow([(165,48),(165,78)],head='both')
    f.tag(222,65,'tx_mnext[12] = 91',size=7.3)
    f.box(154,78,124,29,'white','Shared TX engine','BAG check → dequeue M0')
    f.tag(378,24,'grant: page / length / SN',size=7.3)
    strip(f,310,29,[42,52,42],['12','1200','17'],[GREEN]*3)
    f.arrow([(278,92),(294,92),(294,38),(310,38)])
    f.arrow([(378,48),(378,78)])
    f.box(310,78,136,29,'white','afdx_tx_builder','header + stored payload + SN')
    f.tag(127,118,'tx_payload',size=8,anchor='end')
    for y,page,first,last in [(124,12,0,511),(147,37,512,1023),(170,84,1024,1199)]:
        strip(f,4,y,[26,34,30,38],[str(page),'p'+str(first),'…','p'+str(last)],[GRAY,BYTE,BYTE,BYTE])
    data(f,[(20,107),(20,124)])
    f.tag(24,117,'write',color=DATA,anchor='start',size=6.7)
    f.tag(278,118,'tx_desc[12]',size=8,anchor='end')
    strip(f,154,124,[62,62],['length 1200','ports'],[GRAY]*2)
    f.arrow([(128,92),(141,92),(141,133.5),(154,133.5)])
    f.tag(145,154,'descriptor write',anchor='start',size=6.7)
    f.arrow([(163,124),(163,107)])
    data(f,[(128,179.5),(290,179.5),(290,118),(352,118),(352,107)])
    f.tag(210,175,'p0 … p1199',color=DATA)
    f.box(310,128,136,31,'white','Stream buffer → MAC','preamble + A/B FCS')
    data(f,[(411,107),(411,128)])
    f.tag(415,121,'bytes',color=DATA,anchor='start',size=6.7)
    data(f,[(411,159),(411,192)])
    f.tag(415,174,'GMII',color=DATA,anchor='start',size=6.7)
    f.tag(415,185,'A / B',color=DATA,anchor='start',size=6.7)
    strip(f,154,192,[39,63,104,43,43],['pre','H0 … H41','p0 … p1199','SN 17','FCS'],[GRAY,GRAY,BYTE,GREEN,GRAY],size=7)
    for x,s in [(173.5,'8 B'),(224.5,'42 B'),(308,'1200 B'),(381.5,'1 B'),(424.5,'4 B')]: f.tag(x,223,s,size=6.7)
    f.tag(68,211,'tx_free: append read pages',size=6.7)
    strip(f,4,219,[32,32,32,32],['…','12','37','84'],[GRAY,GREEN,GREEN,GREEN])
    f.arrow([(68,189),(68,201)],color=RETURN)
    f.tag(224,250,'head: 12 → 91     count: 2 → 1     next SN: 17 → 18',color=QUEUE)
    return f


def f08_txfsm():
    f=Fig(450,279)
    title(f,9,'(a) START wins: priority logic drives one phase counter and one RAM write port')
    f.tag(4,25,'pending VL 7; candidate VL 9; enqueue VL 8',anchor='start',size=7.3)
    for y,lab,high in [(46,'START: ack_pending = 1',True),(70,'ENQ: want_enq = 1',True),(94,'GRANT: blocked by pending',False)]:
        f.tag(4,y-9,lab,anchor='start',size=7.3)
        pts=[(4,y+5),(25,y+5),(25,y-5),(80,y-5)] if high else [(4,y+5),(80,y+5)]
        f.arrow(pts,head=None,color=QUEUE if high else '#777')
        f.arrow([(80,y-5 if high else y+5),(139,y-5 if high else y+5)],color=QUEUE if high else '#777')
    f.mux(139,35,22,72)
    f.tag(150,119,'priority encoder',size=7.3)
    f.arrow([(161,71),(203,71)],color=QUEUE)
    f.tag(182,63,'START',size=7.3,color=QUEUE)
    f.rect(203,54,78,34,'#fff','#000',BW)
    f.text(242,66,'phase register',7.3,bold=True)
    f.text(242,81,'0 → 1 → 2',8,bold=True)
    f.arrow([(208,88),(212,83),(216,88)],head=None,check=False)
    f.rect(231,26,22,18,GRAY,'#000',BW)
    f.text(242,38,'+1',8,bold=True)
    f.arrow([(217,54),(217,35),(231,35)])
    f.arrow([(253,35),(268,35),(268,54)])
    f.tag(242,103,'3 cycles',size=7.3)
    f.rect(290,63,24,18,GRAY,'#000',BW)
    f.text(302,75,'= 2',7.3,bold=True)
    f.arrow([(281,71),(290,71)])
    gate=f.gate_and(319,63,18)
    f.arrow([(314,72),(316,72),gate.inputs[0]],head=None)
    f.arrow([(182,71),(182,110),(317,110),(317,gate.inputs[1][1]),gate.inputs[1]],head=None,color=QUEUE)
    f.tag(255,122,'op = START',size=6.7,color=QUEUE)
    f.arrow([gate.output,(338,72),(338,90),(350,90)])
    f.tag(312,58,'write enable',size=6.7)
    f.tag(312,99,'wa = 7',anchor='end',size=7.3)
    f.rect(345,34,101,92,'#fff','#000',BW)
    f.text(395.5,47,'tx_state RAM',8,bold=True)
    strip(f,350,56,[22,69],['6','…'],[GRAY,GRAY],h=16)
    strip(f,350,82,[22,69],['7','375040'],[GREEN,GREEN],h=16)
    strip(f,350,108,[22,69],['8','…'],[GRAY,GRAY],h=16)
    f.tag(406,79,'next_time',size=6.7)
    f.tag(4,140,'START writes 250040 + 125000; then clears pend_valid.',anchor='start',size=7.3)
    title(f,160,'(b) Later IDLE decisions reuse the same counter and write port')
    f.tag(4,178,'ENQ = 1',anchor='start',size=7.3,color=QUEUE)
    f.tag(4,190,'GRANT = 1',anchor='start',size=7.3,color='#777')
    f.tag(4,202,'START = 0',anchor='start',size=6.7)
    f.mux(83,168,12,34)
    f.arrow([(62,176),(83,176)],color=QUEUE)
    f.arrow([(62,193),(83,193)],color='#777')
    f.arrow([(95,185),(119,185)],color=QUEUE)
    f.arrow([(119,185),(234,185)],head=None,color=QUEUE)
    for i,x in enumerate([125,150,175,200,225]):
        f.arrow([(x,181),(x,189)],head=None,color=QUEUE)
        f.tag(x,176,str(i),size=7.3)
    f.tag(175,202,'ENQ · 5 cycles',size=7.3)
    f.arrow([(234,185),(286,185)])
    f.tag(294,177,'wa = 8: count 1 → 2',anchor='start',size=7.3)
    f.tag(294,190,'tail 25 → 91',anchor='start',size=7.3)
    f.tag(294,203,'tx_mnext[25] ← 91',anchor='start',size=7.3,color=QUEUE)
    f.tag(4,227,'GRANT = 1',anchor='start',size=7.3,color=QUEUE)
    f.tag(4,240,'ENQ = 0',anchor='start',size=7.3)
    f.arrow([(69,232),(119,232)],color=QUEUE)
    f.arrow([(119,232),(274,232)],head=None,color=QUEUE)
    for i,x in enumerate([125,145,165,185,205,225,245,265]):
        f.arrow([(x,228),(x,236)],head=None,color=QUEUE)
        f.tag(x,223,str(i),size=7.3)
    f.tag(195,250,'GRANT · 8 cycles',size=7.3)
    f.arrow([(274,232),(286,232)])
    f.tag(294,224,'wa = 9: head 50 → 67',anchor='start',size=7.3)
    f.tag(294,237,'count 2 → 1; SN 24 → 25',anchor='start',size=7.3)
    f.tag(294,250,'tx_mnext[50] = 67',anchor='start',size=7.3,color=QUEUE)
    f.tag(4,264,'GRANT sets pend_vl = 9. Only the selected operation can assert state_we.',anchor='start',size=7.3)
    f.tag(4,276,'Counter-lane durations exclude the IDLE dispatch cycle.',anchor='start',size=7.3)
    return f


def f19_txbuf():
    f=Fig(450,290)
    title(f,9,'Paged storage: page links follow M0; the message link skips to M1')
    f.tag(94,29,'tx_pnext',size=7.3,color=DATA)
    f.tag(154,29,'page',size=7.3)
    f.tag(298,29,'tx_payload · 512 B / page',size=8)
    f.box(4,34,65,60,'gray','tx_state[7]','head = 12','tail = 91','count = 2',tsize=7.3,ssize=7.3,pad=2)
    f.arrow([(8,94),(12,89),(16,94)],head=None,check=False)
    f.arrow([(69,49),(73,49),(73,35),(154,35),(154,45)],color=QUEUE)
    for y,page in [(45,12),(83,37),(121,84),(159,91)]:
        strip(f,80,y,[28],[{12:'37',37:'84',84:'—',91:'—'}[page]],[BYTE if page in (12,37) else GRAY],h=20)
        strip(f,140,y,[28],[str(page)],[GRAY],h=20)
        if page==12:
            strip(f,168,y,[60,140,60],['p0','…','p511'],h=20)
            f.tag(298,y+32,'M0 · 512 B',size=7.3)
        elif page==37:
            strip(f,168,y,[60,140,60],['p512','…','p1023'],h=20)
            f.tag(298,y+32,'M0 · 512 B',size=7.3)
        elif page==84:
            strip(f,168,y,[32,25.375,32,170.625],['p1024','…','p1199','unused'],[BYTE,BYTE,BYTE,GRAY],h=20)
            f.tag(212.7,y+32,'176 B',size=7.3)
            f.tag(342.7,y+32,'336 B unused',size=7.3,color='#666')
        else:
            strip(f,168,y,[152.34375,107.65625],['M1: q0 … q299','unused'],[PURPLE,GRAY],h=20)
            f.tag(244.2,y+32,'300 B',size=7.3)
            f.tag(374.2,y+32,'212 B',size=7.3,color='#666')
    # Adjacent pointer/address columns keep links local instead of wrapping the RAM.
    data(f,[(108,55),(122,55),(122,77),(154,77),(154,83)])
    data(f,[(108,93),(122,93),(122,115),(154,115),(154,121)])
    f.tag(94,191,'unused',size=6.7)
    f.arrow([(428,55),(442,55),(442,169),(428,169)],color=QUEUE)
    f.tag(4,117,'tx_mnext[12]',anchor='start',size=7.3,color=QUEUE)
    f.tag(4,130,'= 91',anchor='start',size=8,color=QUEUE)
    f.tag(4,149,'next message',anchor='start',size=6.7,color=QUEUE)
    f.tag(4,211,'Builder page-end reads: p511 → p1023 → p1199',anchor='start',size=8)
    f.tag(349,228,'ret1_page: 12 → 37 → 84',size=7.3,color=RETURN)
    f.tag(4,243,'tx_free',anchor='start',size=8)
    strip(f,100,237,[62,62,62,62,62],['existing …','12','37','84',''],[GRAY,GREEN,GREEN,GREEN,'#fff'],h=20)
    f.arrow([(446,247),(410,247)],color=RETURN)
    f.arrow([(100,247),(68,247)],color=RETURN)
    f.tag(4,260,'pop → tx_buf',anchor='start',size=6.7)
    for x,lab in [(131,'rd_ptr'),(379,'wr_ptr')]:
        f.arrow([(x,274),(x,257)],color=RETURN)
        f.tag(x,287,lab,size=7.3,color=RETURN)
    f.tag(251,280,'after the three returns',size=7.3)
    return f


def f21_scan():
    f=Fig(450,297)
    title(f,9,'Eligibility is a time window; pending temporarily excludes the selected VL')
    f.tag(4,26,'Active timers; now = 249600; d = now − next_time',anchor='start',size=7.3)
    # Two VL deadlines share one linear time coordinate in this upper view.
    nowx=112
    f.arrow([(nowx,37),(nowx,125)],head=None,dash=True,color=QUEUE)
    f.tag(nowx,33,'now',size=6.7,color=QUEUE)
    f.tag(4,61,'VL 7',anchor='start',size=8)
    f.tag(4,75,'q_count = 2',anchor='start',size=6.7)
    f.rect(89.6,53,102.4,20,GREEN,'none',0)
    f.arrow([(72,63),(235,63)],head=None)
    for x,t in [(89.6,'249488'),(192,'250000')]:
        f.arrow([(x,50),(x,78)],head=None)
        f.tag(x,47,t,size=6.7)
    f.rect(nowx-2.5,60.5,5,5,RETURN,'none',0)
    f.arrow([(192,63),(235,63)],color=RETURN)
    f.tag(244,66,'select M0: d + 512 = 112',anchor='start',size=7.3,color=RETURN)
    f.tag(142,87,'512-cycle window',size=6.7)
    f.tag(4,101,'VL 8',anchor='start',size=8)
    f.tag(4,115,'q_count = 1',anchor='start',size=6.7)
    f.rect(289.6,93,102.4,20,GRAY,'none',0)
    f.arrow([(72,103),(423,103)],head=None)
    for x,t in [(289.6,'250488'),(392,'251000')]:
        f.arrow([(x,90),(x,118)],head=None)
        f.tag(x,87,t,size=6.7)
    f.rect(nowx-2.5,100.5,5,5,'#fff','#777',1.4)
    f.tag(144,98,'too early: d + 512 = −888',anchor='start',size=6.7)
    f.tag(340,128,'512-cycle window',size=6.7)
    f.tag(4,143,'Grant M0: q_count 2 → 1; pend_vl = 7 blocks M1 until START clears pending.',anchor='start',size=7.3)
    title(f,159,'M0 timeline and the stored deadline (illustrative; lower axis not to scale)')
    f.arrow([(64,187),(442,187)])
    for x,t in [(70,'249600'),(150,'249630'),(300,'250000'),(350,'250040')]:
        f.arrow([(x,182),(x,192)],head=None)
        f.tag(x,179,t,size=6.7)
    f.tag(405,179,'write',size=6.7)
    f.tag(405,168,'after ack',size=6.7)
    f.arrow([(405,182),(405,258)],head=None,dash=True,color=RETURN)
    for x,w,col,lab in [(70,80,GRAY,'prepare'),(150,150,PURPLE,'wait for T'),(300,50,GRAY,'busy'),(350,88,GREEN,'on wire')]:
        f.rect(x,200,w,14,col,'none',0)
        f.tag(381 if lab == 'on wire' else x+w/2,225,lab,size=7.3)
    f.arrow([(350,192),(350,238)],color=DATA)
    f.tag(346,236,'t_start',anchor='end',size=7.3,color=DATA)
    f.tag(211,236,'idle line → start at T',size=6.7)
    # The state changes on the later START write, not at the tx_sof timestamp.
    f.arrow([(70,258),(405,258),(405,239),(438,239)],color=RETURN,sw=1.6)
    f.tag(70,250,'next_time = 250000',anchor='start',size=7.3)
    f.tag(441,236,'375040',anchor='end',size=7.3,color=RETURN)
    f.tag(70,274,'new deadline = actual t_start + BAG = 250040 + 125000',anchor='start',size=7.3)
    f.tag(4,294,'Prepared before T + idle line → start at T.  timer_active = 0 → skip the T check.',anchor='start',size=7.3)
    return f


def f22_builder():
    f=Fig(450,280)
    title(f,9,'(a) During the preamble: header bytes queue ahead of payload')
    f.tag(4,28,'42-byte header register (after two takes)',anchor='start',size=8)
    strip(f,4,36,[37]*6,['H2','H3','…','H41','0','0'],[GRAY]*6)
    f.tag(4,65,'8-byte payload FIFO',anchor='start',size=8)
    strip(f,4,73,[27.75]*8,['p0','p1','p2','p3','','','',''],[BYTE]*4+['#fff']*4)
    f.tag(4,104,'rd ↑',anchor='start',size=6.7,color=DATA)
    f.tag(115,104,'↑ wr',anchor='start',size=6.7,color=DATA)
    f.tag(4,113,'issue reads only if count < 5',anchor='start',size=6.7)
    f.mux(256,46,18,54)
    data(f,[(226,45.5),(242,45.5),(242,55),(256,55)])
    data(f,[(226,82.5),(236,82.5),(236,73),(256,73)])
    strip(f,150,99,[38,38],['pad 0','SN 17'],[GRAY,GREEN],h=16,size=6.7)
    data(f,[(226,107),(246,107),(246,91),(256,91)])
    data(f,[(274,73),(302,73)])
    strip(f,302,63.5,[22,22],['H0','H1'],[GRAY,GRAY])
    f.tag(324,55,'stream buffer',size=7.3)
    data(f,[(346,73),(365,73)])
    f.box(365,59,81,28,'white','MAC A / B','adds pre + FCS',tsize=8,ssize=6.7)
    f.tag(287,100,'Next MAC take: H0 → MAC',anchor='start',size=7.3)
    f.tag(287,112,'H1 → head; H2 held this cycle',anchor='start',size=6.7)
    title(f,132,'(b) At a page boundary: byte data and page number arrive together')
    strip(f,4,150,[39,39],['p510','p511'])
    f.tag(43,178,'page 12',size=7.3)
    data(f,[(82,159.5),(108,159.5)])
    f.box(108,148,87,23,'white','RAM read pipeline',tsize=7.3)
    data(f,[(195,159.5),(216,159.5),(216,152.5),(245,152.5)])
    strip(f,245,143,[20]*8,['p508','p509','p510','p511','','','',''],[BYTE]*3+[GREEN]+['#fff']*4)
    f.tag(325,176,'Byte FIFO: append p511',size=7.3,color=DATA)
    f.arrow([(151,171),(151,199.5),(245,199.5)],color=RETURN)
    f.tag(155,192,'page 12; end = 1',anchor='start',color=RETURN,size=6.7)
    strip(f,245,190,[40]*4,['12','','',''],[GREEN,'#fff','#fff','#fff'])
    f.tag(325,222,'Return FIFO → tx_free',size=7.3,color=RETURN)
    f.tag(4,222,'next address: {37, 0} → p512',anchor='start',size=7.3,color=QUEUE)
    title(f,239,'(c) Builder byte order for M0 (1200 B needs no padding)')
    strip(f,4,249,[132,232,78],['H0 … H41','p0 … p1199','SN 17'],[GRAY,BYTE,GREEN],h=18)
    for x,s in [(70,'42 B'),(252,'1200 B'),(407,'1 B')]:f.tag(x,277,s,size=7.3)
    return f


FIGS = {fn.__name__: fn for fn in (f07_tx, f08_txfsm, f19_txbuf, f21_scan, f22_builder)}
