"""Generate the default "VLID + application payload" stimulus for sim/run_app.do.

The entry itself needs no Python: this script only writes the committed default
files under sim/vectors/app/.  R120-1 requires >=100 Mbps of injected payload
over a sustained window, so the default keeps one frame per BAG per VL and
16 throughput VLs at 1471 bytes and BAG 1 ms.
"""
import argparse
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "sim" / "vectors" / "app"

THROUGHPUT_VLS = 16
SIZE_VLS = (1, 17, 256, 1024, 1471)
BAG_US = 1000
ROUNDS = 4
WINDOW_US = (1000, 4000)


def blob(message, length):
    return bytes((message * 37 + i * 19 + (message >> (i % 3))) & 0xFF for i in range(length))


def vl_config():
    rows = []
    for index in range(THROUGHPUT_VLS):
        rows.append((0x0100 + index, BAG_US, 1471, 0x1234, 0x4321))
    for index, length in enumerate(SIZE_VLS):
        rows.append((0x0200 + index, BAG_US, max(length, 17), 0x1234, 0x4321))
    return rows


def stimulus():
    messages = []
    # Throughput group: 16 VLs per round, staggered by 60 us; each round is
    # shifted by 13 us so the same (VL, length) pair sees a changing BAG phase.
    for round_number in range(ROUNDS):
        base = round_number * 1000 + round_number * 13
        for index in range(THROUGHPUT_VLS):
            messages.append((base + index * 60, 0x0100 + index, 1471))
    # Size group: minimum, maximum and three middle payload lengths, half a BAG
    # away from the throughput rounds so both groups are concurrently active.
    for round_number in range(ROUNDS):
        base = 500 + round_number * 1000
        for index, length in enumerate(SIZE_VLS):
            messages.append((base + index * 40, 0x0200 + index, length))
    messages.sort(key=lambda item: item[0])
    return messages


def main():
    global OUT
    parser = argparse.ArgumentParser()
    parser.add_argument('--long', action='store_true', help='add fragmentation boundary messages')
    parser.add_argument('--out', type=Path, default=OUT, help='destination for generated files')
    args = parser.parse_args()
    OUT = args.out
    OUT.mkdir(parents=True, exist_ok=True)
    config = vl_config()
    if args.long:
        config.append((0x0300, BAG_US, 1471, 0x1234, 0x4321))
    (OUT / "vl_config.txt").write_text(
        "".join(f"{vlid:04X} {bag} {lmax} {sport} {dport}\n" for vlid, bag, lmax, sport, dport in config),
        encoding="ascii")
    lines = []
    message = 0
    schedule = stimulus()
    if args.long:
        schedule.extend((5000 + i*10000, 0x0300, length) for i, length in enumerate((1464, 1471, 1472, 8192)))
    for due, vlid, length in schedule:
        message += 1
        lines.append(f"{due} {vlid:04X} {blob(message, length).hex()}\n")
    (OUT / "stimulus.txt").write_text("".join(lines), encoding="ascii")
    (OUT / "window.txt").write_text(f"{WINDOW_US[0]} {WINDOW_US[1]}\n", encoding="ascii")
    print(f"vl_config.txt: {len(config)} VLs; stimulus.txt: {len(lines)} messages; "
          f"window {WINDOW_US[0]}..{WINDOW_US[1]} us")


if __name__ == "__main__":
    main()
