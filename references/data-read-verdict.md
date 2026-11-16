# 读取数据的硬性判据

“得到数字”只说明一次 JTAG 请求返回了内容。可信的运行态数据同时需要**读前门禁、完整采集、读后校验**。`scripts/ti_c2000_check_read.ps1` 只检 CSV；会话和固件证据由公开读入口与内部 `ti_c2000_live_read.ps1` 提供，不能拿单独的 CSV 检查冒充板上运行证明。

## 读前：先告知，再决定是否允许读

| 证据 | 通过条件 | 失败处理 |
|---|---|---|
| 工程与镜像 | 已选实际工程/目标核；精确 `.out` 不比工程内源码、`.cmd`、构建配置旧；其 SHA256 等于常驻 DSS 会话加载时的记录。工程外链接源码须另核构建记录 | 旧产物 `STALE_ARTEFACT`；文件变了 `STALE_SERVICE`，不重下载来凑数。时间戳和重复 `gFwId` 都不能单独证明“最新构建” |
| 探针与目标 | 探针可枚举且可用；DSS 进程活着；目标实际回应。DSS `connect()` 无异常后还须查 `target.isConnected(true)` 并查询目标 | `NO_PROBE` / `TARGET_NOT_CONNECTED`，不把 PID 或符号表命中当成连接证明 |
| RAM/Flash | 本会话钉住的 `.map` 证明 `.text` 在 RAM，更新函数和计数器地址在 RAM，且 `gRamProofTick` 推进；其他可执行段仍需工程代码审查 | `NOT_RAM_IMAGE` / `PREFLIGHT_FAILED`；旧固件没有[RAM 自证契约](ram-proof-firmware.md)就拒绝。此门禁仅通过离线测试，尚无板上验证。 |
| 固件身份 | 加载时记录 `gFwId`，读前再读相同值；必须按构建生成唯一值 | 不可读或不符即拒绝。磁盘 SHA 只证明所选文件与会话记录一致；重复 `gFwId` 留下旧固件碰撞风险 |
| 应用活性 | 至少一个契约中的应用心跳在两次请求间推进；想分别确认 ISR 和主循环，应让两者都推进 | 心跳不动、目标被 halt 或读不到都拒绝 |
| 加载次数 | 报告累计成功加载数与本会话加载序号 | 此项是溯源信息；失败/部分写入的加载尝试看 DSS 日志，不伪称计数覆盖所有物理写入 |

`-NoProbeCheck`、`-AllowUnverified`、`-NoHeartbeat` 不能放宽上述 ReadOnly 门禁。`ReadOnly` 零构建、零下载、零因读而 halt/reset/disconnect；`LoadRead -ConfirmLoad` 先由常驻服务加载，再走同一门禁。失败必须删除上一轮成功 CSV/判据；新数据不得写成 `RESULT: OK`。固件符号及时间门限统一见[契约](firmware-contract.json)，维护时先改契约再跑 `tools/audit_fw_contract.ps1`。

## 采集中：数值与时间含义

- 标量读取要限定简单变量/寄存器路径，避免赋值、调用和副作用表达式；读清除型寄存器需查器件手册。多变量的顺序 `evaluate` **不是原子快照**。16/32 位变量也不能因“看起来有值”就断言并发读写原子，固件侧需快照、版本号或冻结协议。
- 轮询请求至少间隔 400 ms，默认 `-IntervalMs 500` 还会额外等待；不能按旧的 8–20 Hz 估计。`ADCRESULTx` 只保存最近转换；慢轮询不记录两次请求间的历史。100 ms 更新的信号须由固件定时采样进 RAM，再冻结数组传出。JTAG 传输耗时可以长于采样窗口。
- DMA 或 ISR 录波前确认 ADC 触发、缓冲容量、序号、ping-pong/冻结逻辑和数据对齐。十个 50 Hz 周期在 1 kHz 下是 200 点；这是**固件采集长度**，不是要求 JTAG 在 200 ms 内读完。当前 DMA 上板验证尚待固件配置完成。

## 读后：四级判据

| 层级 | 判定 | 说明 |
|---|---|---|
| 1 身份 | 读后身份仍等于读前和本会话记录；`.out` SHA 未变 | 身份不符或不可读均失败；唯一 ID 由固件构建流程负责 |
| 2 活性 | 跨轮心跳推进；若指定速率，则按主机实测时间计算 `Δ计数/Δ秒`，容差由参数决定 | 仅 `isHalted()==false` 不够。多候选中至少一个推进证明有代码执行；若要断言主循环正常，必须单独检查主循环计数器 |
| 3 冻结数组 | 完成标志等于指定值（默认 `1`），复制前后标志及序号不变，返回点数为 `Rows×Columns`，首元素 `evaluate` 与 `readData` 一致 | 标志一直为 0 但“不变”不能算冻结；空 `-FrozenValue` 不得跳过等值检查。无固件实际填充计数时，不能声称已核实录满 |
| 4 数值 | 每个指定数值可解析且有限；指定上下限则逐点检查；轮次数和字段数完整 | 12 bit 右对齐 ADC 常用 0–4095；左对齐原始值为 0–65535 且低 4 位为 0，后者需工程专用校验 |

最终结论写在 `<工程>\readout\check\verdict.txt`，数据在 `<工程>\readout\data\data.csv` 或 `array.csv`。身份、速率、心跳、结构或数值任一失败，判据文件须是 `result: FAIL`，退出码非零，控制台 `RESULT: FAIL`；不能先写 `result: OK` 再输出失败。下次读取开始先移除旧成功文件；失败后保留当次失败数据时必须有明确 FAIL 判据，不能误用。

纯离线复核可运行：

```powershell
pwsh -NoProfile -File scripts/ti_c2000_check_read.ps1 -CsvPath <csv> -RangeVars adcValue -ValueMin 0 -ValueMax 4095
```

数组 CSV 没有心跳列时，校验器可用 `-AllowNoHeartbeat` 检查文件结构与范围；这**不构成板上活性证明**，公开读入口还须在同一 DSS 会话单独检查应用心跳。缺少校验脚本时公开读入口应报 `ENV_NO_VERDICT_SCRIPT`，拒绝成功结论。
