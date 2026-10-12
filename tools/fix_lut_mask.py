"""Adapt an eLinx mapped netlist for ModelSim functional simulation only.

The original netlist is retained. The vendor backend writes a 16-bit LUT mask
as a comma-separated list of gnd/vcc identifiers; Verilog requires one value.
Some emitted arithmetic LUTs omit the model's explicit carry-use parameter;
some RAM instances omit ports for which the model provides pull defaults.
"""
import pathlib
import re
import sys


source = pathlib.Path(sys.argv[1])
target = pathlib.Path(sys.argv[2])
data = source.read_text(encoding="utf-8")
pattern = re.compile(r"\.lut_mask\(\s*((?:\\(?:gnd|vcc)\s*,\s*){15}\\(?:gnd|vcc))\s*\)")


def replace(match):
    bits = re.findall(r"\\(gnd|vcc)", match.group(1))
    assert len(bits) == 16
    # eLinx emits bit 15 first; the vendor model parses hexadecimal digits
    # in that same order. Reversing the list corrupts synchronous reset LUTs.
    value = int("".join("1" if bit == "vcc" else "0" for bit in bits), 2)
    return f'.lut_mask("{value:04x}")'


fixed, count = pattern.subn(replace, data)
if count == 0 or fixed.count(".lut_mask(") != count:
    raise SystemExit("unexpected LUT mask format; refusing partial repair")
input_defaults = {
    "dataa": "1'b0", "datab": "1'b0", "datac": "1'b0", "datad": "1'b0",
    "clk": "1'b0", "aclr": "1'b0", "aload": "1'b0", "sclr": "1'b0",
    "sload": "1'b0", "ena": "1'b1", "cin": "1'b0", "cin0": "1'b0",
    "cin1": "1'b0", "inverta": "1'b0", "regcascin": "1'b0",
    "devclrn": "1'b1", "devpor": "1'b1",
}
outputs = ("combout", "regout", "cout", "cout0", "cout1")
cell = re.compile(r"(stratix_lcell\s*#\([\s\S]*?\)\s+\S+\s*\()([\s\S]*?)(\);)")
carry_repairs = 0


def tie_ports(match):
    global carry_repairs
    head = match.group(1)
    body = match.group(2).rstrip()
    present = set(re.findall(r"\.(\w+)\s*\(", body))
    if '.operation_mode("arithmetic")' in head:
        enabled = [port for port in ("cin", "cin0", "cin1") if port in present]
        missing_params = [port for port in enabled if f".{port}_used(" not in head]
        if missing_params:
            offset = head.rfind(")")
            head = (head[:offset] + ",\n    " +
                    ",\n    ".join(f'.{port}_used("true")' for port in missing_params) +
                    head[offset:])
            carry_repairs += 1
    missing = [f".{port}({value})" for port, value in input_defaults.items() if port not in present]
    missing += [f".{port}()" for port in outputs if port not in present]
    if missing:
        body += ("," if body.rstrip().endswith(")") else "") + "\n    " + ",\n    ".join(missing) + "\n  "
    return head + body + match.group(3)


fixed, cells = cell.subn(tie_ports, fixed)
if cells != count:
    raise SystemExit(f"expected {count} lcell instances, found {cells}")
ram_defaults = {
    "ena0": "1'b1", "ena1": "1'b1", "clk1": "1'b0",
    "clr0": "1'b0", "clr1": "1'b0", "devclrn": "1'b1",
    "devpor": "1'b1",
}
ram_outputs = ("portadataout", "portbdataout")
ram = re.compile(r"(stratix_ram_block\s*#\([\s\S]*?\)\s+\S+\s*\()([\s\S]*?)(\);)")


def tie_ram_ports(match):
    body = match.group(2).rstrip()
    present = set(re.findall(r"\.(\w+)\s*\(", body))
    def width(parameter):
        found = re.search(r"\." + parameter + r"\(32'd(\d+)\)", match.group(1))
        value = int(found.group(1)) if found else 1  # Vendor model default.
        if not 1 <= value <= 512:
            raise ValueError(f"unexpected {parameter}={value}")
        return value

    defaults = dict(ram_defaults)
    defaults["portbdatain"] = f"{width('port_b_data_width')}'b0"
    defaults["portabyteenamasks"] = "{" + str(width('port_a_byte_enable_mask_width')) + "{1'b1}}"
    defaults["portbbyteenamasks"] = "{" + str(width('port_b_byte_enable_mask_width')) + "{1'b1}}"
    missing = [f".{port}({value})" for port, value in defaults.items() if port not in present]
    missing += [f".{port}()" for port in ram_outputs if port not in present]
    if missing:
        body += ("," if body.rstrip().endswith(")") else "") + "\n    " + ",\n    ".join(missing) + "\n  "
    return match.group(1) + body + match.group(3)


fixed, ram_cells = ram.subn(tie_ram_ports, fixed)
if ram_cells == 0 and "--allow-no-ram" not in sys.argv[3:]:
    raise SystemExit("no RAM primitive instances found")
target.write_text(fixed, encoding="utf-8")
print(f"Repaired {count} LUT masks (MSB first), {carry_repairs} arithmetic carry parameters, tied omitted ports on {cells} LUT and {ram_cells} RAM instances in simulation copy; source retained: {source}")
