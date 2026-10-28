"""Derive the fixed T61 region from the frozen r5 A physical/timing evidence.

This program reads existing evidence only and emits region_manifest.json.
It does not invoke eLinx, modify source evidence, or assert native legality.
"""
from __future__ import annotations

import argparse
import collections
import hashlib
import json
import re
import sqlite3
import statistics
import xml.etree.ElementTree as ET
from pathlib import Path


SOURCE_ROOT = Path("E:/2026_Embedded_FPGA/worktrees/active/c3_t60_r5a_p155")
SYNTH_REL = Path("out/synth/AFDX_top/20261027_085802_489925/project/AFDX_EndSystem.runs")
TIMING_REL = Path("out/timing/AFDX_top_full_timing/20261027_091407_901817/full_timing.tan.pb")
DEVICE_ROOT = Path("E:/2026_Embedded_FPGA/setup_pack/bin/shell/Infrastructure/psk_intern/eHiChip6")
BOUNDS = (22, 60, 41, 75)
PATH_SLACK_LIMIT_PS = 500
TARGETS = (
    "es|rx_core|map_bank[18].write_request~I",
    "es|rx_core|map_bank[19].write_request~I",
    "es|rx_core|engine|deliver_allowed~I",
)
STATE_WD = re.compile(r"^es\|rx_core\|engine\|state_wd\[\d+\]~I$")
BANK_MEMBER = re.compile(r"(?:^|\|)map_bank\[(18|19)\]\.")
LOGIC_TYPES = ("BLK", "M4KLAB", "DSPLAB")


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def normal_name(name: str) -> str:
    """Match a VQM/cluster name to STA's type-prefix-free instance name."""
    return "|".join(part.split(":", 1)[-1] for part in name.lstrip("\\").split("|"))


def endpoint_cell(name: str) -> str:
    return normal_name(name.split("|ff/", 1)[0])


def attributes(element: ET.Element) -> dict[str, str]:
    return {a.attrib["name"]: a.attrib["value"] for a in element.findall("ATTRIB")}


def parse_place(path: Path) -> dict[str, tuple[int, int, int]]:
    result = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        words = line.split()
        if len(words) < 4:
            continue
        try:
            if words[1] in ("input", "output", "inout"):
                name, xyz = words[3], tuple(map(int, words[4:7]))
            else:
                name, xyz = words[0], tuple(map(int, words[1:4]))
        except ValueError:
            continue
        if len(xyz) != 3:
            raise ValueError(f"Incomplete placement: {line}")
        if name in result:
            raise ValueError(f"Duplicate placement: {name}")
        result[name] = xyz
    return result


def coordinate_values(text: str) -> list[int]:
    values = []
    for piece in text.split(","):
        if not piece:
            continue
        if ":" in piece:
            first, last = map(int, piece.split(":"))
            values.extend(range(first, last + 1))
        else:
            values.append(int(piece))
    return values


def device_tiles(path: Path) -> dict[str, set[tuple[int, int]]]:
    result = {}
    for tile in ET.parse(path).getroot().findall("TILE"):
        positions = set()
        for instance in tile.findall("TILE_INS"):
            positions.update(
                (x, y)
                for x in coordinate_values(instance.attrib["loc_x"])
                for y in coordinate_values(instance.attrib["loc_y"])
            )
        result[tile.attrib["name"]] = positions
    return result


def in_region(x: int, y: int, bounds=BOUNDS) -> bool:
    return bounds[0] <= x <= bounds[2] and bounds[1] <= y <= bounds[3]


def position_summary(positions: list[tuple[int, int, int]]) -> dict:
    if not positions:
        return {}
    return {
        "count": len(positions),
        "min_xy": [min(p[a] for p in positions) for a in (0, 1)],
        "max_xy": [max(p[a] for p in positions) for a in (0, 1)],
        "median_xy": [statistics.median(p[a] for p in positions) for a in (0, 1)],
        "mean_xy": [statistics.mean(p[a] for p in positions) for a in (0, 1)],
    }


def selected_paths(database: Path) -> tuple[list[dict], dict[str, list[int]]]:
    db = sqlite3.connect(database.resolve().as_uri() + "?mode=ro", uri=True)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA query_only=ON")
    db.execute("PRAGMA temp_store=MEMORY")
    try:
        paths = []
        for row in db.execute(
            "SELECT * FROM elinx_intra_clock_longest_sync_path_report "
            "WHERE slack < ? ORDER BY slack, path_id",
            (PATH_SLACK_LIMIT_PS,),
        ):
            endpoint = endpoint_cell(row["to_cell_name"])
            if endpoint in TARGETS or STATE_WD.fullmatch(endpoint):
                paths.append(dict(row))
        if not paths:
            raise ValueError("No target paths found; refusing an empty region.")
        path_keys = {
            (p["clock_scoped_path_reports_x"], p["clock_scoped_path_reports_y"], p["path_id"]): p
            for p in paths
        }
        ids = sorted({p["path_id"] for p in paths})
        placeholders = ",".join("?" for _ in ids)
        cells_by_path = collections.defaultdict(list)
        for row in db.execute(
            "SELECT * FROM elinx_cell_property "
            f"WHERE path_type=0 AND sync_type=0 AND path_id IN ({placeholders}) "
            "ORDER BY cell_id",
            ids,
        ):
            key = (row["clock_scoped_path_reports_x"], row["clock_scoped_path_reports_y"], row["path_id"])
            if key in path_keys:
                cells_by_path[key].append(dict(row))
        nodes_by_path = collections.defaultdict(list)
        for row in db.execute(
            "SELECT * FROM elinx_data_path_node_detail "
            f"WHERE path_type=0 AND sync_type=0 AND path_id IN ({placeholders}) "
            "ORDER BY path_node_detail_id",
            ids,
        ):
            key = (row["clock_scoped_path_reports_x"], row["clock_scoped_path_reports_y"], row["path_id"])
            if key in path_keys:
                nodes_by_path[key].append(dict(row))
        cell_paths = collections.defaultdict(set)
        for key, path in path_keys.items():
            cells = cells_by_path[key]
            if not cells:
                raise ValueError(f"No setup cell details for path {key}")
            if normal_name(cells[0]["cell_name"]) != endpoint_cell(path["from_cell_name"]):
                raise ValueError(f"Source mismatch for path {key}")
            if normal_name(cells[-1]["cell_name"]) != endpoint_cell(path["to_cell_name"]):
                raise ValueError(f"Sink mismatch for path {key}")
            path["cell_details"] = cells
            path["node_details"] = nodes_by_path[key]
            for cell in cells:
                cell_paths[normal_name(cell["cell_name"])].add(path["path_id"])
        return paths, {k: sorted(v) for k, v in sorted(cell_paths.items())}
    finally:
        db.close()


def derive(source_root: Path, device_root: Path) -> dict:
    project = source_root / SYNTH_REL
    inputs = {
        "cluster_xml": project / "synth_1/AFDX_EndSystem_cluster.xml",
        "vqm": project / "synth_1/AFDX_EndSystem.vqm",
        "placement": project / "imple_1/AFDX_EndSystem.place",
        "full_timing_database": source_root / TIMING_REL,
        "core_arrangement": device_root / "EQ6HL130/core_arrangement.xml",
    }
    places = parse_place(inputs["placement"])
    root = ET.parse(inputs["cluster_xml"]).getroot()
    clusters = {c.attrib["name"]: c for c in root.findall("CLUSTER")}
    logical_index = {}
    for name, cluster in clusters.items():
        for molecule in cluster.findall("MOLECULE"):
            key = normal_name(molecule.attrib["name"])
            if key in logical_index:
                raise ValueError(f"Ambiguous normalized molecule name: {key}")
            logical_index[key] = (name, molecule)
    vqm_names = {
        m.group(2): m.group(1)
        for m in re.finditer(
            r"(?m)^(stratix_\w+)\s+(\S+)\s*\(",
            inputs["vqm"].read_text(encoding="utf-8"),
        )
    }
    paths, cell_paths = selected_paths(inputs["full_timing_database"])
    reasons = collections.defaultdict(set)
    seed_molecules = set()
    critical_clusters = set()
    for key, ids in cell_paths.items():
        if key not in logical_index:
            raise ValueError(f"STA cell not found in packed cluster XML: {key}")
        cluster_name, _ = logical_index[key]
        reasons[cluster_name].add("setup_path:" + ",".join(map(str, ids)))
        critical_clusters.add(cluster_name)
        seed_molecules.add(key)
    for key, (cluster_name, molecule) in logical_index.items():
        if key.startswith("es|rx_core|") and BANK_MEMBER.search(key):
            reasons[cluster_name].add("bank_18_19_RAM_or_local_pipeline")
            seed_molecules.add(key)
    # Carry chains can span multiple clusters. Expand their entire packed chain.
    selected_chains = {
        (clusters[name].attrib["type"], attributes(clusters[name]).get("chainID"))
        for name in reasons
        if attributes(clusters[name]).get("chainID", "-1") != "-1"
    }
    for name, cluster in clusters.items():
        key = (cluster.attrib["type"], attributes(cluster).get("chainID"))
        if key in selected_chains:
            reasons[name].add("complete_carry_chain:" + str(key[1]))

    members = []
    type_counts = collections.Counter()
    mode_counts = collections.Counter()
    module_counts = collections.Counter()
    missing_vqm = []
    for name in sorted(reasons):
        cluster = clusters[name]
        if name not in places:
            raise ValueError(f"Selected cluster has no original placement: {name}")
        typ = cluster.attrib["type"]
        if typ not in ("glj_blk_hc", "wb_m4kblk_hc"):
            raise ValueError(f"Unexpected resource in region: {name}: {typ}")
        type_counts[typ] += 1
        children = []
        for molecule in cluster.findall("MOLECULE"):
            full_name = molecule.attrib["name"]
            key = normal_name(full_name)
            attr = attributes(molecule)
            kind = molecule.attrib["type"]
            if vqm_names.get(full_name) != kind:
                missing_vqm.append({"name": full_name, "expected_type": kind, "vqm_type": vqm_names.get(full_name)})
            if kind == "stratix_lcell":
                mode_counts[attr.get("output_mode", "unknown")] += 1
            module = "|".join(key.split("|")[:-1])
            module_counts[module] += 1
            children.append({
                "full_name": full_name,
                "timing_name": "\\" + key,
                "native_cell_name_candidate": full_name,
                "native_name_verified": False,
                "type": kind,
                "output_mode": attr.get("output_mode"),
                "loc_s": int(molecule.attrib["loc_s"]),
                "original_location": [places[name][0], places[name][1], int(molecule.attrib["loc_s"])],
                "seed": key in seed_molecules,
                "setup_path_ids": cell_paths.get(key, []),
                "vqm_declaration_matched": vqm_names.get(full_name) == kind,
            })
        members.append({
            "cluster_name": name,
            "cluster_type": typ,
            "native_cluster_name_candidate": name,
            "native_name_verified": False,
            "original_location": list(places[name]),
            "reasons": sorted(reasons[name]),
            "chain_id": attributes(cluster).get("chainID"),
            "chain_offset": attributes(cluster).get("offsetInChain"),
            "place_module": attributes(cluster).get("PLACE_MODULE"),
            "children": children,
        })
    if missing_vqm:
        raise ValueError(f"Selected packed molecules do not match VQM: {missing_vqm}")
    tiles = device_tiles(inputs["core_arrangement"])
    core_capacity = {
        name: sorted([x, y] for x, y in tiles[name] if in_region(x, y))
        for name in LOGIC_TYPES
    }
    # M4K anchors occupy x and x+1. Never count a RAM cut by the rectangle edge.
    m4k_sites = sorted(
        [x, y] for x, y in tiles["M4K"]
        if in_region(x, y) and in_region(x + 1, y)
    )
    logic_demand, ram_demand = type_counts["glj_blk_hc"], type_counts["wb_m4kblk_hc"]
    conservative_logic = len(core_capacity["BLK"])
    if conservative_logic < logic_demand * 2 or len(m4k_sites) < ram_demand * 2:
        raise ValueError("Region lacks the selected >=50% geometric resource reserve.")
    original_shared_tiles = collections.defaultdict(list)
    selected_set = set(reasons)
    for name, xyz in places.items():
        if name in clusters and clusters[name].attrib["type"] in ("glj_blk_hc", "wb_m4kblk_hc"):
            original_shared_tiles[xyz[:2]].append(name)
    cross_region_shared = [
        {"xy": list(xy), "clusters": names}
        for xy, names in original_shared_tiles.items()
        if len(names) > 1 and selected_set.intersection(names) and not selected_set.issuperset(names)
    ]
    if cross_region_shared:
        raise ValueError(f"Original shared tiles were not completely selected: {cross_region_shared}")
    chains = []
    for typ, chain_id in sorted(selected_chains):
        chain_names = [
            name for name, c in clusters.items()
            if c.attrib["type"] == typ and attributes(c).get("chainID") == chain_id
        ]
        chains.append({
            "type": typ, "chain_id": chain_id,
            "clusters": sorted(chain_names),
            "fully_included": selected_set.issuperset(chain_names),
            "max_chain_length": len(chain_names),
        })
    rx_total = sum(
        any(normal_name(m.attrib["name"]).startswith("es|rx_core|") for m in c.findall("MOLECULE"))
        for c in clusters.values()
    )
    occupied_original = collections.Counter()
    for name, xyz in places.items():
        if name in clusters and in_region(xyz[0], xyz[1]):
            occupied_original[clusters[name].attrib["type"]] += 1

    return {
        "schema_version": 1,
        "purpose": "T61 preparation 4: one fixed region R, identical in E5 and E6",
        "design_baseline": "18d1606cc86930e76332120131c55fa982e0e018",
        "native_legality_checked": False,
        "native_legality_status": "pending coordinator validation; static evidence is not native acceptance",
        "inputs": {k: {"path": p.as_posix(), "size_bytes": p.stat().st_size, "sha256": sha256(p)} for k, p in inputs.items()},
        "selection": {
            "bank_indices": [18, 19],
            "bank_policy": "All logical molecules belonging to the two banks, including RAM, request/address/data registers and clear/select logic.",
            "path_policy": "All reported setup paths with slack <500 ps into bank18/19 write_request, engine deliver_allowed, or engine state_wd; include every source/intermediate/sink cell.",
            "path_slack_limit_ps": PATH_SLACK_LIMIT_PS,
            "path_count": len(paths),
            "negative_path_count": sum(p["slack"] < 0 for p in paths),
            "distinct_seed_path_cells": len(cell_paths),
            "seed_molecule_count": len(seed_molecules),
            "cluster_closure": "Include all molecules of every selected packed cluster, plus complete carry chains.",
            "whole_rx_core_selected": False,
            "rx_clusters_in_source": rx_total,
            "selected_cluster_count": len(members),
            "critical_cluster_count": len(critical_clusters),
        },
        "bounds": {"x_min": BOUNDS[0], "y_min": BOUNDS[1], "x_max": BOUNDS[2], "y_max": BOUNDS[3], "inclusive": True},
        "bounds_rationale": [
            "Critical-control clusters have median location (34,68); keep this neighborhood as the anchor instead of preserving the remote RAM column at x10, y2..29.",
            "X22..41 covers the neighboring M4K columns x22 and x38 including each two-column footprint.",
            "Y60..75 offers 32 M4K sites for 14 packed M4K blocks and limits the selected cone to a 20 by 16 coordinate rectangle.",
            "Count only BLK for the guaranteed geometric logic reserve; M4KLAB/DSPLAB are separately listed and are not needed to make capacity pass.",
            "No placement sweep or timing experiment selected these bounds. The bounds are one fixed diagnostic choice, not a proven timing optimum.",
        ],
        "constraint_intent": {
            "pblock_name": "t61_rx_request_R",
            "constraint_strength": "All 52 selected packed clusters and every constituent molecule must be inside the same hard rectangle.",
            "identical_for": ["E5", "E6"],
            "native_entry": "Coordinator must validate the exact accepted cell/cluster names, then use one complete naming set. Do not silently skip nonmatching members.",
            "native_member_name_candidate_count": sum(len(m["children"]) for m in members),
            "native_cluster_name_candidate_count": len(members),
            "native_name_formats": ["cluster_name", "children[].full_name", "children[].timing_name"],
            "wildcards_used": False,
        },
        "resources": {
            "packed_logic_clusters": logic_demand,
            "packed_M4K_clusters": ram_demand,
            "logical_cell_count": sum(len(m["children"]) for m in members),
            "logical_lcell_count": sum(mode_counts.values()),
            "logical_lcell_modes": dict(sorted(mode_counts.items())),
            "registered_lcell_count": sum(v for k, v in mode_counts.items() if k != "comb_only"),
            "logical_ram_molecules": sum(c["type"] == "stratix_ram_block" for m in members for c in m["children"]),
            "capacity_BLK_only": conservative_logic,
            "reserve_BLK_only": conservative_logic - logic_demand,
            "occupancy_BLK_only": logic_demand / conservative_logic,
            "additional_M4KLAB_sites": len(core_capacity["M4KLAB"]),
            "additional_DSPLAB_sites": len(core_capacity["DSPLAB"]),
            "capacity_M4K_full_footprint": len(m4k_sites),
            "reserve_M4K": len(m4k_sites) - ram_demand,
            "occupancy_M4K": ram_demand / len(m4k_sites),
            "native_capacity_verified": False,
            "capacity_warning": "Geometric capacity is not a routing guarantee or a promise that nonmembers vacate this rectangle.",
        },
        "macro_coverage": {
            "M4K_footprint": [2, 1],
            "M4K_capacity_policy": "Count anchors only if both x and x+1 are inside the inclusive rectangle.",
            "M4K_columns": sorted({p[0] for p in m4k_sites}),
            "selected_carry_chains": chains,
            "original_cross_region_shared_tiles": cross_region_shared,
            "native_macro_and_shared_tile_check": "pending",
        },
        "original_placement": {
            "all_selected": position_summary([places[n] for n in reasons]),
            "logic_selected": position_summary([places[n] for n in reasons if clusters[n].attrib["type"] == "glj_blk_hc"]),
            "M4K_selected": position_summary([places[n] for n in reasons if clusters[n].attrib["type"] == "wb_m4kblk_hc"]),
            "critical_clusters": position_summary([places[n] for n in critical_clusters]),
            "original_occupancy_inside_R": dict(sorted(occupied_original.items())),
            "selected_clusters_already_inside_R": sum(in_region(*places[n][:2]) for n in reasons),
        },
        "module_molecule_counts": dict(sorted(module_counts.items())),
        "capacity_sites": {**core_capacity, "M4K_full_footprint_anchors": m4k_sites},
        "selected_setup_paths": paths,
        "members": members,
        "static_checks": {
            "all_STA_cells_map_uniquely_to_cluster": True,
            "all_selected_molecules_match_VQM_declarations": True,
            "all_selected_clusters_have_original_placement": True,
            "all_seed_cluster_members_included": True,
            "all_selected_carry_chains_complete": all(c["fully_included"] for c in chains),
            "geometric_capacity_at_least_twice_demand": True,
            "native_checks_not_performed": True,
        },
        "risks": [
            "Moving bank18/19 RAM and read pipeline may change timing to unselected map/read consumers.",
            "Complete packed-cluster inclusion adds neighboring cfg/parser/other-bank read-request molecules; these collateral members are explicit in members[].children.",
            "The engine remains mostly unconstrained; timing to neighboring unselected engine registers may worsen.",
            "Region nonmember occupancy and route congestion require native implementation evidence; geometric slack alone cannot prove closure.",
        ],
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, default=SOURCE_ROOT)
    parser.add_argument("--device-root", type=Path, default=DEVICE_ROOT)
    parser.add_argument(
        "--output", type=Path,
        default=Path(__file__).resolve().parents[1] / "out/t61/preparation/region_manifest.json",
    )
    args = parser.parse_args()
    result = derive(args.source_root, args.device_root)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({
        "output": args.output.as_posix(),
        "bounds": result["bounds"],
        "selection": result["selection"],
        "resources": result["resources"],
        "native_legality_checked": result["native_legality_checked"],
    }, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()

