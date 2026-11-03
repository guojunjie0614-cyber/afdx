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

未放宽：FCS/IP/UDP 校验、字节值、网络副本、SN、ID、BAG、IFG 下界、容量、RAM 冲突、断言和复位检查。
