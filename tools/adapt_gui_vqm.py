"""为界面导出的 VQM 创建仿真副本，保留原网表和厂商模型。

输入取值依据：厂商 stratix_components.vhd 546–561 行和
stratix_atoms.v 的默认上拉、下拉。实际接入的进位输入须声明为使用。
本脚本不改查找表内容、不改已有连接、不修补单元逻辑。
"""
from pathlib import Path
import collections
import hashlib
import json
import re
import sys

LCELL = {
    "dataa": "1'b1", "datab": "1'b1", "datac": "1'b1", "datad": "1'b1",
    "clk": "1'b0", "aclr": "1'b0", "aload": "1'b0", "sclr": "1'b0",
    "sload": "1'b0", "ena": "1'b1", "cin": "1'b0", "cin0": "1'b0",
    "cin1": "1'b0", "inverta": "1'b0", "regcascin": "1'b0",
    "devclrn": "1'b1", "devpor": "1'b1",
}
RAM = {
    "ena0": "1'b1", "ena1": "1'b1", "clk1": "1'b0",
    "clr0": "1'b0", "clr1": "1'b0", "devclrn": "1'b1", "devpor": "1'b1",
}
OUTPUTS = {
    "stratix_lcell": ("combout", "regout", "cout", "cout0", "cout1"),
    "stratix_ram_block": ("portadataout", "portbdataout"),
}
CELL = re.compile(
    r"(?m)^(?P<kind>stratix_lcell|stratix_ram_block)[ \t]+"
    r"(?P<name>\S+)[ \t]*\((?P<body>[\s\S]*?)\);"
    r"(?P<params>(?:\ndefparam[^\n]*)*)"
)


def adapt(source, target):
    assert source.resolve() != target.resolve()
    original = source.read_bytes()
    data = original.decode('utf-8').replace('\r\n', '\n')
    stats = collections.defaultdict(collections.Counter)
    cells = collections.Counter()
    carry_params = collections.Counter()
    audit = []

    def replace(match):
        kind, name, body, params = (match.group(k) for k in ('kind', 'name', 'body', 'params'))
        present = set(re.findall(r'\.(\w+)\s*\(', body))
        values = dict(LCELL if kind == 'stratix_lcell' else RAM)
        extra_params = ''
        if kind == 'stratix_lcell':
            # 只看原有连接，不能把下面补上的常量误认为实际进位。
            for port in ('cin', 'cin0', 'cin1'):
                if port not in present:
                    continue
                used = re.search(r'\.' + port + r'_used\s*=\s*"([^"]+)"', params)
                if used:
                    assert used.group(1) == 'true', (name, port, 'explicit conflicting parameter')
                else:
                    extra_params += f'\ndefparam {name} .{port}_used = "true";'
                    carry_params[port + '_used'] += 1
        else:
            def width(key):
                found = re.search(r'\.' + key + r'\s*=\s*(\d+)\s*;', params)
                result = int(found.group(1)) if found else 1
                assert 1 <= result <= 512, (name, key, result)
                return result
            values['portbdatain'] = f"{width('port_b_data_width')}'b0"
            for letter in ('a', 'b'):
                size = width('port_' + letter + '_byte_enable_mask_width')
                values['port' + letter + 'byteenamasks'] = '{' + str(size) + "{1'b1}}"
        added = [(p, v) for p, v in values.items() if p not in present]
        extra = [f'.{p}({v})' for p, v in added]
        extra += [f'.{p}()' for p in OUTPUTS[kind] if p not in present]
        result_body = body.rstrip() + (',\n\t' + ',\n\t'.join(extra) if extra else '')
        head = match.group(0)[:match.start('body') - match.start()]
        cells[kind] += 1
        for p, v in added:
            stats[kind][p + '=' + v] += 1
        audit.append((kind, name, body, params + extra_params))
        return head + result_body + ');' + params + extra_params

    result = CELL.sub(replace, data)
    expected = collections.Counter(re.findall(r'(?m)^(stratix_lcell|stratix_ram_block)\s', data))
    if not cells or cells != expected:
        raise ValueError('无法完整解析界面网表，已停止补全')
    # 原有连接和参数必须逐项保留，不能为了仿真通过而改变它们。
    after = list(CELL.finditer(result))
    assert len(after) == len(audit)
    for m, (kind, name, body, params) in zip(after, audit):
        assert (m['kind'], m['name'], m['params']) == (kind, name, params)
        assert m['body'].startswith(body.rstrip())
    target.write_text(result, encoding='utf-8', newline='\n')
    assert source.read_bytes() == original
    report = {
        'source_sha256': hashlib.sha256(original).hexdigest(),
        'adapted_sha256': hashlib.sha256(target.read_bytes()).hexdigest(),
        'cells': cells, 'added_input_defaults': stats,
        'original_connections_and_parameters_unchanged': True,
        'carry_use_parameters_added': carry_params,
        'lut_masks_changed': 0,
    }
    target.with_suffix('.defaults.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    return report


if __name__ == '__main__':
    print(json.dumps(adapt(Path(sys.argv[1]), Path(sys.argv[2])), indent=2))
