"""Declaration-order portability adapter; writes simulation copies in out only.

ModelSim 2020.4 rejects these forward references, which the branch's synthesis
and Icarus accept. Move declarations without changing their width/type or any
expression. Net declaration assignments remain continuous assignments at their
original location. This adapter never writes an original RTL source.
"""
import hashlib
from pathlib import Path
import re

DECLARATIONS = {
    'afdx_615a.v': ('engine_status', 'engine_main_tid', 'engine_status_tid', 'engine_deny_tid'),
    'afdx_app_tx.v': ('read_en',),
    'afdx_rtc.v': ('receive_timestamp_seconds', 'receive_timestamp_nanoseconds',
                   'rtc_request_armed', 'rtc_server_launch', 'rtc_client_launch'),
    'afdx_rx_engine.v': ('frame_start_q', 'age_start_q', 'age_tick', 'dq_commit', 'dq_room', 'fragmented'),
    'afdx_rx_parse.v': ('ip_len',),
    'afdx_rx_reassembly_bank.v': ('query_start', 'commit_cmd', 'payload_we', 'output_position'),
    'afdx_tx_engine.v': ('words',),
}
OPEN_PORTS = {
    'afdx_app_tx.v': ('.read_data(memory_q));', '.read_data(memory_q),.raw_write_data());'),
    'afdx_app_rx.v': ('.valid(q_valid),.ready(q_ready),.data(q_data));',
                      '.valid(q_valid),.ready(q_ready),.data(q_data),.next_limit());'),
}


def adapt(source, destination):
    source, destination = Path(source), Path(destination)
    original = source.read_bytes()
    raw_text = original.decode('utf-8-sig')
    finish_count = raw_text.count('$finish_and_return(1)')
    text = raw_text.replace('$finish_and_return(1)', '$fatal(1, "branch assertion failed")')
    open_port = OPEN_PORTS.get(source.name)
    if open_port:
        before, after = open_port
        if text.count(before) != 1:
            raise ValueError('Optional open-port instance is not unique: ' + source.name)
        text = text.replace(before, after)
    lines = text.splitlines(keepends=True)
    names = DECLARATIONS.get(source.name, ())
    moved, edits, found = [], [], set()
    for index, line in enumerate(lines):
        match = re.fullmatch(r'(\s*(?:\(\*[^\n]*?\*\)\s*)?(wire|reg)\s+(?:\[[^\n]+?\]\s*)?)([^;\n]+);\s*\r?\n?', line)
        if not match:
            continue
        head, kind, body = match.groups()
        # Identify declared identifiers, excluding references in initializers.
        lhs = body.split('=', 1)[0]
        declared = set(re.findall(r'\b[A-Za-z_][A-Za-z0-9_]*\b', lhs))
        targets = declared.intersection(names)
        if not targets:
            continue
        found.update(targets)
        if '=' in body:
            if kind != 'wire' or ',' in lhs:
                raise ValueError('Unsupported initialized declaration: ' + line.strip())
            name, expression = body.split('=', 1)
            declaration = head + name.rstrip() + ';\n'
            replacement = '    assign ' + name.strip() + ' =' + expression + ';\n'
        else:
            declaration, replacement = line, '\n'
        moved.append(declaration)
        edits.append(dict(line=index + 1, original=line, declaration=declaration, replacement=replacement))
        lines[index] = replacement
    if found != set(names):
        raise ValueError(f'Declaration adapter did not find {source.name}: {set(names)-found}')
    # Only the first (top-level) module in each explicitly listed file changes.
    header = re.search(r'(?ms)^module\b.*?;\s*\n', text)
    if not header:
        raise ValueError('Module header absent: ' + source.name)
    insertion = len(text[:header.end()].splitlines())
    lines[insertion:insertion] = moved
    adapted = ''.join(lines)
    # Check an exact inverse before writing: every remaining source byte is
    # unchanged, and each moved declaration has exactly one original location.
    inverse = list(lines)
    del inverse[insertion:insertion + len(moved)]
    for edit in edits:
        inverse[edit['line'] - 1] = edit['original']
    if ''.join(inverse) != text:
        raise ValueError('Declaration-only inverse check failed')
    restored = text.replace('$fatal(1, "branch assertion failed")', '$finish_and_return(1)')
    if open_port:
        restored = restored.replace(open_port[1],open_port[0])
    if restored != raw_text:
        raise ValueError('System-task inverse check failed')
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(adapted.encode('utf-8'))
    return dict(source=str(source), copy=str(destination), edits=edits,
                source_sha256=hashlib.sha256(original).hexdigest().upper(),
                copy_sha256=hashlib.sha256(destination.read_bytes()).hexdigest().upper(),
                finish_and_return_to_fatal=finish_count,
                explicit_open_optional_port=open_port,
                exact_inverse_verified=True)


def prepare(sources, folder):
    compiled, evidence = [], []
    for source in sources:
        if source.name in DECLARATIONS or source.name in OPEN_PORTS or b'$finish_and_return(1)' in source.read_bytes():
            target = folder / 'modelsim_rtl' / source.name
            evidence.append(adapt(source, target))
            compiled.append(target)
        else:
            compiled.append(source)
    return compiled, evidence
