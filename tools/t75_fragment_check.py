"""Independent fragmentation checker plus explicit T75 coverage receipts."""
import argparse
import json
from pathlib import Path

import fragment_integration as fragment


def check(folder):
    fragment.check(folder)
    schedule, target = fragment.read_schedule(folder)
    rows = list(fragment.records(folder / 'rx.txt'))
    delivered = {int(row[2], 16): bytes.fromhex(row[3]) for row in rows}
    checks = []
    for length in (1464, 1472, 8192):
        candidates = [(vl, payload) for _, vl, payload in schedule if len(payload) == length]
        if not candidates or not any(delivered.get(vl) == payload for vl, payload in candidates):
            raise ValueError(f'T75 required complete delivery absent: {length}')
        checks.append(f'complete_delivery_{length}')
    for vl, tag, length in ((0x300,30,8192),(0x301,31,1472),(0x302,33,1472),
                            (0x303,35,1472),(0x304,37,1472),(0x305,39,1472)):
        if delivered.get(vl) != fragment.pattern(tag, length):
            raise ValueError(f'T75 recovery delivery absent: {vl:04x}')
        checks.append(f'recovery_vl_{vl:04x}')
    result = dict(errors=0, items=len(checks), coverage_checks=checks,
                  independent_fragment_checker='PASS', complete_deliveries=len(rows),
                  tx_messages=len(schedule), tx_target=target,
                  tx_frames={net: len(list(fragment.records(folder / ('tx_' + net + '.txt')))) for net in ('a','b')})
    (folder / 'check_summary.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(result),flush=True)
    return result


if __name__ == '__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dir',type=Path,required=True)
    check(parser.parse_args().dir)
