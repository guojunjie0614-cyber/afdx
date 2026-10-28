"""Prepare T61 P0/P1 data from existing implementation evidence; never run EDA.

P1 maps old GMII signals by function, not by the reused application-port names.
Electrical/package checks here are static. Native legality and application of
the eventual exported EDC must be verified independently by the coordinator.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import io
import itertools
import json
import re
import statistics
import sys
import xml.etree.ElementTree as ET
from collections import Counter, defaultdict
from pathlib import Path


ROOT = Path("E:/2026_Embedded_FPGA")
R5 = ROOT / "worktrees/active/c3_t60_r5a_p155/out/synth/AFDX_top/20261027_085802_489925/project/AFDX_EndSystem.runs"
T57 = ROOT / "worktrees/active/c3_t57/out/synth/AFDX_top/20261026_111158_306529/project/AFDX_EndSystem.runs"
PAD = ROOT / "setup_pack/bin/shell/Infrastructure/psk_intern/eHiChip6/EQ6HL130/CSG484_H/pad_arrangement.xml"
GMII_SOURCE = {
    "gmii_txd_a": "tx_data", "gmii_txd_b": "tx_data_b",
    "gmii_tx_en_a": "tx_valid", "gmii_tx_en_b": "tx_valid_b",
    "gmii_rxd_a": "rx_data", "gmii_rxd_b": "rx_data_b",
    "gmii_rx_dv_a": "rx_valid", "gmii_rx_dv_b": "rx_valid_b",
}
GROUPS = {
    "application_tx_data": [f"tx_data[{i}]" for i in range(8)],
    "application_rx_data": [f"rx_data[{i}]" for i in range(8)],
    "application_events": [f"ev_app[{i}]" for i in range(3)],
    "application_tx_handshake": ["tx_valid", "tx_ready"],
    "application_rx_handshake": ["rx_valid", "rx_ready"],
}
OUTPUT_PINS = {"combout", "regout", "cout", "sumout", "portadataout", "portbdataout"}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def file_identity(path):
    return {"path": path.as_posix(), "bytes": path.stat().st_size,
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}


def read_place(path):
    ports, clusters = {}, {}
    for line_no, line in enumerate(path.read_text(encoding="utf-8-sig").splitlines(), 1):
        tokens = line.split("#", 1)[0].split()
        if not tokens:
            continue
        if len(tokens) >= 7 and tokens[1] in {"input", "output", "inout"}:
            name, direction, pin, cluster = tokens[:4]
            xyz = [int(x) for x in tokens[4:7]]
            require(name not in ports, f"Duplicate .place port {name}")
            ports[name] = {"port": name, "direction": direction, "pin": pin,
                           "cluster": cluster, "xyz": xyz, "place_line": line_no}
        elif len(tokens) >= 4 and re.fullmatch(r"-?\d+", tokens[1]):
            cluster, xyz = tokens[0], [int(x) for x in tokens[1:4]]
        else:
            continue
        require(cluster not in clusters, f"Duplicate .place cluster {cluster}")
        clusters[cluster] = xyz
    return ports, clusters


def read_clusters(path):
    ports, cells = {}, {}
    root = ET.parse(path).getroot()
    require(root.get("device_name") == "EQ6HL130", "Unexpected cluster device")
    for cluster in root.findall("CLUSTER"):
        attrs = {a.get("name"): a.get("value") for a in cluster.findall("ATTRIB")}
        for child in cluster:
            if child.tag == "ATTRIB":
                continue
            name = child.get("name")
            if name:
                require(name not in cells, f"Duplicate mapped cell {name}")
                cells[name] = cluster.get("name")
            if child.tag == "IO":
                ports[name] = {"cluster": cluster.get("name"),
                               "direction": attrs.get("operation_mode"),
                               "io_standard": attrs.get("IO_STANDARD")}
    return ports, cells


def read_pads(path):
    root = ET.parse(path).getroot()
    require(root.get("name") == "EQ6HL130", "Unexpected pad device")
    require(root.find("PACKAGE").get("name") == "CSG484_H", "Unexpected package")
    pads = {}
    for node in root.iter("PAD_INS"):
        if node.findtext("TYPE") != "UIO":
            continue
        loc = node.find("LOCATION")
        require(loc is not None, "UIO without location")
        pin = node.get("pac_name")
        require(pin not in pads, f"Ambiguous UIO package pin {pin}")
        pads[pin] = {"pin": pin, "xyz": [int(loc.get(k)) for k in ("loc_x", "loc_y", "loc_s")],
                     "bank": int(node.findtext("BANK")), "pad_type": "UIO",
                     "pad_attribute": node.get("attr"), "pin_function": node.findtext("PIN_FUNCTION") or "",
                     "vref_capable": node.get("vref") == "true"}
    return pads


def read_vqm(path, wanted, cell_cluster, placements):
    text = path.read_text(encoding="utf-8-sig")
    ports = {}
    for direction, msb, lsb, name in re.findall(
            r"^(input|output|inout)\s+(?:\[(\d+):(\d+)\]\s*)?(\w+)\s*;", text, re.M):
        names = [f"{name}[{i}]" for i in range(int(lsb), int(msb) + 1)] if msb else [name]
        for port in names:
            ports[port] = direction
    aliases = dict((a.strip(), b.strip()) for a, b in re.findall(r"^assign\s+(.+?)\s*=\s*(.+?)\s*;", text, re.M))

    def resolve(name):
        seen = set()
        while name in aliases:
            require(name not in seen, f"Alias cycle at {name}")
            seen.add(name)
            name = aliases[name]
        return name

    nets = defaultdict(list)
    for port in wanted:
        nets[resolve(port)].append(port)
    consumers = {port: {"resolved_net": resolve(port), "connections": []} for port in wanted}
    primitive = re.compile(r"^(stratix_\w+)\s+(\\\S+|\w+)\s*\((.*?)\);", re.M | re.S)
    for match in primitive.finditer(text):
        cell_type, cell, body = match.groups()
        for terminal, expression in re.findall(r"\.(\w+)\((.*?)\)", body, re.S):
            expression = expression.strip()
            for port in nets.get(expression, []):
                is_driver = terminal in OUTPUT_PINS
                if (ports[port] == "output") != is_driver:
                    continue
                require(cell in cell_cluster, f"Connected cell absent from packed clusters: {cell}")
                cluster = cell_cluster[cell]
                require(cluster in placements, f"Cluster not placed: {cluster}")
                consumers[port]["connections"].append({"cell": cell, "cell_type": cell_type,
                    "terminal": terminal, "role": "driver" if is_driver else "consumer",
                    "cluster": cluster, "xyz": placements[cluster]})
    for port, entry in consumers.items():
        connections = entry["connections"]
        require(bool(connections) or port == "rx_ready", f"No actual connectivity for {port}")
        require(port != "rx_ready" or not connections, "rx_ready unexpectedly gained a consumer")
        entry["connection_count"] = len(connections)
        entry["unused"] = not connections
        entry["centroid_xy"] = ([statistics.mean(c["xyz"][i] for c in connections) for i in (0, 1)]
                                 if connections else None)
        entry["note"] = ("Unused in frozen VQM; placed adjacent to RX group, no timing consumer inferred."
                         if not connections else "Direct frozen-VQM primitive connectivity at r5 A placement.")
    return ports, consumers


def old_source(port):
    base = port.split("[", 1)[0]
    if base in GMII_SOURCE:
        return GMII_SOURCE[base] + port[len(base):]
    if base.startswith("cfg_") or base in {"clk", "reset", "ev_tx", "ev_a", "ev_b", "ev_rm_drop", "ev_deliver"}:
        return port
    return None


def edge(pad):
    x, y, _ = pad["xyz"]
    if x == 0:
        return "left", y
    if x == 165:
        return "right", y
    if y == 0:
        return "bottom", x
    if y == 101:
        return "top", x
    raise ValueError(f"UIO is not on expected device perimeter: {pad}")


def select_groups(pads, inherited, consumers):
    used = {r["pin"] for r in inherited}
    pools = defaultdict(list)
    for pad in pads.values():
        if pad["pin"] in used or pad["pad_attribute"] != "NORMAL":
            continue
        side, coordinate = edge(pad)
        pools[(pad["bank"], side)].append(pad)
    choices = {}
    group_centres = {}
    for group, ports in GROUPS.items():
        centres = [consumers[p]["centroid_xy"] for p in ports if consumers[p]["centroid_xy"] is not None]
        centre = [statistics.mean(c[i] for c in centres) for i in (0, 1)]
        group_centres[group] = centre
        candidates = []
        for (bank, side), available in sorted(pools.items()):
            ordered = sorted(available, key=lambda p: (edge(p)[1], p["xyz"][2], p["pin"]))
            for start in range(len(ordered) - len(ports) + 1):
                window = ordered[start:start + len(ports)]
                span = edge(window[-1])[1] - edge(window[0])[1]
                mean_distance = statistics.mean(abs(p["xyz"][0] - centre[0]) + abs(p["xyz"][1] - centre[1]) for p in window)
                # Compactness is charged once per pad as a soft placement prior.
                score = len(ports) * (mean_distance + span / 2)
                candidates.append({"bank": bank, "edge": side, "pads": window,
                                   "span": span, "mean_distance": mean_distance, "score": score})
        require(candidates, f"No same-bank perimeter window for {group}")
        choices[group] = sorted(candidates, key=lambda c: (c["score"], c["bank"], c["edge"], [p["pin"] for p in c["pads"]]))

    names = list(GROUPS)
    remaining_minimum = [0.0] * (len(names) + 1)
    for index in range(len(names) - 1, -1, -1):
        remaining_minimum[index] = remaining_minimum[index + 1] + choices[names[index]][0]["score"]
    best, best_key = None, None
    def search(index, occupied, selected, score):
        nonlocal best, best_key
        if index == len(names):
            key = (score, tuple(tuple(p["pin"] for p in c["pads"]) for c in selected))
            if best_key is None or key < best_key:
                best, best_key = list(selected), key
            return
        for candidate in choices[names[index]]:
            next_score = score + candidate["score"]
            if best_key is not None and next_score + remaining_minimum[index + 1] > best_key[0]:
                break
            pins = {p["pin"] for p in candidate["pads"]}
            if not pins.intersection(occupied):
                search(index + 1, occupied | pins, selected + [candidate], next_score)
    search(0, set(), [], 0.0)
    require(best is not None, "No disjoint group-window combination")
    assignments, evidence = {}, {}
    for group, selected in zip(names, best):
        ports, window = GROUPS[group], selected["pads"]
        # Preserve bit order as perimeter order; enumerate direction to select the
        # better of two orientations without scattering a bus across the die.
        def assignment_cost(order):
            return sum(abs(pad["xyz"][0] - c[0]) + abs(pad["xyz"][1] - c[1])
                       for port, pad in zip(ports, order)
                       for c in [consumers[port]["centroid_xy"] or group_centres[group]])
        alternatives = [window, list(reversed(window))]
        selected_order = min(alternatives, key=lambda order: (assignment_cost(order), [p["pin"] for p in order]))
        assignments.update(zip(ports, selected_order))
        evidence[group] = {k: v for k, v in selected.items() if k != "pads"}
        evidence[group].update({"ports": ports, "pins": [p["pin"] for p in selected_order],
            "target_centroid_xy": group_centres[group], "candidate_windows": len(choices[group]),
            "per_port_manhattan_sum": assignment_cost(selected_order)})
    return assignments, evidence


def row(port, mapped, pad, semantic_source, source_port, source_place):
    return {"port": port, "direction": mapped["direction"], "semantic_source": semantic_source,
            "source_port": source_port, "source_place": source_place, "pin": pad["pin"],
            "bank": pad["bank"], "io_standard": mapped["io_standard"], "xyz": pad["xyz"],
            "cluster": mapped["cluster"], "pad_type": pad["pad_type"],
            "pad_attribute": pad["pad_attribute"], "pin_function": pad["pin_function"],
            "vref_capable": pad["vref_capable"]}


def validate_rows(rows, expected_ports, pads):
    require(len(rows) == 172, "Expected all 172 pins")
    require({r["port"] for r in rows} == set(expected_ports), "Port coverage mismatch")
    for key in ("port", "pin"):
        require(len({r[key] for r in rows}) == len(rows), f"Duplicate {key}")
    require(len({tuple(r["xyz"]) for r in rows}) == len(rows), "Two package pins share one pad site")
    for r in rows:
        require(r["direction"] == expected_ports[r["port"]], f"Direction mismatch: {r['port']}")
        require(r["pin"] in pads and r["xyz"] == pads[r["pin"]]["xyz"], f"Package/coordinate mismatch: {r['port']}")
        require(r["io_standard"] == "3.3V LVTTL", f"Unverified electrical standard: {r['port']}")
        require(r["pad_attribute"] in {"NORMAL", "GCLK"}, f"Invalid pad: {r['pin']}")
    clk = next(r for r in rows if r["port"] == "clk")
    require(clk["pin"] == "J1" and clk["xyz"] == [0, 46, 2] and clk["pad_attribute"] == "GCLK", "Clock pad changed")
    return {"static_pass": True, "port_count": len(rows), "unique_pin_count": len(rows),
            "bank_counts": dict(sorted(Counter(str(r["bank"]) for r in rows).items())),
            "io_standard": "3.3V LVTTL", "clock_pin": "J1", "native_legality": None,
            "board_electrical_validation": None}


def prepare():
    p0_place, p0_locations = read_place(R5 / "imple_1/AFDX_EndSystem.place")
    old_place, _ = read_place(T57 / "imple_1/AFDX_EndSystem.place")
    mapped, cells = read_clusters(R5 / "synth_1/AFDX_EndSystem_cluster.xml")
    old_mapped, _ = read_clusters(T57 / "synth_1/AFDX_EndSystem_cluster.xml")
    pads = read_pads(PAD)
    wanted = list(itertools.chain.from_iterable(GROUPS.values()))
    expected_ports, consumers = read_vqm(R5 / "synth_1/AFDX_EndSystem.vqm", wanted, cells, p0_locations)
    require(set(mapped) == set(p0_place) == set(expected_ports), "Mapped I/O, VQM and .place disagree")
    p0, inherited, new = [], [], []
    for port in sorted(expected_ports):
        placed, current = p0_place[port], mapped[port]
        pad = pads[placed["pin"]]
        require(current["direction"] == placed["direction"], f"Packed/.place direction mismatch: {port}")
        require(current["cluster"] == placed["cluster"], f"Packed/.place cluster mismatch: {port}")
        require(pad["xyz"] == placed["xyz"], f"P0 not at package pad location: {port}")
        p0.append(row(port, current, pad, "r5 A P1.55 routed location", port, "r5a"))
        source = old_source(port)
        if source is None:
            new.append(port)
            continue
        require(source in old_place, f"Missing semantic source: {source}")
        require(old_place[source]["direction"] == current["direction"], f"Semantic direction mismatch: {port}")
        require(old_mapped[source]["io_standard"] == current["io_standard"], f"Semantic electrical mismatch: {port}")
        old_pad = pads[old_place[source]["pin"]]
        require(old_place[source]["xyz"] == old_pad["xyz"], f"T57 package/coordinate mismatch: {source}")
        inherited.append(row(port, current, old_pad, "T57 same function", source, "t57"))
    require(len(inherited) == 149 and sorted(new) == sorted(wanted), "Expected 149 inherited and 23 new signals")
    inherited_pins = {r["pin"]: r["port"] for r in inherited}
    collisions = [{"port": port, "p0_pin": p0_place[port]["pin"], "inherited_port": inherited_pins[p0_place[port]["pin"]]}
                  for port in new if p0_place[port]["pin"] in inherited_pins]
    require(len(collisions) == 18, "Expected 18 collisions when retaining P0 for new signals")
    assignments, group_evidence = select_groups(pads, inherited, consumers)
    p1 = sorted(inherited + [row(port, mapped[port], assignments[port], "New application signal; grouped near r5 A logic", None, None)
                            for port in new], key=lambda r: r["port"])
    checks = {"P0": validate_rows(p0, expected_ports, pads), "P1": validate_rows(p1, expected_ports, pads)}
    inputs = {"r5_place": R5 / "imple_1/AFDX_EndSystem.place", "r5_cluster": R5 / "synth_1/AFDX_EndSystem_cluster.xml",
              "r5_vqm": R5 / "synth_1/AFDX_EndSystem.vqm", "t57_place": T57 / "imple_1/AFDX_EndSystem.place",
              "t57_cluster": T57 / "synth_1/AFDX_EndSystem_cluster.xml", "pad_xml": PAD}
    summary = {"schema_version": 1, "inputs": {k: file_identity(v) for k, v in inputs.items()},
        "checks": checks, "inherited_port_count": 149, "new_port_count": 23,
        "inherited_moved_from_p0": sum(r["pin"] != p0_place[r["port"]]["pin"] for r in inherited),
        "p0_retention_collisions": collisions, "new_signal_groups": group_evidence,
        "selection_rule": "Keep each 8-bit data bus, each 2-bit handshake group and the 3-bit event group contiguous in the available-pad order. Enumerate same-bank/same-edge windows among unused NORMAL UIO pads; minimize total (group-size * (mean Manhattan distance to equal-port-weight centroid + half window span)) over disjoint windows. Preserve bus order, choose lower-distance orientation. No GCLK consumed by new ports.",
        "native_legality": None,
        "limitations": ["Native I/O Planning syntax/export and native legality are not checked by this data-preparation script.",
            "Package XML identifies UIO and banks; board rail voltage and board connectivity are not available here.",
            "All current packed I/O specify 3.3V LVTTL; this script preserves that standard.",
            "rx_ready has no load in frozen VQM and is only grouped with application RX signals.",
            "Manhattan distances use the existing r5 A placement and are placement priors, not predicted routed delay."]}
    return {"pins_P0.json": {"schema_version": 1, "plan": "P0", "rows": p0, "validation": checks["P0"]},
            "pins_P1.json": {"schema_version": 1, "plan": "P1", "rows": p1, "validation": checks["P1"]},
            "pins_consumers.json": {"schema_version": 1, "ports": consumers},
            "pins_summary.json": summary}


def artifacts():
    data = prepare()
    text = {name: json.dumps(value, indent=2, ensure_ascii=False) + "\n" for name, value in data.items()}
    for plan in ("P0", "P1"):
        rows = data[f"pins_{plan}.json"]["rows"]
        output = io.StringIO(newline="")
        fields = ["port", "direction", "semantic_source", "source_port", "source_place", "pin", "bank",
                  "io_standard", "x", "y", "s", "cluster", "pad_type", "pad_attribute", "pin_function", "vref_capable"]
        writer = csv.DictWriter(output, fieldnames=fields, lineterminator="\n")
        writer.writeheader()
        for r in rows:
            record = {k: v for k, v in r.items() if k != "xyz"}
            record.update(zip(("x", "y", "s"), r["xyz"]))
            writer.writerow(record)
        text[f"pins_{plan}.csv"] = output.getvalue()
    return text


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, default=Path(__file__).resolve().parents[1] / "out/t61/preparation")
    parser.add_argument("--stdout-bundle", action="store_true", help="Print all file contents as JSON; write no files.")
    args = parser.parse_args()
    result = artifacts()
    if args.stdout_bundle:
        sys.stdout.reconfigure(encoding="utf-8")
        print(json.dumps(result, ensure_ascii=False))
        return
    args.out.mkdir(parents=True, exist_ok=True)
    for name, contents in result.items():
        (args.out / name).write_text(contents, encoding="utf-8", newline="\n")
    print(json.dumps({"outputs": [str(args.out / name) for name in result], "static_pass": True,
                      "native_legality": None}, ensure_ascii=False))


if __name__ == "__main__":
    main()
