# 常驻 DSS 会话读取

调试阶段先加载 RAM 镜像，再在**同一个仍在线的 DSS 会话**中运行和读取。不能把断开后的新连接当成这次 RAM 运行的延续。DSP28335 和 F28379D 的历史现场见各自调试案例；这是一条保守的跨器件工作规则，不能推断每块芯片断开都必然复位。

## 入口与状态

| 操作 | 行为 |
|---|---|
| `ti_c2000_service.ps1 -Start -ConfirmLoad [-Build]` | 用户同意后选择精确 `.out`、连接、验证连接、复位或有效链路上 halt 兜底、加载、运行，DSS 常驻。 |
| `ti_c2000_run_read.ps1 -Mode ReadOnly` | 读慢变量；不编译、不下载、不连接、不 halt。 |
| `ti_c2000_read_dma.ps1 -Mode ReadOnly -FrozenBufferReady` | 读固件已冻结的数组；DMA 初始化与 ping-pong 尚未完成真机验证。 |
| 两个读入口的 `-Mode LoadRead -ConfirmLoad` | 必要时停止旧会话，调用常驻服务加载一次，再经相同 ReadOnly 判据读取；读完保留服务。`-Standalone` 仅是此路径的旧别名。 |
| `ti_c2000_iterate.ps1 -UserApproved -Expect ...` | 只有用户明确要求连续运行才重复构建/加载/读/判据；最多 20 轮，下载间隔至少 5 秒。 |
| `ti_c2000_service.ps1 -Stop` | 显式结束会话。DSS 需要释放调试状态，可能暂时使探针重新枚举；不是普通读数步骤。 |

连续运行时的目标锁禁止外部 ReadOnly、LoadRead、Start/Stop 与第二个 Iterate 抢占。ReadOnly 与 `-Build/-ConfirmLoad/-Expect/-MaxLoads>1` 互斥；LoadRead 缺 `-ConfirmLoad` 拒绝。只读绕过开关 `-NoProbeCheck/-AllowUnverified/-NoHeartbeat` 已禁用。下载计数在 `readout/load-count.json`，只计**成功加载**；失败或部分 `loadProgram` 尝试看 DSS 日志。

## 读前必须呈现的证据

1. 工程入口检查通过，目标核和所选 `.out` 明确；精确 `.out` 不比源文件旧，SHA256 与会话加载记录一致。
2. 探针通过枚举和可用性检查，DSS 会话 PID 活着，目标实际应答。`connect()` 无异常或 `isHalted()==false` 都不够。
3. RAM/Flash 证据明确且为 RAM：本会话钉住 `.out/.map`，`.text`、RAM 更新函数和计数器位于 RAM，`gRamProofTick` 在读取间推进。旧固件须先按[RAM 自证契约](ram-proof-firmware.md)集成；其他自定义可执行段仍需工程代码审查。这个新门禁尚未上板验证。
4. 本会话加载时记录过固件身份，读前身份仍相同，应用计数器跨时间窗推进。`gFwId` 必须随构建唯一变化；重复 ID 会留下旧固件冒充的风险。
5. 输出成功加载累计次数和本会话序号。两个读之间次数变化，数据属于不同运行。

任一必需证据缺失、Flash、链路掉线、计数器不动或身份不符时拒绝读取。拒绝后清理旧 `data.csv/array.csv` 与旧成功判据，不能展示残留数字作为新结果。

## 读后校验

慢变量读：检查轮数、数值是否为有限数字、指定上下限、固件身份再次匹配、心跳推进，可选速率是否落在容差内。数组读：检查完成标志到位、复制前后标志及序号未变、点数齐全、首元素的表达式读与 `readData` 锚点一致。读到数字不等于数据可靠；最终以 `check/verdict.txt`、退出码 0 和 `RESULT: OK` 一起判定。详见[数据判据](data-read-verdict.md)。

## 轮询速度

每次**数据请求**至少间隔 400 ms，另有 DSS 求值与文件往返开销。因此慢变量读取每秒最多约 2.5 次，实际更慢；默认 `-IntervalMs 500` 再增加等待。它只能看较慢的状态和趋势，不能还原 100 ms 一次的序列，更不能量相位、频率或脉冲。要看每个采样点，先在固件侧由定时器/ISR/DMA 采集到 RAM，冻结后在同一会话传出；JTAG 传输可长于采样窗口。

不应把“32 位变量看起来有值”当原子性保证：固件与主机的读写并发需要快照、序号或专用冻结协议。也不要把正在变化的 ADC 结果寄存器当成等间隔波形。
