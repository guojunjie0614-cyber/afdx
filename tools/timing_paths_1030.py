"""Classify saved eLinx timing paths without modifying the timing database.

Example:
  python tools/timing_paths_1030.py --timing path/to/design.tan.pb --scope synthesis

The .tan.pb file is SQLite. Summaries describe the analyzed design; path tables
are report-limited samples. A family count is NEVER a full-design endpoint count.
Scope is supplied by the caller, because the native `route` field does not
identify synthesis versus routed timing. No input fingerprints are computed.
"""
import argparse
from collections import defaultdict
import json
from pathlib import Path
import re
import sqlite3


# Native detail discriminators: sync_type distinguishes synchronous/asynchronous
# checks; path_type distinguishes scope and longest/shortest. Never join on id
# alone: setup and hold reuse path_id and clock_scoped_path_reports_x/y.
PATH_TABLES = {}
for scope, base in (("intra_clock", 0), ("inter_clock", 2)):
    for direction, delta in (("longest", 0), ("shortest", 1)):
        for kind, sync in (("sync", 0), ("async", 1)):
            PATH_TABLES[f"elinx_{scope}_{direction}_{kind}_path_report"] = (base + delta, sync)
for scope, base in (("user_ignored", 4), ("unconstrain", 6)):
    for direction, delta in (("longest", 0), ("shortest", 1)):
        PATH_TABLES[f"elinx_{scope}_{direction}_path_report"] = (base + delta, 0)

SUMMARY_TABLES = (
    "elinx_timer_tr_cfg", "elinx_timer_setting", "elinx_timing_summary",
    "elinx_intra_clock_summary", "elinx_inter_clock_summary",
    "elinx_user_ignored_clock_summary", "elinx_unconstrain_clock_summary",
)
DETAIL_TABLES = (
    "elinx_source_clock_path_node_detail", "elinx_data_path_node_detail",
    "elinx_dest_clcock_path_node_detail",  # Native spelling is intentional.
)


def family(name):
    """Readable grouping heuristic; exact mapped names remain in representatives."""
    value = re.sub(r"\[\d+\]", "[*]", name)
    value = re.sub(r"ram_block(\d+)([ab])(\d+)", r"ram_block*\2*", value)
    return re.sub(r"~\d+", "~*", value)


def rows(connection, table):
    # Table identifiers only come from the fixed allowlists above.
    return [dict(row) for row in connection.execute('SELECT * FROM "' + table + '"')]


def detail(connection, available, table, path):
    path_type, sync_type = PATH_TABLES[table]
    result = {}
    for detail_table in DETAIL_TABLES:
        if detail_table not in available:
            continue
        result[detail_table] = [dict(row) for row in connection.execute(
            'SELECT * FROM "' + detail_table + '" WHERE path_id=? '
            'AND clock_scoped_path_reports_x=? AND clock_scoped_path_reports_y=? '
            'AND path_type=? AND sync_type=? ORDER BY path_node_detail_id',
            (path['path_id'], path['clock_scoped_path_reports_x'],
             path['clock_scoped_path_reports_y'], path_type, sync_type))]
    data = result.get('elinx_data_path_node_detail', [])
    # Report mismatch rather than silently attaching an unrelated path.
    result['data_endpoints_match'] = bool(data) and (
        data[0]['resource'] == path['from_cell_name'] and
        data[-1]['resource'] == path['to_cell_name'])
    return result


def classify(database, scope, representatives=1, include_details=False):
    database = database.resolve()
    connection = sqlite3.connect(database.as_uri() + '?mode=ro', uri=True)
    connection.row_factory = sqlite3.Row
    try:
        available = {row[0] for row in connection.execute(
            "SELECT name FROM sqlite_master WHERE type='table'")}
        if 'elinx_timing_summary' not in available:
            raise ValueError('Not an eLinx timing database: elinx_timing_summary is missing')
        result = {
            'timing_database': str(database), 'scope': scope,
            'scope_source': 'caller declaration; not inferred from native route field',
            'limitation': 'Path/family/endpoint sample counts refer only to saved path rows. '
                          'Use native summary fields for analyzed-design totals; omitted families '
                          'cannot be ruled out even when saved paths all share one family.',
            'units': {'slack_total_delay_logic_delay_net_delay': 'ps',
                      'clock_skew': 'native ns; preserved unchanged',
                      'other_fields': 'native values; preserved unchanged'},
            'family_rule': 'Normalize numeric bit indices, ram_block word/slice indices, '
                           'and tilde numeric suffixes; retain module/instance hierarchy.',
            'native_summaries': {table: rows(connection, table)
                                 for table in SUMMARY_TABLES if table in available},
            'path_samples': {}, 'warnings': [],
        }
        configs = result['native_summaries'].get('elinx_timer_tr_cfg', [])
        settings = result['native_summaries'].get('elinx_timer_setting', [])
        if configs and settings and configs[0]['max_worstpaths_per_endpoint'] != settings[0]['paths_per_endpoint']:
            result['warnings'].append(
                'Native paths-per-endpoint fields disagree. eLinx 3.0.7 encoded-RAM '
                'probe saved multiple rows per endpoint despite tr_cfg=1 while '
                'timer_setting remained 10. Do not assume the requested limit is '
                'enforced; inspect actual saved path/endpoint counts.')
        for table in PATH_TABLES:
            if table not in available:
                continue
            paths = rows(connection, table)
            if not paths:
                continue
            paths.sort(key=lambda p: (p['slack'], p['path_id']))
            groups = defaultdict(list)
            for path in paths:
                groups[(path['source_clock_id'], path['dest_clock_id'],
                        family(path['from_cell_name']), family(path['to_cell_name']))].append(path)
            families = []
            for key, members in groups.items():
                examples, seen = [], set()
                for path in members:
                    endpoint = (path['dest_clock_id'], path['to_cell_name'])
                    if endpoint in seen:
                        continue
                    seen.add(endpoint)
                    example = {'native_path': path}
                    if include_details:
                        example['native_details'] = detail(connection, available, table, path)
                    examples.append(example)
                    if len(examples) >= representatives:
                        break
                families.append({
                    'source_clock_id': key[0], 'dest_clock_id': key[1],
                    'from_family': key[2], 'to_family': key[3],
                    'saved_paths': len(members),
                    'saved_endpoints': len({p['to_cell_name'] for p in members}),
                    'saved_failing_endpoints': len({p['to_cell_name'] for p in members if p['slack'] < 0}),
                    'worst_slack_ps': members[0]['slack'],
                    'logic_delay_ps_range': [min(p['logic_delay'] for p in members), max(p['logic_delay'] for p in members)],
                    'net_delay_ps_range': [min(p['net_delay'] for p in members), max(p['net_delay'] for p in members)],
                    'representatives': examples,
                })
            families.sort(key=lambda f: (f['worst_slack_ps'], f['to_family'], f['from_family']))
            result['path_samples'][table] = {
                'constraint_scope': ('unconstrained; negative slack is not a constrained timing failure'
                                     if '_unconstrain_' in table else
                                     'user ignored; not a constrained timing gate'
                                     if '_user_ignored_' in table else 'constrained'),
                'saved_paths': len(paths),
                'saved_endpoints': len({(p['dest_clock_id'], p['to_cell_name']) for p in paths}),
                'saved_failing_endpoints': len({(p['dest_clock_id'], p['to_cell_name']) for p in paths if p['slack'] < 0}),
                'family_count': len(families), 'families': families,
            }
        return result
    finally:
        connection.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--timing', required=True, type=Path)
    parser.add_argument('--scope', required=True, choices=('synthesis', 'routed', 'unknown'))
    parser.add_argument('--representatives', type=int, default=1,
                        help='Worst distinct saved endpoints shown per path family (default 1)')
    parser.add_argument('--details', action='store_true', help='Include correctly keyed native node details')
    parser.add_argument('--output', type=Path, help='Write JSON here; otherwise print JSON to stdout')
    args = parser.parse_args()
    if args.representatives < 1:
        parser.error('--representatives must be positive')
    if args.output and args.output.resolve() == args.timing.resolve():
        parser.error('--output must not overwrite the input database')
    try:
        result = classify(args.timing, args.scope, args.representatives, args.details)
    except (OSError, sqlite3.Error, ValueError) as error:
        parser.exit(1, str(error) + '\n')
    text = json.dumps(result, ensure_ascii=False, indent=2) + '\n'
    if args.output:
        args.output.write_text(text, encoding='utf-8')
    else:
        print(text, end='')


if __name__ == '__main__':
    main()
