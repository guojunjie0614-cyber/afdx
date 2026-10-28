"""T61 stage-E timing guard; no unobserved physical syntax is authorized."""
import hashlib
from pathlib import Path
import check_multicycle

BASE_CONSTRAINT_SHA256 = '5328761C10377347042EF375481DA612F3B4C8DF401F9396FDE18AAA4D3BE150'
ORIGINAL_CONSTRAINTS = check_multicycle.constraints

def strict_constraints(path):
    data = path.read_bytes()
    if hashlib.sha256(data).hexdigest().upper() != BASE_CONSTRAINT_SHA256:
        raise ValueError('T61: constraint differs from frozen r5 A P1.55; physical export is unavailable')
    result = ORIGINAL_CONSTRAINTS(path)
    if result[1] != 0.30:
        raise ValueError('T61 requires exactly 0.30 ns setup uncertainty')
    return result

def install_guard(root):
    root = Path(root)
    strict_constraints(root/'elinx/constraints.edc')
    check_multicycle.constraints = strict_constraints

def self_check(root):
    """Required rejection checks in memory; no synthetic RTL or EDA jobs."""
    root=Path(root)
    path=root/'elinx/constraints.edc'
    source=path.read_bytes()
    baseline=ORIGINAL_CONSTRAINTS(path)
    cases={'baseline':source,
           'period_changed':source.replace(b'-period 8.000',b'-period 9.000'),
           'uncertainty_changed':source.replace(b'-setup 0.30',b'-setup 0.20'),
           'multicycle_changed':source.replace(b'set_multicycle_path -setup 2',b'set_multicycle_path -setup 1',1),
           'unapproved_exception':source+b'\nset_false_path -from [get_ports {reset}]\n',
           'unobserved_pin_syntax':source+b'\nset_location_assignment PIN_J1 -to missing_port\n',
           'missing_region_member':source+b'\ncreate_pblock t61_missing -from X22_Y60 -to X41_Y75\nadd_cells_to_pblock t61_missing -to {missing_cell}\n'}
    class InMemory:
        def __init__(self,data): self.data=data
        def read_bytes(self): return self.data
        def read_text(self,encoding='utf-8-sig'): return self.data.decode(encoding)
    tests=[]
    for name,data in cases.items():
        if name!='baseline' and data==source: raise RuntimeError('Mutation was not exercised: '+name)
        try:
            parsed=strict_constraints(InMemory(data))
            passed=(name=='baseline' and parsed==baseline)
            detail='same timing semantics'
        except ValueError as error:
            passed=name!='baseline';detail=str(error)
        tests.append({'case':name,'passed':passed,'detail':detail})
    if not all(t['passed'] for t in tests): raise RuntimeError(str(tests))
    return {'tests':tests,'timing_semantics_unchanged':True,
            'physical_positive_tests':None,
            'physical_positive_tests_reason':'Blocked: I/O Planning export not obtained; no guessed pin syntax or zero-match success permitted',
            'mcp_definitions_sha256':hashlib.sha256(repr(baseline).encode()).hexdigest()}
