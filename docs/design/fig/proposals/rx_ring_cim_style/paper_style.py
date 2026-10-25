import os
from pathlib import Path

os.environ.setdefault("MPLCONFIGDIR", "/tmp/cim_rc_mpl")
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

ROOT = Path(__file__).resolve().parents[2]
OUT = Path(__file__).resolve().parent

INK = "#202124"
GRAY = "#6F6F6F"
MID = "#B8B8B8"
LIGHT = "#F1F1F1"
LAVENDER = "#F4F1F6"
PEACH = "#FCE7D5"
CYAN = "#008AA6"
CYAN_DARK = "#006B82"
CYAN_FILL = "#DDF1F4"
PURPLE = "#7A4E9E"
PURPLE_DARK = "#5D387B"
PURPLE_FILL = "#ECE3F2"
GREEN = "#739F45"
GREEN_DARK = "#557D2D"
GREEN_FILL = "#EAF2DF"
RED = "#C7433C"
RED_FILL = "#F9E5DF"
BLUE = "#008BC2"
BLUE_DARK = "#00658C"
BLUE_FILL = "#DCEFF7"
BAR_RED = "#D63F38"
BAR_RED_DARK = "#A92F2C"
ORANGE = RED
ORANGE_FILL = RED_FILL
LW = 1.15

matplotlib.rcParams.update({
    "font.family": "sans-serif",
    "font.sans-serif": ["Arial", "Helvetica", "DejaVu Sans"],
    "font.size": 8.5,
    "axes.labelsize": 8.5,
    "xtick.labelsize": 8.0,
    "ytick.labelsize": 8.0,
    "legend.fontsize": 8.0,
    "mathtext.fontset": "stix",
    "axes.linewidth": 1.1,
    "lines.linewidth": 1.2,
    "xtick.major.width": 1.0,
    "ytick.major.width": 1.0,
    "svg.fonttype": "none",
    "pdf.fonttype": 42,
    "savefig.facecolor": "white",
    "figure.facecolor": "white",
    "axes.unicode_minus": False,
})


def save(fig, stem):
    for extension in ("svg", "pdf", "png"):
        fig.savefig(OUT / f"{stem}.{extension}", dpi=300, facecolor="white")
    print(stem)
    return fig
