"""Check mapped RX metadata RAM and lane write-data isolation, without hashes.

This inventories intermediate VQM primitives, not native M4K utilization.
Native pack/utilization reports remain authoritative for physical block counts.
"""
import json
from pathlib import Path
import re


STORES = ('key_table', 'header_table', 'admission_table', 'progress_table')


def payload_inputs(text):
    """Inspect the actual RAM data drivers across slot and lane hierarchy."""
    slots, lanes, isolation = set(), set(), set()
    ram_inputs = []
    for block in text.split('\n\n'):
        cell = re.match(r'stratix_(lcell|ram_block)\s+\\([^\s]+)\s+\(', block)
        if not cell or '|afdx_rx_reassembly_payload:' not in cell[2]:
            continue
        if cell[1] == 'lcell':
            driver = re.search(r'\.combout\(\\([^\s)]+)', block)
            # The lane may separate RAM write-enable from a same-edge local
            # qualifier FF. Both forms must retain the actual data AND LUT;
            # a qualifier name alone never establishes input isolation.
            local_qualifier = ('|write_command ' in block or
                               '|write_qualifier ' in block)
            if (driver and local_qualifier and '|write_data[' in block
                    and '.lut_mask = "8888"' in block
                    and '.output_mode = "comb_only"' in block):
                isolation.add(driver[1])
        else:
            slot = re.search(r'^(.*?afdx_rx_reassembly_payload_slot:[^|]+)', cell[2])
            lane = re.search(r'^(.*?afdx_rx_reassembly_payload_lane:[^|]+)', cell[2])
            if slot:
                slots.add(slot[1])
            if lane:
                lanes.add(lane[1])
            driver = re.search(r'\.portadatain\(\{?\\([^\s})]+)', block)
            ram_inputs.append(driver[1] if driver else None)
    direct = [driver for driver in ram_inputs if driver not in isolation]
    return {
        'slot_instances': len(slots),
        'lane_instances': len(lanes),
        'write_isolation_luts': len(isolation),
        'ram_data_input_connections': len(ram_inputs),
        'inputs_without_isolation_lut': direct,
        'passed': len(slots) == 16 and len(lanes) == 64
                  and len(isolation) == 128 and len(ram_inputs) == 256 and not direct,
        'scope': '16 slots, each four 8192x2 lanes; intermediate primitives, '
                 'not native physical block utilization',
    }


def audit(netlist, output):
    text = Path(netlist).read_text(encoding='utf-8', errors='replace')
    cells = re.findall(r'^stratix_ram_block\s+\\([^\s]+)\s+\(', text, re.M)
    tables = {name: {} for name in STORES}
    for cell in cells:
        if 'afdx_rx_reassembly' not in cell:
            continue
        for store in STORES:
            match = re.search(r'(?:^|\|)(?:[^|]*:)?' + store + r'(?=\||$)', cell)
            if match:
                instance = cell[:match.end()]
                tables[store][instance] = tables[store].get(instance, 0) + 1
    payload = payload_inputs(text)
    result = {
        'netlist': str(Path(netlist).resolve()),
        'scope': 'Default 16-context / two-bank RX metadata and slot write isolation in intermediate VQM',
        'expected_bank_instances_per_store': 2,
        'tables': tables,
        'payload': payload,
        'passed': all(len(instances) == 2 for instances in tables.values()) and payload['passed'],
        'limitations': 'Checks retained RAM primitives, bank identities and payload write-data LUT connections; '
                      'does not prove port timing, functional behavior, native block count or STA.',
    }
    Path(output).write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    return result
