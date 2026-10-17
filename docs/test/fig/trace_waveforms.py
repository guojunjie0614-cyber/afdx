"""Production timing figures drawn from the checked-in RTL trace capture."""
from functools import lru_cache
from pathlib import Path
import json
import sys

DESIGN = Path(__file__).resolve().parents[2] / 'design' / 'fig'
if str(DESIGN) not in sys.path:
    sys.path.insert(0, str(DESIGN))
from jssc import Fig, PAL, tw

SOURCE = Path(__file__).resolve().parent / 'src' / 'wave_traces.json'
LEFT, RIGHT, ROW, RH = 96, 448, 17, 9


@lru_cache(maxsize=1)
def _windows():
    return json.loads(SOURCE.read_text(encoding='utf-8'))['windows']


def _path(f, points, width=0.75, color='#000'):
    d = ' '.join(('M' if i == 0 else 'L') + f' {x:.2f} {y:.2f}'
                 for i, (x, y) in enumerate(points))
    f.body.append(f'<path d="{d}" fill="none" stroke="{color}" stroke-width="{width}"/>')


def _value(signal, time):
    value = signal['events'][0][1]
    for event, item in signal['events']:
        if event > time:
            break
        value = item
    return value


def _intervals(signal, start, end):
    times = [start] + [t for t, _ in signal['events'] if start < t < end] + [end]
    return [(a, b, _value(signal, a)) for a, b in zip(times, times[1:])]


def _bit(f, signal, start, end, x, y):
    points = []
    for a, b, value in _intervals(signal, start, end):
        level = y if value else y + RH
        points.extend([(x(a), level), (x(b), level)])
    _path(f, points, width=0.6 if signal.get('name') == 'clk' else 0.75)


def _label(name, value, width):
    if name == 'cfg_addr':
        return f'0x{value:05X}'
    if name == 'host_read_pipe':
        return f'{value:02b}'
    if name in ('count_a_fcs', 'SNMP_requests', 'BAG_ticks', 'VL', 'SN'):
        return str(value)
    if name == 'cfg_rdata':
        return f'0x{value:08X}'
    return f'{value:0{max(2, (width + 3) // 4)}X}'


def _bus(f, name, signal, mask, start, end, x, y, fill, envelope=False):
    boundaries = {start, end}
    if not envelope:
        boundaries.update(t for t, _ in signal['events'] if start < t < end)
    if mask:
        boundaries.update(t for t, _ in mask['events'] if start < t < end)
    times = sorted(boundaries)
    segments = []
    for a, b in zip(times, times[1:]):
        valid = mask is None or _value(mask, a) == 1
        text = ('bytes' if envelope else _label(name, _value(signal, a), signal['width'])) if valid else ''
        color = fill if valid else PAL['gray'][0]
        # Ignore data changes outside valid, while preserving all valid boundaries.
        if segments and not valid and not segments[-1][4]:
            segments[-1] = (segments[-1][0], b, '', color, False)
        else:
            segments.append((a, b, text, color, valid))
    for a, b, text, color, valid in segments:
        xa, xb, ym = x(a), x(b), y + RH / 2
        slope = min(1.2, (xb - xa) / 4)
        points = f'{xa:.2f},{ym:.2f} {xa+slope:.2f},{y:.2f} {xb-slope:.2f},{y:.2f} {xb:.2f},{ym:.2f} {xb-slope:.2f},{y+RH:.2f} {xa+slope:.2f},{y+RH:.2f}'
        f.body.append(f'<polygon points="{points}" fill="{color}" stroke="#000" stroke-width="0.6"/>')
        if text and tw(text, 6.5) + 2 * slope + 0.8 <= xb - xa:
            f.tag((xa + xb) / 2, ym + 2.3, text, size=6.5, bold=False)


def _axis(f, start, end, x, y, ticks=None):
    _path(f, [(x(start), y), (x(end), y)], width=0.5, color='#777')
    if ticks is None:
        ticks = [start, (start + end) / 2, end]
    for t in ticks:
        xx = x(t)
        _path(f, [(xx, y), (xx, y + 3)], width=0.5, color='#777')
        anchor = 'start' if t == start else 'end' if t == end else 'middle'
        f.tag(xx, y + 11, f'{t / 1000:.3f}', size=6.5, anchor=anchor, bold=False, color='#555')
    f.tag(LEFT - 8, y + 11, 'Time (us)', size=6.5, anchor='end', bold=False, color='#555')


def _panel_height(rows):
    return 28 + len(rows) * ROW + 20


def _panel(f, window_name, title, rows, top, markers=(), start=None, end=None):
    window = _windows()[window_name]
    signals = window['signals']
    start = window['start_ns'] if start is None else start
    end = window['end_ns'] if end is None else end
    x = lambda t: LEFT + (t - start) * (RIGHT - LEFT) / (end - start)
    f.tag(0, top + 8, title, anchor='start', size=7)
    y0 = top + 26
    for i, item in enumerate(rows):
        name, mask_name, style = item
        signal = signals[name]
        y = y0 + i * ROW
        f.tag(LEFT - 7, y + RH / 2 + 2.5, name, anchor='end', size=7)
        if signal['width'] == 1:
            _bit(f, dict(signal, name=name), start, end, x, y)
        else:
            fill = PAL['txl'][0] if style in ('tx', 'tx-envelope') else PAL['pass'][0] if style in ('rx', 'rx-envelope') else '#FFFFFF'
            _bus(f, name, signal, signals[mask_name] if mask_name else None,
                 start, end, x, y, fill, envelope=style.endswith('-envelope'))
    bottom = y0 + (len(rows) - 1) * ROW + RH
    for time, label in markers:
        xx = x(time)
        f.body.append(f'<line x1="{xx:.2f}" y1="{top+17:.2f}" x2="{xx:.2f}" y2="{bottom+3:.2f}" stroke="#777" stroke-width="0.5" stroke-dasharray="2 1.5"/>')
        width = tw(label, 6.5, True)
        tx = min(max(xx, LEFT + width / 2), RIGHT - width / 2)
        f.tag(tx, top + 18, label, size=6.5)
    _axis(f, start, end, x, bottom + 9)
    return top + _panel_height(rows)


def _figure(panels):
    height = sum(_panel_height(p['rows']) for p in panels) + 17
    f = Fig(450, height)
    f.rect(0, 0, 450, height, '#FFFFFF', 'none', 0)
    top = 0
    for panel in panels:
        top = _panel(f, top=top, **panel)
    return f


def _bag():
    source = _windows()['tx_bag']['signals']
    rows = [('BAG_ticks', None, 'control'), ('tx_valid_a', None, 'tx'),
            ('tx_data_a', 'tx_valid_a', 'tx-envelope'), ('tx_valid_b', None, 'tx'),
            ('tx_data_b', 'tx_valid_b', 'tx-envelope'), ('SN', None, 'control')]
    f = Fig(450, 184)
    f.rect(0, 0, 450, 184, '#FFFFFF', 'none', 0)
    f.tag(0, 8, 'Two transmissions on the same VL', anchor='start', size=7)
    windows = [(16900, 17750, LEFT, 261), (816900, 817750, 283, RIGHT)]
    y0 = 35
    for i, (name, mask, style) in enumerate(rows):
        y = y0 + i * ROW
        f.tag(LEFT - 7, y + RH / 2 + 2.5, name, anchor='end', size=7)
        for start, end, left, right in windows:
            x = lambda t, a=start, b=end, l=left, r=right: l + (t-a)*(r-l)/(b-a)
            signal = source[name]
            if signal['width'] == 1:
                _bit(f, signal, start, end, x, y)
            else:
                _bus(f, name, signal, source[mask] if mask else None, start, end, x, y,
                     PAL['txl'][0] if mask else '#FFFFFF', envelope=bool(mask))
        _path(f, [(269, y + RH + 2), (272, y - 2)], width=0.6)
        _path(f, [(273, y + RH + 2), (276, y - 2)], width=0.6)
    for start, end, left, right in windows:
        x = lambda t, a=start, b=end, l=left, r=right: l + (t-a)*(r-l)/(b-a)
        event = next(t for t, value in source['tx_valid_a']['events'] if value == 1 and start <= t < end)
        _path(f, [(left, 151), (right, 151)], width=0.5, color='#777')
        for t in [event, end]:
            xx=x(t)
            _path(f, [(xx, 151), (xx, 154)], width=0.5, color='#777')
            f.tag(xx, 163, f'{t/1000:.3f}', size=6.5, bold=False,
                  anchor='end' if t == end else 'middle', color='#555')
        xx=x(event)
        f.body.append(f'<line x1="{xx:.2f}" y1="20" x2="{xx:.2f}" y2="144" stroke="#777" stroke-width="0.5" stroke-dasharray="2 1.5"/>')
        f.tag((left+right)/2, 23, f'Start {event/1000:.3f} us', size=6.5)
    f.tag(LEFT-7, 163, 'Time (us)', size=6.5, anchor='end', bold=False, color='#555')
    return f


def get_figure(name):
    """Return a 450 pt Fig; all timing and bus values come from src/wave_traces.json."""
    if name == 't13_w_bag':
        return _bag()
    specs = {
        't10_w_tx': [
            dict(window_name='tx_dual_1', title='(a) Application input and dual-network output',
                 rows=[('app_tx_valid',None,'tx'),('app_tx_ready',None,'tx'),('app_tx_data','app_tx_valid','tx-envelope'),('tx_valid',None,'tx'),('tx_data','tx_valid','tx-envelope'),('tx_valid_b',None,'tx'),('tx_data_b','tx_valid_b','tx-envelope')],
                 markers=[(688108,'GMII start 688.108 us')]),
            dict(window_name='tx_dual_2', title='(b) GMII byte detail', end=688300,
                 rows=[('app_tx_valid',None,'tx'),('app_tx_data','app_tx_valid','tx'),('app_tx_last',None,'tx'),('tx_valid',None,'tx'),('tx_data','tx_valid','tx'),('tx_valid_b',None,'tx'),('tx_data_b','tx_valid_b','tx')])],
        't11_w_rm': [
            dict(window_name='rx_redundancy_1', title='(a) A-network copy accepted and delivered', start=3014004, end=3014220,
                 rows=[('ev_deliver',None,'rx'),('app_rx_valid',None,'rx'),('app_rx_data','app_rx_valid','rx'),('app_rx_last',None,'rx'),('app_rx_net',None,'rx')],
                 markers=[(3014028,'Accept 3014.028 us')]),
            dict(window_name='rx_redundancy_2', title='(b) Late B-network copy discarded', start=3029832, end=3030064,
                 rows=[('rx_valid_b',None,'rx'),('rx_data_b','rx_valid_b','rx'),('ev_rm_drop',None,'rx'),('app_rx_valid',None,'rx')],
                 markers=[(3030044,'Drop 3030.044 us')])],
        't12_w_fault': [
            dict(window_name='rx_fcs_error_1', title='(a) A-network FCS error; B-network copy delivered',
                 rows=[('rx_valid',None,'rx'),('rx_data','rx_valid','rx-envelope'),('rx_valid_b',None,'rx'),('ev_a_fcs_error',None,'rx'),('count_a_fcs',None,'control'),('app_rx_valid',None,'rx'),('app_rx_net',None,'rx')],
                 markers=[(799156,'FCS error 799.156 us')]),
            dict(window_name='rx_fcs_error_3', title='(b) Independent configuration read of address 0x49',
                 rows=[('clk',None,'control'),('cfg_rd',None,'control'),('cfg_addr',None,'control'),('host_read_pipe',None,'control'),('cfg_rvalid',None,'control'),('cfg_rdata',None,'control'),('count_a_fcs',None,'control')])],
        't14_w_snmp': [
            dict(window_name='snmp_get_1', title='(a) Get request received on A and B', end=525472,
                 rows=[('rx_valid',None,'rx'),('rx_data','rx_valid','rx'),('rx_valid_b',None,'rx'),('rx_data_b','rx_valid_b','rx'),('SNMP_requests',None,'control')],
                 markers=[(525292,'Start 525.292 us')]),
            dict(window_name='snmp_get_2', title='(b) Response transmitted on A and B', end=531852,
                 rows=[('tx_valid',None,'tx'),('tx_data','tx_valid','tx'),('tx_valid_b',None,'tx'),('tx_data_b','tx_valid_b','tx'),('SNMP_requests',None,'control')],
                 markers=[(531676,'Start 531.676 us')])],
    }
    if name not in specs:
        raise ValueError('Unknown captured waveform: ' + name)
    return _figure(specs[name])
