"""Prepare an isolated copy for one actual eLinx behavioral simulation."""
from pathlib import Path
import json
import shutil
import subprocess
from v2_source_check import ROOT, EVIDENCE, digest, save, stamp, TZ
from datetime import datetime
import psutil
import eda


def main():
    receipt = EVIDENCE / 'v2_gui_simulation.json'
    if receipt.exists():
        raise RuntimeError('GUI evidence already exists; implicit retry forbidden')
    e2e = json.loads((EVIDENCE / 'v2_end_to_end.json').read_text(encoding='utf-8'))
    if not e2e.get('accepted') or 'finished' not in e2e:
        raise RuntimeError('Do not start GUI tests before positive end-to-end acceptance')
    resources = dict(free_memory_gib=psutil.virtual_memory().available / 1024**3,
                     e_free_gib=eda.free_disk_bytes(ROOT.anchor) / 1024**3,
                     global_modelsim_slots=len(eda.modelsim_slot_pids()))
    if resources['free_memory_gib'] < 3 or resources['e_free_gib'] < 8 or resources['global_modelsim_slots'] >= 10:
        raise RuntimeError('GUI launch resource floors/capacity not met; no app launched')
    destination = ROOT / 'out/t77_gui' / datetime.now(TZ).strftime('%Y%m%d_%H%M%S') / 'source'
    relatives = subprocess.check_output(['git', 'ls-files', 'rtl', 'tb'], cwd=ROOT, text=True).splitlines()
    relatives.extend('elinx/' + name for name in ('AFDX_EndSystem.epr', 'AFDX_EndSystem_assignment_defaults.qdf',
        'afdx_all.v', 'constraints.edc', 'physical_only.edc', 'timing_only.sdc', 'constraints_t62.json', 'tiles_1030.edc'))
    copied = {}
    for relative in relatives:
        source = ROOT / relative
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
        if source.read_bytes() != target.read_bytes():
            raise RuntimeError('GUI snapshot differs: ' + relative)
        copied[relative] = digest(target.read_bytes())
    existing = []
    for p in psutil.process_iter(['name', 'cmdline']):
        if (p.info['name'] or '').lower() in ('vsim.exe', 'vsimk.exe', 'elinx3.0.exe', 'elinx.exe'):
            try:
                existing.append(dict(pid=p.pid, created=p.create_time(), name=p.name(), command=p.cmdline()))
            except psutil.NoSuchProcess:
                pass
    save(receipt, dict(status='PREPARED', prepared=stamp(), passed=False,
        isolated_project=str(destination / 'elinx/AFDX_EndSystem.epr'), source_root=str(destination),
        source_sha256=copied, original_source_unchanged_expected=copied,
        launch_resources=resources,
        preexisting_simulator_or_gui_processes=existing,
        test='tb_elinx', expected_checks=9238, gui_click_tested=False,
        note='All app-generated files must remain inside this isolated copy. No T75/T76 project is opened.'))
    print(str(destination / 'elinx/AFDX_EndSystem.epr'))


if __name__ == '__main__':
    main()
