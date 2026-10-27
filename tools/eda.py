"""统一工具入口；所有工具产物只写out，进程保护只作用本次子进程树。"""
import argparse, hashlib, json, math, os, re, shutil, sqlite3, subprocess, sys, time
from datetime import datetime
from pathlib import Path
import psutil

ROOT=Path(__file__).resolve().parents[1]
def modelsim_dir():
    home=os.environ.get("MODELSIM_HOME")
    executable=Path(home)/"vsim.exe" if home else shutil.which("vsim.exe")
    if not executable or not Path(executable).is_file():
        raise RuntimeError("Set MODELSIM_HOME to the directory containing vsim.exe, or add it to PATH")
    return Path(executable).resolve().parent

def elinx_bin():
    home=os.environ.get("ELINX_HOME")
    executable=Path(home)/"bin/shell/bin/eLinx_synthesis.exe" if home else shutil.which("eLinx_synthesis.exe")
    if not executable or not Path(executable).is_file():
        raise RuntimeError("Set ELINX_HOME to the eLinx installation root, or add its bin/shell/bin to PATH")
    return Path(executable).resolve().parent

def memory_bytes(variable,default_gib):
    value=os.environ.get(variable,str(default_gib))
    try:gib=float(value)
    except ValueError:raise ValueError(f"{variable} must be a nonnegative number in GiB; 0 disables this guard") from None
    if not math.isfinite(gib) or gib<0:
        raise ValueError(f"{variable} must be a nonnegative finite number in GiB; 0 disables this guard")
    return int(gib*1024**3)

MEMORY_LIMIT=memory_bytes("AFDX_MEM_LIMIT_GB",10)
MEMORY_FLOOR=memory_bytes("AFDX_MEM_FLOOR_GB",5)

def save(path,data):
    path.write_text(json.dumps(data,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest().upper()

class Flow:
    def __init__(self,kind,name,deadline):
        stamp=datetime.now().strftime("%Y%m%d_%H%M%S_%f")
        self.folder=ROOT/"out"/kind/name/stamp
        self.folder.mkdir(parents=True,exist_ok=False)
        self.deadline=datetime.fromisoformat(deadline).timestamp() if deadline else time.time()+3600
        self.jobs=[]
        self.result={"name":name,"started":datetime.now().astimezone().isoformat(),
                     "folder":str(self.folder),"scope":"EQ6HL130/CSG484_H; unplaced estimates, no physical signoff",
                     "memory_floor_gib":MEMORY_FLOOR/1024**3,"memory_limit_gib":MEMORY_LIMIT/1024**3}
    def job(self,name,command,budget=900,cwd=None):
        remaining=self.deadline-time.time()
        if remaining<=0:raise RuntimeError("Task deadline reached; no new tool launched")
        if MEMORY_FLOOR and psutil.virtual_memory().available<MEMORY_FLOOR:
            raise RuntimeError(f"Available memory below {MEMORY_FLOOR/1024**3:g} GiB (AFDX_MEM_FLOOR_GB); other jobs untouched")
        budget=min(budget,remaining)
        begin=time.monotonic();owned={};peak=0;reason=None
        command=list(map(str,command))
        log_path=self.folder/(name+".log")
        with log_path.open("wb") as stream:
            p=psutil.Popen(command,cwd=cwd or self.folder,stdout=stream,stderr=subprocess.STDOUT,
                           creationflags=subprocess.CREATE_NO_WINDOW)
            identity={"pid":p.pid,"created":p.create_time()}
            active={"name":name,"command":command,"cwd":str(cwd or self.folder),**identity,
                    "log":str(log_path),
                    "budget_seconds":budget,"status":"running"}
            save(self.folder/"active_job.json",active)
            while p.poll() is None:
                try:
                    rss=0
                    for q in [p]+p.children(recursive=True):
                        owned[q.pid]=q.create_time();rss+=q.memory_info().rss
                    peak=max(peak,rss)
                except psutil.NoSuchProcess:pass
                if time.monotonic()-begin>budget:reason="deadline_or_tool_budget"
                elif (MEMORY_LIMIT and peak>MEMORY_LIMIT) or (MEMORY_FLOOR and psutil.virtual_memory().available<MEMORY_FLOOR):reason="memory_guard"
                if reason:
                    for pid,created in reversed(list(owned.items())):
                        try:
                            q=psutil.Process(pid)
                            if q.create_time()==created:q.kill()
                        except psutil.NoSuchProcess:pass
                    p.wait();break
                time.sleep(.25)
        info={"name":name,"command":command,"cwd":str(cwd or self.folder),**identity,
              "exit_code":p.returncode,"stop_reason":reason,"seconds":round(time.monotonic()-begin,3),
              "peak_tree_bytes":peak,"budget_seconds":budget,"log":str(log_path)}
        self.jobs.append(info);save(self.folder/"tool_metrics.json",self.jobs)
        save(self.folder/"active_job.json",{**active,**info,"status":"finished"})
        if p.returncode or reason:raise RuntimeError(f"{name}: exit={p.returncode} reason={reason}; {log_path}")
        return log_path.read_text(encoding="utf-8-sig",errors="replace")
    def finish(self):
        self.result["finished"]=datetime.now().astimezone().isoformat()
        self.result["jobs"]=self.jobs
        save(self.folder/"summary.json",self.result)
        # Parallel verification batches keep separate latest pointers.
        save(ROOT/"out"/(os.environ.get("AFDX_LATEST_PREFIX","")+"latest_"+self.result["name"]+".json"),self.result)

def sim(options):
    f=Flow("net" if options.netlist else "sim",options.test,options.deadline)
    try:
        MS=modelsim_dir()
        bench=ROOT/"tb"/(options.test+".v")
        if not bench.is_file():raise RuntimeError("Unknown test: "+str(bench))
        netlists=[Path(p).resolve() for p in options.netlist]
        if options.coverage and netlists:raise ValueError("Code coverage is available for RTL simulation only")
        replaced=set()
        adapted=[]
        for index,path in enumerate(netlists):
            if not path.is_file():raise RuntimeError("Missing netlist: "+str(path))
            modules=set(re.findall(r"(?m)^module\s+(\w+)\s*\(",path.read_text(encoding="utf-8-sig")))
            if not modules or replaced & modules:raise RuntimeError("Missing or duplicate netlist modules")
            replaced.update(modules)
            target=f.folder/("netlist_"+str(index)+".v")
            f.job("adapt_"+str(index),[sys.executable,ROOT/"tools/fix_lut_mask.py",path,target,"--allow-no-ram"],30)
            adapted.append(target)
        rtl=[]
        for path in sorted((ROOT/"rtl").glob("*.v")):
            modules=set(re.findall(r"(?m)^module\s+(\w+)",path.read_text(encoding="utf-8-sig")))
            if not modules & replaced:rtl.append(path)
        sources=rtl+sorted((ROOT/"tb/lib").glob("*.v"))+[bench]
        compile_sources=list(sources)
        sources.extend(sorted((ROOT/"tb/lib").glob("*.vh")))
        if netlists:
            BIN=elinx_bin()
            compile_sources=[BIN.parents[2]/"Simulation/elinx_lib/stratix_atoms.v"]+adapted+compile_sources
            # Simulation原始输入保留，适配副本与原网表同时留在各自输出目录。
            sources+=netlists+[ROOT/"tools/fix_lut_mask.py",compile_sources[0]]
        f.result["replaced_modules"]=sorted(replaced)
        if options.test.startswith("tb_sys_") and options.test not in ("tb_sys_rtc","tb_sys_snmp","tb_sys_snmp_settrap","tb_sys_615a"):
            f.job("vectors",[sys.executable,ROOT/"tools/sys_cases.py","--test",options.test,
                  "--seed",str(options.seed),"--out",f.folder/"vectors"],
                  300 if options.test in ("tb_sys_perf","tb_sys_perf_var") else 30)
            for sub in ("es1_tx","es1_rx","es2_tx","es2_rx","es1_gmii_tx","es1_gmii_rx","es2_gmii_tx","es2_gmii_rx"):(f.folder/sub).mkdir()
            sources.extend(ROOT/"tools"/name for name in ("sys_cases.py","sys_ref.py","sys_checks.py","sys_run_checks.py","gmii_ref.py","tx_ref.py","rx_ref.py","rx_checks.py","afdx_ref.py"))
            if (ROOT/"tools/perf_ref.py").exists():sources.append(ROOT/"tools/perf_ref.py")
        if options.test.startswith(("tb_mac_","tb_tx_","tb_rx_")) or options.test=="tb_probe_ram":
            ram_top="probe_p2_array" if "probe_p2_array" in replaced else "probe_p1_2048x8"
            command=[sys.executable,ROOT/"tools/afdx_ref.py","vectors","--test",options.test,
                     "--seed",str(options.seed),"--out",f.folder/"vectors","--ram-top",ram_top]
            f.job("vectors",command,30)
            sources.append(ROOT/"tools/afdx_ref.py")
            if options.test.startswith("tb_tx_"):sources.append(ROOT/"tools/tx_ref.py")
            if options.test.startswith("tb_rx_"):sources.extend(ROOT/"tools"/name for name in ("rx_ref.py","rx_cases.py","rx_checks.py"))
        if options.test in ("tb_sys_snmp","tb_sys_snmp_settrap"):
            f.job("vectors",[sys.executable,ROOT/"tools/snmp_ref.py","vectors" if options.test=="tb_sys_snmp" else "settrap_vectors","--dir",f.folder],30)
            sources.append(ROOT/"tools/snmp_ref.py")
        if options.test=="tb_sys_rtc":
            f.job("vectors",[sys.executable,ROOT/"tools/rtc_ref.py","vectors","--dir",f.folder],30)
            sources.extend([ROOT/"tools/rtc_ref.py",ROOT/"tools/load_ref.py"])
        if options.test=="tb_sys_615a":
            f.job("vectors",[sys.executable,ROOT/"tools/load_ref.py","vectors","--dir",f.folder],30)
            sources.extend(ROOT/"tools"/name for name in ("load_ref.py","download_ref.py","unsupported_ref.py"))
        if options.test=="tb_net_services":
            f.job("vectors",[sys.executable,ROOT/"tools/net_services_ref.py","vectors","--dir",f.folder],30)
            sources.extend(ROOT/"tools"/name for name in ("net_services_ref.py","load_ref.py","download_ref.py","snmp_ref.py","afdx_ref.py"))
        f.result["inputs"]=[{"path":str(p),"sha256":sha(p)} for p in sources]
        snapshot=f.folder/"sources";snapshot.mkdir()
        for i,p in enumerate(sources):(snapshot/(str(i)+"_"+p.name)).write_bytes(p.read_bytes())
        run_do="onerror {quit -code 1}\nonbreak {quit -code 1}\n"
        if options.coverage:
            run_do+=f"coverage save -onexit -testname {options.test}_{f.folder.name} coverage.ucdb\n"
        (f.folder/"run.do").write_text(run_do+"run -all\nquit -code 0\n",encoding="ascii")
        f.job("vlib",[MS/"vlib.exe","work"],30)
        defines=["+define+PROBE_P2"] if "probe_p2_array" in replaced else []
        ce_div=os.environ.get("AFDX_CE_DIV","2")
        if ce_div not in ("1","2"):raise ValueError("AFDX_CE_DIV must be 1 or 2")
        defines.append("+define+AFDX_CE_DIV="+ce_div)
        f.result["ce_div"]=int(ce_div)
        if "AFDX_top" in replaced:
            defines.append("+define+SYS_TOP_NETLIST")
            defaults={"TX_PAGE_AW":"8","TX_OFF_AW":"9","LOOKAHEAD":"512","RX_RING_AW":"12","RX_DQ_AW":"5"}
            if any(defaults.get(value.partition('=')[0])!=value.partition('=')[2] for value in options.param):
                raise ValueError("AFDX_top mapped netlist has fixed default parameters")
            candidates=sorted((ROOT/"out/sim"/options.test).glob("*/summary.json"),reverse=True)
            reference=next((p.parent for p in candidates if json.loads(p.read_text()).get("passed")),None)
            if reference is None:raise RuntimeError("Top netlist requires a passed RTL run of the same test")
            f.result["rtl_reference"]=str(reference)
        if "afdx_tx_core" in replaced:
            defines.append("+define+CORE_NETLIST")
            defaults={"TX_PAGE_AW":"8","TX_OFF_AW":"9","LOOKAHEAD":"512"}
            if any(defaults.get(value.partition('=')[0])!=value.partition('=')[2] for value in options.param):
                raise ValueError("afdx_tx_core mapped netlist has fixed default parameters; use RTL for alternate parameters")
        if "afdx_rx_core" in replaced:
            defines.append("+define+RX_CORE_NETLIST")
            defaults={"RX_RING_AW":"12","RX_DQ_AW":"5"}
            if any(defaults.get(value.partition('=')[0])!=value.partition('=')[2] for value in options.param):
                raise ValueError("afdx_rx_core mapped netlist has fixed default parameters")
        if options.coverage:
            # t 记录翻转；测试平台另编译，不把激励与检查器计入 RTL 覆盖率。
            compile_log=f.job("compile_rtl",[MS/"vlog.exe","-vlog01compat","+cover=sbceft",*defines,*rtl],120)
            if not re.search(r"Errors: 0, Warnings: 0",compile_log):raise RuntimeError("RTL compile diagnostic; see compile_rtl.log")
            compile_log=f.job("compile",[MS/"vlog.exe","-vlog01compat","+incdir+"+str(ROOT/"tb/lib"),*defines,*compile_sources[len(rtl):]],120)
        else:
            compile_log=f.job("compile",[MS/"vlog.exe","-vlog01compat", "+incdir+"+str(ROOT/"tb/lib"),*defines,*compile_sources],120)
        if not re.search(r"Errors: 0, Warnings: 0",compile_log):raise RuntimeError("Compile diagnostic; see compile.log")
        parameters=[]
        for value in options.param:
            if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*=[0-9]+",value):raise ValueError("Invalid parameter "+value)
            parameters.append("-g"+value)
        f.result["parameters"]=options.param
        # 加载后卸载使五功能场景达到约70万拍；网表预算8小时，仍受Deadline截断。
        sim_budget=28800 if "AFDX_top" in replaced and options.test=="tb_net_services" else 5400 if "AFDX_top" in replaced else 1800 if netlists else 900
        if options.test in ("tb_sys_perf", "tb_sys_perf_var") and not netlists:sim_budget=max(sim_budget,5400)
        if options.test=="tb_sys_perf_var" and not netlists:sim_budget=max(sim_budget,14400)
        if options.coverage:sim_budget=max(sim_budget,9000 if options.test=="tb_sys_perf" else 3600)
        log=f.job("simulation",[MS/"vsim.exe","-c",*(["-coverage"] if options.coverage else []),options.test,*parameters,"-wlf","simulation.wlf","-do","do run.do"],sim_budget)
        if options.coverage:
            ucdb=f.folder/"coverage.ucdb"
            if not ucdb.is_file() or not ucdb.stat().st_size:raise RuntimeError("Coverage database absent; see simulation.log")
            f.result["code_coverage"]={"metrics":"sbceft","ucdb":str(ucdb),"bytes":ucdb.stat().st_size}
        rows=re.findall(r"\[RESULT\]\s+(\w+)\s+(PASS|FAIL)\s+checks=(\d+)\s+errors=(\d+)[^\r\n]*",log)
        if not rows:raise RuntimeError("Test [RESULT] absent")
        name,status,checks,errors=rows[-1]
        good=name==options.test and status=="PASS" and int(errors)==0 and all(row[1]=="PASS" for row in rows)
        diagnostics={kind:len(re.findall(r"\*\* "+kind+":",log)) for kind in ("Error","Fatal","Warning")}
        diagnostics["RAMCOLL"]=log.count("RAMCOLL")
        f.result["simulation_diagnostics"]=diagnostics
        good=good and not any(diagnostics.values())
        good=good and all(sha(Path(r["path"]))==r["sha256"] for r in f.result["inputs"])
        if options.test.startswith(("tb_tx_","tb_rx_")):
            report=f.job("check",[sys.executable,ROOT/"tools/afdx_ref.py","check","--test",options.test,"--dir",f.folder],180)
            f.result["check"]=json.loads((f.folder/"check_summary.json").read_text())
            good=good and f.result["check"]["errors"]==0
            print(report.strip(),flush=True)
        if options.test.startswith("tb_sys_") and options.test not in ("tb_sys_rtc","tb_sys_snmp","tb_sys_snmp_settrap","tb_sys_615a"):
            check_command=[sys.executable,ROOT/"tools/sys_run_checks.py","--test",options.test,"--dir",f.folder]
            if "AFDX_top" in replaced:check_command += ["--netlist","--rtl-reference",f.result["rtl_reference"]]
            report=f.job("check",check_command,1200 if options.test=="tb_sys_perf_var" else 300)
            f.result["check"]=json.loads((f.folder/"check_summary.json").read_text())
            good=good and f.result["check"]["errors"]==0
            print(report.strip(),flush=True)
        if options.test in ("tb_sys_snmp","tb_sys_snmp_settrap"):
            report=f.job("check",[sys.executable,ROOT/"tools/snmp_ref.py","check" if options.test=="tb_sys_snmp" else "settrap_check","--dir",f.folder],60)
            f.result["check"]=json.loads((f.folder/"check_summary.json").read_text())
            good=good and f.result["check"]["errors"]==0
            print(report.strip(),flush=True)
        if options.test=="tb_sys_rtc":
            report=f.job("check",[sys.executable,ROOT/"tools/rtc_ref.py","check","--dir",f.folder],60)
            f.result["check"]=json.loads((f.folder/"check_summary.json").read_text())
            good=good and f.result["check"]["errors"]==0
            print(report.strip(),flush=True)
        if options.test=="tb_sys_615a":
            report=f.job("check",[sys.executable,ROOT/"tools/load_ref.py","check","--dir",f.folder],60)
            f.result["check"]=json.loads((f.folder/"check_summary.json").read_text())
            good=good and f.result["check"]["errors"]==0
            print(report.strip(),flush=True)
        if options.test=="tb_net_services":
            command=[sys.executable,ROOT/"tools/net_services_ref.py","check","--dir",f.folder]
            if "AFDX_top" in replaced:command.extend(["--rtl-reference",f.result["rtl_reference"]])
            report=f.job("check",command,60)
            f.result["check"]=json.loads((f.folder/"check_summary.json").read_text())
            good=good and f.result["check"]["errors"]==0
            print(report.strip(),flush=True)
        if good and options.test=="tb_mac_loop":
            f.result["pcap"]={}
            for net in ("a","b"):
                report=f.job("pcap_"+net,[sys.executable,ROOT/"tools/afdx_ref.py","pcap",
                    "--dump",f.folder/("dump_"+net+".txt"),"--out",f.folder/("network_"+net+".pcap")],30)
                f.result["pcap"][net]=json.loads(report)
        f.result.update(passed=good,checks=int(checks),errors=int(errors),result=status)
        f.result["coverage"]=re.findall(r"\[COVERAGE\][^\r\n]*",log)
        print("输出："+str(f.folder),flush=True)
        if any(diagnostics.values()):print("[DIAGNOSTICS] "+json.dumps(diagnostics),flush=True)
        print(f"[RESULT] {options.test} {'PASS' if good else 'FAIL'} checks={checks} errors={errors}",flush=True)
        return 0 if good else 1
    except Exception as error:
        f.result.update(passed=False,error=str(error))
        print(f"[RESULT] {options.test} FAIL checks=0 errors=1",flush=True)
        print(str(error),flush=True)
        return 1
    finally:f.finish()

def canonicalize(source,target):
    raw=source.read_text(encoding="utf-8-sig")
    count=0
    names=set(re.findall(r"^\s*cell\s+\S+\s+(\S+)",raw,re.M))
    def fix(m):
        nonlocal count
        if m[2].startswith(("\\","$")):return m[0]
        new="\\c3_native_cell_"+str(count)
        while new in names:new+="_"
        names.add(new);count+=1
        return m[1]+new+m[3]
    text=re.sub(r"^(\s*cell\s+\S+\s+)(\S+)(\s*)$",fix,raw,flags=re.M)
    target.write_text(text,encoding="utf-8")
    return count

def extract_timing(folder):
    db=folder/"synthesized_timing.pb"
    con=sqlite3.connect(db.as_uri()+"?mode=ro",uri=True);con.row_factory=sqlite3.Row
    assert con.execute("pragma integrity_check").fetchone()[0]=="ok"
    tables={r[0] for r in con.execute("select name from sqlite_master where type='table'")}
    summaries=[dict(r) for r in con.execute("select * from elinx_intra_clock_summary")]
    assert len(summaries)==1 and summaries[0]["name"]=="clk" and summaries[0]["period"]==8000
    clk=summaries[0]
    paths=[dict(r) for r in con.execute("select * from elinx_intra_clock_longest_sync_path_report order by slack")]
    mapped=(folder/"import.il").read_text(encoding="utf-8")
    ram_names=re.findall(r"^  cell \\stratix_ram_block (\\\S+)",mapped,re.M)
    ram_names=[n.lstrip("\\") for n in ram_names]
    nodes=[]
    if "elinx_data_path_node_detail" in tables:
        for row in con.execute("select * from elinx_data_path_node_detail"):
            r=dict(row);resource=r.get("resource","").lstrip("\\")
            if any(resource.startswith(n+"/") or resource.startswith(n+"|") for n in ram_names):nodes.append(r)
    raw={}
    for table in ("elinx_timing_summary","elinx_inter_clock_summary","elinx_unconstrain_clock_summary","elinx_not_delay_Io"):
        if table in tables:raw[table]=[dict(r) for r in con.execute('select * from "'+table+'"')]
    con.close()
    result={"period_ns":8,"fmax_mhz":clk["fmax"],"setup_wns_ns":clk["setup_worst_slack"]/1000,
            "hold_wns_ns":clk["hold_worst_slack"]/1000,"setup_fail_ends":clk["setup_fail_ends"],
            "hold_fail_ends":clk["hold_fail_ends"],"raw_clock_summary":clk,
            "worst_path":paths[0] if paths else None,"reported_register_paths":paths,
            "reported_ram_nodes":nodes,"raw_other_tables":raw,"report_sha256":sha(db),
            "complete_ram_arc_coverage_proven":False,"io_delays_supplied":False}
    save(folder/"timing_summary.json",result)
    return result

def synth(options):
    f=Flow("synth",options.top,options.deadline)
    try:
        BIN=elinx_bin()
        top=options.top
        sources=sorted((ROOT/"rtl").glob("*.v"))+sorted((ROOT/"elinx/probe").glob("*.v"))
        f.result["inputs"]=[{"path":str(p),"sha256":sha(p)} for p in sources]
        snapshot=f.folder/"sources";snapshot.mkdir()
        for i,p in enumerate(sources):(snapshot/(str(i)+"_"+p.name)).write_bytes(p.read_bytes())
        # 探测初值文件只在输出目录生成，避免修改或删除已有工程文件。
        (f.folder/"init_probe.hex").write_text("\n".join(f"{((i*37)^0xa5)&255:02x}" for i in range(2048))+"\n",encoding="ascii")
        script="\n".join([
            "read_verilog "+" ".join('"'+p.as_posix()+'"' for p in sources),
            "hierarchy -check -top "+top,"select -assert-none A:blackbox","proc","opt",
            "write_ilang frontend.il",
            f"synth_stratix -nooptpmux -family EQ6HL130 -top {top} -run begin:coarse",
            "synth -run coarse -noshare",
            f"synth_stratix -nooptpmux -family EQ6HL130 -top {top} -run pll:",
            "check -assert","stat","rename -enumerate","write_ilang mapped.il",
            "write_verilog -noattr netlist.v"])+"\n"
        (f.folder/"mapping.ys").write_text(script,encoding="utf-8")
        log=f.job("mapping",[BIN/"eLinx_synthesis.exe","-s",f.folder/"mapping.ys"],900)
        if "Yosys execute success!" not in log or re.search(r"(?im)^\s*ERROR:|Driver-driver conflict|bad allocation",log):
            raise RuntimeError("Mapping invalid; mapping.log")
        ilang=(f.folder/"mapped.il").read_text(encoding="utf-8-sig")
        cells=re.findall(r"^  cell (\S+) (\S+)\n(.*?)^  end",ilang,re.M|re.S)
        counts={}
        ram_info=[]
        for kind,name,body in cells:
            kind=kind.lstrip("\\");counts[kind]=counts.get(kind,0)+1
            if kind=="stratix_ram_block":
                params=dict(re.findall(r"^\s+parameter \\(\S+) (.+)$",body,re.M))
                pins=dict(re.findall(r"^\s+connect \\(\S+) (.+)$",body,re.M))
                ram_info.append({"name":name,"parameters":params,"pins":pins})
        frontend=(f.folder/"frontend.il").read_text(encoding="utf-8-sig")
        f.result.update(mapping_passed=True,lcells=counts.get("stratix_lcell",0),
                        ram_blocks=counts.get("stratix_ram_block",0),primitive_counts=counts,
                        warnings=re.findall(r"(?m)^Warning:.*",log),ram_info=ram_info,
                        frontend_meminit_cells=len(re.findall(r"^  cell \$meminit",frontend,re.M)),
                        frontend_init_parameters=re.findall(r"^\s+parameter \\INIT (.+)$",frontend,re.M),
                        netlist_sha256=sha(f.folder/"netlist.v"))
        if options.sta:
            # 原生setlogfile会回写传入的property文件；必须使用本次输出目录的副本。
            (f.folder/"log4cpp.property").write_bytes((BIN/"log4cpp.property").read_bytes())
            f.result["native_identifier_repairs"]=canonicalize(f.folder/"mapped.il",f.folder/"import.il")
            (f.folder/"export.ys").write_text('read_ilang "'+(f.folder/"import.il").as_posix()+'"\nwrite_verilog -noattr -defparam -nohex -decimal -renameprefix syn_ "'+(f.folder/"design.vqm").as_posix()+'"\n',encoding="utf-8")
            f.job("export",[BIN/"eLinx_synthesis.exe","-s",f.folder/"export.ys"],120)
            shutil.copy2(ROOT/"elinx/constraints.edc",f.folder/"constraints.sdc")
            tcl=r'''if {[catch {
set run {@RUN@}
set base {@BASE@}
set device [file join $base Infrastructure psk_intern eHiChip6 EQ6HL130]
setlogfile [file join $run log4cpp.property] [file join $run timing.edi]
print_version_information
set_global_assignment -name TOP_LEVEL_ENTITY @TOP@
set_global_assignment -name DESIGN_PATH $run
set_global_assignment -name PROJECT_NAME @TOP@
set_global_assignment -name DEVICE_SERIES eHiChip6
set_global_assignment -name DEVICE_NAME EQ6HL130
set_global_assignment -name PACKAGE_NAME CSG484_H
set_global_assignment -name PACKAGE CSG484_H
set_global_assignment -name PINS 484
puts "C3_STAGE parse"
udm_parse_vqm [file join $run design.vqm]
read_port_info -f [file join $base Infrastructure psk_intern eHiChip6 series_library place_route_guide.xml]
set model [file nativename $device]
append model "\\"
load_time_model $model
read_sdc [file join $run constraints.sdc]
no_pack_timing
write_statistical_info @TOP@ -pack -f [file join $run utilization_synth.rpt]
puts "C3_STAGE graph"
flush stdout
build_timing_graph
puts "C3_STAGE analysis"
flush stdout
do_timing_analysis
print_timing_report [file join $run synthesized_timing.rpt]
free_timing_graph
puts "C3_STAGE completed"
} message]} {puts "C3_FAILED $message";exit 1}
exit 0
'''.replace("@RUN@",f.folder.as_posix()).replace("@TOP@",top).replace("@BASE@",BIN.parent.as_posix())
            (f.folder/"timing.tcl").write_text(tcl,encoding="utf-8")
            timing=f.job("timing",[BIN/"Implementation.exe","-f",f.folder/"timing.tcl"],1200,cwd=BIN)
            if "C3_STAGE completed" not in timing or "C3_FAILED" in timing:raise RuntimeError("STA did not complete")
            f.result["timing"]=extract_timing(f.folder)
            diag=timing+(f.folder/"timing.edi").read_text(errors="replace")
            f.result["timing_diagnostics"]={x:len(re.findall(r"\["+x+r"\]",diag)) for x in ("ERROR","CRIT","WARN","WARNING")}
            if f.result["timing_diagnostics"]["ERROR"] or f.result["timing_diagnostics"]["CRIT"]:raise RuntimeError("Native STA error diagnostics")
        if not all(sha(Path(r["path"]))==r["sha256"] for r in f.result["inputs"]):raise RuntimeError("Source changed during execution")
        t=f.result.get("timing")
        line=f"[SYNTH] {top} lcell={f.result['lcells']} ram={f.result['ram_blocks']}"
        if t:
            path=t["worst_path"] or {}
            line+=f" setup_wns_ns={t['setup_wns_ns']:.3f} hold_wns_ns={t['hold_wns_ns']:.3f} fmax_mhz={t['fmax_mhz']:.6f} from={path.get('from_cell_name','UNREPORTED')} to={path.get('to_cell_name','UNREPORTED')}"
        print("输出："+str(f.folder),flush=True);print(line,flush=True)
        f.result["completed"]=True
        return 0
    except Exception as error:
        f.result.update(completed=False,error=str(error))
        print("输出："+str(f.folder),flush=True)
        print(f"[SYNTH] {options.top} lcell={f.result.get('lcells','未测')} ram={f.result.get('ram_blocks','未测')} FAILED "+str(error),flush=True)
        return 1
    finally:f.finish()

def implement(options):
    """一次限时布局布线；资源与流程完成和可选布线时序分开记录。"""
    f=Flow("impl",options.top+"_route",options.deadline)
    try:
        BIN=elinx_bin()
        summary=json.loads((ROOT/"out"/("latest_"+options.top+".json")).read_text(encoding="utf-8"))
        if not summary.get("completed"):raise RuntimeError("A completed synthesis is required")
        for row in summary["inputs"]:
            if sha(Path(row["path"]))!=row["sha256"]:raise RuntimeError("Synthesis source changed: "+row["path"])
        source=Path(summary["folder"])
        if sha(source/"netlist.v")!=summary["netlist_sha256"]:raise RuntimeError("Synthesis netlist changed")
        f.result["synthesis_folder"]=str(source)
        f.result["inputs"]=summary["inputs"]
        for name in ("design.vqm","constraints.sdc"):(f.folder/name).write_bytes((source/name).read_bytes())
        (f.folder/"log4cpp.property").write_bytes((BIN/"log4cpp.property").read_bytes())
        template=ROOT/"elinx/implement.tcl"
        script=template.read_text(encoding="utf-8").replace("@RUN@",f.folder.as_posix()).replace("@TOP@",options.top).replace("@BASE@",BIN.parent.as_posix())
        (f.folder/"implement.tcl").write_text(script,encoding="utf-8")
        log=f.job("implementation",[BIN/"Implementation.exe","-f",f.folder/"implement.tcl"],3600,cwd=BIN)
        f.result["completed"]="C3_IMPL_STAGE completed" in log and "C3_IMPL_FAILED" not in log
    except Exception as error:
        f.result.update(completed=False,error=str(error))
    finally:
        logs="\n".join(p.read_text(encoding="utf-8-sig",errors="replace") for p in f.folder.glob("*.log"))
        f.result["stages"]=re.findall(r"C3_IMPL_STAGE (\w+)",logs)
        f.result["resources"]={}
        for name in ("utilization_packed.rpt","utilization_routed.rpt"):
            path=f.folder/name
            if path.exists():
                body=path.read_text(encoding="utf-8-sig",errors="replace")
                f.result["resources"][name]={k:{"used":int(v),"capacity":int(n)} for k,v,n in re.findall(r"Total (\w+)\s*:\s*(\d+)\s*/\s*(\d+)",body)}
                f.result["resources"][name]["raw_report"]=body
        f.result["native_flow_completed"]=f.result.get("completed",False)
        routed=f.result["resources"].get("utilization_routed.rpt",{}).get("raw_report","")
        f.result["completed"]=f.result.get("completed",False) and "Implementation Status : Successful" in routed
        status_file=f.folder/"route_status.rpt"
        if status_file.exists():
            status=status_file.read_text(encoding="utf-8-sig",errors="replace")
            f.result["route_status_report"]=status
            failures=re.search(r"nets with routing error[^:]*:\s*(\d+)",status)
            if failures and int(failures.group(1)):f.result["completed"]=False
        f.result["route_timing_diagnostic_only"]=True
        f.finish()
        print("输出："+str(f.folder),flush=True)
        print("[IMPL] "+options.top+" "+("COMPLETED" if f.result.get("completed") else "INCOMPLETE"),flush=True)
    return 0 if f.result.get("completed") else 1


def main():
    parser=argparse.ArgumentParser()
    sub=parser.add_subparsers(dest="action",required=True)
    p=sub.add_parser("sim");p.add_argument("--test",required=True);p.add_argument("--deadline")
    p.add_argument("--netlist",nargs="*",default=[]);p.add_argument("--seed",type=int,default=20261007)
    p.add_argument("--param",action="append",default=[])
    p.add_argument("--coverage",action="store_true",help="Instrument RTL only and save coverage.ucdb after simulation")
    p=sub.add_parser("synth");p.add_argument("--top",required=True);p.add_argument("--sta",action="store_true");p.add_argument("--deadline")
    p=sub.add_parser("impl");p.add_argument("--top",default="AFDX_top");p.add_argument("--deadline",required=True)
    args=parser.parse_args()
    identity=args.test if args.action=="sim" else args.top
    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*",identity):parser.error("Invalid Verilog identifier")
    return sim(args) if args.action=="sim" else synth(args) if args.action=="synth" else implement(args)

if __name__=="__main__":raise SystemExit(main())
