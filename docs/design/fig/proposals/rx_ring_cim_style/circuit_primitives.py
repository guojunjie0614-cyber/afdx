from paper_style import *
from matplotlib.patches import Arc, Circle, FancyArrowPatch, PathPatch, Polygon, Rectangle
from matplotlib.path import Path


def canvas(w, h):
    fig = plt.figure(figsize=(w / 25.4, h / 25.4))
    ax = fig.add_axes([0, 0, 1, 1])
    ax.set_xlim(0, w)
    ax.set_ylim(h, 0)
    ax.set_aspect("equal")
    ax.axis("off")
    return fig, ax


def text(ax, x, y, value, size=8.5, color=INK, ha="center", weight="normal", **kwargs):
    return ax.text(x, y, value, fontsize=size, color=color, ha=ha, va="center",
                   fontweight=weight, **kwargs)


def rect(ax, x, y, w, h, fill="white", edge=INK, lw=1.15, ls="-", zorder=2):
    patch = Rectangle((x, y), w, h, facecolor=fill, edgecolor=edge,
                      linewidth=lw, linestyle=ls, zorder=zorder)
    ax.add_patch(patch)
    return patch


def line(ax, pts, color=INK, lw=1.1, dash=None, dashed=False, zorder=4):
    style = dash if dash is not None else ((0, (4, 2.4)) if dashed else "-")
    return ax.plot([p[0] for p in pts], [p[1] for p in pts], color=color,
                   linewidth=lw, linestyle=style, solid_capstyle="butt", zorder=zorder)[0]


def arrow(ax, pts, color=INK, lw=1.15, both=False, dashed=False, ms=9, zorder=5):
    line(ax, pts, color, lw, dashed=dashed, zorder=zorder)
    patch = FancyArrowPatch(pts[-2], pts[-1], arrowstyle="<|-|>" if both else "-|>",
                            mutation_scale=ms, linewidth=0, color=color,
                            shrinkA=0, shrinkB=0, zorder=zorder + 1)
    ax.add_patch(patch)
    return patch


def path_arrow(ax, pts, color=INK, lw=1.25, dashed=False):
    return arrow(ax, pts, color, lw, dashed=dashed, ms=9.5)


def box(ax, x, y, w, h, label=None, color=INK, lw=1.15, dash=False,
        size=8.5, fill="white", ls=None):
    rect(ax, x, y, w, h, fill, color, lw, ls or ((0, (4, 3)) if dash else "-"))
    if label:
        text(ax, x + w / 2, y + h / 2, label, size=size)


def dot(ax, x, y, color=INK):
    ax.add_patch(Circle((x, y), 0.55, facecolor=color, edgecolor=color, zorder=7))


def op(ax, x, y, s, r=2.4, color=INK):
    ax.add_patch(Circle((x, y), r, facecolor="white", edgecolor=color,
                        linewidth=1.15, zorder=5))
    text(ax, x, y, s, size=10, color=color, zorder=6)


def reg(ax, x, y, w=12, h=9, label="D   Q", color=INK):
    rect(ax, x, y, w, h, "white", color, 1.05, zorder=4)
    line(ax, [(x + 1, y + h), (x + 2, y + h - 1.3), (x + 3, y + h)],
         color, 0.9, zorder=5)
    if label:
        text(ax, x + w / 2, y + h * 0.43, label, size=7.5, color=color, zorder=6)


def mux(ax, x, y, w=5, h=13, label="", color=INK, fill="white", lw=1.15):
    ax.add_patch(Polygon([(x, y), (x + w, y + 2), (x + w, y + h - 2), (x, y + h)],
                         closed=True, facecolor=fill, edgecolor=color, linewidth=lw, zorder=4))
    if label:
        text(ax, x + w * 0.43, y + h / 2, label, size=7.8, color=color, weight="bold", zorder=6)


def memory(ax, x, y, w, h, rows=5, cols=6, accent=None, fill="white", label=None):
    rect(ax, x, y, w, h, fill, INK, 1.1)
    for k in range(1, rows):
        line(ax, [(x, y + k * h / rows), (x + w, y + k * h / rows)], GRAY, 0.6)
    for k in range(1, cols):
        line(ax, [(x + k * w / cols, y), (x + k * w / cols, y + h)], GRAY, 0.6)
    if accent is not None:
        rect(ax, x, y + accent * h / rows, w, h / rows, "none", PURPLE, 1.2, zorder=5)
    if label:
        text(ax, x + w / 2, y + h / 2, label, size=7.8, weight="bold",
             bbox=dict(facecolor=fill, edgecolor="none", pad=0.7), zorder=6)


def busmark(ax, x, y, label, color=INK):
    line(ax, [(x - 1, y + 1.8), (x + 1, y - 1.8)], color, 1.0)
    text(ax, x + 2.5, y - 2, label, size=7.5, ha="left", color=color)


def panel(ax, x, y, label, size=9.0, color=INK):
    text(ax, x, y, label, size=size, color=color, weight="bold", ha="left")


def pwl(ax, x, y, w=10, h=8, color=CYAN):
    rect(ax, x, y, w, h, "white", INK, 1.0, zorder=4)
    line(ax, [(x + 1.7, y + h - 1.3), (x + 1.7, y + 1.1)], GRAY, 0.65)
    line(ax, [(x + 1.1, y + h - 1.8), (x + w - 1, y + h - 1.8)], GRAY, 0.65)
    line(ax, [(x + 1.7, y + h - 1.8), (x + w * 0.55, y + h * 0.38),
              (x + w - 1.1, y + 1.3)], color, 1.5)


def and_gate(ax, x, y, w=8, h=7):
    path = Path([(x, y), (x + w * 0.5, y), (x + w, y), (x + w, y + h),
                 (x + w * 0.5, y + h), (x, y + h), (x, y)],
                [Path.MOVETO, Path.LINETO, Path.CURVE4, Path.CURVE4,
                 Path.CURVE4, Path.LINETO, Path.CLOSEPOLY])
    ax.add_patch(PathPatch(path, facecolor="white", edgecolor=INK, linewidth=1.15, zorder=4))


def port(ax, x, y, name, color=INK, w=12, fill="white"):
    h = 3.6
    points = [(x - w / 2, y - h / 2), (x + w / 2 - 1.5, y - h / 2),
              (x + w / 2, y), (x + w / 2 - 1.5, y + h / 2),
              (x - w / 2, y + h / 2)]
    ax.add_patch(Polygon(points, closed=True, facecolor=fill, edgecolor=color,
                         linewidth=1.0, zorder=7))
    text(ax, x - 0.2, y, name, size=7.0, color=color, weight="bold", zorder=8)


def crossover(ax, x, y, color=INK, lw=1.25):
    ax.plot([x - 1.6, x + 1.6], [y, y], color="white", linewidth=lw + 2.5, zorder=8)
    ax.add_patch(Arc((x, y), 3.2, 3.2, theta1=0, theta2=180,
                     color=color, linewidth=lw, zorder=9))


def cim_array(ax, x, y, rows=5, cols=5, cell_w=3.0, cell_h=2.3):
    active_row, active_col = 2, 3
    for row in range(rows):
        for col in range(cols):
            if row == active_row and col == active_col:
                fill = "#D9CBE6"
            elif row == active_row:
                fill = CYAN_FILL
            elif col == active_col:
                fill = PURPLE_FILL
            else:
                fill = "white"
            rect(ax, x + col * cell_w, y + row * cell_h, cell_w, cell_h,
                 fill, INK, 0.55, zorder=3)
    rect(ax, x, y, cols * cell_w, rows * cell_h, "none", INK, 1.15, zorder=4)
    rect(ax, x, y + active_row * cell_h, cols * cell_w, cell_h,
         "none", CYAN, 1.25, zorder=5)
    rect(ax, x + active_col * cell_w, y, cell_w, rows * cell_h,
         "none", PURPLE, 1.25, zorder=5)
