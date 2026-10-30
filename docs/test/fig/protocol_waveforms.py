# -*- coding: utf-8 -*-
"""TFTP/SNTP schematic figures using the design report's timing primitives."""
import json
from pathlib import Path
import sys

sys.dont_write_bytecode = True
BASE = Path(__file__).resolve().parent
sys.path.insert(0, str(BASE.parents[1]/'design/fig'))
from figs import Fig, slots, wave, guide, dim, tw


def source(name):
    # The WaveJSON sources use the strict JSON subset of JSON5.
    return json.loads((BASE / (name + '.json5')).read_text(encoding='utf-8'))


def bit_values(value):
    values, state = [], None
    for c in value:
        if c in '01x':
            state = c
        elif c not in '.|':
            raise ValueError('Unsupported bit state: '+c)
        if state is None:
            raise ValueError('Missing initial bit state')
        values.append(state)
    return ''.join(values)


def bus_segments(signal, rx):
    segments, fields, start, state = [], [], 0, None
    data = iter(signal['data'])
    for i, c in enumerate(signal['wave']+'!'):
        if c in '.|':
            continue
        if state is not None:
            raw = state[0]
            text = {'DATA n+1 (<512 B)':'DATA n+1', 'ACK n (Block n)':'ACK n',
                    'SNTP Request (Transmit=T1)':'SNTP Request',
                    'SNTP Response (Originate=T1 | T2, T3)':'SNTP Response'}.get(raw,raw)
            segments.append((start,i,text,state[1]))
            note = {'DATA n+1 (<512 B)':'last block: <512 B',
                    'SNTP Request (Transmit=T1)':'Transmit = T1',
                    'SNTP Response (Originate=T1 | T2, T3)':'Originate = T1; Receive = T2; Transmit = T3'}.get(raw)
            if note:
                fields.append((start,i,note))
        if c == '!':
            break
        if c == 'x':
            state = ('','x')
        elif c in '23456789=':
            payload = next(data)
            state = (payload,'v' if payload=='55' else 'g' if rx else 'h')
        else:
            raise ValueError('Unsupported bus state: '+c)
        start = i
    if next(data,None) is not None:
        raise ValueError('Unconsumed bus data')
    return segments,fields


def get_figure(name):
    rtc = name == 't16_w_rtc'
    data = source(name)
    f = Fig(450,205)
    f.rect(0,0,450,205,'#FFFFFF','none',0)
    widths = [18]*20
    widths[7] = 9
    if not rtc:
        widths[8] = widths[9] = 15
        widths[17] = widths[18] = 21
    xs = slots(78,widths)
    rows,notes = [],[]
    signals = [s for s in data['signal'] if s.get('wave')]
    for index,signal in enumerate(signals):
        label = signal['name'].split(' (')[0]
        if index == 0:
            rows.append(('clk','clk',None))
        elif 'data' in signal:
            segments,fields = bus_segments(signal,label.startswith('rx'))
            rows.append((label,'bus',segments))
            notes.extend((index,a,b,text) for a,b,text in fields)
        else:
            rows.append((label,'bit',bit_values(signal['wave'])))
    ys = wave(f,xs,16,rows,rh=9,gap=12,brk=(7,))
    for index,a,b,text in notes:
        width = tw(text,6.5,True)
        center = min(max((xs[a]+xs[b])/2,78+width/2),446-width/2)
        f.tag(center,ys[index]+18,text,size=6.5)
    phases = [(1,8,'Request'),(10,17,'Response')] if rtc else [(1,8,'DATA n'),(10,14,'ACK n'),(15,19,'DATA n+1')]
    for start,end,title in phases:
        dim(f,xs[start],xs[end],12,title,above=True)
    bottom = ys[-1]+9
    if rtc:
        guide(f,xs[1],ys[1]-3,ys[4]+12)
        dim(f,xs[1],xs[8],bottom+28,'A / B aligned',above=False)
    else:
        guide(f,xs[10],ys[3]-3,bottom+5)
        dim(f,xs[10],xs[14],bottom+16,'A / B aligned',above=False)
    f.check()
    if f.warn:
        raise ValueError('; '.join(f.warn))
    return f
