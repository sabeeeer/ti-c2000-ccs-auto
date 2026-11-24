# 第三类：调试经验与故障复盘

遇到 ADC、eCAP、SCI、SPI、串口抓包、数据撕裂、寄存器读回、编译或下载异常时，从这里按 **器件 + 模块 + 现象** 检索。外设如何配置先查[第一类](device-platform.md)，算法库怎么调用先查[第二类](ti-algorithm-libraries.md)；诊断过程和实测结论写在第三类。旧记录保留原文，不因整理目录而删减。

## 已有经验索引

| 器件/范围 | 模块或环节 | 现象与检索词 | 记录 |
|---|---|---|---|
| DSP28335 实测 | ADC | 采样不更新、`ADCTRL2` 被覆写、结果为零、转换时序 | [C28x 踩坑清单 §一](c28x-pitfalls.md) |
| DSP28335 实测 | SPI / 外部 DAC | 发送完成标志、LOAD 脉冲、时序、波形削平 | [C28x 踩坑清单 §二](c28x-pitfalls.md) |
| DSP28335 实测 | SCI / 串口抓包 | FIFO 状态、多个发送者、帧错位 | [C28x 踩坑清单 §三](c28x-pitfalls.md) |
| DSP28335 工程实测 | CCS / 链接 / 文本编码 / 抓包工具 | include 路径、`.text` 空间、GBK、DSS、SerialPlot | [C28x 踩坑清单 §四](c28x-pitfalls.md)；[现场手册](field-guide.md) |
| DSP28335 工程实测 | PID / dq / 控制波形 | 噪声、误差来源、角度约定、母线前馈 | [C28x 踩坑清单 §五](c28x-pitfalls.md)；算法库选择另看[第二类](ti-algorithm-libraries.md) |
| DSP28335 实测 | ISR / 主循环共享数据 | 波形毛刺、原子快照、关中断、INTM | [C28x 踩坑清单 §六](c28x-pitfalls.md)；[TI 例程写法 §4.5](ti-official-style.md) |
| DSP28335 / F28379D 等，按各文适用范围 | JTAG / DSS / 读回 | 下载失败、就绪条件、读得太早、长时等待 | [DSS 调试](dss-debug.md)；[器件与探针记录](other-devices-and-probes.md) |
| 具体工程与工具链，按原文适用范围 | 构建 / 链接 / 自动化 | 旧 `.out`、失败分类、RAM/Flash 段 | [现场手册](field-guide.md)；[RAM 与链接](ram-and-linker.md) |

上表是旧资料的入口，**不表示每条旧结论已在所有列出的器件上验证**。尤其不要把 DSP28335 的 ADC、SPI、SCI 寄存器行为直接套到 F28379D。eCAP 的当前板实测故障见下表；先查当前器件例程，再按下面规则建立案例。

## 新案例索引

以后每个新的故障或可复用调试发现单独写一份 `debug-cases/<器件型号>/<日期>-<模块>-<简短现象>.md`，文件名用小写 ASCII，例如 `debug-cases/f28379d/2026-10-27-ecap-capture-zero.md`。按下表登记；模块可写 ADC、SCI、eCAP、CPU1/CPU2、JTAG、链接等，不预设固定清单。查找时同时搜器件、模块、现象词；跨器件问题在单一案例中写清逐个验证的型号，不能仅凭家族相似性推广。

| 器件/目标核 | 模块 | 现象与检索词 | 状态 | 案例 |
|---|---|---|---|---|
| DSP28335 | SPI / 外部 DAC（TLV5620） | LOAD 拉早、残字锁存、码值翻倍/串道、DAC 假损坏、`BUFFULL_FLAG`/`INT_FLAG`、`SPIRXBUF`、FIFO 不适用、`SPIBRR` | 已回归 | [2026-10-26-tlv5620-load-timing](debug-cases/dsp28335/2026-10-26-tlv5620-load-timing.md) |
| DSP28335 | SCI / 共享数据 | 波形垂直毛刺、帧错位、原子快照、`DINT` | 排查中 | [2026-10-26-sci-shared-data-tearing](debug-cases/dsp28335/2026-10-26-sci-shared-data-tearing.md) |
| DSP28335 | ADC / 接线判据 | 悬空引脚读数稳定、误判通道损坏、历史 `0.95V` 读数 | 待复核 | [2026-10-27-adc-floating-misjudge](debug-cases/dsp28335/2026-10-27-adc-floating-misjudge.md) |
| DSP28335 | SolarLib SPLL / 三相 SOGI | sine 型输入的 d/q、硬编码 B0/B1、半拍补偿、DSOGI 正负序分离、不平衡下 vq 纹波 0.262→0.001 pu | 已回归 | [2026-10-27-solarlib-spll-integration](debug-cases/dsp28335/2026-10-27-solarlib-spll-integration.md) |
| DSP28335 | CCS / SDK 例程构建 | eCAP、`INSTALLROOT_*`、linked resources、通用构建脚本失败 | 已回归（构建适配） | [2026-10-27-sdk-example-build-macros](debug-cases/dsp28335/2026-10-27-sdk-example-build-macros.md) |
| DSP28335 / XDS100v1/v2 | JTAG / DSS 自动化 | PowerShell 调用 `.bat` 失败、CIM 误报无探针、`xds100serial`、构建前探针预检 | 待上板回归 | [2026-10-28-dss-batch-probe-preflight](debug-cases/dsp28335/2026-10-28-dss-batch-probe-preflight.md) |
| DSP28335 | eCAP / GPIO 连通性 | GPIO4 翻转、GPIO24 恒高、eCAP 捕获计数为零、跳线 | 排查中 | [2026-10-28-ecap-gpio24-no-edge](debug-cases/dsp28335/2026-10-28-ecap-gpio24-no-edge.md) |
| DSP28335 / CCS 12.8 DSS | FPU / 浮点读回 | `expression.evaluate` 截断、浮点显示整数、原始位型、误判超时 | 已回归（读回方法） | [2026-10-28-fpu-dss-float-readback](debug-cases/dsp28335/2026-10-28-fpu-dss-float-readback.md) |
| DSP28335 / 本机 SDK | FPU software / 工程选项 | 源码写软件浮点、`.cproject` 仍启用 `fpu32`、错误验收 | 待复核 | [2026-10-28-fpu-software-project-options](debug-cases/dsp28335/2026-10-28-fpu-software-project-options.md) |
| DSP28335 / CCS 12.8 DSS | 实时读 / `loadti` 运行状态 | `HaltOnConnect`、ERTM、只读停核、`-Build` 隐式 `-l`、PC 在 Flash 而 `.out` 在 RAM | 已定位 | [2026-11-07-realtime-read-implicit-loadonly](debug-cases/dsp28335/2026-11-07-realtime-read-implicit-loadonly.md) |
| DSP28335 / 4-1 两电平逆变器 | ADC 采样链 / 校准 / 探针 / GPIO | `AdcMirror` 对齐、误加 DMA、SOC、通道误判、整流平均、零点、校准超时放波、OLED 引脚、XDS100 串号 | 待复核 | [2026-11-07-adc-chain-port-audit](debug-cases/dsp28335/2026-11-07-adc-chain-port-audit.md) |
| DSP28335 / 4-1 两电平逆变器 | DSS / 运行态数组读取 | 符号错配、重复 `connect`、`-1133`、`halt → readData → runAsynch`、继电器释放、`gAdcAllBuf[16][400]`、6400 点只读实测、62516/65012、字寻址 | 待复核 | [2026-11-07-read-halt-bulk-array](debug-cases/dsp28335/2026-11-07-read-halt-bulk-array.md) |
| F28379D / CPU1 / XDS100v2 | DSS / RAM 单会话上板 | `reset()` 返回 -1、加载前 `halt()` 回退、加载一次、运行态心跳递增、断开后状态未在本次复核 | 待复核 | [2026-11-14-dss-single-session-heartbeat](debug-cases/f28379d/2026-11-14-dss-single-session-heartbeat.md) |
| F28379D / CPU1 / XDS100v2+XDS110 | DSS / 会话边界 | 断开后另起只读、`gMsTick 527→0`、复位跑 Flash、28335 读到 Flash 旧程序、只读入口已删除 | 已定位 | [2026-11-14-disconnect-then-read-is-a-bug](debug-cases/f28379d/2026-11-14-disconnect-then-read-is-a-bug.md) |
| F28379D / CPU1 / XDS110 | 单会话读取 / 输出契约 | 重复 `RESULT:` 行、失败保留上次 `result: OK`、`-Build` 双 RESULT、心跳失败无 `REASON`、`NO_FROZEN_FLAG` 误报、旧只读脚本强制参数绕过守卫、时间戳目录与 `Tools/out` 镜像、旧只读入口已彻底删除 | 已回归 | [2026-11-14-readout-contract-brute-test](debug-cases/f28379d/2026-11-14-readout-contract-brute-test.md) |
| F28379D / CPU1 / XDS100v2 | 执行模式 / 常驻会话 | 每次读都重载程序、`gMsTick` 反复归零、两次读数描述两次不同运行、`STALE_SERVICE`、`NO_FROZEN_FLAG`、Rhino varargs 与 `delete` 关键字、`/s /c` 引号、`$rounds` 撞 `-Rounds` | 已上板验证 | [2026-11-14-live-session-service](debug-cases/f28379d/2026-11-14-live-session-service.md) |
| F28379D / CPU1 / XDS100v2 | 运行模式 × 读模式 / 互锁 / 下载计数 | 自动编译下载打乱数据、频繁烧录伤机器、单步常驻、连续模式反复下载到数据对、只读模式零下载、`READONLY_IN_ITERATE`、`ITERATE_IN_PROGRESS`、`MUTUALLY_EXCLUSIVE`、`NO_SESSION`、`NOT_RAM_IMAGE`、`LOAD_NOT_CONFIRMED`、`ITERATE_NOT_APPROVED`、`load-count.json`、`LOAD #N` | 已回归（脚本层） | [2026-11-14-run-modes-and-load-counter](debug-cases/f28379d/2026-11-14-run-modes-and-load-counter.md) |
| F28379D / CPU1 / XDS100v2 | DSS 时序 / 编译器选项 | `connect()` 假成功；`-1138` 后重试把探针推入 -1041/-150；`.cproject` 的 `ENTRY_POINT`/`CLA`/`VCU` 从未传递（入口点与 CCS 构建不同），`ofd2000` 的 Entry Point 字段不可信 | 已回归 | [2026-11-15-dss-timing-and-build-audit](debug-cases/f28379d/2026-11-15-dss-timing-and-build-audit.md) |
| F28379D / CPU1 / XDS100v2 | 读前门禁 / 掉线 | 读 ADC 读到旧工程值却无人报告；`STOP` 不 `halt` 导致下次 `Load failed`（debug state 残留）；连续十几个只读用例后 `target is not connected` | 已回归 | [2026-11-15-preflight-and-link-drops](debug-cases/f28379d/2026-11-15-preflight-and-link-drops.md) |
| F28379D / CPU1 / XDS100v2 | JTAG 链路 / 判据假阳性 | 探针仍在设备列表、会话进程存活、`sha256` 一致、符号求值 `main` 成功，但寄存器/内存读报 `target is not connected`；"running from RAM" 被误当作连接证据；`-Stop` + `-Start -ConfirmLoad` 才能恢复 | 已定位 | [2026-11-15-xds100-link-drops](debug-cases/f28379d/2026-11-15-xds100-link-drops.md) |
| F28379D / CPU1 / XDS100v2 | 全功能上机审计 / 心跳 / 互锁 | 连续运行结束后 `READONLY_IN_ITERATE` 永久挡住只读（遗留会话 `runMode=Iterate`）；读不含心跳量的变量必然 `HEARTBEAT_FAIL`（心跳值只存在于 `VARS` 响应）；`-NoHeartbeat` 反而判失败；CSV 判据重复要求心跳列；`member not found` 缺 `.bit.` 提示 | 已回归 | [2026-11-14-on-target-audit](debug-cases/f28379d/2026-11-14-on-target-audit.md) |
| F28379D / CPU1 / XDS100v2 | ADC+DMA 双链录波 / 方法论 | 录波实现全过程的可复用教训：用 `Sleep` 推断读耗时会高估覆盖次数；`BURST_SIZE=0` 时 `DST_BURST_STEP`/`DST_TRANSFER_STEP` 不推进地址（整块只写 `[0]`）；JTAG 读中断高频写入区必报 `0x200000` 并断链；控制链与录波链共用 `ADCRESULT0` 导致相位浮动；上传任务解冻清数组导致导出读到半成品；`int16` 字段按无符号导出变 64108；SCI 115200 每 ms 仅 11.5 B 却塞两个生产者导致 FIFO 永满。检索词：采满即停、`PERINTE` 冻结、独立 SOC、`gCtrlLogFrozen`、双链并行 | 已回归 | [2026-11-17-dual-chain-recording-lessons](debug-cases/f28379d/2026-11-17-dual-chain-recording-lessons.md) |
| F28379D / CPU1 | PIE / 中断不响应 | `IFR` 恒 0 但 `PIEIFR` 置位、`ETFLG` 置位、ISR 一次不进；`PIEACK` 未释放（`main` 缺 `EnableInterrupts()` 里的 `PIEACK.all=0xFFFF`）；一次改多处导致误判因果关系；`TB_COUNT_UP == 0x0` 被误读成冻结；`gMsTick` 正常不能证明中断在跑。检索词：PIEACK、IFR=0、中断不进、EnableInterrupts | 已回归 | [2026-11-18-pieack-blocks-interrupts](debug-cases/f28379d/2026-11-18-pieack-blocks-interrupts.md) |
| F28379D / CPU1 | RAM 链接 / 段布局 / Flash 擦写 | `.text : >> RAMD0 … RAMLS0 …` 把 0xB000 排在 0x8000 前面，加载器分片写、第一片就报 `-1041`；`>>` 地址升序仍判跨片，必须合并 MEMORY + 单块 `>`；`-1133` 时 `service.ps1` 因 `PoliteRealtimeMode=true` 连不上而 `loadti` 能连；真实错误码在 DSS stdout、Java 异常只有 `emulation failure`；**违反工程「只走 RAM」约定去烧 Flash 失败后擦空 Flash，CPU 跑飞，DSS 三个入口全部无解，只能 CCS GUI 复位或 BOOT=111**。检索词：`-1041`、`0x7ff`、跨片、RAMCODE、`-1133`、PoliteRealtimeMode、loadti 对比、Flash 擦空 | 已定位 | [2026-11-18-text-cross-block-and-flash-erase-brick](debug-cases/f28379d/2026-11-18-text-cross-block-and-flash-erase-brick.md) |
| F28379D / CPU1 | 链接入口 / RAM 下载 | `-EntryPoint code_start` 若用短形式 `-e` 追加在 `-z` 之后会被 cl2000 吞掉，日志仍打印 overridden，而 `.out` 入口退化成 `_c_int00`（位于 `.text` 内）→ loadProgram 写完 BEGIN 就把 PC 指进尚未写入的 `.text` → CPU 跑飞 → 首块写 0x8000 报 `-1041` + `-150`；同时 `service.ps1` 的 `NON_DEFAULT_ENTRY_POINT` 会无条件拒绝 `code_start`，把 `.cproject` 声明的唯一正确入口挡在门外。修法：改用 `--entry_point=` 长形式、未传时自动取 `.cproject`、构建期用 map 校验命中、拦截判据改为与 `.cproject` 声明比对。检索词：-1041、入口点、ENTRY POINT SYMBOL、code_start、-e 不生效、NON_DEFAULT_ENTRY_POINT | 部分推翻 | [2026-11-18-entry-point-not-applied-causes-1041](debug-cases/f28379d/2026-11-18-entry-point-not-applied-causes-1041.md) |
| F28379D / CPU1 / XDS100v2 | 读模式 / 数据判据 / 负向测试 | `ReadOnly` 与 `LoadRead` 两种交易模式、`read_continuous` 的 200 点（20 ms = 1 个工频周期）与 5000 点两种规模，全部上板验证；四个负向用例证明判据会真正 FAIL：范围给错 → `RANGE: FAIL` + exit 1、不带 `-FrozenBufferReady` → `BUFFER_NOT_CONFIRMED` exit 2、`ReadOnly + -ConfirmLoad` → `MUTUALLY_EXCLUSIVE` exit 2、`check_read` 对无心跳列 CSV → `HEARTBEAT: FAIL`。两个易误判点：`-ValueMin/-ValueMax` 作用于 `-Variables` 全部变量（混入 `gMsTick` 会误判，正解是计数器交给 `-RateVar`）；失败读会删旧 CSV，`NO_CSV` 属设计行为。检索词：读模式、判据、负向、RANGE FAIL、BUFFER_NOT_CONFIRMED、MUTUALLY_EXCLUSIVE、NO_CSV、AllowNoHeartbeat | 已验证 | [2026-11-18-read-modes-and-verdict-verification](debug-cases/f28379d/2026-11-18-read-modes-and-verdict-verification.md) |
| F28379D / CPU1 / XDS100v2 | RAM 下载成功路径 / DSS 日志判读 / 读回符号 | `-1133` 后 `PoliteRealtimeMode off` 自动降级即成功；`-150`/`flash operation`/`-6310` 是 GEL 噪声；只有 `DSS: loaded` 算写成功；`FLASHA~N used=0` + `code_start@00000000` 证明 RAM 镜像；`AdcRegs`/`ADCTRL1` 在 F2837xD 不存在（用 `AdcaRegs.ADCCTL1/ADCCTL2/ADCSOC0CTL`）；`CMPA.all` 读回 >16 位拼合值应改读 `.bit.CMPA`；`pwsh -File -Variables 'a','b'` 引号成为字面量导致 `INVALID_READ_REQUEST`。检索词：成功路径、PoliteRealtimeMode、DSS loaded、AdcaRegs、CMPA.all、INVALID_READ_REQUEST | 已回归 | [2026-11-18-ram-download-success-path](debug-cases/f28379d/2026-11-18-ram-download-success-path.md) |
| F28379D / CPU1 / XDS100v2 | 误诊复盘 / 控制实验 / 旧会话污染 | "幽灵探针导致 -151"的前提被 A/B 推翻：`xds100serial` 在 DSS 会话运行中必然报"找不到"（停会话 3 秒就能读到），只反映 FTDI 句柄占用；同路径 A/B（统一 10 s）`Only one` 两次都 `-215` 信号量超时，按串号 `TI90I42A` 则 `LOAD #113` OK —— 失败的是"自动选择/枚举"路径，不是"打开幽灵"（幽灵 `Present=False` 打不开）。另：**改了 SKILL.md 后已开启的会话仍按旧指令构建**，会持续把 `code_start` 镜像写回 `Debug\`，需让会话重开。检索词：幽灵探针、-215、semaphore、xds100serial、A/B、控制变量、旧会话、改 skill 不生效、-NoProbeResolve | 已回归 | [2026-11-18-ghost-probe-misdiagnosis-and-stale-session](debug-cases/f28379d/2026-11-18-ghost-probe-misdiagnosis-and-stale-session.md) |
| F28379D / CPU1 / XDS100v2 | 构建入口点 / 参数未生效 / 两度误诊 | **短形式 `-e <sym>` 被 cl2000 吞掉** → `.out` 实际入口仍是 `_c_int00`（落在 `.text` 内），`loadProgram` 写完 `BEGIN` 就把 PC 指向未写入的 `.text` → CPU 跑飞 → 首块 `0x8000` 报 `-1041` + FTDI `-150`。曾被误诊两次：①"以后别传入口"；②"必须 `_c_int00`、不能用 `code_start`"——**两条都错**。正解：入口跟随 `.cproject` 的 `linkerID.ENTRY_POINT`，用**长形式** `--entry_point=<sym>`，链接后用 `.map` 复核（`ENTRY_POINT_NOT_APPLIED`）；改完 `LOAD #116/#119` 连续成功。判别指纹：`.out` 592810 vs 592642、`ENTRY POINT SYMBOL`、`Length 0x800` vs `0x16a8`。检索词：code_start、entry_point、短形式被吞、-1041、分片、另一个对话下不进去、误诊 | 已回归 | [2026-11-18-code-start-entry-point-blocks-download](debug-cases/f28379d/2026-11-18-code-start-entry-point-blocks-download.md) |
| F28379D / CPU1 / XDS100v2 | 探针配置 / set_probe 脚本回归 / `-151` | `-151` 先查 ccxml 是否按串号选探针（幽灵实例让 "Only one" 打开错探针）；`ti_c2000_set_probe.ps1` 旧版重建 ccxml 时丢 3 个 driver + 整个 `<device>`（partnum/ICEPick_C router/Subpath），报 `invalid processor ID`；已改最小侵入式改写，逐 driver 存在才换、绝不删节点。检索词：`-151`、FTDI、xds100serial、按串号、幽灵实例、invalid processor ID、ccxml 丢节点、set_probe | 已回归 | [2026-11-18-set-probe-drops-device-link](debug-cases/f28379d/2026-11-18-set-probe-drops-device-link.md) |
| F28379D / CPU1 / XDS100v2 + CCS 12.8.1 | CCS Graph 人工观察 / 参数换算 | 程序在跑、Memory Browser 里数组有数据，Graph 却全空：Y 轴 0~0.9、X 轴缩到 1e-5，反复 Refresh 无用；根因是 **`Acquisition Buffer Size × Index Increment` 超过数组字数**（结构体数组 `{Uint16 ia; Uint16 dac;}[1000]` = 2000 字，填 2000×2=4000 字越界）。正确参数用**变量名** `Start=gCtrlFrozen` / `gCtrlLog`，**10 kHz 控制周期**下 `Sampling Rate=10000`，`Display=200` 即 20 ms（1 个 50 Hz 周期）、`Display=1000` 即 100 ms（5 个周期）；`Acquisition` 与 Display 同为点数（200 / 1000），`Index=2`、`16 bit unsigned`、`Time=ms`。注意 Acquisition 是点数不是字数，20 ms 填 200 不是 400。检索词：graph 参数、Graph 没波形、图空、只有一次正弦、全 0、Acquisition Buffer Size、Index Increment、Display Data Size、16 bit unsigned、10 kHz、20 ms、结构体数组、gCtrlFrozen、gCtrlLog、滚动刷新、Continuous Refresh、冻结数组、环形缓冲、实时 vs 冻结 | 已回归 | [2026-11-18-ccs-graph-acquisition-buffer](debug-cases/f28379d/2026-11-18-ccs-graph-acquisition-buffer.md) |

新案例按[案例模板](debug-cases/CASE-TEMPLATE.md)记录，原始日志/波形优先保存在对应工程或用户指定位置，案例中写稳定路径与关键读数，避免把大量原始数据复制进技能。

## 每次调试结束时的归档判定

1. 先按器件、模块、现象查本页、`debug-cases/` 和旧记录。新故障、新证据、新根因，或**可复现但尚未定位**的问题，都建立案例；已有案例则补充新器件的验证结果或反例，不制造重复案例。纯操作且没有新证据时不建空案例。
2. 案例写清器件/板卡/目标核、模块、环境、现象、复现条件、原始证据、排查过程、原因或假设、修复与回归结果。用“排查中 / 待复核 / 已定位 / 已回归 / 已证伪”标状态；PC 数值验证与目标板回归分别写明。把实测事实与推测分开；缺失的参数写“未知”，不要补造。
3. 登记上面的新案例索引，状态和文件一致。运行 `pwsh -NoProfile -File "<skill>\scripts\check_debug_catalog.ps1" -SkillRoot "<skill>"`，确认每个案例都入索引、每条案例链接都存在。交付时告知用户新增或更新的案例；无法写入技能时，把证据和待归档事项明确交给用户。

**结论晋级门槛**：标“已定位”须有能区分竞争原因的原始读数/抓包/波形及对应源码版本；标“已回归”还须有修复前后同条件结果、实际构建标识和目标板运行记录。工程注释、旧 `.out`、口述截图、PC 仿真各自只能支持其实际覆盖范围。算法或外设建议与旧案例冲突时，先核对当前器件 TI 手册和真实寄存器配置，修正冲突后再归档。目录检查脚本只校验收录、链接与状态一致性，**不校验技术结论是否正确**。
