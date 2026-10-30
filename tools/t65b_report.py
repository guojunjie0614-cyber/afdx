"""Publish one completed T65b batch, without rerunning any simulation."""
import re
import sys
from datetime import datetime
from pathlib import Path
from t65b_run import ROOT, BASE, EVID, load, save, git, sha, binding, resources, now

def main():
    state=load(BASE/'state.json')
    batch=load(EVID/'regression_summary.txt')
    ordinary=load(ROOT/'sim/reference/regression.json')['Runs']
    t64=load(ROOT/'docs/evidence/t64_f1_coverage/comparison.json')
    t65=load(ROOT/'docs/evidence/t65_gap_tests/results.json')['rows']
    runs=batch['Runs']; assert len(runs)==56 and len(ordinary)==len(t64)==40 and len(t65)==16
    lines=(ROOT/'sim/tests.txt').read_text().splitlines()
    cases=[x.strip() for x in lines if x.strip() and not x.lstrip().startswith('#')]
    original=git('show','HEAD:sim/tests.txt')
    assert (ROOT/'sim/tests.txt').read_bytes().startswith(original)
    assert cases==[r['Test']+('|' + r['Param'] if r['Param'] else '') for r in runs]
    details=[]; totals=dict(Error=0,Fatal=0,Warning=0,FAIL=0,RAMCOLL=0)
    for i,r in enumerate(runs):
        p=Path(r['Folder']); s=load(p/'summary.json')
        assert r['Status']=='PASS' and r['Exit']==0 and s['passed'] and s['errors']==0
        assert s['checks']==r['Checks']
        assert s.get('check',{}).get('items')==r['CheckItems']
        assert s['ce_div']==2 and not s.get('code_coverage') and not s['replaced_modules']
        assert sorted(s['parameters'])==sorted(filter(None,r['Param'].split(',')))
        diagnostics=dict(s['simulation_diagnostics'])
        log=(p/'simulation.log').read_text(encoding='utf-8-sig',errors='replace')
        diagnostics['FAIL']=len(re.findall(r'\[RESULT\][^\r\n]*\bFAIL\b',log))
        assert not any(diagnostics.values()), (r['Test'],diagnostics)
        comp=(p/'compile.log').read_text(encoding='utf-8-sig',errors='replace')
        assert re.search(r'Errors: 0, Warnings: 0',comp)
        assert all(sha(Path(x['path']))==x['sha256'] for x in s['inputs'])
        for key in totals:totals[key]+=diagnostics[key]
        d=dict(index=i+1,**r,diagnostics=diagnostics,summary_sha256=sha(p/'summary.json'),
               independent=s.get('check'),started=s['started'],finished=s['finished'],
               simulation_seconds=next(j['seconds'] for j in s['jobs'] if j['name']=='simulation'))
        if i<40:
            a=ordinary[i]; b=t64[i]
            assert (r['Test'],r['Param'])==(a['Test'],a['Param'])
            assert r['Test']==b['test'] and sorted(filter(None,r['Param'].split(',')))==sorted(b['parameters'])
            d['f1_equal']=(r['Checks'],r['CheckItems'])==(a['Checks'],a['CheckItems'])
            d['t64_equal']=(r['Checks'],r['CheckItems'])==(b['checks'],b['check_items'])
            assert d['f1_equal'] and d['t64_equal'],d
        else:
            a=t65[i-40]; assert a['test']==r['Test']
            d['t65_equal']=r['Checks']==a['checks'] and s['check']['checks']==a['independent_checks']
            assert d['t65_equal'] and s['check']['passed'] and s['check']['errors']==0
            assert any(Path(x['path']).name=='t65_check.py' for x in s['inputs'])
            assert s['check']['mutant']==0
        details.append(d)
    # Invoke only the read-only case validator; never T64 preflight/collect/publish.
    import t64_coverage
    try:t64_coverage.cases()
    except RuntimeError as e:expected=str(e)
    else:raise AssertionError('T64 frozen-case validator unexpectedly accepted 56 cases')
    assert expected=='Expected exactly 40 unique frozen cases'
    save(EVID/'t64_expected_failure.txt',dict(function='tools/t64_coverage.py:cases()',expected_failure=True,error=expected))
    assert binding()==state['binding_before']==load(EVID/'binding_after.txt')
    end=now()
    acceptance=dict(passed=True,finished=end,regression_passed=56,original_f1_equal=40,original_t64_equal=40,new_t65_equal=16,
                    diagnostics=totals,rtl_elinx_byte_equal=True,resources_after=resources(),details=details)
    save(EVID/'acceptance.txt',acceptance)
    diff=git('diff','--','tools/eda.py').decode()
    save(EVID/'source_binding.txt',dict(rtl_elinx=state['binding_before'],checker_sha256=sha(ROOT/'tools/t65_check.py'),
         eda_sha256=sha(ROOT/'tools/eda.py'),tests_sha256=sha(ROOT/'sim/tests.txt'),original_tests_prefix_preserved=True))
    report='''# T65b 标准回归合并验收

## 验收结论

唯一官方普通 RTL 批次 **56/56 PASS**；Error、Fatal、Warning、FAIL、RAMCOLL 全为 0，56 项编译均 Errors=0、Warnings=0。原 40 项 Checks、CheckItems 与 F1 普通回归及 T64 复用记录逐项一致；新 16 项 TB Checks 和独立核对 checks 与 T65 正向证据逐项一致，独立核对全部通过。无未完成项，无待解决功能问题。

初始分支 t63，HEAD 591d99a65933464faa5f2eda3e0e7e2253ed84bb，工作区干净。rtl/、elinx/ 的跟踪文件集合和每个文件原始字节在执行前后均与 e5cd8150 一致。证据为 preflight.txt、binding_after.txt、source_binding.txt。

## 实际执行与资源

'''
    rr=load(EVID/'regression_result.txt')
    def dt(s):return datetime.fromisoformat(s).strftime('%Y-%m-%d %H:%M:%S')
    report+=f"预检计时开始：{dt(state['start'])}；正反例与回归完成：{dt(state['finished'])}；证据验收完成：{dt(end)}。官方回归开始：{dt(rr['started'])}，结束：{dt(rr['finished'])}，用时 {(datetime.fromisoformat(rr['finished'])-datetime.fromisoformat(rr['started'])).total_seconds():.3f} 秒。回归 Deadline：{dt(rr['deadline'])}；整卡硬截止：{dt(state['hard_deadline'])}，均未触发。\n\n"
    report+=f"初始空闲内存 {state['resources']['memory_bytes']/1024**3:.3f} GiB，E 盘空闲 {state['resources']['disk_bytes']/1024**3:.3f} GiB，未发现原生 EDA 作业。普通程序持有唯一 OS 文件锁并等待子进程完成，记录 PID、创建时间、命令及结果。没有重启、重复或追加全量回归，没有子代理、heartbeat、定时任务、自我续接。运行期间工作区只读，ModelSim 作业串行；结束后无原生 EDA 进程。\n\n"
    report+='''官方入口为 sim/regress.ps1，不带 Coverage，Seed 保留默认 20261007；调用 run.ps1/regress.ps1 时均显式设置 AFDX_PYTHON=E:/anaconda3/python.exe、MODELSIM_HOME=E:/Verilog/ModelSim/setup_pack/win64、AFDX_CE_DIV=2，Deadline 带 +08:00。5 GiB 内存下限及各单项原预算均保留。原始入口命令见 regression_result.txt，完整输出见 regression_entry.txt。

## 挂接实现与影响范围

eda.py 只有下面两个受 tb_t65_ 前缀条件保护的新增块，原代码行未删改：

```diff
'''+diff+'''```

第一块仅对 T65 把 tools/t65_check.py 纳入 inputs 摘要及源码快照；不加入 Verilog 编译列表。第二块仅对 T65 在仿真后调用原 check()，将原结果写入 check_summary.json 和 f.result["check"]，errors>0 使 good 为假，最终入口返回 1。包装子进程成功只表示检查器正常执行，功能判定由 errors 决定；这样失败结果仍完整保存在 summary.json。检查器异常仍由原 Flow.job 异常处理判失败。

mutant 取实际参数列表中最后一个 T65_MUTANT 值，默认 0，并传入 check()；没有改变检查器函数、命令行默认行为或 tools/t65_run.py。原 40 项的两个新增 if 均为假，源码快照、编译、仿真、独立核对、预算和判定原有路径保持逐行不变；本次 40 项与两套基线的逐项数值相等进一步验证该范围。

tests.txt 保留原有全部字节（含空行）作为前缀，仅追加 16 项。参数从 T65 ucdb_inputs.json 指向的正式 summary.json 读取，16 项实际均为默认参数，因此未追加参数。收尾仅把新增行的行尾统一为 LF，解析后的 56 个测试/参数身份与本批逐项一致，不影响激励或判定，无须重跑。

## 正例与反例证明

正例通过官方 run.ps1 单跑 tb_t65_queue_a：TB PASS、3088 checks、errors=0；独立核对 PASS、10 checks、errors=0，入口退出码 0。summary.json 包含 check，inputs 包含原 t65_check.py 的路径和 SHA-256。见 positive_result.txt、positive_simulation.txt、positive_check.txt。

反例复用同一 TB 的默认激励，在独立的临时 Python 包装进程内调用 eda.sim，仅在真实 simulation 作业完成后清空该次生成的 t65_trace.txt。原始捕获临时备份在 out/t65b/，没有改动交付 TB 或检查器。TB 仍 PASS、3088 checks、errors=0；独立核对 4 checks、4 errors，eda.py 判 FAIL，入口退出码 1。见 negative_result.txt、negative_simulation.txt、negative_check.txt。tools/t65b_run.py 的 negative 分支保留可复现方法，正常入口不加载该包装。

## 56 项结果与基线对照

表中“—”对应原 JSON 的 null；原 40 项对照栏表示 Checks、CheckItems 同时与 F1 和 T64 相等，新 16 项表示 TB Checks、独立 checks 同时与 T65 相等。每项诊断均为 0。完整输出目录、摘要和逐项比较见 acceptance.txt、regression_summary.txt。

|序号|测试及非默认参数|结果|Checks|CheckItems|独立 checks|基线对照|
|---:|---|---|---:|---:|---:|---|
'''
    for d in details:
        label=d['Test']+(' ('+d['Param']+')' if d['Param'] else '')
        independent=(d['independent'] or {}).get('checks','—')
        report+=f"|{d['index']}|{label}|PASS|{d['Checks']}|{d['CheckItems'] if d['CheckItems'] is not None else '—'}|{independent}|{'F1/T64 一致' if d['index']<=40 else 'T65 一致'}|\n"
    report+='''
F1 来源 sim/reference/regression.json；T64 来源 docs/evidence/t64_f1_coverage/comparison.json；T65 来源 docs/evidence/t65_gap_tests/results.json 及 ucdb_inputs.json。直接复用既有记录，未重新执行这些历史批次，无数值不一致需要解释。

## T64 冻结校验与规则边界

只读调用 tools/t64_coverage.py 的 cases()，得到预期异常 Expected exactly 40 unique frozen cases，见 t64_expected_failure.txt。它有意冻结 40 项，追加后 56 项无法通过其原集合核验；这不是本批功能失败。没有修改该工具，没有调用会写入 T64 证据的 preflight、collect、publish 等入口。

规则冲突按更严格者执行：内存按任务卡和 eda.py 的 5 GiB 下限，严于项目通用 3 GiB；本卡只运行普通 RTL，禁止综合、布局布线、时序复验、网表仿真和 GUI，项目的网表通用超时不适用于本卡。项目“作业运行时只读、不另开作业”按串行执行：上一作业结束后才进入下一官方测试，运行时不改工作区。

只修改 tools/eda.py、sim/tests.txt，新增本报告、docs/evidence/t65b_regress/ 和 tools/t65b_*.py。未改 RTL、elinx、TB、既有检查器、门限、种子、单项超时或禁止路径。未执行第六节父线程收尾，未改 README、FACTS 等文档，未碰 submission/；无 push、merge、amend。没有做综合、时序复验、网表验证、GUI、烧录或上板。本批不新增覆盖率统计，不改变 T65 既有分母差异结论。

必要证据保留在上述目录及各 out/sim/ 尝试；本次临时捕获备份已清理，运行器已退出并释放文件锁，无需撤销监控。本地提交号见交付回复及 Git 历史。
'''
    (ROOT/'docs/T65b_REGRESS.md').write_text(report,encoding='utf-8')
    temp=BASE/'negative_original_trace.txt'
    if temp.exists():temp.unlink()
    print('56/56 PASS; F1/T64 40/40 equal; T65 16/16 equal; diagnostics '+str(totals))

if __name__=='__main__':main()
