INK='#1F2937'; MUT='#6B7280'; GRID='#D5D2C9'; TRACK='#EDEBE3'
TEAL='#2E9E96'; AMBER='#D99A2B'; BLUE='#7FB6D9'
F='PingFang SC, Hiragino Sans GB, Microsoft YaHei, sans-serif'
M='Menlo, Consolas, monospace'

def head(w,h,t,sub):
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}">
<rect width="{w}" height="{h}" fill="#FFFFFF"/>
<text x="28" y="34" font-family="{F}" font-size="19" font-weight="600" fill="{INK}">{t}</text>
<text x="28" y="58" font-family="{F}" font-size="13.5" fill="{MUT}">{sub}</text>'''

def bars():
    rows=[('LUT',45.74,'查找表'),('FF',26.14,'触发器'),('CLB',75.13,'可配置逻辑块'),
          ('M4K',67.83,'片上存储'),('Pins',50.74,'用户 I/O')]
    w,h=900,360; s=head(w,h,'资源占用 · EQ6HL130-CSG484_H','百分比为占器件总容量；CLB 为最高项')
    x0,x1=190,760
    for i,(k,v,cn) in enumerate(rows):
        y=112+i*44
        s+=f'<text x="{x0-34}" y="{y+13}" font-family="{M}" font-size="14" fill="{INK}" text-anchor="end">{k}</text>'
        s+=f'<text x="{x0-34}" y="{y+30}" font-family="{F}" font-size="11.5" fill="{MUT}" text-anchor="end">{cn}</text>'
        s+=f'<rect x="{x0}" y="{y}" width="{x1-x0}" height="13" rx="2" fill="{TRACK}"/>'
        col=AMBER if v==max(r[1] for r in rows) else TEAL
        s+=f'<rect x="{x0}" y="{y}" width="{(x1-x0)*v/100:.1f}" height="13" rx="2" fill="{col}"/>'
        s+=f'<text x="{x1+14}" y="{y+12}" font-family="{M}" font-size="14" fill="{INK}">{v:.2f}%</text>'
    s+=f'<line x1="{x1}" y1="92" x2="{x1}" y2="{112+4*44+16}" stroke="{GRID}" stroke-width="1" stroke-dasharray="3 4"/>'
    s+=f'<text x="{x1}" y="86" font-family="{F}" font-size="11.5" fill="{MUT}" text-anchor="middle">100%</text>'
    return s+'</svg>'

def thru():
    w,h=900,380; s=head(w,h,'单向有效载荷吞吐 vs 活跃 VL 数','去重后有效载荷，A/B 副本不计入；虚线为赛题门限')
    x0,y0,x1,y1=120,110,820,320
    ymax=1000
    for v in (0,250,500,750,1000):
        y=y1-(v/ymax)*(y1-y0)
        s+=f'<line x1="{x0}" y1="{y}" x2="{x1}" y2="{y}" stroke="{GRID}" stroke-width="1" stroke-dasharray="2 5"/>'
        s+=f'<text x="{x0-16}" y="{y+4}" font-family="{M}" font-size="12.5" fill="{MUT}" text-anchor="end">{v}</text>'
    yth=y1-(100/ymax)*(y1-y0)
    s+=f'<line x1="{x0}" y1="{yth}" x2="{x1}" y2="{yth}" stroke="{AMBER}" stroke-width="1.6" stroke-dasharray="6 4"/>'
    s+=f'<text x="{x0+232}" y="{yth-10}" font-family="{F}" font-size="12.5" fill="{AMBER}" text-anchor="middle">赛题门限 100 Mbps</text>'
    data=[(63,741.384),(77,906.136),(81,953.208)]
    bw=86; gap=(x1-x0)/len(data)
    for i,(vl,tp) in enumerate(data):
        cx=x0+gap*(i+0.5); y=y1-(tp/ymax)*(y1-y0)
        s+=f'<rect x="{cx-bw/2}" y="{y}" width="{bw}" height="{y1-y}" rx="3" fill="{TEAL}"/>'
        s+=f'<text x="{cx}" y="{y-12}" font-family="{M}" font-size="15" fill="{INK}" text-anchor="middle">{tp:.0f}</text>'
        s+=f'<text x="{cx}" y="{y1+26}" font-family="{M}" font-size="14" fill="{INK}" text-anchor="middle">{vl} VL</text>'
        s+=f'<text x="{cx}" y="{y1+46}" font-family="{F}" font-size="11.5" fill="{MUT}" text-anchor="middle">{"满载规格" if vl==63 else ("定长满载" if vl==77 else "超规格")}</text>'
    s+=f'<text x="28" y="{y1+46}" font-family="{F}" font-size="12" fill="{MUT}">Mbps</text>'
    s+=f'<line x1="{x0}" y1="{y1}" x2="{x1}" y2="{y1}" stroke="{GRID}" stroke-width="1"/>'
    return s+'</svg>'

def lat():
    w,h=900,380; s=head(w,h,'端到端时延 vs 应用消息长度','轻载分组测量，横轴对数刻度；每个长度 8 个样本')
    x0,y0,x1,y1=130,110,820,320
    ymax=25
    for v in (0,5,10,15,20,25):
        y=y1-(v/ymax)*(y1-y0)
        s+=f'<line x1="{x0}" y1="{y}" x2="{x1}" y2="{y}" stroke="{GRID}" stroke-width="1" stroke-dasharray="2 5"/>'
        s+=f'<text x="{x0-16}" y="{y+4}" font-family="{M}" font-size="12.5" fill="{MUT}" text-anchor="end">{v}</text>'
    import math
    pts=[(1,1.056),(17,1.136),(18,1.152),(511,9.040),(1471,24.400)]
    lmax=math.log10(1471)
    def px(n): return x0+(math.log10(n)/lmax)*(x1-x0)
    def py(v): return y1-(v/ymax)*(y1-y0)
    path=' '.join(f'{px(n):.1f},{py(v):.1f}' for n,v in pts)
    s+=f'<polyline points="{path}" fill="none" stroke="{TEAL}" stroke-width="2.2" stroke-linejoin="round"/>'
    for n,v in pts:
        s+=f'<circle cx="{px(n):.1f}" cy="{py(v):.1f}" r="4.2" fill="#FFFFFF" stroke="{TEAL}" stroke-width="2.2"/>'
        anc,dx=("end",-7) if n==17 else (("start",7) if n==18 else ("middle",0))
        s+=f'<text x="{px(n)+dx:.1f}" y="{y1+26}" font-family="{M}" font-size="13" fill="{INK}" text-anchor="{anc}">{n}</text>'
    s+=f'<text x="{px(1471):.1f}" y="{py(24.4)-16}" font-family="{M}" font-size="15" fill="{INK}" text-anchor="end">24.400 µs</text>'
    s+=f'<text x="{px(1)+6}" y="{py(1.056)-12}" font-family="{M}" font-size="13" fill="{MUT}">1.056 µs</text>'
    s+=f'<text x="28" y="{y1+46}" font-family="{F}" font-size="12" fill="{MUT}">µs  /  B</text>'
    s+=f'<line x1="{x0}" y1="{y1}" x2="{x1}" y2="{y1}" stroke="{GRID}" stroke-width="1"/>'
    return s+'</svg>'

for name,svg in (('resource',bars()),('throughput',thru()),('latency',lat())):
    open(f'{name}.svg','w',encoding='utf-8').write(svg)
print('svg ok')
