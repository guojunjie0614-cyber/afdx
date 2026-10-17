"""Reconstruct the IC decision diagram as editable SVG and vector PDF.

The two panels show per-frame state updates and independent A/B histories.
Sequence decisions follow rtl/afdx_rx_engine.v and tools/rx_cases.py:icrm.
Run: MPLCONFIGDIR=/tmp/afdx-mpl python3 docs/test/fig/ic_sequence.py
"""

import argparse
from pathlib import Path
import sys

import matplotlib

matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.font_manager import FontProperties
from matplotlib.patches import Polygon, Rectangle


WIDTH, HEIGHT = 1024, 572
WIDTH_MM = 160
SCALE = WIDTH_MM / 25.4 * 72 / WIDTH
PASS_FILL = '#DCEBE1'
DROP_FILL = '#F0A18E'
LINE_PT = 0.8
TOP_SEQUENCE = (7, 8, 10, 13, 14, 14)
NETWORK_SEQUENCES = {'A': (5, 6, 7, 9), 'B': (5, 6, 7, 10)}


def decisions(sequence):
    """IC stores every received sequence number, including rejected ones."""
    previous = None
    result = []
    for sn in sequence:
        next_sn = 1 if previous == 255 else (previous or 0) + 1
        second_sn = 1 if next_sn == 255 else next_sn + 1
        result.append(previous is None or sn == 0 or sn in (next_sn, second_sn))
        previous = sn
    return result


def create_figure():
    matplotlib.rcParams.update({
        'font.family': 'Arial Narrow',
        'svg.fonttype': 'none',
        'pdf.fonttype': 42,
        'font.size': 12,
        'savefig.facecolor': 'white',
    })
    fig = plt.figure(figsize=(WIDTH_MM / 25.4, WIDTH_MM / 25.4 * HEIGHT / WIDTH))
    panels = [fig.add_axes((0, 332 / HEIGHT, 1, 240 / HEIGHT)),
              fig.add_axes((0, 0, 1, 300 / HEIGHT))]
    for ax, bottom, top in ((panels[0], 240, 0), (panels[1], 572, 272)):
        ax.set_xlim(0, WIDTH)
        ax.set_ylim(bottom, top)
        ax.set_axis_off()

    def label(ax, x, y, value, size=29, bold=False, align='center'):
        ax.text(x, y, value, fontsize=size * SCALE, fontweight='bold' if bold else 'normal',
                ha=align, va='baseline', color='black', clip_on=False)

    def box(ax, x, y, width, height, passed, dividers=()):
        ax.add_patch(Rectangle((x, y), width, height,
                              facecolor=PASS_FILL if passed else DROP_FILL,
                              edgecolor='black', linewidth=LINE_PT))
        for offset in dividers:
            ax.plot((x, x + width), (y + offset, y + offset), color='black', linewidth=0.45)

    def arrow(ax, left, right, y):
        # Explicit head geometry keeps short connectors identical across exports.
        ax.plot((left, right - 11), (y, y), color='black', linewidth=LINE_PT)
        ax.add_patch(Polygon(((right, y), (right - 14, y - 7),
                              (right - 11, y), (right - 14, y + 7)),
                             closed=True, facecolor='black', edgecolor='none'))

    top = panels[0]
    label(top, 14, 45, '(a) Sequence decisions — IC ON, RM OFF', 36, True, 'left')
    xs = (29, 198, 366, 535, 710, 881)
    outcomes = decisions(TOP_SEQUENCE)
    for i, (x, sn, passed) in enumerate(zip(xs, TOP_SEQUENCE, outcomes)):
        box(top, x, 93, 126, 133, passed, (44, 89))
        label(top, x + 63, 126, f'SN {sn}')
        label(top, x + 63, 170, 'PASS' if passed else 'DROP', 30, True)
        label(top, x + 63, 214, f'last ← {sn}', 28)
        if i < len(xs) - 1 and i != 3:
            arrow(top, x + 126, xs[i + 1], 160)
    # Keep the reference's open implication arrow after the rejected SN 13.
    top.plot((669, 699), (156, 156), color='black', linewidth=LINE_PT)
    top.plot((669, 699), (164, 164), color='black', linewidth=LINE_PT)
    top.plot((690, 702, 690), (150, 160, 170), color='black', linewidth=LINE_PT)

    bottom = panels[1]
    label(bottom, 14, 313, '(b) Independent A/B states', 36, True, 'left')
    network_xs = (172, 389, 605, 824)
    for network, y in (('A', 353), ('B', 471)):
        label(bottom, 14, y + 57, f'Network {network}', 34, True, 'left')
        sequence = NETWORK_SEQUENCES[network]
        for i, (x, sn, passed) in enumerate(zip(network_xs, sequence, decisions(sequence))):
            last = i == len(sequence) - 1
            box(bottom, x, y, 184, 90, passed, (45,) if last else ())
            label(bottom, x + 92, y + (34 if last else 56),
                  f'SN {sn} / ' + ('PASS' if passed else 'DROP'), 29)
            if last:
                # Native text parts preserve editable subscripts without math font substitution.
                parts = [('last', 28, 0), (network, 19, 5), (f' ← {sn}', 28, 0)]
                renderer = fig.canvas.get_renderer()
                widths = [renderer.get_text_width_height_descent(
                    value, FontProperties(family='Arial Narrow', size=size * SCALE), False)[0]
                    / fig.bbox.width * WIDTH for value, size, _ in parts]
                left = x + 92 - sum(widths) / 2
                for (value, size, offset), width in zip(parts, widths):
                    label(bottom, left, y + 77 + offset, value, size, align='left')
                    left += width
            else:
                arrow(bottom, x + 184, network_xs[i + 1], y + 45)

    fig.canvas.draw()
    return fig


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--qa-tools', type=Path, help='Optional figure QA tools directory')
    parser.add_argument('--qa-output', type=Path, default=Path('/tmp/afdx-ic-alignment.json'))
    args = parser.parse_args()
    folder = Path(__file__).resolve().parent
    for name in ('v2', 'pdf'):
        (folder / name).mkdir(exist_ok=True)
    fig = create_figure()
    if args.qa_tools:
        sys.path.insert(0, str(args.qa_tools))
        from audit_panel_alignment import require_matplotlib_panel_alignment
        require_matplotlib_panel_alignment(
            fig, json_out=args.qa_output, panel_ids=['a', 'b'],
            column_groups=[['a', 'b']], strict=True)
    svg_path = folder / 'v2/t03_ic_sequence.svg'
    fig.savefig(svg_path)
    svg_path.write_text('\n'.join(line.rstrip() for line in svg_path.read_text().splitlines()) + '\n')
    fig.savefig(folder / 'pdf/t03_ic_sequence.pdf')
    fig.savefig(folder / 'v2/t03_ic_sequence.png', dpi=325.12)
    plt.close(fig)


if __name__ == '__main__':
    main()
