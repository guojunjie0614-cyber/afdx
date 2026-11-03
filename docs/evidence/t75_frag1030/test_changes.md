# 测试改动与依据

检查器修改必须经实际重跑验收；原始失败记录保留。未修改 RTL、网表或时序约束。

| 测试/入口 | 旧判据或兼容问题 | 新判据/改动 | 依据 |
|---|---|---|---|
| 六项 cfg/context/reassembly/service 分支测试 | Icarus 专用 `$finish_and_return(1)` | 等价 `$finish`，失败 RESULT 保留；检查逻辑与计数不变 | T75 P0.2；eda.py 要求 PASS 且 errors=0 |
| ModelSim RTL 编译 | 7 个文件有声明前引用 | `out/` 副本前移 21 处声明；wire 初始化保留为原位置连续赋值；精确逆变换核对 | ModelSim 2020.4 vlog-2730；源级声明顺序兼容，不改变功能 |
| RTL 仿真断言 | 源码有 Icarus 专用退出任务 | 仅在仿真副本将 `$finish_and_return(1)` 转成 `$fatal(1,...)` | 保留全部断言及失败退出；未定义 SYNTHESIS 或关闭断言 |
| app TX/RX 默认可选端口 | 未列出的非启用输入导致 ModelSim TFMPC 告警 | 仿真副本显式空连接 raw_write_data / next_limit，保持 Z 值 | hardware_contract revision 7 app_storage.reader_issuance / rx_payload_data_capture；默认模式忽略这些输入 |
| tb_cfg_local_ready | 未连接新公开就绪输出；固定旧模块未在 eda 中准备 | 显式空输出；运行目录从固定 Git 对象生成仅重命名的 legacy 模块 | 原 tools/run_1030_checks.py 的 c857aba8 基线，检查 6090 拍不变 |
| tb_reassembly_engine | initialized 在声明前使用；新 bank 端口省略 | 前移测试线网声明；显式空连接默认不使用的 bank 端口 | 原测试功能/断言不变；BANK_CTRL_COPIES 默认模式 |
| tb_reassembly_limits / transactions | 默认不使用的 bank 端口省略 | 显式空连接；71 / 126 项检查保留 | afdx_rx_reassembly 默认 BANK_CTRL_COPIES=0 |
| tb_service_pipeline | 新专用服务 RX 输出未列出 | 显式空连接输出；127 项检查保留 | 同一 svc_rx/app_rx 公共接口检查，无功能改动 |
| tb_rtc_banked 及共享 RTC 套件 | 卡称缺 RESULT；实际上共享套件已有带 NAME 的 RESULT，失败源于新可选端口告警 | 保留 RESULT 与 34 项 banked 检查；显式空连接默认未启用的配置预测端口 | rtc_retry_suite 原 RESULT；RTC 默认 CFG_READY_PREDICT/TERMS 路径 |
| tb_app_payload_pipeline | 直接 RAM/reader 实例的可选输入省略 | 显式空连接，全部字节/信用/配置边界检查不变 | 默认 EARLY_DATA/PREDICT_LIMIT=0 |
| tb_fragmentation / tb_frag1030_net | 原分片平台没有标准 checks 字段，官方 VQM 入口未注册 | 为既有边界检查计数；完整复用 7 条发送及 6 类故障恢复；新增 A 类名称 | T75 P2；1464/1472/8192 字节完整交付，六份外部记录逐字节比较 |
| tb_tx_ingress_elastic / tb_tx_buffer_bounds | eda 按名称误调用旧 TX 向量生成器 | 使用测试原有自生成激励和自检，不调用不适用的向量生成器 | 分支独立握手/边界测试；139695 / 49800 项原检查 |
| TX 丢弃/网表及共享 TX 平台 | >1471 字节一律 drop_long，接受一次只期待一帧，记录数组仅 4096 字节 | 1472/3000 保留并检查完整分片；添加 8193/8194 越界；按 Lmax 和 IPv4 UDP 偏移计算完整帧数；记录容量扩至 8194 | R138-6；hardware_contract.tx.ipv4/sn/bag；上限 8192、Lmax 约束单帧 |
| TX 超长回滚时限 | 所有长度沿用 96 拍 | 仅 >8192 字节新输入按六拍/页加三拍，16 页为 99 拍；其他输入仍 96 拍 | hardware_contract.tx.rollback_ram；RETURN 同步读/握手与 CE2；不扩大短消息界限 |
| TX G7（系统复位场景） | 冷启动准备界限 100 拍，下一帧仅按 IFG 推断最晚起点 | 128 VL 扫描、5 拍扫描/ENQ、9 拍 GRANT、builder 捕获推导冷启动 310 拍；重授权准备 32 拍；12 拍 IFG 下界和精确 BAG 检查保留 | hardware_contract.tx.context_pipeline/busy_lookup/grant_commit/builder_capture；T75 P1.2 的流水延迟合法变化 |
| tb_rx_fault | 所有 MF/非零 offset 都直接判坏头；修复同 SN 必须交付 | 两个孤立但 IPv4 合法的片经过 IC 后重组拒收，RM 不提交；同 SN 后帧被 IC 拒收；严格事件总数和全部 888 项检查保留 | R138-6；逐帧 IC/RM 先于重组；缺首片/长度矛盾拒收，事件位 7，无部分交付 |
| tb_sys_basic / top_stream_endpoint | 直接 afdx_es 实例省略新增 app_cfg_ready 输出 | 显式空连接，检查与激励不变 | hardware_contract.architecture.external_ports；只给内部 wrapper 使用的输出 |
| tb_rm_phase / rm_age_probe | 旧位置端口实例未适应插入的重组接口；95 位描述符和 68 位队列线网过时 | 全部改按端口名对应原信号；描述符低 95 位原样、补 126 个零；队列线网扩至 73 位；未使用重组输入置零、输出空连接 | hardware_contract RX 描述符/重组接口；该 fixture 只测试非分片 RM 老化，保留同 SN、忙时计龄、旧记录失效全部原检查 |
| RTL 长用例工具预算 | tb_sys_rtc 沿用 900 秒预算而超时 | 冻结输入副本以 AFDX_SIM_TIMEOUT_SECONDS=28800 配置补跑和最终整表，旧超时保留 | T75 P1 八小时上限和 P0 可配置预算要求；不改变仿真时钟、激励、检查或 HDL watchdog |
| T65 TX 全部应用入口用例 | 4 KiB 环、1471 字节预留形成 used<=2616；首字节 ready 在本地 vq 阶段记录；发送后观察早于新增描述符退休 | 32 KiB/8192 字节预留精确 used<=24576；记录真实公共首拍 ready；等待新增一拍描述符可见后再观察/开始下一消息；容量事件和逐字节检查不变 | hardware_contract.app_storage.payload_write_latency / tx_ingress_control；入口 ready 只授权消息起始，后续 valid 区间保持 |
| tb_t65_tx_space / edge | 单条非法消息曾能填满旧 4096 环，count 在 8191 饱和 | 新环容量大于消息上限；仍用越界输入验证完整回滚，存储恰为 8192、计数 8194；边界输入改为两字节 VLID+8193 字节载荷；32 KiB 原始存储容量另由 tb_app_payload_pipeline 全容量测试覆盖 | hardware_contract.app_storage.depth_bytes=32768、单消息上限 8192；不把消息上限称为 32 KiB 环耗尽 |
| T65 RX data / desc | 4 KiB 预留门槛 used>2624；原始 av 配合延后一拍的 active 重复记首帧；压力量和排空时间仅适合旧缓存 | 门槛 used>24575、描述符仍 >=30；独立寄存输入与元数据对齐 E1，保留原字节期望；扩大 data 压力上界/记账数组和排空时间以实际触及 32 KiB 数据门槛；HDL watchdog 有界增至 20000000 拍 | hardware_contract.app_storage.payload_write_latency / depth_bytes / rollback；输入 E0、本地接纳 E1，容量变化必须重新形成真实压力 |
| RM 忙时覆盖统计 | 旧数值状态 FRAME=2、IDLE=1 | 使用 dut.FRAME / dut.engine.IDLE 符号比较，仍要求忙时改变粗时钟和验证老化 | 新状态为独热编码；原覆盖条件含义不变 |
| 并发准入 | 用 max(全机原生进程数, 自有 worker 数) 合并计数，存在外部作业与自有编译/排队阶段时可能少算预留 | 逐 PID 识别自有原生子进程；槽位为对应自有 worker 数加外部内核/待启动器或 eLinx/GUI 进程数；已有内核的 launcher 不重复计数 | T75 第三节全机最多 10 个 ModelSim、6 个 eLinx；tools/t75_resource_check.py 的 13 个进程清单/槽位边界用例通过，见 resource_slot_checks.json |

未放宽：FCS/IP/UDP 校验、字节值、网络副本、SN、ID、BAG、IFG 下界、容量、RAM 冲突、断言和复位检查。

最后一项仅修正未来作业的资源准入，在最终 RTL 结果收齐后用只读模拟清单验证；没有重启当前 VQM，也没有修改仿真源、激励或检查器。当前执行期间未观察到外部 ModelSim 或超出 10 内核的情形。
