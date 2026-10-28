"""Read-only T61 timing and placement statistics; no EDA or design mutation."""
import argparse
from collections import Counter
import json
from pathlib import Path
import sqlite3
import xml.etree.ElementTree as ET


def module_name(name):
    parts = [part.split(':')[-1] for part in name.lstrip('\\').split('|')]
    if parts and parts[0] == 'es':
        parts = parts[1:]
    return parts[0] if len(parts) > 1 else 'top_wrapper'


def _rank(row):
    return row['slack'], row['path_id'], row['from_cell_name'], row['to_cell_name']


def timing_statistics(database):
    """Keep the native TNS separate from the sum of per-endpoint minima.

    Endpoint identity follows check_multicycle.timing: the complete to_cell_name.
    The edge class is the actual capture minus launch edge of its worst path.
    All native ps numbers are retained; no rounded number controls a decision.
    """
    database = Path(database).resolve()
    connection = sqlite3.connect(database.as_uri() + '?mode=ro', uri=True)
    connection.execute('PRAGMA query_only=ON')
    connection.execute('PRAGMA temp_store=MEMORY')
    connection.row_factory = sqlite3.Row
    try:
        clocks = [dict(row) for row in connection.execute('SELECT * FROM elinx_intra_clock_summary')]
        if not clocks:
            raise ValueError('No constrained clocks in timing database')
        setup = {}
        hold = {}
        count = {}
        top = []
        interval_sets = {}
        for kind, table, endpoints in (
                ('setup', 'longest', setup), ('hold', 'shortest', hold)):
            count[kind] = 0
            for native in connection.execute('SELECT * FROM elinx_intra_clock_' + table + '_sync_path_report'):
                row = dict(native)
                endpoint = row['to_cell_name']
                count[kind] += 1
                if endpoint not in endpoints or _rank(row) < _rank(endpoints[endpoint]):
                    endpoints[endpoint] = row
                if kind == 'setup':
                    interval = row['capture_edge'] - row['launch_edge']
                    interval_sets.setdefault(endpoint, set()).add(interval)
                    top.append(row)
                    top.sort(key=_rank)
                    del top[3:]
        expected_setup = sum(row['setup_total_ends'] for row in clocks)
        expected_hold = sum(row['hold_total_ends'] for row in clocks)
        if len(setup) != expected_setup or len(hold) != expected_hold:
            raise ValueError('Full endpoint coverage mismatch: setup %s/%s, hold %s/%s' %
                             (len(setup), expected_setup, len(hold), expected_hold))
        groups = {}
        classes = {}
        nearcritical = []
        for row in setup.values():
            interval = row['capture_edge'] - row['launch_edge']
            label = {8000: '8ns', 16000: '16ns'}.get(interval, 'other_' + str(interval) + 'ps')
            module = module_name(row['to_cell_name'])
            for bucket, key in ((classes, label), (groups, module)):
                entry = bucket.setdefault(key, dict(endpoints=0, failed_endpoints=0,
                    below_0p5ns=0, below_0p8ns=0, endpoint_min_negative_slack_sum_ps=0,
                    worst_setup_slack_ps=None))
                entry['endpoints'] += 1
                entry['failed_endpoints'] += row['slack'] < 0
                entry['below_0p5ns'] += row['slack'] < 500
                entry['below_0p8ns'] += row['slack'] < 800
                entry['endpoint_min_negative_slack_sum_ps'] += min(row['slack'], 0)
                prior = entry['worst_setup_slack_ps']
                entry['worst_setup_slack_ps'] = row['slack'] if prior is None else min(prior, row['slack'])
            if row['slack'] < 800:
                nearcritical.append(dict(row, edge_interval_ps=interval, edge_class=label, endpoint_module=module))
        negative_setup = sum(min(row['slack'], 0) for row in setup.values())
        negative_hold = sum(min(row['slack'], 0) for row in hold.values())
        return dict(database=str(database), units='ps unless suffixed otherwise',
            endpoint_identity='complete to_cell_name; one worst path per endpoint',
            clocks=clocks, native_path_counts=count,
            setup_worst_slack_ps=min(row['setup_worst_slack'] for row in clocks),
            hold_worst_slack_ps=min(row['hold_worst_slack'] for row in clocks),
            native_setup_total_violation_ps=sum(row['setup_total_violation'] for row in clocks),
            native_hold_total_violation_ps=sum(row['hold_total_violation'] for row in clocks),
            endpoint_min_setup_negative_slack_sum_ps=negative_setup,
            endpoint_min_hold_negative_slack_sum_ps=negative_hold,
            setup_endpoint_count=len(setup), hold_endpoint_count=len(hold),
            setup_failed_endpoints=sum(row['slack'] < 0 for row in setup.values()),
            hold_failed_endpoints=sum(row['slack'] < 0 for row in hold.values()),
            below_0p5ns=sum(row['slack'] < 500 for row in setup.values()),
            below_0p8ns=sum(row['slack'] < 800 for row in setup.values()),
            edge_classes=classes, endpoint_module_groups=groups,
            endpoints_with_multiple_edge_intervals=sum(len(value) > 1 for value in interval_sets.values()),
            worst_three_native_paths=top,
            worst_three_distinct_endpoints=sorted(setup.values(), key=_rank)[:3],
            nearcritical_endpoints=sorted(nearcritical, key=_rank),
            timing_closed=all(row['setup_worst_slack'] > 0 and row['hold_worst_slack'] >= 0 for row in clocks))
    finally:
        connection.close()


def read_place(path):
    clusters = {}
    pins = {}
    for line in Path(path).read_text(encoding='utf-8-sig').splitlines():
        fields = line.split()
        if len(fields) < 4 or fields[0].startswith('#'):
            continue
        if fields[1] in ('input', 'output', 'inout'):
            if len(fields) < 7:
                raise ValueError('Incomplete I/O placement line: ' + line)
            port, direction, package_pin, cluster = fields[:4]
            position = tuple(map(int, fields[4:7]))
            if port in pins:
                raise ValueError('Duplicate I/O placement: ' + port)
            pins[port] = dict(port=port, direction=direction, package_pin=package_pin,
                              cluster=cluster, coordinates=list(position))
        else:
            cluster = fields[0]
            try:
                position = tuple(map(int, fields[1:4]))
            except ValueError:
                raise ValueError('Unrecognized placement line: ' + line) from None
        if cluster in clusters:
            raise ValueError('Duplicate cluster placement: ' + cluster)
        clusters[cluster] = position
    if not clusters or not pins:
        raise ValueError('No placed clusters or I/O positions')
    return clusters, pins


def placement_statistics(place, cluster_xml):
    clusters, pins = read_place(place)
    modules = {}
    absent = []
    for _, element in ET.iterparse(cluster_xml, events=('end',)):
        if element.tag != 'CLUSTER':
            continue
        cluster = element.attrib['name']
        if cluster not in clusters:
            absent.append(cluster)
            element.clear()
            continue
        x, y, _ = clusters[cluster]
        for child in element:
            if child.tag not in ('MOLECULE', 'IO') or 'name' not in child.attrib:
                continue
            module = module_name(child.attrib['name'])
            entry = modules.setdefault(module, dict(cells=0, clusters=set(), resource_types=Counter(),
                physical_cluster_types={},
                sum_x=0, sum_y=0, min_x=x, max_x=x, min_y=y, max_y=y))
            entry['cells'] += 1
            entry['clusters'].add(cluster)
            entry['physical_cluster_types'].setdefault(element.attrib['type'], set()).add(cluster)
            entry['resource_types'][child.attrib.get('type', child.tag)] += 1
            entry['sum_x'] += x
            entry['sum_y'] += y
            for key, value, fun in (('min_x', x, min), ('max_x', x, max), ('min_y', y, min), ('max_y', y, max)):
                entry[key] = fun(entry[key], value)
        element.clear()
    for entry in modules.values():
        entry['clusters'] = len(entry['clusters'])
        entry['resource_types'] = dict(entry['resource_types'])
        entry['physical_cluster_types'] = {kind: len(names) for kind, names in entry['physical_cluster_types'].items()}
        entry['mean_x_by_cell'] = entry.pop('sum_x') / entry['cells']
        entry['mean_y_by_cell'] = entry.pop('sum_y') / entry['cells']
    return dict(place=str(place), cluster_xml=str(cluster_xml), placed_clusters=len(clusters),
                io_count=len(pins), pins=[pins[key] for key in sorted(pins)],
                counting='cells/resource_types count packed logical molecules; physical_cluster_types count unique clusters per module; shared clusters can occur in multiple modules',
                modules=modules, missing_cluster_positions=absent)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--database', type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(timing_statistics(args.database), ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
