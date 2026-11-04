"""Run a current waveform experiment and capture only its owned Wave window."""
import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import time
import psutil

sys.path.insert(0,str(Path(__file__).resolve().parent))
import eda
from process_guard import run as guarded_run
from run_modelsim_entries import prepare_tree

SCENARIOS=('tx_dual','rx_redundancy','rx_fcs_error','snmp_get','tx_bag','services')


def owned_ids(active):
    process=psutil.Process(active['pid'])
    if process.create_time()!=active['created']:
        raise RuntimeError('GUI PID identity changed')
    result={process.pid:process.create_time()}
    for child in process.children(recursive=True):
        try:result[child.pid]=child.create_time()
        except psutil.NoSuchProcess:pass
    return result


def complete_service_reference(flow,root,wave_output):
    # The original Tcl entry copies the two HDL input files. The independent
    # Python checker also needs its known application data as a companion.
    reference=flow.folder/'service_reference';reference.mkdir()
    flow.job('service_reference',[sys.executable,root/'tools/net_services_ref.py',
        'vectors','--dir',reference],30)
    matched=[]
    for name in ('bytes.hex','offsets.txt'):
        actual=wave_output/'vectors'/name;expected=reference/'vectors'/name
        if actual.read_bytes()!=expected.read_bytes():
            raise RuntimeError('Service GUI input differs from independent vectors: '+name)
        matched.append(dict(name=name,sha256=eda.sha(actual)))
    companion=wave_output/'vectors/data.bin';expected=reference/'vectors/data.bin'
    if companion.exists():
        if companion.read_bytes()!=expected.read_bytes():raise RuntimeError('Service golden data mismatch')
    else:shutil.copy2(expected,companion)
    flow.result['service_reference']=dict(matched_hdl_inputs=matched,
        companion=str(companion),companion_sha256=eda.sha(companion),
        provenance='Known input regenerated independently; both actual HDL input files matched before adding checker companion')


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('scenario',choices=SCENARIOS)
    args=parser.parse_args()
    os.environ['AFDX_VERIFICATION_PROFILE']='fragmentation1030'
    os.environ['AFDX_PYTHON']=sys.executable
    os.environ['AFDX_CE_DIV']='2'
    os.environ['AFDX_LATEST_PREFIX']='report_wave_'
    deadline=(datetime.now().astimezone()+timedelta(hours=2)).isoformat()
    flow=eda.Flow('report_wave',args.scenario,deadline)
    root=flow.folder/'project';capture=flow.folder/'captures'
    capture.mkdir();os.environ['AFDX_WAVE_CAPTURE_DIR']=str(capture)
    failures=[];captures=[]
    try:
        originals=prepare_tree(root)
        bootstrap=root/'current_wave_entry.do'
        experiment='do sim/wave/current_report.do '+args.scenario
        if args.scenario=='services':
            experiment=('source sim/wave/common.do\n'
                'do sim/run_services.do\n'
                'set wave_output [pwd]\n'
                'view wave -undock -title Wave -width 1480 -height 650 -x 0 -y 0\n'
                'delete wave *\n'
                'foreach name {clk reset phase rm1 rm2 ic2 difference status_value} {\n'
                ' wave_signal /tb_net_services/$name $name decimal\n}\n'
                'foreach endpoint {es1 es2} {\n'
                ' foreach name {d_valid d_data d_last} {\n'
                '  wave_signal /tb_net_services/$endpoint/$name ${endpoint}_$name hexadecimal\n }\n}\n'
                'configure wave -namecolwidth 180 -valuecolwidth 100 -timelineunits us\n'
                'wave_snapshot services 0ns [format %.3fns [wave_now_ns]]\n'
                'set fh [open current_wave_result.txt w]\n'
                'puts $fh "WAVE CURRENT PASS scenario=services test=tb_net_services"\n'
                'close $fh\nputs "WAVE CURRENT PASS scenario=services"')
        bootstrap.write_text('onerror {quit -code 1}\n'
            'if {[catch {'+experiment+'} detail]} {\n'
            ' puts "WAVE ENTRY FAIL $detail"\n puts $::errorInfo\n quit -code 1\n}\n'
            'quit -code 0\n',encoding='ascii')
        flow.result.update(scenario=args.scenario,inputs=originals,root=str(root))
        print('OUTPUT',flow.folder,flush=True)
        with ThreadPoolExecutor(max_workers=1) as pool:
            future=pool.submit(flow.job,'gui',[eda.modelsim_dir()/'vsim.exe','-gui','-do',
                'do current_wave_entry.do'],6600,root)
            handled=set()
            while not future.done():
                request=capture/'capture_request.txt'
                if request.is_file():
                    fields=request.read_text(encoding='utf-8-sig').splitlines()
                    if len(fields)==3 and fields[1] not in handled:
                        pid=int(fields[0]);name=fields[1]
                        if not re.fullmatch(r'[a-z0-9_]+',name):
                            raise RuntimeError('Unexpected capture name')
                        active=json.loads((flow.folder/'active_job.json').read_text())
                        ids=owned_ids(active)
                        if pid not in ids:raise RuntimeError('Capture requested by an unowned GUI process')
                        destination=capture/(name+'.png')
                        try:
                            with (capture/(name+'.log')).open('wb') as stream:
                                result=guarded_run(['powershell.exe','-NoProfile','-ExecutionPolicy','Bypass',
                                    '-File',root/'sim/wave/capture.ps1','-SessionProcessIds',
                                    ','.join(map(str,ids)),'-Destination',destination],cwd=root,
                                    stdout=stream,stderr=subprocess.STDOUT,timeout=45,
                                    metrics=capture/(name+'.resources.json'))
                            if result.returncode or not destination.is_file() or destination.stat().st_size<1024:
                                raise RuntimeError('Owned Wave capture failed; see '+name+'.log')
                            with destination.open('rb') as picture:
                                header=picture.read(24)
                            if header[:8]!=b'\x89PNG\r\n\x1a\n':raise RuntimeError('Capture is not a PNG')
                            width,height=struct.unpack('>II',header[16:24])
                            if width<600 or height<300:raise RuntimeError('Capture contains no readable Wave window')
                            captures.append(dict(name=name,path=str(destination),sha256=eda.sha(destination),
                                width=width,height=height,requested_pid=pid,owned_processes=ids,window=fields[2]))
                        except Exception as error:
                            failures.append(str(error))
                        handled.add(name)
                        # Release only this experiment's capture handshake; any
                        # capture error remains fatal to the coordinator result.
                        (capture/(name+'.done')).write_text('captured' if not failures else 'capture failed',encoding='ascii')
                        eda.save(flow.folder/'captures.json',dict(captures=captures,failures=failures))
                time.sleep(.1)
            log=future.result()
        output_root=root/('out/modelsim' if args.scenario=='services' else 'out/wave')
        outputs=list(output_root.glob('*/current_wave_result.txt'))
        expected={'tx_dual':2,'rx_redundancy':2,'rx_fcs_error':3,'snmp_get':2,'tx_bag':3,'services':1}[args.scenario]
        if len(outputs)==1:
            # GUI ModelSim writes Tcl output to its transcript, not redirected
            # stdout. Read the real transcript and Tcl result file as evidence.
            log+='\n'+(outputs[0].parent/'simulation.log').read_text(encoding='utf-8-sig',errors='replace')
            log+='\n'+outputs[0].read_text(encoding='utf-8-sig')
        if failures or len(captures)!=expected or len(outputs)!=1 or 'WAVE CURRENT PASS' not in log:
            raise RuntimeError('Waveform evidence incomplete: '+str(failures))
        if re.search(r'(?m)^(?:# )?(?:\*\* (?:Error|Fatal|Warning)(?::|\s)|WAVE ENTRY FAIL\b)',log):
            raise RuntimeError('Waveform execution diagnostics')
        wave_output=outputs[0].parent
        test={'tx_dual':'tb_sys_net','rx_redundancy':'tb_sys_delay','rx_fcs_error':'tb_sys_net',
              'snmp_get':'tb_judge_snmp','tx_bag':'tb_tx_bag','services':'tb_net_services'}[args.scenario]
        if test=='tb_net_services':
            service_result=(wave_output/'result.txt').read_text(encoding='utf-8-sig')
            if not re.search(r'^PASS checks=\d+ errors=0$',service_result,re.M):
                raise RuntimeError('Original service GUI entry did not pass')
            complete_service_reference(flow,root,wave_output)
            flow.job('check',[sys.executable,root/'tools/net_services_ref.py','check','--dir',wave_output],120)
            check=json.loads((wave_output/'check_summary.json').read_text())
            if check['errors']:raise RuntimeError('Independent service GUI check failed')
            flow.result['check']=check
        elif test in ('tb_sys_net','tb_sys_delay'):
            flow.job('check',[sys.executable,root/'tools/sys_run_checks.py','--test',test,'--dir',wave_output],300)
            check=json.loads((wave_output/'check_summary.json').read_text())
            if check['errors']:raise RuntimeError('Independent waveform system check failed')
            flow.result['check']=check
        elif test=='tb_tx_bag':
            flow.job('check',[sys.executable,root/'tools/afdx_ref.py','check','--test',test,'--dir',wave_output],180)
            check=json.loads((wave_output/'check_summary.json').read_text())
            if check['errors']:raise RuntimeError('Independent waveform TX check failed')
            flow.result['check']=check
        flow.result.update(passed=True,captures=captures,wave_output=str(wave_output),
            changed_originals=[r['path'] for r in originals if eda.sha(Path(r['path']))!=r['sha256']],
            visual_inspection='Required after execution; raw simulator defaults and signal labels retained')
        print('WAVE CAPTURE PASS',args.scenario,'OUTPUT',flow.folder,flush=True)
        return 0
    except Exception as error:
        flow.result.update(passed=False,error=str(error),captures=captures,failures=failures)
        print('WAVE CAPTURE FAIL',args.scenario,error,flush=True)
        return 1
    finally:flow.finish()


if __name__=='__main__':raise SystemExit(main())
