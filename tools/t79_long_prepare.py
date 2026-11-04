"""Prepare a task-owned mode-3 source tree without touching active run inputs."""
import hashlib
import json
from pathlib import Path
import subprocess

ROOT=Path(__file__).resolve().parents[1]
DEST=ROOT/'out/t79_long_source'

def main():
    DEST.mkdir(parents=True,exist_ok=False)
    files=list((ROOT/'rtl').glob('*.v'))+[ROOT/p for p in (
        'tb/tb_t76_load.v','tb/lib/t76_load_endpoint.v','tb/lib/afdx_x_monitor.v',
        'tools/t76_sim.py','tools/t76_stats.py','tools/eda.py','tools/adapt_gui_vqm.py',
        'tools/modelsim_sources.py','sim/t76_stats.tcl')]
    base={}
    for p in files:
        rel=p.relative_to(ROOT);target=DEST/rel;target.parent.mkdir(parents=True,exist_ok=True)
        data=subprocess.check_output(['git','show','468a5e6:'+rel.as_posix()],cwd=ROOT)
        target.write_bytes(data);base[rel.as_posix()]=hashlib.sha256(data).hexdigest()
    replacements={
        'tb/lib/t76_load_endpoint.v':[
            ('MIXED=0,NET_RX=0','MIXED=0,NET_RX=0,LONG_COUNT=1'),
            ('            if(MIXED==2 && vl==VL_COUNT-1)message_length=1472;',
             '            if(MIXED==2 && vl==VL_COUNT-1)message_length=1472;\n'
             '            if(MIXED==3 && sequence>0 && vl>=VL_COUNT-LONG_COUNT)message_length=8192;')],
        'tb/tb_t76_load.v':[
            ('SMOKE=0,SWAP=0,BAG_BURST=0','SMOKE=0,SWAP=0,BAG_BURST=0,LONG_COUNT=1'),
            ('GROUP_LENGTH,MIXED,SWAP)','GROUP_LENGTH,MIXED,SWAP,LONG_COUNT)'),
            ('GROUP_LENGTH,MIXED,!SWAP)','GROUP_LENGTH,MIXED,!SWAP,LONG_COUNT)'),
            ('$fwrite(fd,"%0d %0d %0d %0d %0d %0d %0d\\n",epoch,epoch+DURATION,VL_COUNT,GROUP_LENGTH,MIXED,DUPLEX,BAG_BURST);',
             'if(MIXED==3)$fwrite(fd,"%0d %0d %0d %0d %0d %0d %0d %0d\\n",epoch,epoch+DURATION,VL_COUNT,GROUP_LENGTH,MIXED,DUPLEX,BAG_BURST,LONG_COUNT);\n'
             '        else $fwrite(fd,"%0d %0d %0d %0d %0d %0d %0d\\n",epoch,epoch+DURATION,VL_COUNT,GROUP_LENGTH,MIXED,DUPLEX,BAG_BURST);')],
        'tools/t76_sim.py':[
            ('SMOKE=0,SWAP=0,BAG_BURST=0)','SMOKE=0,SWAP=0,BAG_BURST=0,LONG_COUNT=1)'),
            ("    flow = eda.Flow('t76_sim'", "    if params['MIXED']==3 and (params['GROUP_LENGTH']!=1471 or params['BAG_BURST'] or not 1<=params['LONG_COUNT']<=params['VL_COUNT']):\n"
             "        parser.error('Mode 3 requires 1..VL_COUNT long VLs, 1471-byte short messages and no BAG burst')\n"
             "    if params['MIXED']!=3:params.pop('LONG_COUNT')\n"
             "    flow = eda.Flow('t76_sim'")],
        'tools/t76_stats.py':[
            ("    burst=window[6] if len(window)>6 else 0", "    burst=window[6] if len(window)>6 else 0\n    long_count=window[7] if len(window)>7 else 1"),
            ('                    length=1472 if mixed==2', '                    length=8192 if mixed==3 and sequence>0 and vl>=vls-long_count else 1472 if mixed==2'),
            ('    (folder/\'t76_samples.json\').write_text', "    if mixed==3:result['long_count']=long_count\n    (folder/'t76_samples.json').write_text")]
    }
    changed={}
    for rel,edits in replacements.items():
        p=DEST/rel;original=p.read_text(encoding='utf-8');text=original
        for old,new in edits:
            assert text.count(old)==1,(rel,old)
            text=text.replace(old,new)
        inverse=text
        for old,new in reversed(edits):
            assert inverse.count(new)==1,(rel,'inverse')
            inverse=inverse.replace(new,old)
        assert inverse==original
        p.write_bytes(text.encode('utf-8'))
        changed[rel]=dict(base_sha256=base[rel],new_sha256=hashlib.sha256(p.read_bytes()).hexdigest(),
            exact_inverse_verified=True,edits=edits)
    evidence=ROOT/'docs/evidence/t79_63vl'
    (evidence/'mixed3_code_path_proof.json').write_text(json.dumps(dict(
        source_tree=str(DEST),changes=changed,baseline_hashes=base,
        reasoning='MIXED=0/1/2: added length branch is false; original branches and all due/sequence scheduling remain byte-identical. LONG_COUNT defaults to 1 and is unused in old modes. Existing seven-field window output is unchanged. Python coverage extra branch is false, Tcl is byte-identical. All RTL is copied unchanged.',
        fragment_billing='First seq=0 message is 1471 B; subsequent long seqs are 8192 B, six frames, next due +=6*125000 cycles. No phase or statistics formula change.'),indent=2)+'\n',encoding='utf-8')
    print(DEST)

if __name__=='__main__':main()
