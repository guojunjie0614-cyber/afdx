"""测试报告插图：平台图、判据图、性能图和时序图。

波形绘图元素沿用设计报告，RTL 观察窗口读取 src/wave_traces.json，
TFTP/SNTP 示意读取本目录的 WaveJSON。图注由 LaTeX 排版。
用法：python3 -I tfigs.py <输出目录> [图名 ...]
"""
import os
from functools import partial
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

# 引入本模块自带的生成器
from gen_jssc_figures import (  # noqa: E402
    gen_t01_platform,
    gen_t02_criteria,
    gen_t20_thru,
    gen_t21_lat,
    PAL,
)

from protocol_waveforms import get_figure as protocol_figure  # noqa: E402
from trace_waveforms import get_figure as trace_figure  # noqa: E402
from jssc import FONT  # noqa: E402


def gen_timing(name):
    figure = protocol_figure(name) if name in ('t15_w_615a', 't16_w_rtc') else trace_figure(name)
    figure.check()
    if figure.warn:
        raise ValueError('; '.join(figure.warn))
    # Crop unused bottom canvas without rescaling the drawing.
    bottom_trim = {
        't10_w_tx': 21, 't11_w_rm': 21, 't12_w_fault': 21,
        't13_w_bag': 15, 't14_w_snmp': 21, 't15_w_615a': 25, 't16_w_rtc': 13,
    }.get(name, 0)
    height = figure.h - bottom_trim
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{figure.w}pt" height="{height}pt" '
            f'viewBox="0 0 {figure.w} {height}">\n'
            f'<style>text {{ font-family: {FONT}; }}</style>\n'
            + '\n'.join(figure.body) + '\n</svg>\n')


FIGS = {
    't01_platform': gen_t01_platform,
    't02_criteria': gen_t02_criteria,
    't20_thru': gen_t20_thru,
    't21_lat': gen_t21_lat,
}
FIGS.update({name: partial(gen_timing, name) for name in (
    't10_w_tx', 't11_w_rm', 't12_w_fault', 't13_w_bag',
    't14_w_snmp', 't15_w_615a', 't16_w_rtc',
)})


def fig(fn):
    FIGS[fn.__name__] = fn
    return fn


if __name__ == '__main__':
    out = sys.argv[1] if len(sys.argv) > 1 else 'v2'
    os.makedirs(out, exist_ok=True)
    names = sys.argv[2:] or list(FIGS)
    for n in names:
        if n in FIGS:
            content = FIGS[n]()
            p = os.path.join(out, f'{n}.svg')
            with open(p, 'w', encoding='utf-8') as f:
                f.write(content)
            print(f'wrote {p}')
        else:
            print(f'unknown figure: {n}')
