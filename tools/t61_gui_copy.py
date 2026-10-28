"""Create an isolated I/O Planning export project; never launch compilation."""
from pathlib import Path
import hashlib
import json
import shutil

ROOT = Path(__file__).resolve().parents[1]
SOURCE = Path('E:/2026_Embedded_FPGA/worktrees/active/c3_t60_r5a_p155/out/synth/AFDX_top/20261027_085802_489925/project')
INSTALL = Path('E:/2026_Embedded_FPGA/setup_pack')
DEST = Path('D:/2026_Embedded_FPGA_t61/preparation')

def main():
    runtime = DEST / 'gui_runtime'
    project_root = DEST / 'gui_project'
    project = project_root / 'elinx'
    if runtime.exists() or project_root.exists():
        raise RuntimeError('Existing preparation copy; inspect before reuse')
    if shutil.disk_usage('D:/').free < 12 * 1024**3:
        raise RuntimeError('Insufficient reserved space')
    runtime.mkdir(parents=True)
    before = {}
    for p in list(INSTALL.glob('*.dll')) + [INSTALL/'eLinx3.0.exe']:
        shutil.copy2(p, runtime/p.name)
    for relative in ('data', 'resource', 'platforms', 'translations', 'Licenses',
                     'iconengines', 'imageformats', 'bin/shell'):
        shutil.copytree(INSTALL/relative, runtime/relative)
    for p in (INSTALL/'data').rglob('*'):
        if p.is_file():
            before[str(p)] = hashlib.sha256(p.read_bytes()).hexdigest()
    shutil.copytree(ROOT/'elinx', project)
    shutil.copytree(ROOT/'rtl', project_root/'rtl')
    shutil.copytree(SOURCE/'AFDX_EndSystem.runs'/'synth_1', project/'AFDX_EndSystem.runs'/'synth_1')
    # GUI reads the packed synthesis result. Source files and constraints point
    # to this disposable project; old route data is retained only as a reference.
    for p in (project/'AFDX_EndSystem.runs'/'synth_1').glob('*.run.psf'):
        constraint=(project/'constraints.edc').as_posix()
        p.write_text('source {'+constraint+'}\nread_sdc {'+constraint+'}\nset_global_assignment -name TARGET_CONSTRAINT_FILE {'+constraint+'}\n', encoding='utf-8')
    record={'runtime':str(runtime),'project':str(project/'AFDX_EndSystem.epr'),
            'original_installation_data_hashes':before,'purpose':'I/O Planning export only; no synthesis/implementation'}
    output=ROOT/'out/t61/preparation/gui_copy.json'
    output.parent.mkdir(parents=True,exist_ok=True)
    output.write_text(json.dumps(record,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(record,indent=2))

if __name__=='__main__':
    main()
