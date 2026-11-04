"""T77 official map/export only, followed by an ordered VQM comparison."""
import argparse
from datetime import datetime, timedelta, timezone
import filecmp
import hashlib
import itertools
import os
from pathlib import Path
import sys
import time

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools"))
os.environ.setdefault("AFDX_MEM_FLOOR_GB", "3")
os.environ.setdefault("AFDX_CE_DIV", "2")
os.environ.setdefault("ELINX_HOME", "E:/2026_Embedded_FPGA/setup_pack")
import psutil
import eda
import build_1030
import official_synth

EVIDENCE = Path(__file__).resolve().parent
BASELINE = Path("E:/2026_Embedded_FPGA/worktrees/active/c3_frag1030/out/build1030/"
                "AFDX_top_1030/20261102_212626_064390/project/"
                "AFDX_EndSystem.runs/synth_1/AFDX_EndSystem.vqm")
TZ = timezone(timedelta(hours=8))


def stamp():
    return datetime.now(TZ).strftime("%Y-%m-%d %H:%M:%S")


def compare(candidate):
    baseline_sha, candidate_sha = eda.sha(BASELINE).lower(), eda.sha(candidate).lower()
    if not baseline_sha.startswith("3cd8f5f8"):
        raise RuntimeError("Task-card baseline SHA256 prefix differs")
    def noncomment_lines(path):
        with path.open("rb") as stream:
            for number, line in enumerate(stream, 1):
                if not line.lstrip().startswith(b"//"):
                    yield number, line.rstrip(b"\r\n")
    baseline_count = candidate_count = difference_count = 0
    differences = []
    baseline_normalized, candidate_normalized = hashlib.sha256(), hashlib.sha256()
    for index, (left, right) in enumerate(itertools.zip_longest(
            noncomment_lines(BASELINE), noncomment_lines(candidate)), 1):
        if left is not None:
            baseline_count += 1
            baseline_normalized.update(left[1] + b"\n")
        if right is not None:
            candidate_count += 1
            candidate_normalized.update(right[1] + b"\n")
        if left is None or right is None or left[1] != right[1]:
            difference_count += 1
            if len(differences) < 10:
                differences.append(dict(noncomment_line=index,
                    baseline_line=left[0] if left else None,
                    candidate_line=right[0] if right else None,
                    baseline=left[1].decode("utf-8", errors="replace") if left else None,
                    candidate=right[1].decode("utf-8", errors="replace") if right else None))
    byte_equal = filecmp.cmp(BASELINE, candidate, shallow=False)
    ordered_equal = difference_count == 0
    result = dict(baseline=str(BASELINE), candidate=str(candidate),
                  baseline_sha256=baseline_sha,
                  candidate_sha256=candidate_sha,
                  baseline_bytes=BASELINE.stat().st_size, candidate_bytes=candidate.stat().st_size,
                  byte_equal=byte_equal,
                  ordered_noncomment_lines_equal=ordered_equal, sorting_used=False,
                  baseline_noncomment_lines=baseline_count,
                  candidate_noncomment_lines=candidate_count,
                  baseline_noncomment_sha256=baseline_normalized.hexdigest(),
                  candidate_noncomment_sha256=candidate_normalized.hexdigest(),
                  different_noncomment_line_positions=difference_count,
                  difference_excerpt=differences,
                  passed=byte_equal or ordered_equal,
                  comparison="byte_equal" if byte_equal else
                  "ordered_noncomment_lines_equal" if ordered_equal else "different")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("label")
    args = parser.parse_args()
    if not args.label.replace("_", "").isalnum():
        raise ValueError("Use an alphanumeric label")
    receipt = EVIDENCE / (args.label + ".json")
    if receipt.exists():
        raise RuntimeError("Existing receipt must not be overwritten")
    now = datetime.now(TZ)
    deadline = now + timedelta(seconds=1800)
    process = psutil.Process()
    flow = eda.Flow("t77_synth", args.label, deadline.isoformat())
    started = time.monotonic()
    report = dict(started=stamp(), deadline=deadline.strftime("%Y-%m-%d %H:%M:%S"),
                  runner_pid=process.pid, runner_created=process.create_time(),
                  flow_folder=str(flow.folder), scope="official quartus_map and VQM export only",
                  baseline_sha256=eda.sha(BASELINE).lower(), completed=False, passed=False)
    eda.save(receipt, report)
    try:
        free_memory = psutil.virtual_memory().available / 1024**3
        free_disk = eda.free_disk_bytes(ROOT.anchor) / 1024**3
        report["launch_resources"] = dict(free_memory_gib=free_memory, free_disk_gib=free_disk)
        if free_memory < 3 or free_disk < 8:
            raise RuntimeError("Launch resources below card floors; no new tool launched")
        home = official_synth.installation()
        project, synth, implementation, opts, directory, output, constraint = build_1030.prepare(flow, "1.30")
        paths = sorted((flow.folder / "source/rtl").glob("*.v"))
        paths.append(flow.folder / "source/elinx/afdx_all.v")
        report["source_hashes"] = {str(p.relative_to(flow.folder / "source")): eda.sha(p).lower()
                                   for p in paths}
        eda.save(receipt, report)
        print("T77_SYNTH_START " + str(flow.folder), flush=True)
        binary = home / "bin/Passkey/bin"
        log = flow.job("analysis", [binary / "quartus_map.exe", "--read_settings_files=on",
                                   "--write_settings_files=off", project.stem], 1800, cwd=directory)
        if "Analysis & Synthesis was successful. 0 errors" not in log:
            raise RuntimeError("Official synthesis success marker absent")
        netlist = output / (project.stem + ".vqm")
        flow.job("export", [binary / "quartus_cdb.exe", project.stem, "-c", project.stem,
                            "--vqm=" + str(netlist)], 300, cwd=directory)
        report.update(compare(netlist), completed=True)
        print("T77_VQM " + report["comparison"], flush=True)
        return 0 if report["passed"] else 2
    except Exception as error:
        report["error"] = str(error)
        print("T77_SYNTH_STOP " + str(error), flush=True)
        return 1
    finally:
        report.update(finished=stamp(), elapsed_seconds=round(time.monotonic() - started, 3),
                      jobs=flow.jobs)
        flow.result.update(report)
        flow.finish()
        eda.save(receipt, report)


if __name__ == "__main__":
    raise SystemExit(main())
