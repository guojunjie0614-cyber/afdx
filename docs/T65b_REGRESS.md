# T65b 标准回归合并验收

## 验收结论

唯一官方普通 RTL 批次 **56/56 PASS**；Error、Fatal、Warning、FAIL、RAMCOLL 全为 0，56 项编译均 Errors=0、Warnings=0。原 40 项 Checks、CheckItems 与 F1 普通回归及 T64 复用记录逐项一致；新 16 项 TB Checks 和独立核对 checks 与 T65 正向证据逐项一致，独立核对全部通过。无未完成项，无待解决功能问题。

初始分支 t63，HEAD 591d99a65933464faa5f2eda3e0e7e2253ed84bb，工作区干净。rtl/、elinx/ 的跟踪文件集合和每个文件原始字节在执行前后均与 e5cd8150 一致。证据为 preflight.txt、binding_after.txt、source_binding.txt。

## 实际执行与资源

预检计时开始：2026-10-30 09:55:46；正反例与回归完成：2026-10-30 11:36:59；证据验收完成：2026-10-30 11:38:47。官方回归开始：2026-10-30 09:56:18，结束：2026-10-30 11:36:57，用时 6038.613 秒。回归 Deadline：2026-10-30 14:56:18；整卡硬截止：2026-10-30 15:55:46，均未触发。

初始空闲内存 13.351 GiB，E 盘空闲 105.230 GiB，未发现原生 EDA 作业。普通程序持有唯一 OS 文件锁并等待子进程完成，记录 PID、创建时间、命令及结果。没有重启、重复或追加全量回归，没有子代理、heartbeat、定时任务、自我续接。运行期间工作区只读，ModelSim 作业串行；结束后无原生 EDA 进程。

官方入口为 sim/regress.ps1，不带 Coverage，Seed 保留默认 20261007；调用 run.ps1/regress.ps1 时均显式设置 AFDX_PYTHON=E:/anaconda3/python.exe、MODELSIM_HOME=E:/Verilog/ModelSim/setup_pack/win64、AFDX_CE_DIV=2，Deadline 带 +08:00。5 GiB 内存下限及各单项原预算均保留。原始入口命令见 regression_result.txt，完整输出见 regression_entry.txt。

## 挂接实现与影响范围

eda.py 只有下面两个受 tb_t65_ 前缀条件保护的新增块，原代码行未删改：

```diff
diff --git a/tools/eda.py b/tools/eda.py
index 0d537dfa..64e52796 100644
--- a/tools/eda.py
+++ b/tools/eda.py
@@ -152,6 +152,8 @@ def sim(options):
         if options.test=="tb_net_services":
             f.job("vectors",[sys.executable,ROOT/"tools/net_services_ref.py","vectors","--dir",f.folder],30)
             sources.extend(ROOT/"tools"/name for name in ("net_services_ref.py","load_ref.py","download_ref.py","snmp_ref.py","afdx_ref.py"))
+        if options.test.startswith("tb_t65_"):
+            sources.append(ROOT/"tools/t65_check.py")
         f.result["inputs"]=[{"path":str(p),"sha256":sha(p)} for p in sources]
         snapshot=f.folder/"sources";snapshot.mkdir()
         for i,p in enumerate(sources):(snapshot/(str(i)+"_"+p.name)).write_bytes(p.read_bytes())
@@ -250,6 +252,13 @@ def sim(options):
             f.result["check"]=json.loads((f.folder/"check_summary.json").read_text())
             good=good and f.result["check"]["errors"]==0
             print(report.strip(),flush=True)
+        if options.test.startswith("tb_t65_"):
+            mutant=next((int(value.split("=",1)[1]) for value in reversed(options.param) if value.startswith("T65_MUTANT=")),0)
+            command="import sys,json;from pathlib import Path;sys.path.insert(0,sys.argv[1]);from t65_check import check;r=check(sys.argv[2],sys.argv[3],int(sys.argv[4]));s=json.dumps(r,ensure_ascii=False,indent=2);Path(sys.argv[2],'check_summary.json').write_text(s+'\\n',encoding='utf-8');print(s)"
+            report=f.job("check",[sys.executable,"-c",command,ROOT/"tools",f.folder,options.test,str(mutant)],60)
+            f.result["check"]=json.loads((f.folder/"check_summary.json").read_text(encoding="utf-8"))
+            good=good and f.result["check"]["errors"]==0
+            print(report.strip(),flush=True)
         if good and options.test=="tb_mac_loop":
             f.result["pcap"]={}
             for net in ("a","b"):
```

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
|1|tb_ram_sdp|PASS|20764|—|—|F1/T64 一致|
|2|tb_mac_tx|PASS|264649|—|—|F1/T64 一致|
|3|tb_mac_rx|PASS|105303|—|—|F1/T64 一致|
|4|tb_mac_loop|PASS|1385254|—|—|F1/T64 一致|
|5|tb_tx_basic|PASS|662156|7606|—|F1/T64 一致|
|6|tb_tx_basic (TX_PAGE_AW=5,TX_OFF_AW=11)|PASS|661736|7606|—|F1/T64 一致|
|7|tb_tx_bag|PASS|14054199|14592|—|F1/T64 一致|
|8|tb_tx_multi|PASS|14438572|56224|—|F1/T64 一致|
|9|tb_tx_drop|PASS|30267272|4643|—|F1/T64 一致|
|10|tb_tx_net|PASS|219323|230|—|F1/T64 一致|
|11|tb_rx_basic|PASS|9960369|123855|—|F1/T64 一致|
|12|tb_rx_fault|PASS|576923|890|—|F1/T64 一致|
|13|tb_rx_icrm|PASS|4635284|1274|—|F1/T64 一致|
|14|tb_rx_load|PASS|6406189|19180|—|F1/T64 一致|
|15|tb_rx_ovf_ring (RX_RING_AW=9)|PASS|422837|99|—|F1/T64 一致|
|16|tb_rx_ovf_dq (RX_DQ_AW=1)|PASS|373852|57|—|F1/T64 一致|
|17|tb_rx_net|PASS|374111|110|—|F1/T64 一致|
|18|tb_sys_basic|PASS|5156222|2898|—|F1/T64 一致|
|19|tb_sys_fault|PASS|42097787|9008|—|F1/T64 一致|
|20|tb_sys_delay|PASS|13938621|3915|—|F1/T64 一致|
|21|tb_sys_load|PASS|193108134|122284|—|F1/T64 一致|
|22|tb_sys_cfg|PASS|19020433|717644|—|F1/T64 一致|
|23|tb_sys_reset|PASS|10177297|3844|—|F1/T64 一致|
|24|tb_sys_ovf (RX_RING_AW=9)|PASS|8881779|1550|—|F1/T64 一致|
|25|tb_sys_net|PASS|2792795|1307|—|F1/T64 一致|
|26|tb_sys_perf|PASS|683383807|1309214|—|F1/T64 一致|
|27|tb_sys_rtc|PASS|10675841|1811|—|F1/T64 一致|
|28|tb_sys_snmp|PASS|37611|926|—|F1/T64 一致|
|29|tb_sys_snmp_settrap|PASS|8563|188|—|F1/T64 一致|
|30|tb_sys_615a|PASS|44098|752|—|F1/T64 一致|
|31|tb_gbe_burst (COUNT=77)|PASS|530765|—|—|F1/T64 一致|
|32|tb_gbe_burst (COUNT=81)|PASS|554697|—|—|F1/T64 一致|
|33|tb_rm_phase|PASS|353130|—|—|F1/T64 一致|
|34|tb_rtc_recovery|PASS|28|—|—|F1/T64 一致|
|35|tb_rtc_originate|PASS|34|—|—|F1/T64 一致|
|36|tb_judge_capacity|PASS|49924|—|—|F1/T64 一致|
|37|tb_judge_snmp|PASS|699|—|—|F1/T64 一致|
|38|tb_elinx|PASS|9238|—|—|F1/T64 一致|
|39|tb_sys_perf_var|PASS|1254269621|1680167|—|F1/T64 一致|
|40|tb_top_wrap|PASS|12284|—|—|F1/T64 一致|
|41|tb_t65_queue_a|PASS|3088|—|10|T65 一致|
|42|tb_t65_reset_app|PASS|204|—|42|T65 一致|
|43|tb_t65_reset_mac|PASS|204|—|45|T65 一致|
|44|tb_t65_reset_rx|PASS|204|—|44|T65 一致|
|45|tb_t65_rx_data|PASS|1553737|—|1066|T65 一致|
|46|tb_t65_rx_desc|PASS|676|—|217|T65 一致|
|47|tb_t65_tx_desc|PASS|217027|—|244|T65 一致|
|48|tb_t65_tx_hint|PASS|213272|—|229|T65 一致|
|49|tb_t65_tx_init|PASS|198820|—|14|T65 一致|
|50|tb_t65_tx_ready|PASS|216106|—|233|T65 一致|
|51|tb_t65_tx_short_full|PASS|504753|—|18|T65 一致|
|52|tb_t65_tx_short_init|PASS|498820|—|17|T65 一致|
|53|tb_t65_tx_short_normal|PASS|499027|—|17|T65 一致|
|54|tb_t65_tx_space|PASS|246279|—|22|T65 一致|
|55|tb_t65_tx_space_edge|PASS|211187|—|14|T65 一致|
|56|tb_t65_tx_unmapped|PASS|199781|—|14|T65 一致|

F1 来源 sim/reference/regression.json；T64 来源 docs/evidence/t64_f1_coverage/comparison.json；T65 来源 docs/evidence/t65_gap_tests/results.json 及 ucdb_inputs.json。直接复用既有记录，未重新执行这些历史批次，无数值不一致需要解释。

## T64 冻结校验与规则边界

只读调用 tools/t64_coverage.py 的 cases()，得到预期异常 Expected exactly 40 unique frozen cases，见 t64_expected_failure.txt。它有意冻结 40 项，追加后 56 项无法通过其原集合核验；这不是本批功能失败。没有修改该工具，没有调用会写入 T64 证据的 preflight、collect、publish 等入口。

规则冲突按更严格者执行：内存按任务卡和 eda.py 的 5 GiB 下限，严于项目通用 3 GiB；本卡只运行普通 RTL，禁止综合、布局布线、时序复验、网表仿真和 GUI，项目的网表通用超时不适用于本卡。项目“作业运行时只读、不另开作业”按串行执行：上一作业结束后才进入下一官方测试，运行时不改工作区。

只修改 tools/eda.py、sim/tests.txt，新增本报告、docs/evidence/t65b_regress/ 和 tools/t65b_*.py。未改 RTL、elinx、TB、既有检查器、门限、种子、单项超时或禁止路径。未执行第六节父线程收尾，未改 README、FACTS 等文档，未碰 submission/；无 push、merge、amend。没有做综合、时序复验、网表验证、GUI、烧录或上板。本批不新增覆盖率统计，不改变 T65 既有分母差异结论。

必要证据保留在上述目录及各 out/sim/ 尝试；本次临时捕获备份已清理，运行器已退出并释放文件锁，无需撤销监控。本地提交号见交付回复及 Git 历史。
