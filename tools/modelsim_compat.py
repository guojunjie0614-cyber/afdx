"""Narrow declaration-order adapter for disposable ModelSim source snapshots.

Only the reviewed declarations below may move. This is deliberately not a
Verilog rewriter: unfamiliar declarations/scopes fail closed, other paths pass
through unchanged, and this module performs no filesystem writes. Callers own
snapshot creation and recording the returned JSON-serializable audit records.

Whole, uninitialized declarations (including attributes and grouped names) move
immediately after the module header. Initialized wires become an early wire
declaration plus a continuous assignment at the original location. Initialized
regs are not supported by the allowlist: they raise instead of accidentally
turning a time-zero initialization into a continuous assignment or changing its
scheduling. No reset, initial block, function, fork, or expression is rewritten.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import PurePosixPath


# Exact declaration heads, excluding only the semicolon / net initializer.
# Widths are literals, so moving these ahead of body localparams is safe.
# Keep complete grouped declarations to preserve their shared type/attributes.
_DECLARATIONS: dict[str, tuple[str, ...]] = {
    "rtl/afdx_615a.v": (
        "wire [1:0] engine_status",
        "wire [15:0] engine_main_tid",
        "wire [15:0] engine_status_tid",
        "wire [15:0] engine_deny_tid",
    ),
    "rtl/afdx_app_tx.v": ("wire read_en",),
    "rtl/afdx_rtc.v": (
        "wire [31:0] receive_timestamp_seconds",
        "wire [31:0] receive_timestamp_nanoseconds",
        "(* preserve=1,dont_merge=1 *) reg rtc_run_ctl, rtc_request_armed",
        "wire rtc_client_launch",
        "wire rtc_server_launch",
    ),
    "rtl/afdx_rx_engine.v": (
        "(* preserve=1, dont_merge=1 *) reg frame_start_q, age_start_q",
        "wire age_tick",
        "reg dq_commit",
        "reg dq_room",
        "wire fragmented",
    ),
    "rtl/afdx_rx_parse.v": (
        "reg [15:0] vlid, sport, dport, ip_len, udp_len, udp_check, n, "
        "ip_expected, end_data, sn_position, expected_len",
    ),
    "rtl/afdx_rx_reassembly_bank.v": (
        "(* preserve=1, dont_merge=1 *) reg query_active, query_start",
        "(* preserve=1, dont_merge=1 *) reg commit_cmd, allocate",
        "wire payload_we",
        "(* maxfan=16 *) reg [13:0] output_position",
    ),
    "rtl/afdx_tx_engine.v": ("reg [31:0] words[0:5]",),
}

# Comments and strings are atomic: identifiers inside them cannot match code.
# This lexer only locates reviewed token sequences; it does not parse Verilog.
_LEX = re.compile(
    r'(?P<comment>//[^\r\n]*|/\*[\s\S]*?\*/)'
    r'|(?P<token>"(?:\\[\s\S]|[^"\\])*"|\\[^\s]+'
    r'|`[A-Za-z_][A-Za-z_0-9$]*|[A-Za-z_$][A-Za-z_0-9$]*'
    r'|\d+|\(\*|\*\)|\S)'
)
_OPEN = {"begin": "end", "generate": "endgenerate", "function": "endfunction",
         "task": "endtask", "case": "endcase", "casex": "endcase",
         "casez": "endcase", "fork": "join"}
_CLOSE = set(_OPEN.values()) | {"join_any", "join_none"}


@dataclass(frozen=True)
class _Token:
    value: str
    start: int
    end: int


def _tokens(text: str) -> list[_Token]:
    return [_Token(m.group(), m.start(), m.end()) for m in _LEX.finditer(text)
            if m.lastgroup == "token"]


def _module_header(tokens: list[_Token], module: str) -> int:
    modules = [i for i, token in enumerate(tokens) if token.value == "module"]
    ends = [i for i, token in enumerate(tokens) if token.value == "endmodule"]
    if len(modules) != 1 or len(ends) != 1:
        raise ValueError("expected exactly one reviewed module")
    start = modules[0]
    if tokens[start + 1].value != module:
        raise ValueError(f"expected module {module}")
    depth = 0
    for i in range(start + 2, ends[0]):
        value = tokens[i].value
        if value == "(":
            depth += 1
        elif value == ")":
            depth -= 1
        elif value == ";" and depth == 0:
            return i
        if depth < 0:
            break
    raise ValueError("cannot locate balanced module header")


def _check_scope(tokens: list[_Token], header: int, declaration: int) -> None:
    """Reject nested declarations and movement across preprocessor directives."""
    stack: list[str] = []
    attribute = False
    for token in tokens[header + 1:declaration]:
        value = token.value
        if value.startswith("`"):
            raise ValueError("cannot hoist across a preprocessor directive/macro")
        if value == "(*":
            attribute = True
        elif value == "*)":
            attribute = False
        elif not attribute:
            if value in _OPEN:
                stack.append(_OPEN[value])
            elif value in _CLOSE:
                expected = "join" if value in ("join_any", "join_none") else value
                if not stack or stack.pop() != expected:
                    raise ValueError("unrecognized enclosing scope")
    if stack or attribute:
        raise ValueError("reviewed declaration is not at module scope")


def adapt_text(relative_path: str, text: str) -> tuple[str, list[dict]]:
    """Return a simulation-only copy and original-line-number audit records.

    Accept project-relative paths with either slash style (and optional './').
    Unknown paths, including all testbenches, are byte-for-byte text passthrough.
    Missing/changed/duplicate reviewed declarations raise ValueError; callers
    must not silently fall back to compiling partially adapted sources. Running
    this on its own output is a no-op with an empty adaptation list.
    """
    path = PurePosixPath(relative_path.replace("\\", "/")).as_posix()
    declarations = _DECLARATIONS.get(path)
    if declarations is None:
        return text, []

    try:
        tokens = _tokens(text)
        values = [token.value for token in tokens]
        header = _module_header(tokens, PurePosixPath(path).stem)
        insert_at = tokens[header].end
        edits: list[tuple[int, int, str]] = []
        moved: list[str] = []
        records: list[dict] = []
        plans = []
        for declaration in declarations:
            head = [t.value for t in _tokens(declaration)]
            size = len(head)
            matches = [i for i in range(header + 1, len(tokens) - size)
                       if values[i:i + size] == head
                       and values[i + size] in (";", "=")]
            if len(matches) != 1:
                raise ValueError(f"expected one declaration: {declaration!r}; got {len(matches)}")
            start = matches[0]
            _check_scope(tokens, header, start)
            # Prevent a newly added attribute from being left behind / detached.
            if values[start - 1] == "*)":
                raise ValueError(f"unreviewed attribute before {declaration!r}")
            kind_index = next(i for i, value in enumerate(head) if value in ("wire", "reg"))
            kind = head[kind_index]
            # Names follow the optional packed literal range; unpacked ranges
            # contain only numbers in this explicit allowlist.
            names = [value for value in head[kind_index + 1:]
                     if re.fullmatch(r"[A-Za-z_$][A-Za-z_0-9$]*", value)]
            delimiter = start + size
            initialized = values[delimiter] == "="
            end = delimiter
            if initialized:
                if kind != "wire" or len(names) != 1:
                    raise ValueError(f"unreviewed declaration initializer: {declaration!r}")
                while end < len(tokens) and values[end] != ";":
                    end += 1
                if end == len(tokens):
                    raise ValueError(f"unterminated declaration: {declaration!r}")
                # A comma outside expression delimiters means another net has
                # been added. Do not split that unreviewed grouped declaration.
                depth = 0
                for value in values[delimiter + 1:end]:
                    if value in ("(", "[", "{"):
                        depth += 1
                    elif value in (")", "]", "}"):
                        depth -= 1
                    elif value == "," and depth == 0:
                        raise ValueError("unreviewed grouped wire initializer")
                    if value.startswith("`") or value in ("wire", "reg", "endmodule"):
                        raise ValueError("unreviewed wire initializer syntax")
                if depth != 0:
                    raise ValueError("unbalanced wire initializer")
            # Already declared before every use (including a previous call's
            # hoisted declarations): retain verbatim, no audit entry needed.
            if not any(value in names for value in values[header + 1:start]):
                continue
            plans.append((start, delimiter, end, kind, names, initialized))

        # Preserve source declaration order rather than allowlist order.
        for start, delimiter, end, kind, names, initialized in sorted(plans):
            begin_offset, end_offset = tokens[start].start, tokens[end].end
            original = text[begin_offset:end_offset]
            if initialized:
                # Keep the original initializer expression, whitespace and
                # comments at its original source site. A net initializer is
                # a continuous assignment in both Verilog and SystemVerilog.
                hoisted = text[begin_offset:tokens[delimiter].start] + ";"
                replacement = "assign " + names[0] + " " + text[tokens[delimiter].start:end_offset]
                action = "hoist_wire_declaration_keep_continuous_assignment"
            else:
                hoisted = original
                replacement = ""
                action = "hoist_declaration"
            moved.append(hoisted)
            edits.append((begin_offset, end_offset, replacement))
            records.append({
                "path": path,
                "action": action,
                "names": names,
                "original_line": text.count("\n", 0, begin_offset) + 1,
                "insert_after_line": text.count("\n", 0, insert_at) + 1,
                "original": original,
                "hoisted": hoisted,
                "replacement": replacement,
            })
        if not edits:
            return text, []
        newline = "\r\n" if "\r\n" in text else "\n"
        block = newline + "    // ModelSim simulation-copy declaration ordering only." + newline
        block += newline.join("    " + item for item in moved) + newline
        edits.append((insert_at, insert_at, block))
        for start, end, replacement in sorted(edits, reverse=True):
            text = text[:start] + replacement + text[end:]
        return text, records
    except ValueError as exc:
        raise ValueError(f"ModelSim compatibility ({path}): {exc}") from exc
