"""Record native ModelSim macro and vlog-2730 option probes without RTL edits."""
from datetime import datetime, timedelta
import json
import os
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools"))
os.environ.setdefault("AFDX_MEM_FLOOR_GB", "3")
os.environ.setdefault("MODELSIM_HOME", "E:/Verilog/ModelSim/setup_pack/win64")
import eda


def main():
    flow = eda.Flow("t77_compile", "original_probes",
                    (datetime.now().astimezone() + timedelta(seconds=600)).isoformat())
    ms = eda.modelsim_dir()
    result = {"probes": [], "source_transformations": False}
    try:
        flow.job("vlib", [ms / "vlib.exe", "work"], 30)
        macro = flow.folder / "automatic_macro.v"
        macro.write_text("`ifndef MODEL_TECH\n"
                         "MODEL_TECH_MUST_BE_AUTOMATIC !!!\n"
                         "`endif\nmodule automatic_macro; endmodule\n", encoding="ascii")
        flow.job("automatic_macro", [ms / "vlog.exe", "-vlog01compat", macro], 120)
        result["model_tech_automatically_defined"] = True
        sources = sorted((ROOT / "rtl").glob("*.v"))
        result["original_source_hashes"] = {str(p.relative_to(ROOT)): eda.sha(p) for p in sources}
        for name, options in (("unmodified", []), ("suppress_2730", ["-suppress", "2730"]),
                              ("warning_2730", ["-warning", "2730"]),
                              ("permissive", ["-permissive"])):
            command = [ms / "vlog.exe", "-vlog01compat", *options, *sources]
            try:
                flow.job(name, command, 120)
                success = True
            except RuntimeError:
                success = False
            log = (flow.folder / (name + ".log")).read_text(encoding="utf-8-sig", errors="replace")
            result["probes"].append(dict(name=name, compile_success=success,
                                         diagnostic_lines=[line for line in log.splitlines()
                                                           if "** " in line or
                                                           re.search(r"Errors:|Warnings:", line)]))
            print(name + ": " + ("COMPILES" if success else "REJECTED"), flush=True)
        flow.result.update(result)
    finally:
        flow.finish()
        eda.save(Path(__file__).resolve().parent / "compiler_probes.json", flow.result)


if __name__ == "__main__":
    main()
