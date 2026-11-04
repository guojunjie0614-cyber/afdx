"""Run the existing AFDX RTL experiments using eLinx's bundled Verilator.

Full vectors and independent checkers are retained. ModelSim netlist, UCDB,
GUI, and four-state evidence remain separate. Every run has isolated inputs,
commands, diagnostics, source copies and per-case results.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import threading
import time

# Allow an isolated Python (-I) invocation while importing only trusted local
# build helpers, never modules from downloaded runtime/compiler directories.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from verilator_build import ROOT, VERILATOR, build, prepare_runtime, save, snapshot

FOCUSED = ['tb_cfg_local_ready', 'tb_service_pipeline', 'tb_context_pipeline',
           'tb_reassembly_engine', 'tb_reassembly_transactions', 'tb_reassembly_limits',
           'tb_rtc_banked', 'tb_app_payload_pipeline', 'tb_tx_ingress_elastic', 'tb_tx_buffer_bounds']
SYS_SPECIAL = {'tb_sys_rtc', 'tb_sys_snmp', 'tb_sys_snmp_settrap', 'tb_sys_615a'}
LONG = ['tb_sys_perf_var', 'tb_sys_perf', 'tb_fragmentation', 'app_long', 'app_default',
        'tb_sys_load', 'tb_sys_rtc', 'tb_net_services', 'tb_sys_net', 'tb_sys_615a']


class Batch:
    def __init__(self, args):
        self.args = args
        os.environ['AFDX_VERIFICATION_PROFILE']=args.profile
        self.folder = args.out.resolve() if args.out else ROOT/'out/open_verilator'/datetime.now().strftime('%Y%m%d_%H%M%S_%f')
        self.folder.mkdir(parents=True, exist_ok=False)
        self.sources = snapshot(self.folder/'sources')
        self.runtime = self.folder/'runtime/include'
        prepare_runtime(args.runtime_source, self.runtime)
        # Keep original bytes as identity evidence; no new hash baseline.
        self.originals = self.folder/'originals'
        self.inputs = []
        for sub in ('rtl', 'tb', 'tools'):
            for path in (ROOT/sub).rglob('*'):
                if path.is_file() and path.suffix in ('.v', '.vh', '.py') and '__pycache__' not in path.parts:
                    rel = path.relative_to(ROOT)
                    dest = self.originals/rel
                    dest.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(path, dest)
                    self.inputs.append(str(rel))
        self.state = {}
        self.lock = threading.Lock()
        self.start = time.monotonic()
        info = {'simulator': str(VERILATOR), 'version': subprocess.check_output([str(VERILATOR),'--version'],text=True).strip(),
                'compiler': str(args.compiler), 'compiler_version': subprocess.check_output([str(args.compiler),'--version'],text=True).splitlines()[0],
                'ce_div': 2, 'seed': 1, 'verification_profile':args.profile,
                'workers':args.workers,'build_jobs':args.build_jobs,
                'source_snapshot': str(self.originals), 'source_paths': self.inputs,
                'git_head': subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),
                'limitations': ['Verilator two-state timing simulation; no ModelSim UCDB, GUI, or gate-level validation'],
                'started': datetime.now().astimezone().isoformat()}
        save(self.folder/'manifest.json', info)
        diff = subprocess.check_output(['git','diff','--binary'],cwd=ROOT)
        (self.folder/'working_tree.diff').write_bytes(diff)
        print('OUTPUT '+str(self.folder), flush=True)

    def status(self, case, **fields):
        with self.lock:
            self.state.setdefault(case, {}).update(fields)
            save(self.folder/'status.json', self.state)
        if 'passed' in fields:
            print(json.dumps({'case':case, **fields},ensure_ascii=False),flush=True)

    def job(self, folder, name, args, timeout=600):
        args = list(map(str,args))
        with self.lock:
            with (folder/'commands.jsonl').open('a',encoding='utf-8') as f:
                f.write(json.dumps({'stage':name,'command':args,'cwd':str(folder)})+'\n')
        begin = time.monotonic()
        with (folder/(name+'.log')).open('w',encoding='utf-8') as stream:
            from process_guard import run
            process = run(args,cwd=folder,stdout=stream,stderr=subprocess.STDOUT,timeout=timeout,
                          metrics=folder/(name+'.resources.json'))
        text = (folder/(name+'.log')).read_text(encoding='utf-8',errors='replace')
        if process.returncode:
            raise RuntimeError(f'{name} exit={process.returncode}; {folder/(name+".log")}')
        return text, round(time.monotonic()-begin,3)

    def pyjob(self, folder, name, script, *args):
        return self.job(folder,name,[sys.executable,'-X','utf8',ROOT/'tools'/script,*args])

    def prepare(self, top, folder):
        if top.startswith('tb_sys_') and top not in SYS_SPECIAL:
            self.pyjob(folder,'vectors','sys_cases.py','--test',top,'--seed','1','--out',folder/'vectors')
            for n in ('es1_tx','es1_rx','es2_tx','es2_rx','es1_gmii_tx','es1_gmii_rx','es2_gmii_tx','es2_gmii_rx'):
                (folder/n).mkdir()
        elif top.startswith(('tb_mac_','tb_tx_','tb_rx_')) and top not in FOCUSED:
            self.pyjob(folder,'vectors','afdx_ref.py','vectors','--test',top,'--seed','1','--out',folder/'vectors')
        elif top in ('tb_sys_snmp','tb_sys_snmp_settrap'):
            self.pyjob(folder,'vectors','snmp_ref.py','vectors' if top=='tb_sys_snmp' else 'settrap_vectors','--dir',folder)
        elif top == 'tb_sys_rtc':
            self.pyjob(folder,'vectors','rtc_ref.py','vectors','--dir',folder)
        elif top == 'tb_sys_615a':
            self.pyjob(folder,'vectors','load_ref.py','vectors','--dir',folder)
        elif top == 'tb_net_services':
            self.pyjob(folder,'vectors','net_services_ref.py','vectors','--dir',folder)
        elif top == 'tb_fragmentation':
            self.pyjob(folder,'reference','fragment_ref.py','selftest')
            self.pyjob(folder,'vectors','fragment_integration.py','prepare',folder)

    def prepare_app(self, name, folder):
        inputs = folder/'input'
        inputs.mkdir()
        if name == 'app_long':
            self.pyjob(folder,'app-input','gen_app_vectors.py','--long','--out',inputs)
        else:
            for file in ('vl_config.txt','stimulus.txt','window.txt'):
                shutil.copyfile(ROOT/'sim/vectors/app'/file,inputs/file)
            self.pyjob(folder,'vectors','app_verilator_check.py','prepare',folder)
            return None
        from decimal import Decimal, ROUND_HALF_UP
        schedule = []
        payload = bytearray()
        for raw in (inputs/'stimulus.txt').read_text(encoding='ascii').splitlines():
            line = raw.split('#',1)[0].strip()
            if not line:
                continue
            due, vlid, blob = line.split()
            data = bytes.fromhex(blob)
            if not 1 <= len(data) <= 8192:
                raise ValueError('Invalid application stimulus length')
            cycles = int((Decimal(due)*125).to_integral_value(rounding=ROUND_HALF_UP))
            schedule.append((cycles,int(vlid,16),len(data),len(payload)))
            payload.extend(data)
        (inputs/'schedule.txt').write_text(str(len(schedule))+'\n'+''.join('%d %d %d %d\n'%r for r in schedule),encoding='ascii')
        (inputs/'payload.hex').write_text(''.join('%02x\n'%b for b in payload),encoding='ascii')
        window = [int((Decimal(x)*125).to_integral_value(rounding=ROUND_HALF_UP)) for x in (inputs/'window.txt').read_text().split()]
        (inputs/'window_cycles.txt').write_text('%d %d\n'%tuple(window),encoding='ascii')
        self.pyjob(folder,'vectors','fragment_integration.py','app-prepare',folder,inputs/'vl_config.txt',inputs/'schedule.txt',inputs/'payload.hex',inputs/'window_cycles.txt')
        return max(65536,len(payload))

    def check(self, top, folder):
        if top.startswith('tb_sys_') and top not in SYS_SPECIAL:
            self.pyjob(folder,'check','sys_run_checks.py','--test',top,'--dir',folder)
        elif top.startswith(('tb_tx_','tb_rx_')) and top not in FOCUSED:
            self.pyjob(folder,'check','afdx_ref.py','check','--test',top,'--dir',folder)
        elif top in ('tb_sys_snmp','tb_sys_snmp_settrap'):
            self.pyjob(folder,'check','snmp_ref.py','check' if top=='tb_sys_snmp' else 'settrap_check','--dir',folder)
        elif top == 'tb_sys_rtc':
            self.pyjob(folder,'check','rtc_ref.py','check','--dir',folder)
        elif top == 'tb_sys_615a':
            self.pyjob(folder,'check','load_ref.py','check','--dir',folder)
        elif top == 'tb_net_services':
            self.pyjob(folder,'check','net_services_ref.py','check','--dir',folder)
        elif top == 'tb_fragmentation':
            self.pyjob(folder,'check','fragment_integration.py','check',folder)
        elif top.startswith('tb_t65_'):
            code = 'import sys,json;from pathlib import Path;sys.path.insert(0,sys.argv[1]);from t65_check import check;r=check(sys.argv[2],sys.argv[3],0);Path(sys.argv[2],"check_summary.json").write_text(json.dumps(r,indent=2));print(json.dumps(r));sys.exit(bool(r["errors"]))'
            self.job(folder,'check',[sys.executable,'-X','utf8','-c',code,ROOT/'tools',folder,top])
        summary = folder/'check_summary.json'
        if summary.exists():
            result = json.loads(summary.read_text(encoding='utf-8'))
            if result.get('errors',0):
                raise RuntimeError(f'Independent checker errors: {summary}')
            return result
        return None

    def run(self, entry):
        start = time.monotonic()
        top, _, params = entry.partition('|')
        params = params.split(',') if params else []
        name = re.sub(r'[^\w.-]+','_',entry)
        folder = self.folder/name
        folder.mkdir()
        result = {'case':entry,'folder':str(folder),'passed':False}
        try:
            app = top.startswith('app_')
            self.status(entry,stage='vectors',folder=str(folder))
            if app:
                capacity = self.prepare_app(top,folder)
                if entry == 'app_default':
                    top = 'tb_app_entry'
                    for n in ('es1_tx','es1_rx','es2_tx','es2_rx','es1_gmii_tx','es1_gmii_rx','es2_gmii_tx','es2_gmii_rx'):
                        (folder/n).mkdir(exist_ok=True)
                else:
                    top = 'tb_fragmentation'
                    params.append('PAYLOAD_CAPACITY='+str(capacity))
            else:
                self.prepare(top,folder)
            if top == 'tb_cfg_local_ready':
                legacy = subprocess.check_output(['git','show','c857aba8361e7f9cea74801d4a4d908f49a76436:rtl/afdx_cfg.v'],cwd=ROOT,text=True,encoding='utf-8')
                (self.sources/'tb/lib/afdx_cfg_legacy.v').write_text(legacy.replace('module afdx_cfg','module afdx_cfg_legacy',1),encoding='utf-8')
            self.status(entry,stage='compile')
            exe = build(top,folder,self.sources,self.runtime,self.args.compiler,self.args.build_jobs,params)
            self.status(entry,stage='simulation')
            log, seconds = self.job(folder,'simulation',[exe],self.args.timeout)
            result['simulation_seconds'] = seconds
            result['results'] = re.findall(r'\[RESULT\][^\r\n]*',log)
            result['metrics'] = [line for line in log.splitlines() if re.search(r'\[(?:BURST_SUMMARY|RTC_SUMMARY|COVERAGE)\]|METRIC',line)]
            rows = re.findall(r'\[RESULT\]\s+(\w+)\s+(PASS|FAIL)(?:\s+checks=(\d+))?\s+errors=(\d+)',log)
            if not rows or rows[-1][0]!=top or any(r[1]!='PASS' or int(r[3]) for r in rows):
                raise RuntimeError(f'Simulation check failed: {folder/"simulation.log"}')
            if 'RAMCOLL' in log or re.search(r'\*\* (?:Error|Fatal):',log):
                raise RuntimeError(f'Simulation diagnostic: {folder/"simulation.log"}')
            result['checks'] = int(rows[-1][2]) if rows[-1][2] else None
            self.status(entry,stage='independent-check')
            if app:
                if entry == 'app_default':
                    self.pyjob(folder,'check','app_verilator_check.py','check',folder)
                else:
                    self.pyjob(folder,'check','fragment_integration.py','app-check',folder)
                result['application_metrics'] = (folder/'summary.txt').read_text(encoding='ascii').splitlines()
            else:
                result['independent_check'] = self.check(top,folder)
            result['passed'] = True
        except Exception as exc:
            result['error'] = str(exc)
        result['seconds'] = round(time.monotonic()-start,3)
        save(folder/'summary.json',result)
        self.status(entry,stage='done',**{k:v for k,v in result.items() if k!='case'})
        return result

    def finish(self, results):
        changed = [p for p in self.inputs if (ROOT/p).read_bytes()!=(self.originals/p).read_bytes()]
        summary = {'passed':all(r['passed'] for r in results) and not changed,
                   'cases':len(results),'passed_cases':sum(r['passed'] for r in results),
                   'changed_inputs':changed,'seconds':round(time.monotonic()-self.start,3),'results':results}
        save(self.folder/'summary.json',summary)
        print('OPEN VERILATOR '+('PASS' if summary['passed'] else 'FAIL')+' '+str(self.folder),flush=True)
        return 0 if summary['passed'] else 1


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('cases',nargs='*')
    p.add_argument('--out',type=Path)
    p.add_argument('--exclude',nargs='*',default=[])
    p.add_argument('--runtime-source',type=Path,required=True)
    p.add_argument('--compiler',type=Path,required=True)
    p.add_argument('--profile',choices=['legacy','fragmentation1030'],default='legacy')
    p.add_argument('--workers',type=int,choices=range(1,4),default=3)
    p.add_argument('--build-jobs',type=int,choices=range(1,5),default=2)
    p.add_argument('--timeout',type=int,default=3600)
    a = p.parse_args()
    entries = a.cases or [x.strip() for x in (ROOT/'sim/tests.txt').read_text().splitlines() if x.strip()]+['tb_fragmentation','app_default','app_long','tb_net_services']
    entries = [e for e in dict.fromkeys(entries) if e not in a.exclude]
    entries.sort(key=lambda e: LONG.index(e) if e in LONG else len(LONG))
    batch = Batch(a)
    with ThreadPoolExecutor(max_workers=a.workers) as pool:
        results = [f.result() for f in as_completed([pool.submit(batch.run,e) for e in entries])]
    return batch.finish(results)


if __name__=='__main__':
    raise SystemExit(main())
