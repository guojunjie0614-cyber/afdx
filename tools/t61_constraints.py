"""T61 exact timing guards for the two independently frozen controls."""
import hashlib
import json
from pathlib import Path
import check_multicycle

BASE_CONSTRAINT_SHA256 = '5328761C10377347042EF375481DA612F3B4C8DF401F9396FDE18AAA4D3BE150'
LEGACY_CONSTRAINT_SHA256 = 'B3782C141288F4EB293D7E2554A8E2F9F4DC223CFF9748D655139FE44E0C8789'
EXPECTED_SHA256 = BASE_CONSTRAINT_SHA256
PHYSICAL_POLICY = None
ORIGINAL_CONSTRAINTS = check_multicycle.constraints

class ConstraintBytes:
    def __init__(self, data): self.data = data
    def read_bytes(self): return self.data
    def read_text(self, encoding='utf-8-sig'): return self.data.decode(encoding)


def configure(root):
    global EXPECTED_SHA256, PHYSICAL_POLICY
    root = Path(root)
    EXPECTED_SHA256 = LEGACY_CONSTRAINT_SHA256 if root.name == 'c3_t61_e1' else BASE_CONSTRAINT_SHA256
    policy = root / 'out/t61/physical_guard.json'
    PHYSICAL_POLICY = json.loads(policy.read_text(encoding='utf-8')) if policy.is_file() else None
    if PHYSICAL_POLICY:
        if root.name not in ('c3_t61_e3', 'c3_t61_e4', 'c3_t61_e5', 'c3_t61_e6'):
            raise ValueError('Physical policy is not permitted for a control')
        proof = root / PHYSICAL_POLICY['native_proof_path']
        if hashlib.sha256(proof.read_bytes()).hexdigest().upper() != PHYSICAL_POLICY['native_proof_sha256']:
            raise ValueError('Native physical preparation proof changed')
        if not json.loads(proof.read_text(encoding='utf-8'))['passed']:
            raise ValueError('Physical syntax has no passing native placement proof')

def strict_constraints(path):
    data = path.read_bytes()
    if hashlib.sha256(data).hexdigest().upper() == EXPECTED_SHA256:
        timing = data
    elif PHYSICAL_POLICY:
        count = PHYSICAL_POLICY['baseline_bytes']
        timing, physical = data[:count], data[count:]
        if hashlib.sha256(timing).hexdigest().upper() != EXPECTED_SHA256:
            raise ValueError('T61: timing prefix differs from frozen r5 A')
        if physical.decode('utf-8') != PHYSICAL_POLICY['approved_suffix']:
            raise ValueError('T61: physical statements differ from the complete approved pin/member set')
    else:
        raise ValueError('T61: constraint differs from the selected frozen control')
    result = ORIGINAL_CONSTRAINTS(ConstraintBytes(timing))
    if result[1] != 0.30:
        raise ValueError('T61 requires exactly 0.30 ns setup uncertainty')
    return result

def install_guard(root):
    root = Path(root)
    configure(root)
    strict_constraints(root/'elinx/constraints.edc')
    check_multicycle.constraints = strict_constraints

def self_check(root):
    """Required rejection checks in memory; no synthetic RTL or EDA jobs."""
    root=Path(root)
    configure(root)
    path=root/'elinx/constraints.edc'
    source=path.read_bytes()
    baseline_data=source[:PHYSICAL_POLICY['baseline_bytes']] if PHYSICAL_POLICY else source
    baseline=ORIGINAL_CONSTRAINTS(ConstraintBytes(baseline_data))
    cases={'baseline':baseline_data,
           'period_changed':source.replace(b'-period 8.000',b'-period 9.000'),
           'uncertainty_changed':source.replace(b'-setup 0.30',b'-setup 0.20'),
           'multicycle_changed':source.replace(b'set_multicycle_path -setup 2',b'set_multicycle_path -setup 1',1),
           'unapproved_exception':source+b'\nset_false_path -from [get_ports {reset}]\n',
           'unobserved_pin_syntax':source+b'\nset_location_assignment PIN_J1 -to missing_port\n',
           'missing_region_member':source+b'\ncreate_pblock t61_missing -from X22_Y60 -to X41_Y75\nadd_cells_to_pblock t61_missing -to {missing_cell}\n'}
    if PHYSICAL_POLICY:
        cases['approved_physical'] = source
        cases['missing_port'] = source.replace(b'-to {clk}', b'-to {t61_missing_port}', 1)
        if b'add_cells_to_pblock' in source:
            cases['changed_region_member'] = source.replace(b'add_cells_to_pblock ', b'add_cells_to_pblock t61_missing ', 1)
    class InMemory:
        def __init__(self,data): self.data=data
        def read_bytes(self): return self.data
        def read_text(self,encoding='utf-8-sig'): return self.data.decode(encoding)
    tests=[]
    for name,data in cases.items():
        if name not in ('baseline','approved_physical') and data==source: raise RuntimeError('Mutation was not exercised: '+name)
        try:
            parsed=strict_constraints(InMemory(data))
            passed=(name in ('baseline','approved_physical') and parsed==baseline)
            detail='same timing semantics'
        except ValueError as error:
            passed=name not in ('baseline','approved_physical');detail=str(error)
        tests.append({'case':name,'passed':passed,'detail':detail})
    if not all(t['passed'] for t in tests): raise RuntimeError(str(tests))
    return {'tests':tests,'timing_semantics_unchanged':True,
            'physical_positive_tests':bool(PHYSICAL_POLICY) if PHYSICAL_POLICY else None,
            'physical_positive_tests_reason':'Exact native-validated statement set; all pins and packed members are required' if PHYSICAL_POLICY else 'No physical policy is required for this control',
            'mcp_definitions_sha256':hashlib.sha256(repr(baseline).encode()).hexdigest()}
