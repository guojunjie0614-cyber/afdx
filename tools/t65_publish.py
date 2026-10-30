"""Publish only T65 evidence and report; verify all positive and negative attempts."""
import csv
from datetime import datetime
import os
from pathlib import Path
import re
import shutil
import tempfile
from t65_run import ROOT,BASE,EVID,TZ,load,save,sha,now,git,original_check,resources
from t65_check import check

def group(test):
    if 'queue_a' in test:return 'G1'
    if '_tx_' in test:return 'G2 TX'
    if '_rx_' in test:return 'G2 RX'
    return 'G3'

def csvwrite(path,rows,keys):
    with Path(path).open('w',newline='',encoding='utf-8') as stream:
        w=csv.DictWriter(stream,fieldnames=keys,extrasaction='ignore');w.writeheader();w.writerows(rows)

def copy_text(src,dst):
    dst.parent.mkdir(parents=True,exist_ok=True)
    dst.write_text(Path(src).read_text(encoding='utf-8-sig',errors='replace'),encoding='utf-8')

def publish():
    status=original_check();res=resources()
    import ast
    for p in (ROOT/'tools').glob('t65_*.py'):ast.parse(p.read_text(encoding='utf-8'),filename=str(p))
    import t65_generate as generator
    regenerated=[]
    def verify_generated(name,text):
        assert (ROOT/'tb'/(name+'.v')).read_bytes()==text.replace('\n',os.linesep).encode('utf-8'),name
        regenerated.append(name)
    generator.write=verify_generated
    generator.g1();generator.tx_tests();generator.rx_tests();generator.reset_tests()
    save(EVID/'generation_reproducibility.json',dict(passed=True,files=regenerated,byte_identical=True))
    frozen=load(BASE/'freeze.json');coverage=load(EVID/'coverage.json');origin=load(EVID/'ucdb_inputs.json')
    assert sha(ROOT/coverage['merged_ucdb'])==coverage['merged_sha256']
    assert datetime.now(TZ)<datetime.fromisoformat(frozen['hard_deadline'])
    inputs=origin['t65'];attempts=load(BASE/'attempts.json');formal={r['folder'] for r in inputs}
    negatives=[];results=[];selftests=[];expectations=[]
    for a in attempts:
        folder=Path(a['folder'])
        a['classification']='counterexample' if a['mutant'] else ('formal_PASS' if folder.relative_to(ROOT).as_posix() in formal else 'development_attempt_not_merged')
    save(EVID/'attempts.json',attempts)
    for r in inputs:
        test=r['test'];folder=ROOT/r['folder'];summary=load(folder/'summary.json')
        assert summary['passed'] and check(folder,test)['passed']
        assert datetime.fromisoformat(r['finish'])<datetime.fromisoformat(frozen['simulation_deadline'])
        if group(test)=='G3':assert datetime.fromisoformat(r['start'])<datetime.fromisoformat(frozen['g3_start_deadline'])
        out=EVID/'runs'/test
        for name in ['simulation.log','compile.log','compile_rtl.log','t65_trace.txt']:
            if (folder/name).exists():copy_text(folder/name,out/(name.replace('.log','.txt')))
        save(out/'summary.json',summary);save(out/'independent.json',check(folder,test))
        for mutant in (1,2):
            matching=[a for a in attempts if a['test']==test and a['mutant']==mutant]
            assert len(matching)==1,(test,mutant,len(matching))
            a=matching[0];f=Path(a['folder']);s=load(f/'summary.json')
            assert a['exit_code']==1 and s['passed'] is False and 'error' not in s
            assert not any(s['simulation_diagnostics'].values())
            jobs={j['name']:j for j in s['jobs']}
            assert re.search(r'Errors: 0, Warnings: 0',Path(jobs['compile']['log']).read_text(encoding='utf-8-sig'))
            assert 'compile_rtl' not in jobs and not s.get('code_coverage') and not (f/'coverage.ucdb').exists()
            assert '-gT65_MUTANT='+str(mutant) in jobs['simulation']['command']
            assert load(ROOT/'out'/('t65_mut_latest_'+test+'.json'))['parameters']==['T65_MUTANT=2']
            assert load(ROOT/'out'/('latest_'+test+'.json'))['folder']==str(folder)
            text=(f/'simulation.log').read_text(encoding='utf-8-sig')
            last=re.findall(r'\[RESULT\]\s+(\w+)\s+(PASS|FAIL)\s+checks=(\d+)\s+errors=(\d+)',text)[-1]
            assert last[0]==test and last[1]=='FAIL' and int(last[3])>0
            assert not re.search(r'\*\* (?:Error|Fatal|Warning)|RAMCOLL',text)
            for entry in s['inputs']:assert sha(entry['path'])==entry['sha256']
            nf=EVID/'counterexamples'/test/str(mutant)
            copy_text(f/'simulation.log',nf/'simulation.txt');save(nf/'summary.json',s)
            negatives.append(dict(test=test,group=group(test),mutant=mutant,exit_code=a['exit_code'],
                                  folder=f.relative_to(ROOT).as_posix(),errors=int(last[3]),checks=int(last[2]),
                                  correctly_rejected=True,simulation_sha256=sha(f/'simulation.log'),
                                  no_coverage=True,diagnostics=s['simulation_diagnostics'],
                                  kind='reference_payload_byte' if mutant==1 else 'drop_or_idle_resource_count'))
        # Independently corrupt captures, using a task-local temporary directory.
        # These checks supplement, and never replace, the run.ps1 counterexamples.
        channel='rx' if group(test) in ('G1','G2 RX') else 'core' if group(test)=='G2 TX' else 'peer'
        original=(folder/'t65_trace.txt').read_text()
        lines=original.splitlines();candidate=[i for i,s in enumerate(lines) if s.startswith('M '+channel+' ')]
        assert candidate
        (BASE/'tmp').mkdir(exist_ok=True)
        for kind in ('payload','resources'):
            changed=list(lines)
            if kind=='payload':
                index=candidate[-1];row=changed[index].split();b=bytearray.fromhex(row[4]);b[min(2,len(b)-1)]^=1;row[4]=b.hex()
            else:
                index=[i for i,s in enumerate(lines) if s.startswith('Q ')][-1];row=changed[index].split();row[-1]=str(int(row[-1])+1)
            changed[index]=' '.join(row)
            with tempfile.TemporaryDirectory(prefix='checker_',dir=BASE/'tmp') as temp:
                (Path(temp)/'t65_trace.txt').write_text('\n'.join(changed)+'\n')
                result=check(temp,test)
                assert not result['passed'] and result['errors']>0,(test,kind)
            selftests.append(dict(test=test,mutation=kind,line=index+1,correctly_rejected=True,result=result))
        labels=re.findall(r'check\(.*?,\s*"([^"]+)"\)',(ROOT/'tb'/(test+'.v')).read_text(),re.S)
        source={
            'G1':'docs/ARCH.md:247-299,343-363; rtl/afdx_rx_core.v:76-80; rtl/afdx_rx_parse.v:21-35,73-78; tb/lib/rx_core_suite.v:112-154; T65 card section 4 G1',
            'G2 TX':'docs/ARCH.md:54,62-66,339-341; rtl/afdx_app_tx.v:1-2,73-96; tb/tb_top_wrap.v:36-58,96-109; T65 card section 4 G2 TX',
            'G2 RX':'docs/ARCH.md:56,62,68-71; rtl/afdx_app_rx.v:1-2,23-28,54-61; tb/tb_top_wrap.v:36-58; T65 card section 4 G2 RX',
            'G3':'docs/ARCH.md:247-299,339-341,343-363; rtl/afdx_rx_parse.v:21-35,73-78; rtl/afdx_rx_deliver.v:24-26,37-39; tb/lib/rx_core_suite.v:112-154; T65 card section 4 G3'
        }[group(test)]
        for label in dict.fromkeys(labels):expectations.append(dict(test=test,label=label,expected=label,source=source,
                    scope='mutation-only deliberate false reference' if 'mutated' in label else 'contract or registered scenario precondition'))
        results.append(dict(test=test,group=group(test),result='PASS',checks=summary['checks'],
                            independent_checks=r['independent']['checks'],folder=r['folder'],ucdb_sha256=r['sha256'],
                            simulation_seconds=r['simulation_seconds'],counterexamples=2))
    save(EVID/'counterexamples.json',dict(all_rejected=True,count=len(negatives),rows=negatives))
    save(EVID/'checker_selftests.json',dict(all_rejected=True,count=len(selftests),rows=selftests))
    csvwrite(EVID/'expectations.csv',expectations,['test','label','expected','source','scope'])
    save(EVID/'results.json',dict(all_functional_passed=True,passed=len(results),confirmed_rtl_defects=0,incomplete=0,rows=results))
    save(EVID/'freeze.json',frozen)
    save(EVID/'rtl_binding.json',dict(frozen_commit='e5cd815020448820c2de7c587f288554defb74bc',initial_head=frozen['head'],
                before_and_after_equal=True,files={n:h for n,h in frozen['original_files'].items() if n.startswith('rtl/')}))
    for p in (BASE/'coverage').glob('*_dump.json'):save(EVID/'dump_provenance'/p.name,load(p))
    (BASE/'tmp').rmdir()
    # Original baseline branch/statement set versus final native set, read-only.
    from t65_coverage import parse_native
    old=parse_native(ROOT/'out/t64/20261029_093324_002975/du_native_dump.txt')
    current=parse_native(BASE/'coverage/merged_du_native.txt')
    additions=[dict(key=k,line=current[k]['line'],count=current[k]['count']) for k in sorted(current.keys()-old.keys())
               if k.startswith('work.afdx_cfg') and current[k]['type'] in ('UCDB_STMTBIN','UCDB_BRANCHBIN')]
    save(EVID/'denominator_native_additions.json',dict(afdx_cfg_additions=additions,
        target_branch_fsm_keys_preserved=all(k in current for k in old if k.startswith('work.afdx_app_tx::branch#') or k.startswith('work.afdx_rx_engine::op/trans/'))))
    ended=now()
    save(EVID/'acceptance.json',dict(work_delivered=True,all_functional_passed=True,confirmed_rtl_defects=0,incomplete=0,
            positive_tests=len(results),native_counterexamples=len(negatives),independent_counterexamples=len(selftests),
            coverage_comparable=False if not coverage['denominator_same'] else True,
            coverage_delta_reported=coverage['delta'] is not None,requires_parent_denominator_decision=not coverage['denominator_same'],
            source_checks=status,original_file_count=len(frozen['original_files']),start=frozen['start'],acceptance_time=ended,
            simulation_deadline=frozen['simulation_deadline'],hard_deadline=frozen['hard_deadline'],resources=res,
            no_active_native_processes=True,no_heartbeat_or_scheduler=True,
            local_commit_evidence='Git history and final handoff; this snapshot is generated before commit'))
    report(results,negatives,selftests,frozen,coverage,ended)
    original_check()
    status_lines=git('status','--porcelain=v1','--untracked-files=all').splitlines()
    allowed=lambda n:re.fullmatch(r'tb/tb_t65_[^/]+\.v|tools/t65_[^/]+\.py|docs/T65_GAP_TESTS\.md|docs/evidence/t65_gap_tests/.*',n)
    assert all(s.startswith('?? ') and allowed(s[3:]) for s in status_lines),status_lines
    save(EVID/'precommit_scope.json',dict(tracked_diff_empty=True,staged_diff_empty=not git('diff','--cached','--name-only'),
                    only_whitelisted_new_files=True,status=status_lines))
    paths=[p for p in EVID.rglob('*') if p.is_file() and p.name!='manifest.json']+[ROOT/'docs/T65_GAP_TESTS.md']
    paths+=list((ROOT/'tb').glob('tb_t65_*.v'))+list((ROOT/'tools').glob('t65_*.py'))
    save(EVID/'manifest.json',dict(files=[dict(path=p.relative_to(ROOT).as_posix(),sha256=sha(p),bytes=p.stat().st_size) for p in sorted(paths)]))
    print(dict(positive_tests=len(results),native_counterexamples=len(negatives),checker_selftests=len(selftests),report='docs/T65_GAP_TESTS.md',acceptance_time=ended))

def report(results,negatives,selftests,frozen,cov,ended):
    def date(s):return datetime.fromisoformat(s).astimezone(TZ).strftime('%Y-%m-%d %H:%M:%S')
    t64=load(ROOT/'docs/evidence/t64_f1_coverage/coverage.json')
    elapsed=(datetime.fromisoformat(ended)-datetime.fromisoformat(frozen['start'])).total_seconds()
    starts=[a['start'] for a in load(BASE/'attempts.json')]
    finishes=[a['finish'] for a in load(BASE/'attempts.json')]
    lines=[f'''# T65 异常恢复与缓存边界补测

## 补测交付与功能结论

补测工作已交付；全部 {len(results)} 个正向测试 PASS，独立核对全部 PASS；已确认 RTL 缺陷 0，未完成场景 0。每个 PASS 测试各做两个经正式入口执行的反例，{len(negatives)}/{len(negatives)} 均正确 FAIL；另对独立检查器做了 {len(selftests)} 个离线捕获破坏反例，全部检出。反例的 FAIL 表示检查器敏感性通过，不作为 RTL 缺陷，不纳入合并。

覆盖率合并通过工具输入校验，精确包含 T64 的 40 次成功尝试和本卡 16 次正式尝试，仍有 29 个带覆盖统计的设计单元。**分母有变化，不能给出同口径覆盖率增幅，留父线程判定。** A01 的 26 项、A02 的 2 项均命中，G3 登记的 3 个复位目标逐个在独立 UCDB 中计数为 1。应用 TX 选择 `st1=6`；备选 `st9=4`（T64-0906）未注入，不把该备选算成未完成。

## 冻结来源与执行边界

- 执行目录 `E:/2026_Embedded_FPGA/worktrees/active/c3_t63`，分支 `t63`；初始 HEAD `{frozen['head']}`，执行前工作区干净。
- `rtl/` 的 29 个文件在初始快照及结束时均与 T64 冻结 `e5cd815020448820c2de7c587f288554defb74bc` 的原始字节 SHA-256 相同，见 [rtl_binding.json](evidence/t65_gap_tests/rtl_binding.json)。全部 {len(frozen['original_files'])} 个原跟踪文件摘要不变；已有 TB、`tb/lib/`、sim/tools、T64 证据未修改，`tb/lib/` 文件列表不变。提交前跟踪文件 diff 为空，只存在白名单内新增文件。
- 输入 T64 合并库 `{frozen['t64_collection']['merged_ucdb']}`，SHA-256 `{frozen['t64_collection']['merged_sha256']}`，完整核对 collection.json 后使用。T64 的 40 项没有重跑，旧 execution.lock/current.json 保留。
- Python `E:/anaconda3/python.exe`；ModelSim SE-64 2020.4，版本与 T64 相同。子进程显式设置 AFDX_PYTHON、MODELSIM_HOME、AFDX_CE_DIV=2。每次 run.ps1 都传带偏移 Deadline，入口启动日志记录本地换算值。20261007 只保留为既有入口默认参数，新测试激励确定且不依赖种子。
- 只对 RTL 使用 `+cover=sbceft`，TB 无插桩；参数仅默认、RX_DQ_AW=1、RX_RING_AW=9，未引入新参数组合，未做覆盖率排除。所有线帧字节嵌入 TB 源文件，经 eda.py 快照和摘要记录；无外部相对路径激励读取。没有实例化被禁止的 suite/endpoint，也没有在 tb/lib 新增文件。
- 使用只读层次化观察作精确触发、资源核对和输出采集；**这些新测试只适用于 RTL**。没有修改 RTL，没有做综合、布局布线、时序复验、网表仿真、GUI、烧录或上板。
- 串行原生后台运行器持有 OS 文件锁，记录启动身份、子进程命令、预算和结束状态；没有子代理、heartbeat、定时任务或自我续接。运行期间工作区只读，不并发启动其他 ModelSim/eLinx 作业。
- 规则按更严格者执行：内存保留 eda.py 的 5 GiB 下限，未降到项目通用 3 GiB；本卡禁止综合、网表和 GUI，项目通用长用例上限不用于本卡；报告、改动白名单及本地提交均按本卡执行。项目“作业运行时只读、不另开作业”具体执行为单作业串行、作业结束后才改新文件。无 push、merge、amend 或远端操作。

## 实际时间与资源

首次预检与计时起点：**{date(frozen['start'])}**。首项仿真入口开始 {date(min(starts))}，最后一项仿真入口结束 {date(max(finishes))}；统计与证据终验完成 **{date(ended)}**。截至证据终验耗时 **{elapsed:.3f} 秒**，本地提交在此之后执行。仿真截止 {date(frozen['simulation_deadline'])}，G3 未开始场景截止 {date(frozen['g3_start_deadline'])}，整卡硬截止 {date(frozen['hard_deadline'])}；均未触发。原始工具日志保留系统本地时间，本报告时间已统一换算。

初始空闲内存 {frozen['resources']['available_memory']/1024**3:.3f} GiB、E 盘空闲 {frozen['resources']['disk_free']/1024**3:.3f} GiB；每项启动前检查 5 GiB 内存、8 GiB 磁盘和没有其他原生 EDA 作业。各工具原有超时未放宽：覆盖率仿真 3600 秒、反例仿真 900 秒。原始预算和进程峰值在各 summary.json，运行清单见 [attempts.json](evidence/t65_gap_tests/attempts.json)。

## 预期依据与检查范围

每个 TB `check` 标签及其依据逐项登记在 [expectations.csv](evidence/t65_gap_tests/expectations.csv)。以下是判定依据，阈值与精确触发值同时来自本卡第四节指定的源码位置。

|检查类别|有出处的预期|依据|
|---|---|---|
|完整消息与公开字节接口|VLID 高、低字节及载荷顺序；合法消息连续、完整、只交付一次|ARCH 第 1.3 节（52–71 行）；既有 tb_top_wrap 的逐字节、长度和无空洞检查|
|TX 容量、回滚和事件|4096 字节/32 项描述符；资源拒收整条回滚，ev_app[1] 一次；空消息/未命中 ev_app[0]；恢复合法消息完整|ARCH 62–66 行；afdx_app_tx 1–2、96 行注释；本卡 G2 TX 门限与短消息要求|
|RX 模块级预留|首字节按寄存后的 used>2624 或 descriptors>=30 拒收，ev_app[2] 每条一次，拒收消息不输出半条|ARCH 62、68–71 行；afdx_app_rx 1–2 行注释；本卡 G2 RX|
|RX 资源和分类|失败释放暂占数据；交付释放已读空间；队列容量 2^RX_DQ_AW；每网 good 后再有交付/拒收结果|afdx_rx_parse 21–35、73–78 行注释；afdx_rx_deliver 1–3、24–26、37–39 行注释；ARCH 247–299、343–363 行|
|同步复位、截断与恢复|复位作废在途消息、发送归零，接收先等 valid 回低；只在实际收到截断时要求对端错误；重新配置后新消息正确|ARCH 335–341 行；MAC 接收前导/长度/FCS 判定见 ARCH 247–253 行；本卡 G3|
|ready|开始合法最大消息前检查；它是保守准入提示，不能作为输入强制拒收条件|ARCH 54、66 行；本卡 G2 TX；afdx_app_tx 73–90 行|

1 字节消息没有规范预期，测试将其输出和事件保留为观察，关闭该观察窗口的消息结果判定，排空后单独开启恢复检查。2 字节 VLID-only 输入单独记录事件增量，不从前一条 1 字节输入推算。忽略已撤销 ready 但资源尚足的额外输入允许完整出现或完全不出现，仅记录本次观察，不断言必须丢弃或接纳。

## 定向场景与结果

|测试|组|结果|TB checks|独立 checks|仿真秒数|反例|
|---|---|---|---:|---:|---:|---|
''']
    for r in results:lines.append(f"|{r['test']}|{r['group']}|PASS|{r['checks']}|{r['independent_checks']}|{r['simulation_seconds']:.3f}|M1/M2 均 FAIL|")
    lines.append('''
### G1 验证 A 网队列满及恢复

RX_DQ_AW=1，B 网始终空闲。1471 字节长帧开始交付后，在其交付窗口输入 10 条 A 网 1 字节载荷帧，SN 从 1 递增，解析、映射、完整性和冗余检查均有效。预期保留前两条短帧，另外 8 条整帧拒收，长帧和已接纳短帧内容完整。结果 good=12（含恢复帧）、队列 overflow=8、deliver=4、解析器 ring overflow=0、B 事件=0。排空与恢复后两次检查 committed=trial=read_ptr，A/B 待处理描述符和 dq_count 均为 0。恢复载荷 64 字节逐字节正确。UCDB 的 557 行分支与语句均计数 8，排除了 ev_a[7] 仅由字节环满导致的歧义。

### G2 验证发送封装的真实边界

所有输入、配置均经 AFDX_top 公开端口，不强制内部寄存器、不停消费端。合法短消息突发遵守 ready，压到保守准入撤销并排空恢复；ready-low 但尚有资源的额外消息在本次观察中完整接纳，未把“ready 低”写成必须丢弃条件。9002 字节总输入使空间实际到达 4096，计数饱和至 8191；另用 4099 字节总输入对准最后一个输入字节首次看见 used>=4096，命中 bad 尚未置位的另一拒收条件。两者整条回滚，随后正常消息完整发出。

描述符压力按入消息首字节处理拍的真实 descriptors==32 对准，不按第 33 条计数。消费一直运行，安全拍位通过只读查找状态观察选择。未初始化输入在全条结束时仍未初始化；未配置 VLID 场景则在初始化后、写 word2 前固定发送并等查找完成，两者分开判定。普通、未初始化和满描述符三种条件均覆盖 1/2 字节输入：本次 1 字节观察分别为仅 miss 一次、miss/full 各一次、miss/full 各一次，不将其定为接口规范；2 字节独立增量分别为 (full,miss)=(0,1)、(1,0)、(1,0)，其后恢复消息均正确。

### G2 接收封装仅做模块级压力

直接实例化 afdx_app_rx，输出持续采集，不使用顶层 rx_ready。150 条连续单字节短消息再加一条 8 字节消息触发描述符门限，拒收 96 条，max descriptors=32、max used=24；连续 1471 字节长消息触发数据门限，拒收 1 条，max used=2626、max descriptors=3。两种触发相互隔离。独立模型以首字节前一拍资源值核对寄存后的拒收谓词，再按输入账本核对全部接纳消息和 drop 数量；停止输入后自然排空，恢复帧完整。这不是系统级积压场景。

### G3 验证未复位对端的恢复与容量

两端正常线路零延迟直连，不经过 link_model。只有容量探针区间使用 TB 字节源直接驱动对端 A 线，且区间开始要求发送端空闲。E1 为被复位侧，E2 整个运行期间不复位。E2 使用 RX_RING_AW=9；固定探针依次为 320、513、512、17 字节，IC/RM 关闭以隔离容量判定，配置和字节序列前后相同。每帧自然排空并记录实际接收/溢出结果，前后向量均为 **接纳、溢出、接纳、接纳**。两轮全部快照均满足 parse_a/b committed=trial=交付 read_ptr、待处理描述符=0、dq_count=0；指针按模递增，逻辑空闲不要求绝对数值回零。

|场景|复位前登记拍 / 生效拍|状态名与值|未复位 E2 实际收到的旧字节|要求增加的 E2 事件|单项 UCDB|
|---|---|---|---|---|---|
|RX 引擎|75972 / 75973|FRAME=2，phase=0|无 E1 旧发送字节；E2→E1 的 200 字节旧载荷帧已经完整在线发送，E1 尚未交付|不要求错误增加，good/deliver 不增|T64-1619 计数 1|
|MAC TX|75714 / 75715|PREAMBLE=1，pre_index=3|4 个 55，未收到 SFD/载荷/FCS；登记时已采到 3 字节，复位生效边沿对端再采到最后 1 字节|ev_a[2] 增 1，FCS/header 均不增，good/deliver 不增|T64-1225 计数 1|
|应用 TX|75465 / 75466|st1=6|无；查找阶段在首个 GMII 字节前被复位|不要求错误增加，good/deliver 不增|T64-0898 计数 1|

每种场景都检查复位生效后 E1 不继续旧输出、不重发旧消息；重初始化及重新配置完成后，E1→E2 的 64 字节新消息和 E2→E1 的 64 字节新消息逐字节正确、各交付一次。E2 最终均 good=7、deliver=7、ring overflow=2（两轮 513 字节探针）；MAC 场景另有 length/preamble=1，其余场景为 0。旧帧、半条和重复消息均未交付。原始接收侧字节与状态登记保存在各 runs/*/t65_trace.txt。

## 反例与独立核对

每个正向测试都通过 run.ps1 不带覆盖率执行 `T65_MUTANT=1` 和 `T65_MUTANT=2`。M1 改一个合法/恢复参考载荷字节；M2 改 drop 参考数或在原资源清空检查中注入一项描述符偏差。全部 32 次编译 Errors=0/Warnings=0，仿真引擎诊断和 RAMCOLL 均为 0，末个 RESULT 为 FAIL、errors>0、入口退出码 1；没有把编译失败或工具异常当成反例成功。

反例子进程使用 AFDX_LATEST_PREFIX=t65_mut_；正式 latest 指针仍指向正向尝试，反例目录在 out/sim，索引登记在 out/t65/attempts.json，均无 UCDB 纳入合并。因为只改 TB 参考检查，真实 DUT 输出没变，默认独立参考核对仍通过是正常现象。另对 16 份正向捕获各改一个恢复字节和一项资源快照，独立检查器 32/32 判失败。详见 [counterexamples.json](evidence/t65_gap_tests/counterexamples.json) 与 [checker_selftests.json](evidence/t65_gap_tests/checker_selftests.json)。

## 缺口 ID 与 UCDB 证据

目标基于执行前保存的 [targets.json](evidence/t65_gap_tests/targets.json)。[target_hits.csv](evidence/t65_gap_tests/target_hits.csv) 逐项列出 T64 ID、原始项目、命中及原因；[target_hits.json](evidence/t65_gap_tests/target_hits.json) 保留计数和 G3 单项库摘要。

- A02：T64-0023、T64-1621，2/2 命中，各计数 8。
- A01：T64-0139～0145、0852～0854、0871～0881、0907～0911，26/26 命中，没有遗留 A01 项。
- G3：T64-1619、1225、0898，3/3 命中；备选 T64-0906 未测，原计数仍为 0。合并总转移额外命中一个 AGE→INIT，不以此代替三个登记目标。

分支 ID 使用卡允许的第一种方法：同版 vcover dump -canonical，输出在 out/t65/coverage，90 秒上限；完整 DU 段写完、进入首个实例段时核实 PID/创建时间/命令再结束冗余 dump。原始前缀、工具身份与边界分别保存；原生必需 merge/report 均正常结束，dump 的受控结束不算功能失败。分支按完整原生 scope/bin 名直接对应 T64 ID，语句按源码行和 item 编号，FSM 按寄存器、转移和源码行；条件/表达式按原始 FEC 输入项对应。目标摘要见 raw/target_native.txt，三个 G3 单项证据为 raw/reset_*_transition.txt。没有调用会写回 T64 的 collect/publish/du_dump。

## 合并统计与分母差异

合并使用 vcover merge -checkinputs -ucdbchecks，原生输出为 All input files merged successfully、Errors=0、Warnings=0。只有 16 个最终源码对应的功能及独立核对均通过的 UCDB 纳入合并；输入清单、字节数、完整 SHA-256 和摘要在 [ucdb_inputs.json](evidence/t65_gap_tests/ucdb_inputs.json)。失败、反例、旧版成功但源文件已更新的尝试均单独保留并排除。
''')
    lines.append(f"\n最终合并库 `{cov['merged_ucdb']}`，SHA-256 `{cov['merged_sha256']}`。测试集合恰好 56 项，带统计的 DU 恰好 29 个。下列列出两套实际计数，不计算百分比差值；不能将表中变化解释为同口径进退。\n\n|指标|T64 已覆盖/总数|T64 %|本次合并已覆盖/总数|本次 %|\n|---|---:|---:|---:|---:|\n")
    for metric in cov['metrics']:
        a=t64['metrics'][metric];b=cov['metrics'][metric]
        lines.append(f"|{metric}|{a['covered']}/{a['total']}|{a['percent']:.2f}|{b['covered']}/{b['total']}|{b['percent']:.2f}|")
    lines.append('\n逐 DU 的全部 203 组分母核对见 [denominators.json](evidence/t65_gap_tests/denominators.json)，逐模块已覆盖数/总数见 [coverage.json](evidence/t65_gap_tests/coverage.json)，原生 summary/uncovered 见 raw/。有差异的 9 组如下，全部原样保留：\n\n|设计单元|指标|T64 分母|本次分母|\n|---|---|---:|---:|\n')
    for r in load(EVID/'denominators.json')['rows']:
        if not r['same']:lines.append(f"|{r['unit']}|{r['metric']}|{r['t64']}|{r['t65']}|")
    lines.append('''
RTL 字节及插桩选项一致，使用的参数组合已有 T64 覆盖。分母变化的根因没有证明，不能据此声称 RTL 改变或功能退化，也不能擅自把新增项删掉。原生集合差分能定位 afdx_cfg 新出现的两个语句和四个分支 bin 到 509/510 行的 ev_gdrop 计数；ARCH 363 行说明顶层这两位为常量 0。这支持“工具编译/优化上下文保留集合不同”的可能解释，仍属推断。该差异证据在 denominator_native_additions.json，父线程据此决定是否需要另做口径研究。本卡不更改分母、不加排除、不宣称同口径覆盖率提高。

## 编写阶段诊断与验证边界

没有确认 RTL 缺陷。开发阶段有一次 Verilog 数组声明晚于 task 的编译错误，已把新 TB 的数组声明移到使用之前；还有一次短消息满队列刺激在实际处理首字节时已有消费、只剩 31 项，以及观察窗口尚有旧核心帧在发送。失败原始尝试保留，有出处的功能检查没有放宽；修正新 TB 的对拍，并按卡把未规定的 1 字节行为与恢复检查分开后，最终源码重新编译、正向和反例全部完成。完整尝试分类见 attempts.json。

本卡证明所列场景的 RTL 行为与恢复；接收封装压力为模块级，G3 只覆盖登记的三种精确复位状态和所列固定容量序列，未覆盖所有同步复位边或所有资源组合。1 字节输入仅观察。覆盖率没有人为通过线，分母差异待父线程判断。是否并入 sim/tests.txt、是否整合 submission、是否做进一步缺陷/口径处理均留父线程验收和用户决定。

## 复现与交付入口

新 TB 源码内已有全部输入，直接运行无需读取 out/t65 的激励文件。下面是原入口格式，重跑时使用当次有效的带偏移截止时间；本卡已结束，不重启原批次计时。

```powershell
$env:AFDX_PYTHON='E:/anaconda3/python.exe'
$env:MODELSIM_HOME='E:/Verilog/ModelSim/setup_pack/win64'
$env:AFDX_CE_DIV='2'
sim/run.ps1 -Test tb_t65_queue_a -Coverage -Deadline '2026-10-30T18:49:56+08:00'
E:/anaconda3/python.exe -B -X utf8 tools/t65_check.py '<该次输出目录>' tb_t65_queue_a
$env:AFDX_LATEST_PREFIX='t65_mut_'
sim/run.ps1 -Test tb_t65_queue_a -Param T65_MUTANT=1 -Deadline '2026-10-30T18:49:56+08:00'
```

- 运行器与完整尝试：out/t65/current.json、out/t65/attempts.json；仿真、UCDB 和源码快照仍在各 out/sim 目录。
- 正式结果和 32 个原生反例：results.json、counterexamples.json、runs/、counterexamples/。
- UCDB 和 ID：ucdb_inputs.json、coverage.json、denominators.json、target_hits.csv/json、raw/。
- 源码与提交边界：freeze.json、rtl_binding.json、acceptance.json、precommit_scope.json、manifest.json。
- 工具：tools/t65_generate.py 生成确定性新 TB；t65_run.py 控制串行入口；t65_check.py 独立核对；t65_coverage.py 只处理 T65 统计；t65_publish.py 终验并导出白名单证据。复算分析可复用已保存的有效 UCDB，无需重跑 T64。

只在 t63 本地提交白名单新增文件，提交号见本次最终交付及 Git 历史。没有更新 submission、没有 push、merge、amend。没有创建需要撤销的监控或定时机制；本批工作全部结束后释放唯一文件锁，保留必要运行和失败证据。
''')
    text='\n'.join(lines).rstrip()+'\n'
    text=re.sub(r'(?m)(^\|[|:\- ]+\|)\n\n(?=\|)',r'\1\n',text)
    (ROOT/'docs/T65_GAP_TESTS.md').write_text(text,encoding='utf-8')

if __name__=='__main__':publish()
