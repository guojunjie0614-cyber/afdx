"""Collect the actual isolated eLinx -> ModelSim transcript, without replay."""
import argparse
import json
from pathlib import Path
import re
import shutil
from v2_source_check import ROOT, EVIDENCE, digest, save, stamp


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--log', type=Path, required=True)
    args = parser.parse_args()
    receipt = EVIDENCE / 'v2_gui_simulation.json'
    result = json.loads(receipt.read_text(encoding='utf-8'))
    source = Path(result['source_root']).resolve()
    log = args.log.resolve()
    if not log.is_relative_to(source):
        raise ValueError('Transcript must belong to the isolated GUI project')
    raw = log.read_bytes()
    text = raw.decode('utf-8-sig', errors='replace')
    rows = re.findall(r'\[RESULT\]\s+tb_elinx\s+(PASS|FAIL)\s+checks=(\d+)\s+errors=(\d+)', text)
    errors = re.findall(r'(?m)^.*\*\* (?:Error|Fatal)(?: \([^\n]*?\))?:[^\n]*', text)
    warnings = re.findall(r'(?m)^.*\*\* Warning:[^\n]*', text)
    originals = {relative: digest((ROOT / relative).read_bytes()) == sha
                 for relative, sha in result['source_sha256'].items()}
    rtl_snapshot = {relative: digest((source / relative).read_bytes()) == sha
                    for relative, sha in result['source_sha256'].items() if relative.startswith(('rtl/', 'tb/'))}
    accepted = (bool(rows) and all(row == ('PASS', '9238', '0') for row in rows)
                and not errors and '[RX_ASSERT]' not in text and '[RAMCOLL]' not in text
                and all(originals.values()) and all(rtl_snapshot.values()))
    target = EVIDENCE / 'v2_raw/gui'
    target.mkdir(parents=True, exist_ok=True)
    shutil.copy2(log, target / 'transcript.log')
    result.update(status='PASS' if accepted else 'FAIL', passed=accepted, collected=stamp(),
        gui_click_tested=True, transcript=str(log), transcript_sha256=digest(raw), results=rows,
        errors=errors, warnings=warnings, original_inputs_unchanged=originals,
        isolated_rtl_and_tb_unchanged=rtl_snapshot,
        modeltech='No compatibility copy; eLinx compiles the guarded afdx_all.v source entry with ModelSim')
    save(receipt, result)
    print(json.dumps({k: result[k] for k in ('status', 'results', 'errors', 'transcript_sha256')}, indent=2))
    return 0 if accepted else 1


if __name__ == '__main__':
    raise SystemExit(main())
