"""Apply only the three source-portability edits authorized by T76 section 4."""
import hashlib
import json
from pathlib import Path
import re

from modelsim_sources import DECLARATIONS

ROOT = Path(__file__).resolve().parents[1]


def main():
    evidence = []
    names = set(DECLARATIONS) | {
        'afdx_tx_buf.v', 'afdx_tx_builder.v', 'afdx_rx_deliver.v',
        'afdx_rx_reassembly.v', 'afdx_rx_reassembly_ram.v'}
    for name in sorted(names):
        path = ROOT / 'rtl' / name
        original = path.read_bytes()
        text = original.decode('utf-8')
        newline = '\r\n' if b'\r\n' in original else '\n'
        lines = text.splitlines(keepends=True)
        moved, edits, found = [], [], set()
        for index, line in enumerate(lines):
            match = re.fullmatch(
                r'(\s*(?:\(\*[^\n]*?\*\)\s*)?(wire|reg)\s+(?:\[[^\n]+?\]\s*)?)([^;\r\n]+);[^\S\n]*\n?', line)
            if not match:
                continue
            head, kind, body = match.groups()
            targets = set(re.findall(r'\b[A-Za-z_][A-Za-z0-9_]*\b', body.split('=', 1)[0])) & set(DECLARATIONS.get(name, ()))
            if not targets:
                continue
            found.update(targets)
            if '=' in body:
                assert kind == 'wire'
                identifier, expression = body.split('=', 1)
                declaration = head + identifier.rstrip() + ';' + newline
                replacement = '    assign ' + identifier.strip() + ' =' + expression + ';' + newline
            else:
                declaration, replacement = line, newline
            moved.append(declaration)
            edits.append(dict(line=index+1, original=line, replacement=replacement, declaration=declaration))
            lines[index] = replacement
        assert found == set(DECLARATIONS.get(name, ())), (name, found)
        header = re.search(r'(?ms)^module\b.*?;\s*\n', text)
        insertion = len(text[:header.end()].splitlines())
        inverse = list(lines)
        for edit in edits:
            inverse[edit['line']-1] = edit['original']
        assert ''.join(inverse) == text
        lines[insertion:insertion] = moved
        text = ''.join(lines)
        checks = 0
        if name in ('afdx_tx_buf.v', 'afdx_tx_engine.v', 'afdx_tx_builder.v'):
            pattern = r'(?m)^`ifdef AFDX_CE_DIV\r?\n(?:(?!^`endif).)*^`endif[^\S\n]*\n?'
            def guard(match):
                nonlocal checks
                assert '$fatal' in match[0]
                checks += 1
                return '`ifndef SYNTHESIS' + newline + match[0] + '`endif' + newline
            text = re.sub(pattern, guard, text, flags=re.S)
            assert checks == 1, (name, checks)
            text = text.replace('// 所有 RTL 回归都定义此宏；综合不定义，不产生硬件。',
                                '// RTL 检查保留；SYNTHESIS 前端跳过，不产生硬件。')
        tasks = text.count('$finish_and_return(1)')
        text = text.replace('$finish_and_return(1)', '$fatal(1, "RX simulation invariant failed; see preceding diagnostic")')
        path.write_bytes(text.encode('utf-8'))
        evidence.append(dict(file='rtl/'+name, declarations=edits, guarded_blocks=checks,
            replaced_tasks=tasks, declaration_inverse_verified=True,
            before_sha256=hashlib.sha256(original).hexdigest(),
            after_sha256=hashlib.sha256(path.read_bytes()).hexdigest()))
    target = ROOT / 'out/t76/source_compat_edits.json'
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(evidence, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
    print(target)


if __name__ == '__main__':
    main()
