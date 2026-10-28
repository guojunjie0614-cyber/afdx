"""Freeze task-approved synthesis copies and input identities for T61."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import xml.etree.ElementTree as ET

ROOT=Path(__file__).resolve().parents[1]
SOURCE_ROOT=Path('E:/2026_Embedded_FPGA/worktrees/active/c3_t60_r5a_p155')
SOURCE=SOURCE_ROOT/'out/synth/AFDX_top/20261027_085802_489925'
INSTALL=Path('E:/2026_Embedded_FPGA/setup_pack')

def sha(path):
    h=hashlib.sha256()
    with Path(path).open('rb') as f:
        for block in iter(lambda:f.read(1024*1024),b''):h.update(block)
    return h.hexdigest().upper()

def git(root,*args):
    return subprocess.check_output(['git','-c','safe.directory=*','-C',str(root),*args],text=True,encoding='utf-8').strip()

def closure(root):
    found={}
    def visit(path):
        path=path.resolve();relative=path.relative_to(root.resolve()).as_posix()
        if relative in found:return
        text=path.read_text(encoding='utf-8-sig')
        found[relative]={'sha256':sha(path),'bytes':path.stat().st_size,
                         'parameter_macro_declarations':[line.strip() for line in text.splitlines() if re.match(r'\s*(?:parameter\b|localparam\b|`(?:define|ifdef|ifndef|elsif)\b)',line)]}
        for inc in re.findall(r'^\s*`include\s+"([^"]+)"',text,re.M):visit(path.parent/inc)
    visit(root/'elinx/afdx_all.v')
    return found

def identities(root):
    closure_data=closure(root)
    settings={p.relative_to(root).as_posix():sha(p) for p in (root/'elinx').glob('*') if p.is_file() and p.suffix in ('.epr','.edc','.qdf','.qsf')}
    return {'root':str(root),'head':git(root,'rev-parse','HEAD'),'source_closure':closure_data,'setting_hashes':settings,
            'scripts':{p.relative_to(root).as_posix():sha(p) for p in (root/'tools').glob('*.py') if p.name.startswith(('t61_','official_','check_multicycle','report_routed_timing','eda.','adapt_gui_vqm'))}}

def freeze(candidate):
    candidate=Path(candidate).resolve()
    if candidate.parent!=Path('D:/2026_Embedded_FPGA_t61').resolve() or not re.fullmatch('c3_t61_e[2-6]',candidate.name):
        raise ValueError('Unexpected candidate root')
    original=json.loads((SOURCE/'summary.json').read_text(encoding='utf-8'))
    # Validate all original listed settings, then extend source coverage to the
    # actual recursive include closure before copying the packed checkpoint.
    for rel,digest in {**original['source_hashes'],**original['setting_hashes']}.items():
        if sha(SOURCE_ROOT/rel)!=digest or sha(candidate/rel)!=digest:raise RuntimeError('Source/settings changed: '+rel)
    a=closure(SOURCE_ROOT);b=closure(candidate)
    if a!=b:raise RuntimeError('Recursive source closure differs')
    if git(SOURCE_ROOT,'diff','HEAD','--','rtl','elinx'):raise RuntimeError('Canonical source has uncommitted changes')
    folder=candidate/'out/synth/AFDX_top/t61_frozen_v1'
    if folder.exists():raise RuntimeError('Freeze target already exists')
    if shutil.disk_usage(candidate).free<11*1024**3:raise RuntimeError('Disk reserve insufficient for new frozen copy')
    project=folder/'project';synth=project/'AFDX_EndSystem.runs/synth_1'
    synth.parent.mkdir(parents=True)
    source_synth=SOURCE/'project/AFDX_EndSystem.runs/synth_1'
    source_hashes={p.relative_to(source_synth).as_posix():sha(p) for p in source_synth.rglob('*') if p.is_file()}
    shutil.copytree(source_synth,synth)
    copied_hashes={p.relative_to(synth).as_posix():sha(p) for p in synth.rglob('*') if p.is_file()}
    if source_hashes!=copied_hashes:raise RuntimeError('Incomplete checkpoint copy')
    for name in ('AFDX_EndSystem.epr','AFDX_EndSystem_assignment_defaults.qdf','constraints.edc'):
        shutil.copy2(candidate/'elinx'/name,project/name)
    c=(project/'constraints.edc').as_posix()
    (synth/'AFDX_EndSystem.run.psf').write_text('source {'+c+'}\nread_sdc {'+c+'}\nset_global_assignment -name TARGET_CONSTRAINT_FILE {'+c+'}\n',encoding='utf-8')
    mapped={**original,'folder':str(folder),'netlist':str(synth/'AFDX_EndSystem.vqm'),
            'source_hashes':{rel:row['sha256'] for rel,row in b.items()},
            'resources_report':str(synth/'AFDX_EndSystem_utilization_synth.rpt'),
            'timing_database':str(synth/'AFDX_EndSystem.tan.pb'),
            'multicycle_audit':None,'jobs':[],
            'reused_from':str(SOURCE),'reused_without_synthesis_or_packing':True,
            'source_summary_sha256':sha(SOURCE/'summary.json'),
            'original_synth1_hashes':source_hashes,'copied_synth1_initial_hashes':copied_hashes,
            'candidate_synth1_hashes':{p.relative_to(synth).as_posix():sha(p) for p in synth.rglob('*') if p.is_file()}}
    (folder/'summary.json').write_text(json.dumps(mapped,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    (candidate/'out/latest_AFDX_top.json').write_text(json.dumps(mapped,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    record=identities(candidate)
    record.update(synthesis=str(folder),synth1_files=mapped['candidate_synth1_hashes'],original_synth1_files=source_hashes,
                  netlist_sha256=sha(synth/'AFDX_EndSystem.vqm'),checkpoint_sha256=sha(synth/'AFDX_EndSystem_eHiChip6.ecp'))
    print(json.dumps(record,ensure_ascii=False,indent=2))
    return record

def main():
    ap=argparse.ArgumentParser();ap.add_argument('candidate',type=Path);args=ap.parse_args()
    freeze(args.candidate)

if __name__=='__main__':main()
