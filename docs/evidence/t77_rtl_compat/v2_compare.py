"""Read actual quartus_map inputs; compare all three VQMs without rerunning EDA."""
from collections import Counter
import argparse
from datetime import datetime, timedelta, timezone
import hashlib
import itertools
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[3]
EVIDENCE = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / 'tools'))
from t76_vqm_structure import parse
from v2_source_check import digest, save
from synth_check import BASELINE


def input_audit(synthesis, receipt_name='v2_synthesis_inputs.json'):
    run = Path(synthesis['folder'])
    project = run / 'project'
    report = project / 'AFDX_EndSystem.runs/synth_1/AFDX_EndSystem.map.rpt'
    text = report.read_text(encoding='utf-8-sig')
    section = text[text.index('\n; Analysis & Synthesis Source Files Read'):]
    rows = []
    started = False
    for line in section.splitlines():
        if started and line.startswith('+'):
            break
        fields = [v.strip() for v in line.split(';')[1:-1]]
        if len(fields) == 5 and fields[1] in ('yes', 'no'):
            started = True
            rows.append(dict(entered_path=fields[0], used_in_netlist=fields[1], type=fields[2],
                             absolute_path=fields[3], library=fields[4]))
    source = run / 'source'
    user, generated, vendor, unknown = [], [], [], []
    for row in rows:
        path = Path(row['absolute_path'])
        if path.is_relative_to(source):
            relative = path.relative_to(source).as_posix()
            row.update(relative=relative, sha256=digest(path.read_bytes()))
            user.append(row)
        elif path.is_relative_to(project / 'db'):
            generated.append(row)
        elif path.is_relative_to(Path('E:/2026_Embedded_FPGA/setup_pack')):
            vendor.append(row)
        else:
            unknown.append(row)
    qsf = project / 'AFDX_EndSystem.qsf'
    qsf_text = qsf.read_text(encoding='utf-8-sig')
    entries = re.findall(r'(?m)^set_global_assignment -name VERILOG_FILE (.+)$', qsf_text)
    macros = re.findall(r'(?m)^.*(?:VERILOG_MACRO|SEARCH_PATH|SYSTEMVERILOG_FILE|VHDL_FILE).*$' , qsf_text)
    expected = json.loads((EVIDENCE / 'v2_text_equivalence.json').read_text(encoding='utf-8'))
    observed = {r['relative']: r['sha256'] for r in user}
    expected_rtl = {k: v['after_sha256'] for k, v in expected['source_files'].items() if k.startswith('rtl/')}
    entry_ok = len(entries) == 1 and entries[0].strip('{}"') == (source / 'elinx/afdx_all.v').as_posix()
    include_text = (source / 'elinx/afdx_all.v').read_text(encoding='utf-8-sig')
    include_names = re.findall(r'(?m)^`include "../(rtl/[^"\n]+)"', include_text)
    root_marker = [line for line in (run / 'analysis.log').read_text(encoding='utf-8-sig').splitlines()
                   if 'Found 42 design units' in line and '/source/elinx/afdx_all.v' in line]
    passed = (observed == expected_rtl and set(include_names) == set(expected_rtl)
              and len(include_names) == 34 and entry_ok and not macros and not unknown and bool(root_marker))
    result = dict(passed=passed, map_report=str(report), map_report_sha256=digest(report.read_bytes()),
                  qsf_entries=entries, qsf_other_language_or_macro_assignments=macros,
                  entry_log_lines=root_marker, rtl_files_match_text_proof=observed == expected_rtl,
                  include_order=include_names, user_rtl=user, vendor_library_files=vendor,
                  generated_megafunctions=generated, unaccounted_files=unknown,
                  note='The map table lists 34 included RTL files. The single QSF entry afdx_all.v is '
                       'confirmed by the 42-design-unit analysis log. Other reads are vendor libraries or generated db files.')
    save(EVIDENCE / receipt_name, result)
    return passed


def noncomment_lines(path):
    with path.open('rb') as stream:
        for line in stream:
            if not line.lstrip().startswith(b'//'):
                yield line.rstrip(b'\r\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--include-final', action='store_true', help='Include GUI and full modified-RTL end-to-end VQMs')
    args = parser.parse_args()
    synthesis = json.loads((EVIDENCE / 'v2_synthesis.json').read_text(encoding='utf-8'))
    if not synthesis['completed']:
        raise RuntimeError('Official synthesis/export incomplete')
    inputs_passed = input_audit(synthesis)
    v1 = json.loads((EVIDENCE / 'baseline_original.json').read_text(encoding='utf-8'))
    paths = dict(baseline=BASELINE, v1_original=Path(v1['candidate']), v2_guarded=Path(synthesis['netlist']))
    if args.include_final:
        end_to_end = json.loads((EVIDENCE / 'v2_end_to_end.json').read_text(encoding='utf-8'))
        if not end_to_end.get('netlist'):
            raise RuntimeError('End-to-end VQM absent')
        inputs_passed = input_audit(end_to_end, 'v2_e2e_inputs.json') and inputs_passed
        paths['gui_original'] = ROOT.parent / 'c3_frag1030/elinx/AFDX_EndSystem.runs/synth_1/AFDX_EndSystem.vqm'
        paths['e2e_processors_1'] = Path(end_to_end['netlist'])
    records, signatures = {}, {}
    for label, path in paths.items():
        records[label] = parse(path)
        lines = sorted(noncomment_lines(path))
        h = hashlib.sha256()
        for line in lines:
            h.update(line + b'\n')
        signatures[label] = dict(path=str(path), bytes=path.stat().st_size,
                                 sha256=records[label][3], noncomment_lines=len(lines),
                                 sorted_noncomment_sha256=h.hexdigest())
        del lines
    comparisons = []
    for left, right in itertools.combinations(paths, 2):
        a, aa, ap, _ = records[left]
        b, ba, bp, _ = records[right]
        identity = a == b and Counter(aa) == Counter(ba) and ap == bp
        ordered_differences = sum(x != y for x, y in itertools.zip_longest(
            noncomment_lines(paths[left]), noncomment_lines(paths[right])))
        sorted_equal = signatures[left]['sorted_noncomment_sha256'] == signatures[right]['sorted_noncomment_sha256']
        byte_equal = signatures[left]['sha256'] == signatures[right]['sha256']
        row = dict(left=left, right=right, byte_equal=byte_equal,
                   ordered_noncomment_different_positions=ordered_differences,
                   sorted_noncomment_lines_equal=sorted_equal,
                   primitive_counts_left=dict(Counter(v[0] for v in a.values())),
                   primitive_counts_right=dict(Counter(v[0] for v in b.values())),
                   identical_named_functional_cells=sum(name in b and a[name] == b[name] for name in a),
                   functional_cell_records=len(a), assignment_count_left=len(aa), assignment_count_right=len(ba),
                   assignment_multisets_equal=Counter(aa) == Counter(ba), top_ports_equal=ap == bp,
                   name_bijection='identity' if identity else None, mapped_structure_equal=identity,
                   classification='BYTE_IDENTICAL' if byte_equal else 'ORDER_ONLY' if sorted_equal and identity
                   else 'NEEDS_NAME_BIJECTION_OR_STRUCTURE_DIAGNOSIS')
        comparisons.append(row)
    passed = inputs_passed and all(c['mapped_structure_equal'] for c in comparisons)
    result = dict(finished=datetime.now(timezone(timedelta(hours=8))).strftime('%Y-%m-%d %H:%M:%S'),
                  passed=passed, input_audit_passed=inputs_passed, files=signatures, comparisons=comparisons,
                  method='T76 parser: compare each named primitive kind, all functional parameters and ordered port tokens; '
                         'created_from metadata excluded. All names map to themselves. Also compare assignment multisets, '
                         'top declarations, ordered noncomment positions and sorted noncomment line hashes.',
                  timing_binding=('Baseline historical timing, R1 imported-original-VQM timing and the final '
                      'modified-RTL end-to-end timing have separate VQM/result bindings; see v2_route_R1.json '
                      'and v2_end_to_end.json. This comparison itself launches no EDA tools.' if args.include_final else
                      'At this initial comparison stage only the baseline VQM had routed delivery evidence; '
                      'later user-authorized routing is recorded separately.'))
    save(EVIDENCE / ('v2_final_vqm_comparison.json' if args.include_final else 'v2_vqm_comparison.json'), result)
    print(json.dumps(result, indent=2))
    return 0 if passed else 1


if __name__ == '__main__':
    raise SystemExit(main())
