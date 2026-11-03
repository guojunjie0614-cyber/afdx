"""Check admission boundaries with fake process lists; never launch EDA tools."""
import argparse
from datetime import datetime,timedelta,timezone
import hashlib
import json
from pathlib import Path
from unittest.mock import patch

import eda
import par_regress

ROOT=Path(__file__).resolve().parents[1]


class Process:
    def __init__(self,pid,name,children=(),error=None):
        self.pid=pid;self.info={'name':name};self.descendants=children;self.error=error

    def children(self,recursive=False):
        if self.error:raise self.error
        return self.descendants


def worker(pid=None,kind='RTL',eda_pid=None):
    return {'row':{'kind':kind},'sim_pids':set() if pid is None else {pid},
            'eda_pids':set() if eda_pid is None else {eda_pid}}


def check():
    kernel=Process(2,'vsimk.exe');launcher=Process(1,'VSIM.EXE',[kernel])
    pending=Process(3,'vsim.exe');unreadable=Process(4,'vsim.exe',error=eda.psutil.AccessDenied(4))
    rows=[]
    with patch.object(eda.psutil,'process_iter',return_value=[launcher,kernel,pending,unreadable,Process(5,'vopt.exe')]):
        actual=eda.modelsim_slot_pids()
        assert actual=={2,3,4},actual
        rows.append(dict(case='native launcher owns kernel; pending and inaccessible launchers reserve slots',slots=sorted(actual),passed=True))
    cases=[
        ('8 own workers (5 running, 3 compiling), 2 foreign kernels',[worker(i) for i in range(200,205)]+[worker() for _ in range(3)],set(range(200,205))|{500,501},10),
        ('8 own workers (5 running, 3 compiling), 1 foreign launcher',[worker(i) for i in range(200,205)]+[worker() for _ in range(3)],set(range(200,205))|{500},9),
        ('8 own kernels and 2 foreign kernels',[worker(i) for i in range(200,208)],set(range(200,208))|{500,501},10),
        ('all 10 slots foreign',[],set(range(10)),10),
        ('9 slots foreign permit one',[],set(range(9)),9),
        ('synthesis workers consume no simulation slots',[worker(200,'A'),worker(kind='SYNTH'),worker(kind='SYNTH')],{200},1),
        ('unknown child ownership reserves conservatively',[worker(),worker()],{200,201},4),
        ('no workers and no kernels',[],set(),0),
    ]
    for label,workers,global_slots,expected in cases:
        actual=par_regress.reserved_sim_slots(workers,global_slots)
        assert actual==expected,(label,actual,expected)
        rows.append(dict(case=label,reserved=actual,launch_allowed=actual<10,passed=True))
    synth_cases=[
        ('4 mapping workers (2 running, 2 queued), 2 external GUI/helper processes',
         [worker(kind='SYNTH',eda_pid=i) for i in (200,201)]+[worker(kind='SYNTH') for _ in range(2)],{200,201,500,501},6),
        ('4 mapping workers (2 running, 2 queued), 1 external GUI',
         [worker(kind='SYNTH',eda_pid=i) for i in (200,201)]+[worker(kind='SYNTH') for _ in range(2)],{200,201,500},5),
        ('6 own running mappings occupy all synthesis slots',
         [worker(kind='SYNTH',eda_pid=i) for i in range(200,206)],set(range(200,206)),6),
        ('RTL workers consume no synthesis slots; external GUI still counts',
         [worker(100),worker(101,'A'),worker(kind='SYNTH',eda_pid=200)],{200,500},2),
    ]
    for label,workers,global_slots,expected in synth_cases:
        actual=par_regress.reserved_synth_slots(workers,global_slots)
        assert actual==expected,(label,actual,expected)
        rows.append(dict(case=label,reserved=actual,launch_allowed=actual<6,passed=True))
    return rows


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path,default=ROOT/'out/t75/resource_slot_checks.json')
    output=parser.parse_args().output.resolve();output.relative_to(ROOT/'out')
    rows=check()
    files=('eda.py','par_regress.py','t75_resource_check.py')
    source_hashes={name:hashlib.sha256((ROOT/'tools'/name).read_bytes()).hexdigest().upper() for name in files}
    result=dict(passed=True,checked=datetime.now(timezone(timedelta(hours=8))).isoformat(),
                cases=rows,source_hashes=source_hashes,current_global_slots=sorted(eda.modelsim_slot_pids()),
                note='Read-only simulated process lists; no process or simulation launched.')
    output.parent.mkdir(parents=True,exist_ok=True)
    output.write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
    print('[RESULT] par_resource_gate PASS checks='+str(len(rows))+' errors=0')


if __name__=='__main__':
    main()
