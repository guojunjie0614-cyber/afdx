"""Prepare an isolated dual-constraint GUI investigation; do not claim GUI pass."""
import json
from pathlib import Path
import shutil
import xml.etree.ElementTree as ET

import eda
import official_synth
import t62_constraints
import t62_runtime as runtime

ROOT=Path(__file__).resolve().parents[1]


def main():
    directory=ROOT/'out/t62/preparation/gui_project'
    directory.mkdir(parents=True,exist_ok=False)
    project=directory/'elinx';project.mkdir()
    shutil.copytree(ROOT/'rtl',directory/'rtl')
    # A complete independent project copy also preserves its simulation set.
    shutil.copytree(ROOT/'tb',directory/'tb')
    for name in ['afdx_all.v','AFDX_EndSystem_assignment_defaults.qdf','constraints_t62.json']:
        shutil.copy2(ROOT/'elinx'/name,project/name)
    t62_constraints.generate(project,'1.55')
    document=ET.parse(ROOT/'elinx/AFDX_EndSystem.epr')
    constraints=document.getroot().find("./FileSets/FileSet[@Name='constrs_1']")
    for entry in list(constraints.findall('File')):
        constraints.remove(entry)
    constraints.insert(0,ET.Element('File',Path='/physical_only.edc'))
    constraints.insert(1,ET.Element('File',Path='/timing_only.sdc'))
    constraints.find("./Config/Option[@Name='TargetConstrsFile']").set('Val','/physical_only.edc')
    document.write(project/'AFDX_EndSystem.epr',encoding='utf-8',xml_declaration=True)
    parts=t62_constraints.check_project_files([project/'physical_only.edc',project/'timing_only.sdc'])
    assert parts==t62_constraints.split((project/'constraints.edc').read_text(encoding='utf-8'))
    result=dict(status='blocked',reason_code='awaiting_user_gui',project=str(project/'AFDX_EndSystem.epr'),
        static_dual_file_equivalence=True,actual_gui_generated_psf_verified=None,
        native_gui_log_verified=None,actual_gui_172_p0_verified=None,deliverable=False,
        reason='This session has no enabled native desktop control API. Independent project and CLI dual-file parsing are prepared; GUI generation has not been observed.',
        source_hashes={p.relative_to(directory).as_posix():eda.sha(p) for p in directory.rglob('*') if p.is_file()},
        steps=[
            '在 eLinx 中打开本结果的独立 AFDX_EndSystem.epr；不要打开或改写 C0、候选和 T61 工程。',
            '检查约束集同时登记 physical_only.edc 和 timing_only.sdc，目标物理约束为 physical_only.edc。',
            '在此副本执行 Run Synthesis / Implementation；若仍报 Error(292026)许可问题，保留日志并停止，不更改系统许可。',
            '读取界面新生成的 synth_1/imple_1 的 .run.psf：source 只读物理 EDC、read_sdc 只读纯时序 SDC，两份文件来自 constraints_t62.json。',
            '检查原生日志：125MHz、setup uncertainty 0.30ns、原 MCP、PRES1.55；无 invalid-command、约束错误或零匹配。',
            '实现完成后用实际 .place 逐项对照全部172个P0管脚；上述任何一步未经验证都不能宣布界面可交付。'],
        race_policy='No background rewrite of GUI-generated files; no running candidate input was edited')
    runtime.save(ROOT/'out/t62/preparation/gui_result.json',result)
    print(json.dumps({k:v for k,v in result.items() if k!='source_hashes'},ensure_ascii=False,indent=2))


if __name__=='__main__':
    main()
