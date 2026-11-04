"""Adopt the reviewed mode-3 test changes only after the base queue ends."""
import hashlib
import json
from pathlib import Path
import subprocess

ROOT=Path(__file__).resolve().parents[1]

def main():
    evidence=ROOT/'docs/evidence/t79_63vl'
    base=json.loads((ROOT/'out/t79_resume/run.json').read_text())
    assert base['status']=='PASS','Base scenarios must finish before their live source inputs change'
    proof=json.loads((evidence/'mixed3_code_path_proof.json').read_text())
    adopted={}
    for rel,change in proof['changes'].items():
        target=ROOT/rel;source=ROOT/'out/t79_long_source'/rel
        assert hashlib.sha256(target.read_bytes()).hexdigest()==change['base_sha256'],rel
        assert hashlib.sha256(source.read_bytes()).hexdigest()==change['new_sha256'],rel
        target.write_bytes(source.read_bytes())
        adopted[rel]=change['new_sha256']
    for p in (ROOT/'rtl').glob('*.v'):
        assert p.read_bytes()==subprocess.check_output(['git','show','f4632d5c:rtl/'+p.name])
    (evidence/'mixed3_adoption.json').write_text(json.dumps(dict(
        base_queue_status=base['status'],base_queue_finished=base['finished'],
        adopted_files=adopted,rtl_unchanged=True,
        note='Long tests continue against their unchanged isolated source tree; no running base input was changed.'),indent=2)+'\n',encoding='utf-8')
    print('Adopted mode-3 test-only changes; RTL unchanged')

if __name__=='__main__':main()
