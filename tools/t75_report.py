"""Read T75 receipts and render an honest acceptance table; never run tools."""
import argparse
from datetime import datetime, timedelta, timezone
import hashlib
import json
from pathlib import Path
import re

ROOT=Path(__file__).resolve().parents[1]
TZ=timezone(timedelta(hours=8))


def load(path):
    return json.loads(path.read_text(encoding='utf-8-sig')) if path.is_file() else {}


def local(value):
    return datetime.fromisoformat(value).astimezone(TZ).strftime('%Y-%m-%d %H:%M:%S') if value else '—'


def relative(value):
    if not value:return '—'
    try:return Path(value).relative_to(ROOT).as_posix()
    except ValueError:return str(value)


def receipt(row,active=False):
    root=Path(row.get('root',ROOT))
    kind=row.get('kind',row.get('Kind'))
    test=row.get('test',row.get('Test'))
    path=Path(row['Summary']) if row.get('Summary') else root/'out'/(row['prefix']+'latest_'+test+('_gui' if kind=='A' else '')+'.json') if row.get('prefix') else None
    data=load(path) if path else {}
    folder=Path(data.get('folder',row.get('Folder') or ROOT/'out/nonexistent'))
    if not folder.exists() and active:
        candidates=sorted((root/'out'/('gui_netlist' if kind=='A' else 'sim')/(test+('_gui' if kind=='A' else ''))).glob('*'),reverse=True)
        if candidates:folder=candidates[0]
    jobs=data.get('jobs') or load(folder/'tool_metrics.json') or []
    simulation=next((j for j in jobs if j['name']=='simulation'),{})
    results=data.get('results',[])
    log=folder/'simulation.log'
    if log.is_file():
        results=re.findall(r'\[RESULT\]\s+(\w+)\s+(PASS|FAIL)\s+checks=(\d+)\s+errors=(\d+)',log.read_text(encoding='utf-8-sig',errors='replace'))
    native=next((r for r in reversed(results) if r[0]==test),None)
    checks=data.get('checks',int(native[2]) if native else None)
    external=data.get('check') or load(folder/'check_summary.json')
    status='RUNNING' if active else row.get('Status','UNKNOWN')
    identity=row.get('Process') or {}
    started=data.get('started',row.get('Started'))
    if not started and identity.get('created'):
        started=datetime.fromtimestamp(identity['created'],TZ).isoformat()
    return dict(Test=test,Param=row.get('params',row.get('Param','')),Kind=kind,Status=status,
                Checks=checks,CheckItems=external.get('items',external.get('checks')),ExternalErrors=external.get('errors'),
                NativeResult=native[1] if native else None,NativeErrors=int(native[3]) if native else None,
                SimulationSeconds=simulation.get('seconds'),Seconds=row.get('Seconds'),
                Started=started,Finished=data.get('finished',row.get('Finished')),
                Folder=relative(folder) if folder.exists() else relative(row.get('Folder')),
                Summary=relative(path) if path else None,Error=data.get('error',row.get('Error')),
                PeakTreeBytes=simulation.get('peak_tree_bytes'),Process=row.get('Process'),
                RTLReference=data.get('rtl_reference'),ExactExternalRecords=data.get('exact_external_records'))


def approved_prefix(official):
    plan=load(ROOT/'out/t75/prefix_plan.json')
    if not plan:return {},{}
    assert plan['cutoff_cycle']==199578 and plan['result_label']=='PASS-PREFIX'
    row=next(r for r in official if r['Test']=='tb_frag1030_net')
    path=ROOT/'out/t75/fragment_prefix/check_summary.json';data=load(path)
    if data:
        assert (ROOT/data['flow']).resolve()==(ROOT/row['Folder']).resolve()==(ROOT/plan['flow']).resolve()
        assert data['cutoff_cycle']==199578 and data['complete_simulation'] is False
        assert data['kernel']==plan['kernel'] and data['vqm_sha256']==plan['vqm_sha256']
        assert data['source_sha256']==plan['source_sha256']['t75_prefix.py']
        assert hashlib.sha256((ROOT/'tools/t75_prefix.py').read_bytes()).hexdigest().upper()==data['source_sha256']
        assert (ROOT/data['stop_record']).resolve()==(ROOT/'out/t75/fragment_prefix/stop_record.json').resolve()
        stop=load(ROOT/data['stop_record'])
        assert stop['kernel']==plan['kernel'] and stop['signal_sent'] is True and stop['kernel_exited'] is True
        assert stop['ready_before']['ready_to_stop'] is True
        assert data['Status'] in ('PASS-PREFIX','FAIL-PREFIX')
        if data['Status']=='PASS-PREFIX':
            assert data['passed'] is True and data['errors']==0 and data['items']==5
            assert len(data['comparisons'])==5 and all(r['equal'] for r in data['comparisons'])
            assert {r['file'] for r in data['comparisons']}=={'tx_a.txt','tx_b.txt','rx.txt','tx_messages.txt','events.txt'}
        row.update(RawStatus=row['Status'],RawError=row['Error'],Status=data['Status'],
            Checks=None,CheckItems=data['items'],ExternalErrors=data['errors'],
            PrefixCutoff=199578,PrefixComparedRecords=data.get('compared_records'),PrefixEvidence=relative(path),
            Error=None if data['passed'] else data.get('error','Approved prefix records differ'))
    else:
        stop=load(ROOT/'out/t75/fragment_prefix/stop_record.json')
        if stop.get('signal_sent'):
            row.update(RawStatus=row['Status'],RawError=row['Error'],Status='PREFIX-CHECK-PENDING',PrefixCutoff=199578)
    return plan,data


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--batch',type=Path,default=ROOT/'out/t75/baseline_run/summary.json')
    parser.add_argument('--final-start',type=int,default=145)
    parser.add_argument('--final-count',type=int,default=67)
    args=parser.parse_args()
    batch=load(args.batch);evidence=ROOT/'docs/evidence/t75_frag1030';evidence.mkdir(parents=True,exist_ok=True)
    runs=batch.get('Runs',[]);active=batch.get('Active',[]);pending=batch.get('Pending',[])
    final=[]
    selection_receipt=load(ROOT/'out/t75/final_selection.json')
    selection=selection_receipt.get('SelectedIndices',list(range(args.final_start,args.final_start+args.final_count)))
    if len(selection)!=args.final_count or len(set(selection))!=args.final_count:
        raise ValueError('Final selection is incomplete or duplicated')
    for index in selection:
        row=next((r for r in runs if r['Index']==index),None)
        if row:final.append(receipt(row));continue
        row=next((r for r in active if r['id']==index),None)
        if row:final.append(receipt(row,True));continue
        row=next((r for r in pending if r['id']==index),None)
        if not row:raise ValueError('Final case is absent from batch: '+str(index))
        final.append(dict(Test=row['test'],Param=row.get('params',''),Kind='RTL',Status='QUEUED',Checks=None,
                          CheckItems=None,SimulationSeconds=None,Started=None,Finished=None,Folder='—'))
    official=[];references=[]
    for test in ('tb_elinx','tb_net_services','tb_frag1030_net'):
        choices=[r for r in runs if r['Kind']=='A' and r['Test']==test]
        live=next((r for r in active if r['kind']=='A' and r['test']==test),None)
        if live:
            official.append(receipt(live,True));source=Path(live['root']);prefix=live['prefix']
        elif choices:
            row=max(choices,key=lambda r:r['Index']);official.append(receipt(row));
            data=load(Path(row['Summary']));source=Path(row['Summary']).parent.parent;prefix=Path(row['Summary']).name.partition('latest_')[0]
        else:
            raise ValueError('Official test is absent: '+test)
        if test!='tb_elinx':
            ref=load(source/'out'/(prefix+'latest_'+test+'_rtl.json'))
            if ref:
                r=receipt(dict(Test=test,Kind='RTL',Status='PASS' if ref.get('passed') else 'FAIL',Summary=str(source/'out'/(prefix+'latest_'+test+'_rtl.json'))))
                r['Kind']='RTL reference';references.append(r)
    prefix_plan,prefix_receipt=approved_prefix(official)
    secondary_rows=sorted([r for r in runs if r['Kind']=='B']+[r for r in pending if r['kind']=='B'],
                          key=lambda r:r.get('Index',r.get('id')))
    secondary_spec=[line.strip().split('|') for line in (ROOT/'sim/tests_netlist.txt').read_text(encoding='utf-8-sig').splitlines()
                    if line.strip() and not line.lstrip().startswith('#')]
    if len(secondary_rows)!=len(secondary_spec):raise ValueError('Secondary case coverage is incomplete')
    mapped=[]
    for row,spec in zip(secondary_rows,secondary_spec):
        current=receipt(row) if row.get('Status') else receipt(dict(row,Status='QUEUED'))
        current['NetlistTops']=spec[1].split(',')
        current['Param']=spec[1]+(' / '+current['Param'] if current.get('Param') else '')
        mapped.append(current)
    synthesis=[receipt(r) for r in runs if r['Kind']=='SYNTH']
    all_attempts=[receipt(r) for r in runs]
    tests_complete=len(final)==args.final_count and all(r['Status']=='PASS' for r in final) and all(r['Status']=='PASS' for r in official)
    integrity=load(ROOT/'out/t75/final_integrity.json')
    complete=tests_complete and integrity.get('passed') is True
    execution='COMPLETE' if batch.get('Finished') and not active and not pending else 'RUNNING'
    acceptance='TESTS_PASS_WITH_INHERITED_CONSTRAINT_DELTA' if complete and integrity.get('card5_literal_empty') is False else 'PASS' if complete else 'TESTS_PASS_INTEGRITY_PENDING' if tests_complete else 'NOT_ACCEPTED' if execution=='COMPLETE' else 'INCOMPLETE'
    rtl_failures=[r for r in final if r['Status']!='PASS']
    known_perf=(len(rtl_failures)==1 and rtl_failures[0]['Test']=='tb_sys_perf' and rtl_failures[0]['Status']=='FAIL'
                and rtl_failures[0].get('NativeResult')=='PASS' and rtl_failures[0].get('NativeErrors')==0
                and rtl_failures[0].get('ExternalErrors')==702)
    full_official=[r for r in official if r['Test']!='tb_frag1030_net']
    revised_tests_complete=bool(prefix_plan) and len(final)==67 and known_perf and all(r['Status']=='PASS' for r in full_official) and prefix_receipt.get('Status')=='PASS-PREFIX'
    revised_complete=revised_tests_complete and execution=='COMPLETE' and integrity.get('passed') is True
    if revised_complete:acceptance='REVISED_SCOPE_COMPLETE_WITH_LIMITATIONS'
    elif revised_tests_complete:acceptance='REVISED_TESTS_COMPLETE_INTEGRITY_PENDING'
    result=dict(Updated=datetime.now(TZ).isoformat(),Execution=execution,Acceptance=acceptance,FrozenSource=selection_receipt.get('Source'),
                FinalRTL=final,Official=official,PairedRTL=references,Secondary=mapped,Synthesis=synthesis,
                ScopeRevision=prefix_plan.get('approval'),RevisedScopeComplete=revised_complete,PrefixReceipt=prefix_receipt,
                OpenGates=['tb_sys_perf remains FAIL; revised statistics deferred to T76 line 3','8192-byte and fault-recovery VQM coverage deferred to T76','Inherited physical_only.edc delta versus b3a60639 remains'] if prefix_plan else [],
                Note='PASS-PREFIX is not full VQM PASS. Revised-scope completion retains the known performance FAIL and needs current protected-input and VQM integrity receipts.')
    (evidence/'results.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    (ROOT/'out/t75/all_attempts.json').write_text(json.dumps(all_attempts,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    peaks=[dict(Test=r['Test'],Status=r['Status'],PeakTreeBytes=r['PeakTreeBytes'],Summary=r['Summary']) for r in official]
    (evidence/'peak_memory.json').write_text(json.dumps(dict(Updated=result['Updated'],Official=peaks,
        LiveObservedPeak=batch.get('PeakMemory'),Sampling='Flow process-tree RSS sampled every 0.25 seconds; final values require finished simulation metrics.'),indent=2)+'\n',encoding='utf-8')
    def table(rows):
        lines=['| 测试 | 类别 | 结果 | 检查数 | 外部项 | 仿真秒数 | 开始 | 结束 | 输出目录 |',
               '|---|---|---|---:|---:|---:|---|---|---|']
        for r in rows:
            test=r['Test']+(' '+r['Param'] if r.get('Param') else '')
            number=lambda k:'—' if r.get(k) is None else str(r[k])
            lines.append('| '+ ' | '.join((test,r['Kind'],r['Status'],number('Checks'),number('CheckItems'),number('SimulationSeconds'),local(r.get('Started')),local(r.get('Finished')),r['Folder']))+' |')
        return lines
    passed=sum(r['Status']=='PASS' for r in final)
    failures=[r for r in final+official if r['Status'] in ('FAIL','FAIL-PREFIX')]
    official_statement=(f'完整官方 VQM 已通过 {sum(r["Status"]=="PASS" for r in full_official)}/2 项；分片前缀状态为 '+next(r['Status'] for r in official if r['Test']=='tb_frag1030_net')) if prefix_plan else f'正式 VQM 已通过 {sum(r["Status"]=="PASS" for r in official)}/3 项'
    text=['# T75 frag1030 验证结果','',f"更新：{local(result['Updated'])}。执行：{execution}；验收：{result['Acceptance']}。",'',
          f'最终 RTL 已通过 {passed}/{args.final_count} 项；{official_statement}。',
          'RUNNING 和 QUEUED 不计为 PASS；执行结束与验收通过分别报告。','',
          '## 正式官方 VQM 与显式配对参考','',*table(official+references),'',
          '网表记录必须与本次调用显式返回的 RTL 参考逐字节相同。tb_elinx 按卡内规定使用独立公开端口自检。','',
          ('按 11-03 21:30 获批调整，tb_elinx 和 tb_net_services 运行完整版；分片只验证至 199578 拍的前缀，结果标 PASS-PREFIX。A/B 各 6 帧、RX 4 条、全部 8 行发送记录及截止前事件逐字节比对。8192 字节和故障恢复已在 RTL 验证，相应 VQM 覆盖留待 T76。详见 plan_adjustment.md。' if prefix_plan else '三项官方测试使用完整连续状态，未另建分段平台。'),'',
          '前缀的外部项数按五组文件字节比较计；有意中断时没有最终 HDL RESULT，不借用 RTL 的 33 项数值。原 GUI 非零退出及独立 PASS-PREFIX 收据分别保留。','',
          '## 最终 RTL 全表与分支测试','',*table(final),'',
          '## B 类辅助结果','',*table(mapped),'',
          'B 类八份所需映射均已尝试；当前失败原因为整份源文件前端读取时遇到 afdx_tx_buf.v:115 的 $fatal。未用官方 VQM 代替 B 类结果。具体映射输出如下：','',
          *[f"- {r['Test']}: {r['Status']}；{r['Folder']}；{r.get('Error') or '无错误'}" for r in synthesis],'',
          '## 输入冻结、变更与边界','',
          '- VQM 比较见 vqm_sha256.json；正式运行的 original.vqm 与布线输入相同。',
          '- 运行、PID、创建时间、原始截止及全部历史尝试见 out/t75/baseline_run/summary.json 和 out/t75/all_attempts.json。',
          '- 最初原样 56 项编译失败保留；随后冻结旧判据基线与最终新判据运行分列，未覆盖失败。',
          '- 最终整表冻结源为 out/t75/candidate2_source；输入清单为 out/t75/final_source_manifest.json；RTL 工具预算显式配置为 28800 秒。',
          '- 官方入口与最终整表的测试平台字节、34 份 RTL 一致性，以及同次 RTL/网表激励向量哈希见 official_source_compatibility.json。',
          '- 仿真源码兼容只在 out/ 副本执行，保留所有断言；每份副本有精确逆变换收据。',
          ('- 首次 A 调用已结束；四份共享测试库已按哈希核对后恢复为最终整表实际测试的版本，与 candidate2_source 和 Git 中的已提交版本一致。收据见 out/t75/root_library_pins.json 和 final_integrity.json。' if integrity.get('root_libraries_restored') else '- 四份共享测试库的新版已在 Git 提交和 candidate2_source 中保存；首次 A 调用的未实例化库在原入口暂留旧版直至该调用退出，再安全恢复。收据见 out/t75/root_library_pins.json。'),
          '- 冻结快照共 203 个文件：201 份源/辅助文件和 2 份 Python 缓存，全部保持原哈希；根目录源文件比较排除缓存。交付工具相对快照的预算/准入/默认截止差异见 out/t75/tool_delta_after_freeze.patch；所有 A 类实际使用显式截止。',
          '- 卡内 b3a60639 对比要求与指定 a6181267 起点的继承 physical_only.edc 差异单独列出；本任务不更改 RTL、网表或时序约束。',
          '- 13 项资源边界检查见 resource_slot_checks.json；前缀比较器的 12 项夹具自检见 prefix_checker_selftest.json，夹具不构成 VQM 证据。',
          '- 变更依据见 test_changes.md；缺陷和环境分类见 defects.md；网表峰值见 peak_memory.json；旧性能门槛差异见 performance_difference.md，统计未修改。','']
    if failures:text += ['## 未通过项','']+[f"- {r['Test']}: {r.get('Error') or r.get('NativeResult') or '见原始记录'}" for r in failures]+['']
    (evidence/'summary.md').write_text('\n'.join(text),encoding='utf-8')
    print(json.dumps(dict(execution=execution,acceptance=result['Acceptance'],final_rtl_passed=passed,official_passed=sum(r['Status']=='PASS' for r in official),
                         failures=[r['Test'] for r in failures],summary=str(evidence/'summary.md')),ensure_ascii=False))


if __name__=='__main__':
    main()
