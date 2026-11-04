"""Inspect or interrupt only the identity-pinned T75 fragment simulation.

No simulator is started. --stop requires the approved record boundary and an
isolated console containing only this simulation and its own license helper.
ModelSim's documented CTRL-C path runs the existing onbreak/quit handler.
"""
import argparse
import ctypes
from ctypes import wintypes
from datetime import datetime
import os
from pathlib import Path
import time

import psutil

from t75_prefix import FLOW,OUTPUT,TZ,check,load_plan,read_files,read_json,save,status


def identity(process):return dict(pid=process.pid,created=process.create_time())


def same_identity_alive(expected):
    try:return psutil.Process(expected['pid']).create_time()==expected['created']
    except psutil.NoSuchProcess:return False
    except psutil.AccessDenied:return None


def original_process(expected,name):
    process=psutil.Process(expected['pid'])
    assert identity(process)==expected,'PID creation-time mismatch'
    assert process.name().lower()==name and Path(process.cwd()).resolve()==FLOW,'Unexpected process image or cwd'
    return process


def run(stop=False):
    plan,_=load_plan();ready=status(read_files(FLOW))
    if stop and not ready['ready_to_stop']:
        print('NOT READY: '+str(ready));return 2
    owner_path=OUTPUT/'controller_identity.json'
    if stop and owner_path.exists():
        owner=read_json(owner_path)
        assert owner['pid']==os.getpid() or same_identity_alive(owner) is not True,'Existing prefix controller owns the stop action'
    launcher=original_process(plan['launcher'],'vsim.exe')
    process=original_process(plan['kernel'],'vsimk.exe')
    assert process.ppid()==launcher.pid
    assert 'work.tb_frag1030_net' in launcher.cmdline()
    allowed={process.pid,launcher.pid,os.getpid()}
    components=[identity(launcher)|dict(name=launcher.name()),identity(process)|dict(name=process.name())]
    for child in launcher.children(recursive=True):
        if child.name().lower()=='vlm.exe' and Path(child.cwd()).resolve()==FLOW:
            allowed.add(child.pid);components.append(identity(child)|dict(name=child.name()))
    other_kernels=[dict(pid=p.pid,created=p.info['create_time']) for p in psutil.process_iter(['name','create_time'])
                   if (p.info['name'] or '').lower()=='vsimk.exe' and p.pid!=process.pid]
    kernel=ctypes.WinDLL('kernel32',use_last_error=True)
    handler_type=ctypes.WINFUNCTYPE(wintypes.BOOL,wintypes.DWORD)
    handler=handler_type(lambda event:True)
    kernel.AttachConsole.argtypes=[wintypes.DWORD];kernel.AttachConsole.restype=wintypes.BOOL
    kernel.FreeConsole.argtypes=[];kernel.FreeConsole.restype=wintypes.BOOL
    kernel.GetConsoleProcessList.argtypes=[ctypes.POINTER(wintypes.DWORD),wintypes.DWORD];kernel.GetConsoleProcessList.restype=wintypes.DWORD
    kernel.SetConsoleCtrlHandler.argtypes=[handler_type,wintypes.BOOL];kernel.SetConsoleCtrlHandler.restype=wintypes.BOOL
    kernel.GenerateConsoleCtrlEvent.argtypes=[wintypes.DWORD,wintypes.DWORD];kernel.GenerateConsoleCtrlEvent.restype=wintypes.BOOL
    kernel.FreeConsole()
    if not kernel.AttachConsole(process.pid):raise ctypes.WinError(ctypes.get_last_error())
    record=None
    try:
        if not kernel.SetConsoleCtrlHandler(handler,True):raise ctypes.WinError(ctypes.get_last_error())
        pids=(wintypes.DWORD*128)();count=kernel.GetConsoleProcessList(pids,128)
        if not count:raise ctypes.WinError(ctypes.get_last_error())
        assert count<=128,'Console membership exceeds checked buffer'
        members=set(list(pids)[:count])
        assert process.pid in members and launcher.pid in members
        assert members<=allowed,'Unrelated console members; no control event sent: '+str(members-allowed)
        assert not members&{p['pid'] for p in other_kernels},'Another simulation shares this console'
        # Recheck identities and records immediately before the control action.
        original_process(plan['kernel'],'vsimk.exe');original_process(plan['launcher'],'vsim.exe')
        ready=status(read_files(FLOW))
        if stop:assert ready['ready_to_stop'],'Record boundary changed; no signal sent'
        record=dict(kernel=plan['kernel'],launcher=plan['launcher'],ready_before=ready,
            console_members=sorted(members),own_components=components,other_kernels_before=other_kernels,
            checked=datetime.now(TZ).isoformat(),signal_sent=False,
            action='CTRL_C_EVENT to the verified isolated fragment console; no process termination or tree kill')
        if stop:
            assert not (OUTPUT/'stop_record.json').exists(),'Existing stop record retained; refusing a second signal'
            save(OUTPUT/'stop_record.json',record)
            if not kernel.GenerateConsoleCtrlEvent(0,0):raise ctypes.WinError(ctypes.get_last_error())
            record.update(signal_sent=True,signal_time=datetime.now(TZ).isoformat())
            save(OUTPUT/'stop_record.json',record)
            try:
                record.update(kernel_exit=process.wait(timeout=45),kernel_exited=True)
            except psutil.TimeoutExpired:
                record['kernel_exited']=False
            record['finished']=datetime.now(TZ).isoformat()
            record['other_kernels_after']=[row|dict(same_identity_alive=same_identity_alive(row)) for row in other_kernels]
            save(OUTPUT/'stop_record.json',record)
        else:
            record['action']='Read-only inspection; no signal sent'
    finally:
        kernel.FreeConsole()
    print(__import__('json').dumps(record,ensure_ascii=False,indent=2))
    return 0 if not stop or record.get('kernel_exited') else 3


def wait_for_prefix():
    """One bounded test controller; no heartbeat, schedules, or simulator launch."""
    plan,_=load_plan();deadline=datetime.fromisoformat(plan['deadline']).timestamp()
    OUTPUT.mkdir(parents=True,exist_ok=True)
    owner=identity(psutil.Process())|dict(started=datetime.now(TZ).isoformat(),deadline=plan['deadline'],kernel=plan['kernel'])
    # Exclusive creation prevents two controllers from sending stop events.
    with (OUTPUT/'controller_identity.json').open('x',encoding='utf-8') as stream:
        __import__('json').dump(owner,stream,indent=2);stream.write('\n')
    print('PREFIX CONTROLLER START '+str(owner),flush=True)
    result=dict(started=owner['started'],kernel=plan['kernel'],deadline=plan['deadline'])
    try:
        while time.time()<deadline:
            assert same_identity_alive(plan['kernel']) is True,'Original fragment kernel exited before controller action'
            if status(read_files(FLOW))['ready_to_stop']:
                code=run(stop=True)
                if code==0:code=check()
                result.update(exit_code=code,status=read_json(OUTPUT/'check_summary.json')['Status'] if (OUTPUT/'check_summary.json').exists() else 'STOP_PENDING')
                return code
            time.sleep(1)
        raise RuntimeError('Original deadline reached; no signal, restart or extension performed')
    except Exception as error:
        result.update(exit_code=1,status='CONTROLLER_ERROR',error=str(error))
        print('PREFIX CONTROLLER ERROR '+str(error),flush=True)
        return 1
    finally:
        result['finished']=datetime.now(TZ).isoformat();save(OUTPUT/'controller_summary.json',result)


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    group=parser.add_mutually_exclusive_group()
    group.add_argument('--stop',action='store_true',help='Send one scoped CTRL-C only after approved record counts are reached')
    group.add_argument('--wait',action='store_true',help='Wait for approved records, perform the one stop action and compare; original deadline retained')
    options=parser.parse_args()
    raise SystemExit(wait_for_prefix() if options.wait else run(options.stop))
