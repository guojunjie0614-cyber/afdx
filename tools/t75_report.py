"""Read T75 receipts and render an honest acceptance table; never run tools."""
import argparse
from datetime import datetime, timedelta, timezone
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
    path=Path(row['Summary']) if row.get('Summary') else root/'out'/(row['prefix']+'latest_'+test+('_gui' if kind=='A' else '')+'.json')
    data=load(path)
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
    status='RUNNING' if active else row.get('Status','UNKNOWN')
    identity=row.get('Process') or {}
    started=data.get('started',row.get('Started'))
    if not started and identity.get('created'):
        started=datetime.fromtimestamp(identity['created'],TZ).isoformat()
    return dict(Test=test,Param=row.get('params',row.get('Param','')),Kind=kind,Status=status,
                Checks=checks,CheckItems=data.get('check',{}).get('items'),
                NativeResult=native[1] if native else None,NativeErrors=int(native[3]) if native else None,
                SimulationSeconds=simulation.get('seconds'),Seconds=row.get('Seconds'),
                Started=started,Finished=data.get('finished',row.get('Finished')),
                Folder=relative(folder) if folder.exists() else relative(row.get('Folder')),
                Summary=relative(path),Error=data.get('error',row.get('Error')),
                PeakTreeBytes=simulation.get('peak_tree_bytes'),Process=row.get('Process'),
                RTLReference=data.get('rtl_reference'),ExactExternalRecords=data.get('exact_external_records'))


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--batch',type=Path,default=ROOT/'out/t75/baseline_run/summary.json')
    parser.add_argument('--final-start',type=int,default=145)
    parser.add_argument('--final-count',type=int,default=67)
    args=parser.parse_args()
    batch=load(args.batch);evidence=ROOT/'docs/evidence/t75_frag1030';evidence.mkdir(parents=True,exist_ok=True)
    runs=batch.get('Runs',[]);active=batch.get('Active',[]);pending=batch.get('Pending',[])
    final=[]
    selection=load(ROOT/'out/t75/final_selection.json').get('SelectedIndices',list(range(args.final_start,args.final_start+args.final_count)))
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
    mapped=[receipt(r) for r in runs if r['Kind']=='B']
    synthesis=[receipt(r) for r in runs if r['Kind']=='SYNTH']
    all_attempts=[receipt(r) for r in runs]
    tests_complete=len(final)==args.final_count and all(r['Status']=='PASS' for r in final) and all(r['Status']=='PASS' for r in official)
    integrity=load(ROOT/'out/t75/final_integrity.json')
    complete=tests_complete and integrity.get('passed') is True
    result=dict(Updated=datetime.now(TZ).isoformat(),Acceptance='PASS' if complete else 'TESTS_PASS_INTEGRITY_PENDING' if tests_complete else 'INCOMPLETE',
                FinalRTL=final,Official=official,PairedRTL=references,Secondary=mapped,Synthesis=synthesis,
                Note='PASS requires current protected-input and VQM integrity receipts as well; intermediate self-checks alone do not close the card.')
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
    failures=[r for r in final+official if r['Status']=='FAIL']
    text=['# T75 frag1030 验证结果','',f"更新：{local(result['Updated'])}。状态：{result['Acceptance']}。",'',
          f'最终 RTL 已通过 {passed}/{args.final_count} 项；正式 VQM 已通过 {sum(r["Status"]=="PASS" for r in official)}/3 项。',
          '当前仍在执行的用例和排队项不是 PASS。所有报告时间采用北京时间。','',
          '## 正式官方 VQM 与显式配对参考','',*table(official+references),'',
          '网表记录必须与本次调用显式返回的 RTL 参考逐字节相同。tb_elinx 按卡内规定使用独立公开端口自检。','',
          '## 最终 RTL 全表与分支测试','',*table(final),'',
          '## B 类辅助结果','',*table(mapped),'',
          'B 类八份所需映射均已尝试；当前失败原因为整份源文件前端读取时遇到 afdx_tx_buf.v:115 的 $fatal。未用官方 VQM 代替 B 类结果。具体映射输出如下：','',
          *[f"- {r['Test']}: {r['Status']}；{r['Folder']}；{r.get('Error') or '无错误'}" for r in synthesis],'',
          '## 输入冻结、变更与边界','',
          '- VQM 比较见 vqm_sha256.json；正式运行的 original.vqm 与布线输入相同。',
          '- 运行、PID、创建时间、原始截止及全部历史尝试见 out/t75/baseline_run/summary.json 和 out/t75/all_attempts.json。',
          '- 最初原样 56 项编译失败保留；随后冻结旧判据基线与最终新判据运行分列，未覆盖失败。',
          '- 仿真源码兼容只在 out/ 副本执行，保留所有断言；每份副本有精确逆变换收据。',
          '- 两份已更新的共享测试库冻结在 candidate1_source 中；原首次 A 调用复制的未实例化共享库在工作树入口保留旧版本直至该调用结束，再恢复测试改动。',
          '- 卡内 b3a60639 对比要求与指定 a6181267 起点的继承 physical_only.edc 差异单独列出；本任务不更改 RTL、网表或时序约束。',
          '- 变更依据见 test_changes.md；缺陷和环境分类见 defects.md；网表峰值见 peak_memory.json。','']
    if failures:text += ['## 未通过项','']+[f"- {r['Test']}: {r.get('Error') or r.get('NativeResult') or '见原始记录'}" for r in failures]+['']
    (evidence/'summary.md').write_text('\n'.join(text),encoding='utf-8')
    print(json.dumps(dict(acceptance=result['Acceptance'],final_rtl_passed=passed,official_passed=sum(r['Status']=='PASS' for r in official),
                         failures=[r['Test'] for r in failures],summary=str(evidence/'summary.md')),ensure_ascii=False))


if __name__=='__main__':
    main()
