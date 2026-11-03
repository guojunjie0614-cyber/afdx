"""T77 v2: bounded MODEL_TECH edits and reproducible synthesis-input proof."""
import argparse
from datetime import datetime, timedelta, timezone
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
EVIDENCE = Path(__file__).resolve().parent
OUT = ROOT / 'out/t77_v2'
REVISION = 'd3cffda5afe894393d59bd605955f95a2d70d846'
TZ = timezone(timedelta(hours=8))
sys.path.insert(0, str(ROOT / 'tools'))
from modelsim_sources import DECLARATIONS


def stamp():
    return datetime.now(TZ).strftime('%Y-%m-%d %H:%M:%S')


def digest(data):
    return hashlib.sha256(data).hexdigest()


def save(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


def original(relative):
    return subprocess.check_output(['git', 'show', REVISION + ':' + relative], cwd=ROOT)


def transform(raw, names):
    # Preserve line endings, complete original statements, widths and attributes.
    text = raw.decode('utf-8')
    lines = text.splitlines(keepends=True)
    newline = '\r\n' if '\r\n' in text else '\n'
    header = re.search(r'(?ms)^module\b.*?;[^\S\r\n]*\r?\n', text)
    if not header:
        raise ValueError('First module header not found')
    insertion = len(text[:header.end()].splitlines())
    early, edits, found = [], [], set()
    for i, line in enumerate(lines):
        match = re.fullmatch(r'([ \t]*(?:\(\*[^\n]*?\*\)[ \t]*)?(wire|reg)[ \t]+'
                             r'(?:\[[^\n]+?\][ \t]*)?)([^;\r\n]+);[ \t]*\r?\n?', line)
        if not match:
            continue
        head, kind, body = match.groups()
        lhs = body.split('=', 1)[0]
        targets = set(re.findall(r'\b[A-Za-z_][A-Za-z0-9_]*\b', lhs)) & set(names)
        if not targets:
            continue
        if targets & found:
            raise ValueError('Repeated declaration: ' + str(targets))
        found.update(targets)
        if '=' in body:
            if kind != 'wire' or ',' in lhs:
                raise ValueError('Unsupported initialized declaration')
            name, expression = body.split('=', 1)
            declaration = head + name.rstrip() + ';' + newline
            assignment = '    assign ' + name.strip() + ' =' + expression + ';' + newline
            replacement = ('`ifndef MODEL_TECH' + newline + line + '`else' + newline
                           + assignment + '`endif' + newline)
        else:
            declaration = line
            assignment = None
            replacement = '`ifndef MODEL_TECH' + newline + line + '`endif' + newline
        early.append(declaration)
        edits.append(dict(original_line=i + 1, signals=sorted(targets), original=line,
                          early_declaration=declaration, modelsim_assignment=assignment))
        lines[i] = replacement
    if found != set(names):
        raise ValueError('Missing declarations: ' + str(set(names) - found))
    prefix = ['`ifdef MODEL_TECH' + newline] + early + ['`endif' + newline]
    lines[insertion:insertion] = prefix
    return ''.join(lines).encode('utf-8'), edits


# Lex preprocessed Verilog: comments/whitespace omitted, strings and escaped
# identifiers atomic, maximal-munch operators. Reject anything unrecognized.
LEXER = re.compile(r'''(?P<space>\s+)|(?P<comment>//[^\n]*|/\*.*?\*/)|
    (?P<string>"(?:\\.|[^"\\])*")|(?P<escaped>\\[^\s]+)|
    (?P<number>(?:\d[\d_]*\s*)?'[sS]?[bBoOdDhH][0-9a-fA-F_xXzZ?]+|
        \d[\d_]*(?:\.[\d_]+)?(?:[eE][+-]?[\d_]+)?)|
    (?P<identifier>[A-Za-z_$][A-Za-z_0-9$]*)|
    (?P<operator>===|!==|<<<|>>>|&&&|==|!=|<=|>=|&&|\|\||<<|>>|\*\*|~\^|\^~|~&|~\||=>|\*>|[+\-*/%<>=!&|^~?:;,().\[\]{}@\#'])
    ''', re.VERBOSE | re.DOTALL)


def tokens(raw):
    text = raw.decode('utf-8-sig').replace('\r\n', '\n')
    result, pos = [], 0
    while pos < len(text):
        m = LEXER.match(text, pos)
        if not m:
            raise ValueError('Unrecognized preprocessed text: ' + repr(text[pos:pos + 80]))
        if m.lastgroup not in ('space', 'comment'):
            result.append(m.group())
        pos = m.end()
    return result


def preprocess(executable, source, target):
    command = [executable, '-g2001', '-E', '-o', str(target), str(source)]
    started = stamp()
    p = subprocess.Popen(command, cwd=source.parent, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    output, _ = p.communicate(timeout=60)
    if p.returncode:
        raise RuntimeError(output.decode('utf-8', errors='replace'))
    return dict(command=command, pid=p.pid, started=started, finished=stamp(),
                exit_code=p.returncode, diagnostics=output.decode('utf-8', errors='replace'))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    edits = {}
    for name, names in DECLARATIONS.items():
        relative = 'rtl/' + name
        before = original(relative)
        after, rows = transform(before, names)
        current = ROOT / relative
        if args.apply:
            if current.read_bytes() != before:
                raise ValueError('Apply requires unchanged original: ' + relative)
            current.write_bytes(after)
        if current.read_bytes() != after:
            raise ValueError('Unexpected source edit: ' + relative)
        edits[relative] = dict(before_sha256=digest(before), after_sha256=digest(after), edits=rows)
    save(EVIDENCE / 'v2_source_edits.json', dict(revision=REVISION, files=edits,
         declaration_statements=sum(len(v['edits']) for v in edits.values()),
         initialized_wires=sum(e['modelsim_assignment'] is not None for v in edits.values() for e in v['edits'])))
    iverilog = shutil.which('iverilog')
    if not iverilog:
        raise RuntimeError('iverilog absent')
    manifest = {}
    # Check every RTL file and the real include-only synthesis entry.
    relatives = [p.relative_to(ROOT).as_posix() for p in sorted((ROOT / 'rtl').glob('*.v'))]
    relatives.append('elinx/afdx_all.v')
    for relative in relatives:
        before = original(relative)
        after = (ROOT / relative).read_bytes()
        if relative not in edits and before != after:
            raise ValueError('Unlisted source changed: ' + relative)
        manifest[relative] = dict(before_sha256=digest(before), after_sha256=digest(after),
                                  byte_equal=before == after)
        for version, raw in [('original', before), ('modified', after)]:
            path = OUT / version / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(raw)
    proofs = []
    for relative in [*edits, 'elinx/afdx_all.v']:
        pair, jobs = [], []
        for version in ('original', 'modified'):
            target = OUT / ('preprocessed/' + version) / Path(relative).name
            target.parent.mkdir(parents=True, exist_ok=True)
            jobs.append(preprocess(iverilog, OUT / version / relative, target))
            pair.append(target.read_bytes())
        a, b = map(tokens, pair)
        # Independent stronger check: only extra empty lines may remain after
        # preprocessing. No token sorting or name normalization is used.
        nonblank = lambda raw: b'\n'.join(line for line in raw.splitlines() if line.strip())
        row = dict(file=relative, jobs=jobs, tokens_original=len(a), tokens_modified=len(b),
                   token_sha256_original=digest(json.dumps(a, ensure_ascii=True).encode('ascii')),
                   token_sha256_modified=digest(json.dumps(b, ensure_ascii=True).encode('ascii')),
                   token_equal=a == b, nonblank_lines_byte_equal=nonblank(pair[0]) == nonblank(pair[1]),
                   preprocessed_original_sha256=digest(pair[0]), preprocessed_modified_sha256=digest(pair[1]))
        proofs.append(row)
    passed = all(p['token_equal'] and p['nonblank_lines_byte_equal'] for p in proofs)
    report = dict(finished=stamp(), revision=REVISION, passed=passed, defined_on_command_line=[],
                  method='Icarus -g2001 -E, no -D macros; MODEL_TECH absent; native Icarus builtins retained. '
                         'Ordered lexical token comparison, plus exact nonblank-line byte comparison.',
                  source_files=manifest, proofs=proofs)
    save(EVIDENCE / 'v2_text_equivalence.json', report)
    print(json.dumps(dict(passed=passed, declaration_statements=21,
                         proofs=[{k: v for k, v in p.items() if k not in ('jobs',)} for p in proofs]), indent=2))
    return 0 if passed else 1


if __name__ == '__main__':
    raise SystemExit(main())
