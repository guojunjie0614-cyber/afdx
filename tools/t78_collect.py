"""Collect existing T78/T75/T76/T77 receipts after the finite RTL run ends."""
from pathlib import Path
from datetime import datetime, timedelta, timezone
import hashlib
import json
import re
import shutil
import subprocess

ROOT=Path.cwd()
D=ROOT/'docs/evidence'
DEST=D/'frag1030_delivery'

def read(p):return json.loads(p.read_text(encoding='utf-8-sig'))
def git(*args):return subprocess.check_output(['git',*args],cwd=ROOT,text=True,encoding='utf-8').strip()
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def save(name,data):
    (DEST/name).write_text(json.dumps(data,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
def excerpt(p):
    return [line for line in p.read_text(encoding='utf-8',errors='replace').splitlines()
        if '[RESULT]' in line or '$finish' in line or 'Time:' in line or 'End time:' in line or 'Elapsed time:' in line]

def main():
    run=read(ROOT/'out/t78/fast_run.json')
    assert run.get('finished'), 'Quick run has not ended'
    assert git('rev-parse','HEAD')==run['source_commit'], 'HEAD changed during run'
    q=read(ROOT/'out/t78_regression/summary.json')
    long={'tb_sys_perf_var','tb_sys_perf','tb_sys_load','tb_sys_rtc'}
    assert not any(r['test'] not in long for r in q['Active']+q['Pending']), 'Quick cases not terminal'
    DEST.mkdir(parents=True,exist_ok=True)
    save('execution.json',run)
    save('regression_queue_raw.json',q)
    old=read(D/'t75_frag1030/results.json')
    baseline={(r['Test'],r['Param']):r for r in old['FinalRTL']}
    differences=[];native=[]
    for r in q['Runs']:
        b=baseline[(r['Test'],r['Param'])]
        p=Path(r['Folder']); s=read(p/'summary.json')
        if r['CheckItems'] is None and 'checks' in s.get('check',{}):
            r['CheckItems']=s['check']['checks']
            differences.append(dict(test=r['Test'],params=r['Param'],field='CheckItems extraction',
                previous=b['CheckItems'],actual=r['CheckItems'],reason='Queue reads check.items; T65 native receipt stores check.checks. Native values recovered and compared; raw queue preserved.'))
        for key in ('Checks','CheckItems','Status'):
            if r[key]!=b[key]:
                reason='T76 corrected public-port performance checker; 683408635 HDL checks and 1357450 external items expected' if r['Test']=='tb_sys_perf' else 'Unexplained difference; requires review'
                differences.append(dict(test=r['Test'],params=r['Param'],field=key,previous=b[key],actual=r[key],reason=reason))
        native.append(dict(test=r['Test'],params=r['Param'],result=excerpt(p/'simulation.log'),
            seconds=r['Seconds'],simulation_jobs=[j for j in s['jobs'] if j['name']=='simulation'],
            source_inputs=s.get('inputs'),raw_sources='modelsim_declaration_order' not in s))
    save('regression.json',q)
    save('regression_native.json',native);save('regression_differences.json',differences)
    assert len([r for r in q['Runs'] if r['Test'] not in long])==63
    quick=[r for r in q['Runs'] if r['Test'] not in long]
    references=[]
    for name in sorted(long):
        r=read(D/'t76_frag1030/performance_actual_rerun.json')['runs'][0] if name=='tb_sys_perf' else next(r for r in old['FinalRTL'] if r['Test']==name)
        references.append(dict(test=name,reference=r,evidence_commit='afd47721' if name=='tb_sys_perf' else '451b91c4',
            relation='Historical simulation portability copy. T77 MODEL_TECH ModelSim branch equivalence and non-ModelSim ordered synthesis token identity bind final RTL; not a rerun on final HEAD.',
            final_source_completed=[s for s in q['Runs'] if s['Test']==name],
            final_source_active=[s for s in q['Active'] if s['test']==name]))
    save('long_references.json',references)
    apps=[]
    for name in ('isolated_default','isolated_small'):
        paths=sorted((ROOT/'out/t76_app'/name).glob('*/summary.json'))
        assert len(paths)==1, 'Missing or ambiguous configuration case'
        s=read(paths[0]);apps.append(s)
    save('configuration_cases.json',apps)
    # Independently compare the existing paired official windows, without simulation.
    windows=[]
    for r in read(D/'t76_frag1030/netlist_queue.json')['Runs']:
        if r['Kind']!='VQM76':continue
        p=Path(r['Folder']);s=read(p/'summary.json');ref=Path(s['rtl_reference']);records=[]
        for name in s['exact_external_records']:
            a,b=p/name,ref/name
            records.append(dict(file=name,equal=a.read_bytes()==b.read_bytes(),
                netlist_sha256=sha(a),rtl_sha256=sha(b),netlist_lines=len(a.read_bytes().splitlines()),rtl_lines=len(b.read_bytes().splitlines())))
        assert all(x['equal'] for x in records)
        windows.append(dict(index=r['Index'],status=r['Status'],checks=r['Checks'],seconds=r['Seconds'],
            source_evidence_commit='afd47721',folder=str(p),reference=str(ref),records=records,
            result=excerpt(p/'simulation.log'),jobs=s['jobs'],inputs=s['inputs']))
    save('vqm_windows.json',windows)
    # T75 full windows: retain only metadata and the result/end-time excerpt.
    official=[]
    for r in old['Official']:
        p=ROOT.parent/'c3_frag1030'/r['Folder']
        official.append(dict(receipt=r,result=excerpt(p/'simulation.log') if (p/'simulation.log').exists() else [],
            source_evidence_commit='451b91c4'))
    save('t75_official.json',official)
    prefix=read(D/'t75_frag1030/prefix_result.json');save('fragment_prefix.json',prefix)
    # Copy exactly the three small reports from the T77 end-to-end build.
    e=read(D/'t77_rtl_compat/v2_end_to_end.json');p=Path(e['native']['output'])
    timing=dict(source_evidence_commit='fe40d1fb',build=e['folder'],vqm_sha256=e['vqm_sha256'],
        elapsed_seconds=e['elapsed_seconds'],clocks=e['build_result']['routed_timing']['clocks'],
        locks=e['native']['locks'],p0_unchanged=e['native']['p0_unchanged'],reports=[])
    for src,dst in [('AFDX_EndSystem.slack.rpt','slack.rpt'),('AFDX_EndSystem_route_status.rpt','route_status.rpt'),('AFDX_EndSystem_utilization_placed.rpt','utilization_placed.rpt')]:
        shutil.copyfile(p/src,DEST/dst);timing['reports'].append(dict(source=str(p/src),file=dst,sha256=sha(DEST/dst)))
    save('timing.json',timing)
    rtl_diff=git('diff','--stat','451b91c4','HEAD','--','rtl')
    elinx_diff=git('diff','a6181267','HEAD','--','elinx')
    save('merge_verification.json',dict(head=run['source_commit'],rtl_diff=rtl_diff,elinx_diff=elinx_diff,
        elinx_matches_t76_start=not bool(git('diff','afd47721','HEAD','--','elinx')),
        elinx_baseline_gate='FAIL: pre-existing T76 sim_1 afdx_sys_config.v registration; protected project unchanged'))
    card=Path('E:/2026_Embedded_FPGA/cards/T78_frag1030_closeout.md').read_text(encoding='utf-8')
    limitations=card.split('4. 限制与未完成项（照实写，不美化）：\n',1)[1].split('5. 体积检查：',1)[0].rstrip()
    limitations='\n'.join(line[3:] if line.startswith('   ') else line for line in limitations.splitlines())+'\n'
    (DEST/'limitations.md').write_text('# 限制与未完成项\n\n'+limitations,encoding='utf-8')
    passed=sum(r['Status']=='PASS' for r in quick);app_pass=sum(s['passed'] for s in apps)
    perf=read(D/'t76_frag1030/summary.json')
    summary=f'''# frag1030 交付收尾证据

更新：{datetime.now(timezone(timedelta(hours=8))).strftime('%Y-%m-%d %H:%M:%S')}。T78 执行完成；验收存在未闭合项：elinx 基准差异和既有性能限制，不能标整体无条件通过。

| 分块 | 结果 / 检查数 | 用时 | 源码与 VQM 绑定 |
|---|---|---|---|
| RTL 快速回归 | {passed}/63 PASS（52 项基础 + 11 项分支）；配置隔离 {app_pass}/2 PASS；逐项 HDL/外部检查数见 [回归收据](regression.json)、[差异说明](regression_differences.json) | 整轮 {run['seconds']:.3f} s，目标 30 分钟，上限 1 小时；逐项见收据 | `{run['source_commit']}`；原样 RTL，VQM 不适用 |
| 官方 VQM | T75 tb_elinx 9238、tb_net_services 1123；分片 PASS-PREFIX 5 组 / 32 行；T76 TX/RX 各 161 检查，11 份记录逐字节相同 | T75 完整窗口 52312.469 / 23614.453 s，分片前缀 34727.859 s；T76 {windows[0]['seconds']} / {windows[1]['seconds']} s | 证据提交 `451b91c4` / `afd47721`；旧 VQM `{prefix['vqm_sha256'].lower()}`；冻结输入哈希见各收据 |
| 满负载性能 | 未通过：case 16 的 10/162 组 ≥100 µs，最大 107.7 µs；周期最大 3.368 µs；81 VL 混合溢出；63 VL 混合 100 ms 完整性通过 | 100 ms 仿真窗口；运行耗时见 [T76 队列](../t76_frag1030/primary_queue.json) | `afd47721` 保存冻结源码及统计；RTL，VQM 不适用 |
| 时序 | PASS：setup +29 ps，hold +604 ps，setup/hold 各 0/96142 失败；含 0.30 ns 不确定度；11044 簇、172 P0 不变 | 端到端 {e['elapsed_seconds']} s | `fe40d1fb` 保存 T77 构建输入；VQM `{e['vqm_sha256']}`；[原始数值](timing.json) |

[T75 证据](../t75_frag1030/summary.md) · [T76 证据](../t76_frag1030/summary.md) · [T77 证据](../t77_rtl_compat/summary.md)。历史提交号用于定位保存冻结输入的证据，实际输入以原始收据内 SHA256 清单绑定；未将后续报告提交冒称为运行时 HEAD。

快速版覆盖清单为 `sim/t78_quick_tests.txt` 的 52 项和 `par_regress.py DEFAULT_BRANCH` 的 11 项，另加默认 84 消息和两消息配置隔离实际入口。排除 tb_sys_perf_var、tb_sys_perf、tb_sys_load、tb_sys_rtc；tb_sys_perf_var、tb_sys_load、tb_sys_rtc 引用 T75 FinalRTL，tb_sys_perf 引用 T76 performance_actual_rerun（HDL 683408635、独立 1357450），均为 PASS。[长用例收据](long_references.json)保留逐项检查数、用时和运行目录。T77 的 MODEL_TECH 分支对 ModelSim 与兼容副本等价，非 ModelSim 综合入口逐 token 保序相同，见其文本等价与直接 RTL 验收证据；引用历史长例不冒称在最终源码重跑完成。最初四项都已开跑，tb_sys_load/tb_sys_rtc 已完成并附录入本轮收据；tb_sys_perf_var/tb_sys_perf 继续原进程与四小时原截止，不中断、不重启、不等待。其最终结果由原 `out/t78_regression/summary.json` 自动记录；本提交保留收尾时快照。

T76 原摘要的“网表窗口未完成”已过时；[本轮只读核对](vqm_windows.json)确认两窗口终态、[RESULT]、仿真结束时间、进程用时及 22 份文件的两侧 SHA256/行数。未重跑网表仿真。8192 字节及故障恢复网表覆盖仍不成立。T75 [终态摘录](t75_official.json)、[分片前缀](fragment_prefix.json)保留覆盖边界。

合并顺序：fe40d1fb 后 451b91c4，均无冲突。RTL 精确为 7 文件 +89 行。`elinx/` 相对 a6181267 多出 T76 已有的 `sim_1` 配置模块登记一行，因此该条验收 FAIL；相对 afd47721 无改动，未自行回退。见 [合并核验](merge_verification.json)。声明保持：81 TX/RX VL 用于单帧周期场景；长短消息混合独立声明 63 TX/RX VL。ARCH 规格表未改。

## 限制与未完成项

{limitations}
## 复核入口

[原始 RTL RESULT 和输入哈希](regression_native.json)、[配置隔离实际入口](configuration_cases.json)、[slack](slack.rpt)、[route status](route_status.rpt)、[placed utilization](utilization_placed.rpt)。[提交包体积报告](package_size.md)列出测量提交、总大小、最大 20 文件及所有超过 5 MB 的跟踪文件。没有新增超过 5 MB 的文件。
'''
    (DEST/'summary.md').write_text(summary,encoding='utf-8')
    for name in ('FACTS.md','FACTS_DETAIL.md'):
        p=ROOT/'docs'/name;text=p.read_text(encoding='utf-8-sig')
        text=re.sub(r'\n## T76 当前执行状态\n[\s\S]*$','\n',text)
        addition=f'## T78 当前交付状态\n\n最终源码快速回归 {passed}/63 PASS（52 项基础 + 11 项分支）；配置隔离 {app_pass}/2 PASS，源码 `{run["source_commit"]}`。四个长用例按批准的快速范围引用历史：tb_sys_perf 引用 T76 修正检查器，其余引用 T75；与最终源码的关系由 T77 MODEL_TECH/兼容副本 ModelSim 等价及综合逐 token 保序相同证据绑定。已启动长例保留原进程，已完成的结果附录入证据，不等待其余长例。T76 官方 VQM TX/RX 各 161 检查通过，与同激励 RTL 的 11 份记录各自逐字节相同。T77 端到端布线 setup +29 ps / hold +604 ps，setup/hold 各 0/96142 失败端点。旧 VQM `{prefix["vqm_sha256"].lower()}` 与 T77 新 VQM `{e["vqm_sha256"]}` 分开绑定。\n\n81 TX/RX VL 适用于单帧周期注入；长短消息混合独立声明 63 TX/RX VL，70 通过 / 71 溢出。81 VL BAG 连发性能未通过。elinx 相对 a6181267 的 T76 已有一行源登记差异保留，验收未闭合。详细检查数、耗时、输入哈希及体积见 [交付证据](evidence/frag1030_delivery/summary.md)。\n\n### 限制与未完成项\n\n'+limitations
        title,sep,rest=text.partition('\n')
        p.write_text(title+'\n\n'+addition+'\n## 历史验证基线\n\n以下旧轮次数字保留其原始源码和验收边界；当前交付数字以上述 T78 证据为准。\n'+rest.rstrip()+'\n',encoding='utf-8',newline='\n')
    p=ROOT/'README.md'
    text=p.read_text(encoding='utf-8-sig').replace('各项实际结果与未完成门槛见 [T76 记录](docs/evidence/t76_frag1030/summary.md)。','各项最终结果、限制及基准差异见 [T78 交付总表](docs/evidence/frag1030_delivery/summary.md)，历史 T76 记录单独保留。')
    text=text.replace('，也不覆盖 yosys 辅助网表。','。')
    p.write_text(text+reproduction(),encoding='utf-8',newline='\n')
    for file in (DEST/'summary.md',ROOT/'README.md',ROOT/'docs/FACTS.md',ROOT/'docs/FACTS_DETAIL.md'):
        assert 'B 类' not in file.read_text(encoding='utf-8') and 'yosys' not in file.read_text(encoding='utf-8'), file
    save('acceptance.json',dict(rtl_pass=passed,total=63,configuration_pass=app_pass,
        native_raw_sources=all(s['raw_sources'] for s in native),elinx_baseline_gate=False,
        original_limitations_verbatim=True,performance_accepted=False,
        vqm_windows_equal=all(x['equal'] for w in windows for x in w['records'])))
    print('Collected',passed,'/63; config',app_pass,'/2; baseline elinx gate FAIL')

def reproduction():return '''
## frag1030 复现步骤（T78）

在工程根目录运行；软件安装及许可证见前文。先设置：

```powershell
$env:AFDX_PYTHON='E:/anaconda3/python.exe'
$env:MODELSIM_HOME='E:/Verilog/ModelSim/setup_pack/win64'
$env:ELINX_HOME='E:/2026_Embedded_FPGA/setup_pack'
$env:AFDX_CE_DIV='2'
$env:AFDX_MEM_FLOOR_GB='3'
$env:AFDX_MODELSIM_DECL_ORDER='0'
```

1. RTL：打开 `elinx/AFDX_EndSystem.epr`，仿真顶层 `tb_elinx`，点 Run Behavioral Simulation；该界面点击路径尚未人工验收。已验证命令行等价入口：

   ```powershell
   & $env:AFDX_PYTHON -B -X utf8 tools/eda.py sim --test tb_elinx
   ```

   预期 `[RESULT] tb_elinx PASS checks=9238 errors=0`；直接编译原样 RTL。

2. 综合后仿真：按答疑第 155 条，用 `synth_1/AFDX_EndSystem.vqm` 替换实现仿真 `.do` 中的 `.vo`，厂商库保持原样。下列脚本准备运行目录、唯一官方 VQM、参数及 `official_inputs.tcl`，并调用 `sim/run_t76_post_synth.do`：

   ```powershell
   & $env:AFDX_PYTHON -B -X utf8 tools/t76_sim.py --help
   $env:AFDX_T76_SPEC_CONFIRMED='1'
   & $env:AFDX_PYTHON -B -X utf8 tools/t76_sim.py --netlist '<synth_1/AFDX_EndSystem.vqm>' --reference '<同参数RTL运行目录>' --deadline '<本轮ISO截止>' --param VL_COUNT=81 --param GROUP_LENGTH=1471 --param MIXED=2 --param DUPLEX=0 --param DURATION=125001 --param SMOKE=0 --param SWAP=0
   ```

   同参数 RTL 参考先用相同命令去掉 `--netlist` 和 `--reference` 生成；反方向用 `SWAP=1`。预期 `[RESULT] tb_t76_load PASS checks=161 errors=0`、`T76 OFFICIAL .VO TO .VQM ENTRY PASS`，且 11 份公开输出与显式 RTL 参考逐字节相同。现存准备目录可用 `vsim -batch -do "do sim/run_t76_post_synth.do <PREPARED_RUN_FOLDER>"` 重放。此命令会运行耗时网表仿真，T78 没有重跑；历史两窗口各约 7.5 小时，不能用 RTL 的四小时上限替代。

3. 最终快速回归：输出目录必须不存在；52 项基础及 11 项分支用例，最多 6 个 ModelSim，原样 RTL：

   ```powershell
   $env:AFDX_SIM_TIMEOUT_SECONDS='3600'
   & $env:AFDX_PYTHON -B -X utf8 tools/par_regress.py --output out/reproduce_t78 --list sim/t78_quick_tests.txt --branch-tests --raw-sources --max-sims 6 --max-owned-sims 6 --rtl-hours 1
   & $env:AFDX_PYTHON -B -X utf8 tools/t76_app.py --deadline '<本轮ISO截止>'
   & $env:AFDX_PYTHON -B -X utf8 tools/t76_app.py --small --deadline '<本轮ISO截止>'
   ```

   预期 `PAR PASS` 63 项、`PAR FINISHED`；两个配置隔离入口均 `T76 APPLICATION ENTRY PASS`。各项 HDL/独立检查数见 [T78 回归证据](docs/evidence/frag1030_delivery/regression.json)。四个长用例不纳入快速版，其中 `tb_sys_perf` 引用 T76 修正检查器结果：HDL 683408635，独立项 1357450；其余引用 T75。T77 证明 MODEL_TECH 分支对 ModelSim 与兼容副本等价、对综合逐 token 保序相同。目标 30 分钟、上限 1 小时；已启动的原长用例保持原进程和原截止，收尾不等待。`tools/t78_run.py` 保留原全量启动历史；`tools/t78_fast.py` 是本轮快速收尾接管记录，无重试。

4. 实现：eLinx 工程中按综合、实现顺序执行，或命令行：

   ```powershell
   & $env:AFDX_PYTHON -B -X utf8 tools/build_1030.py --route --pres 1.30 --deadline '<本轮ISO截止>'
   ```

   预期 routed setup `+0.029 ns`、hold `+0.604 ns`，setup/hold 各 `0/96142` 失败端点；核对全部 11044 个锁定簇和 172 个 P0 管脚。新输出须绑定自身 VQM SHA256；T77 已验证文本排列不同但结构和锁定布线时序相同，不保证任意安装的普遍确定性。

当前 81 VL 与 63 VL 的适用场景、未通过性能项、GUI 未验收项及工程基准差异见 [交付总表](docs/evidence/frag1030_delivery/summary.md)。
'''

if __name__=='__main__':main()
