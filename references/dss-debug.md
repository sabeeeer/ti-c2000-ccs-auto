# CCS 下载与 DSS 运行态读取

## 所有器件的操作前提：会话边界

无论 DSP28335、F28379D 还是以后新增的 C2000 器件，**操作上先按最严格边界规划**：本用户调试阶段使用 RAM 链接程序和 RAM 变量/冻结缓冲，先核对当前 `.cmd` 与 `.map`。新固件的构建/加载/运行态验证在一个 DSS 会话中完成；加载一次后把计划的标量、冻结缓冲和心跳全部读完，不为补读频繁重新连接或烧录。程序开始运行后的读取、读取结束都不主动 `halt()`；DSS 必须使用实时访问，读数期间若发现目标停机就失败退出，不以停核读数冒充运行态读数。

本 skill 已不再提供任何“独立只读”入口：`connect → 只读符号 → 取数` 这条路径无法证明它看到的是刚刚下载的 RAM 固件（断开后目标可能复位跑 Flash，例如 F28379D 上 `gMsTick 527→0`、`isHalted=true`；DSP28335 上 PC 落在 Flash）。**不能默认 `disconnect()` 后目标继续运行**：如任务要求程序在脚本退出后继续控制输出，应先在该器件、探针、CCS 组合验证断开行为，或保持同一调试会话；当前自动脚本退出时会断开。用户报告 CCS GUI 存在“断开不复位”设置；在本机 CCS 12.8 DSS 中尝试 `HaltOnDisconnect`、`ResetOnDisconnect`、`AutoResetOnDisconnect` 均返回 `Option not found`，目前没有找到脚本层等效控制。以上是跨器件的保守工作规则，**不是**“DSS 对所有 DSP 必然复位”或“最后必须 halt”的已证实 API 性质。TI 的 [CCS 12.8 实时模式说明](https://software-dl.ti.com/ccs/esd/documents/users_guide_12.8.0/ccs_debug-main.html)明确允许运行时访问；[DSS Target API](https://software-dl.ti.com/ccs/esd/documents/scripting_api/ccs_12.8.0/dss/docs/DS_API/com/ti/debug/engine/scripting/Target.html)分别定义 `disconnect()`、`reset()` 和 `halt()`。现场断开结果按器件逐项归档。

执行模式验证新 RAM 固件时，优先用 `ti_c2000_run_read.ps1` 在同一 DSS 会话内加载、运行、读取；固件已有冻结 DMA 缓冲时用 `ti_c2000_read_continuous.ps1`。`ti_c2000_debug.ps1 -Run` 用 `loadti -r -a` 下载并退出会话，**不适合直接作为 DSP28335 新 RAM 固件的读数验收路径**（它不读值，读值只在上面两个单会话入口里发生）。

## 下载/运行边界

| 参数 | 效果 |
|---|---|
| `-Build` | 构建而不下载。 |
| `-Run` | 下载现有 `.out`，复位并异步运行。 |
| `-Build -Run` | 构建成功后下载运行。 |
| `-LoadOnly` | 显式下载后保持暂停；不得用来读取数据。 |

成功看 `RESULT: OK` 与退出码 0，下载还应有 `Done`，运行还应有 `Target running...`。失败先看原始错误、探针/串号、`.ccxml`、供电、目标核和 CCS GUI 是否占用 JTAG；双核与 F28379D 见[器件/探针记录](other-devices-and-probes.md)。

`loadti` 自身有 `-cpu/--cpu-name` 选核参数；本技能包装脚本当前未透传该参数，F28379D 下载前须确认实际加载核。`xds100serial.exe` 可在 `<CCS_ROOT>\ccs_base\common\uscif\` 下列出 XDS100 探针和串号；`dbgjtag.exe` 在同目录用于 JTAG 诊断。识别探针不需要下载程序；`loadti` 则会改变目标状态。

## 一次成功下载的固定顺序与日志判读（2026-11-18，F28379D/CPU1 + XDS100v2 实测）

工程 `F28379D_CPU1_BareMetal`（`CPU1_RAM` 配置、21 个源文件、COFF、`ti-cgt-c2000_15.12.1.LTS`）从"从未构建过"到"RAM 运行并被只读验证"一次跑通，命令只有三条：

```powershell
pwsh -NoProfile -File <skill>\scripts\ti_c2000_build.ps1   -ProjectPath <工程>          # 不要传 -EntryPoint
pwsh -NoProfile -File <skill>\scripts\ti_c2000_service.ps1 -ProjectPath <工程> -Start -ConfirmLoad
pwsh -NoProfile -Command "& '<skill>\scripts\ti_c2000_run_read.ps1' -ProjectPath '<工程>' -Variables usMainLoop,EPwm1Regs.TBPRD -Rounds 4 -IntervalMs 400"
```

DSS 侧只有四步（`scripts/ti_c2000_dss_boot.js`）：`server.openSession("C28xx_CPU1")` → `target.reset()` → `memory.loadProgram(<工程>\Debug\<工程>.out)` → `target.runAsynch()`。**`loadProgram` 是按 `.out` 段地址写内存**；`.out` 若是 RAM 链接（`2837xD_RAM_lnk_cpu1.cmd` + `F2837xD_Headers_nonBIOS_cpu1.cmd`），就不触发任何 Flash 擦写。

成功三条判据，缺一不得写"下载成功"：

| 判据 | 证据位置 | 本次实测值 |
|---|---|---|
| 目标是 RAM 镜像 | `.map` 的 MEMORY CONFIGURATION | `FLASHA~FLASHN` used 全 `00000000`；`ENTRY POINT SYMBOL: "code_start" address: 00000000` |
| 镜像真的写进去了 | `server.log` | `DSS: loaded`（`DSS: reset` 之后） |
| 程序真的在跑 | 只读附着读计数器 | `usMainLoop` 369,300,672 → 374,378,552 → 378,189,143；`gFwId = 65537` |

`server.log` 的正确读法（本次原文顺序，**前半段看起来全是错，但最后确实是成功的**）：

```text
SEVERE: ... (Error -1133 @ 0x0) Device blocked debug access ... non-debuggable code
DSS: PoliteRealtimeMode off, retrying connect for -1133     <- 自动降级，属正常过程
SEVERE: ... Trouble Reading Memory Block at 0x5f05e / 0x5f060 / 0x7026d (Error -150) ...  <- GEL 试探读
DSS: connected (realtime off)                                <- 连接建立（注意：在 -150 之后）
SEVERE: C28xx_CPU1: Failed CPU Reset: (Error -6310) PRSC module failed to read a register
SEVERE: C28xx_CPU1: JTAG Communication Error: (Error -150) ...
SEVERE: C28xx_CPU1: Failed to remove the debug state from the target before disconnecting
SEVERE: GEL: ... Could not write 0x0005D122@Data: target is not connected
SEVERE: Target reset failed. Error: -1
DSS: reset failed (...)                                      <- 复位失败，链路丢失
DSS: link lost after connect, reconnecting
DSS: reconnect 1 failed: ... (IcePick_C_0: Error -151 ...)    <- 退避 900 ms
DSS: reconnect 2 failed: ... (IcePick_C_0: Error -151 ...)    <- 退避 1800 ms
C28xx_CPU1: GEL Output: Memory Map Initialization Complete
DSS: reset after reconnect (try 3)
DSS: loaded                                                  <- 写成功，只有这一行算数
SERVICE: READY
```

- `-1133` 是实时选项（`PoliteRealtimeMode=true` 供运行态读用）被拒绝；`loadti` 从不设这些选项，所以"loadti 能下、自己写的 DSS 下不进"的差异就在这里。**这条错误在本工程里是 skill 自己的连接选项造成的，修好降级逻辑后消失**，不要记成 Flash/硬件状态。
- `-150` 判据不是"出现位置"而是"影响"：本次 `DSS: connected` **之前**出现 3 次（GEL 试探读），链路建立后**又出现 1 次** `JTAG Communication Error`，两次都没阻止最终 `DSS: loaded`。要做的操作还能成功 → 瞬时 FTDI 噪声；同一操作反复失败 → 才查探针/驱动。
- `reset()` 报 `-6310`（PRSC 读失败）或 `Target reset failed. Error: -1` 时不要当场放弃：链路还在就 `halt()` 后直接加载；链路已丢（GEL 报 `target is not connected`）则进重连分支（最多 3 次、退避 900/1800/2700 ms）。本次是第 3 次重连后才 `DSS: reset after reconnect (try 3)` → `DSS: loaded`。只有 3 次全失败才是连接故障。
- **入口点跟随 `.cproject` 的 `linkerID.ENTRY_POINT`**（本工程 = `code_start`），用长形式 `--entry_point=<sym>` 传，并在链接后用 `.map` 复核。这一条 2026-11-18 被写错过两次：先写成"必须传 `code_start`"（当时用短形式 `-e`，没生效，等于白改）；又写成"必须 `_c_int00`、不能传 `code_start`"（**A/B 实测推翻**：`_c_int00` 与 `code_start` 各连续 3 次全 `RESULT: OK`，LOAD #121~#126）。**真正的 bug 是短形式 `-e` 被 cl2000 吞掉，不是 `code_start` 这个符号有毒**；`.text` 分片/整块由 `.cmd` 决定，与入口点无关。判据与原因见 [RAM 与链接](ram-and-linker.md)「入口点」小节。
- 第一次探针检查可能直接 `NO_PROBE`：本次 15:52 报 `PROBE : NOT FOUND` + exit 3，插好后**同一条命令**报 `XDS100 Class Debug Port` / `Auxiliary Port` / `USB Serial Port (COM11)` + `RESULT: OK`。PnP 需要时间，一次 `NO_PROBE` 不构成硬件结论。

### 实时模式与"下一次下载"的关系（别把它记成"必须人工关掉"）

- `ti_c2000_service.ps1` 在 connect **之前**就把 `PoliteRealtimeMode=true`、`AllowInterruptsWhenHalted=true` 打开，因为 `ReadOnly` 要在程序**运行中**读数、不能靠停核。
- `-1133` 发生在 **connect 阶段**；连不上就谈不上 `loadProgram`，所以"下不进"的第一现场往往是连接而不是写内存。
- 这两个选项属于**当次 DSS 会话**，不写进板子、不跨进程保留。下一次下载会**重新以 realtime on 开始**，再由 `dssConnectVerified` 捕获 `-1133`/`non-debuggable code`/`emulation failure` 自动降级（`disconnect` → 等 500 ms → 关两个选项 → 重连一次）。**不需要人工去关**，日志里的 `PoliteRealtimeMode off, retrying connect` 就是它自己做的。
- `loadti`（以及 `ti_c2000_debug.ps1 -Run`）**从不设置**这些选项，所以"它没关什么"也能连上；若 `loadti` 同样报 `-1133`，说明原因不在实时模式，要查复位循环、正在执行的非调试代码或另一个核。
- 降级后的会话是 realtime off：本次读数仍然成功（`usMainLoop` 跨轮递增），但别把"realtime off 也能读"当成所有目标状态的保证。

### `-150` 有两副面孔（同一次实测，同一份日志）

| 位置 | 含义 | 处置 |
|---|---|---|
| `DSS: connected` **之前**，常伴随 `flash operation: Target failed to read 0x05F05E@Program` | GEL/仿真包在连接阶段试探读，**与本次镜像无关**（本次 .out 的 Flash used=0） | 忽略；继续看是否出现 `DSS: loaded` |
| 出现在写/校验失败之后（`Target failed to write 0x008000@Program`），或链路已建立后反复出现，或探针掉出 PnP | 探针/驱动真的没准备好 | 允许重新枚举、重新做可用性检查，不要立刻重连 |

判据只有一条：**`-150` 之前有没有 `DSS: connected`**。有 → 噪声；没有 → 按探针故障处理。

### 读回符号必须用当前器件的名字（同一次实测踩到）

| 写法 | 结果 | 正确写法 |
|---|---|---|
| `AdcRegs.ADCCTL1.all` | `identifier not found: AdcRegs`（2833x 才有 `AdcRegs`） | `AdcaRegs.ADCCTL1.all`（F2837xD 按 A/B/C/D 分实例） |
| `AdcaRegs.ADCTRL1.all` | `member 'ADCTRL1' not found`（F2837xD 无 `ADCTRL1/ADCTRL2`） | `AdcaRegs.ADCCTL1.all`、`ADCCTL2.all`、`ADCSOC0CTL.all` |
| `EPwm1Regs.CMPA.all` | 读回 128122880 / 34209792 等 >16 位的值，与 `TBPRD=4999` 矛盾 | `EPwm1Regs.CMPA.bit.CMPA`（本次 3492 → 1587 → 1245，与环路写占空比一致） |
| `EPwm1Regs.TBCTL.all` | `0`，这是**正确**值（CTRMODE=UP、`HSPCLKDIV/CLKDIV=/1`） | 不要因为读 0 就判"寄存器没配上" |

**`pwsh -File` 传数组参数会带字面引号**：`-Variables 'gFwId','usMainLoop'` 到达脚本时是**一个**字符串 `'gFwId','usMainLoop'`（含引号），于是路径正则不匹配，报 `USAGE: INVALID_READ_REQUEST`。改用 `-Variables gFwId,usMainLoop`（不加引号，脚本自己按逗号拆）或用 `& <脚本> -Variables 'gFwId','usMainLoop'` 在当前进程内调用。

## 单会话读数入口（取代已删除的只读脚本）

```powershell
# 低速：连接 -> 复位 -> 下载 -> 运行 -> 连续读 N 轮 -> 断开
pwsh -NoProfile -File "<skill>\scripts\ti_c2000_run_read.ps1" `
  -ProjectPath "<工程>" -Ccxml "<当前目标配置.ccxml>" `
  -Variables "<变量,寄存器>" -Rounds 10 -IntervalMs 500

# 高速：固件先冻结 DMA 缓冲，再在一个会话里批量搬出
pwsh -NoProfile -File "<skill>\scripts\ti_c2000_read_continuous.ps1" `
  -ProjectPath "<工程>" -Ccxml "<当前目标配置.ccxml>" `
  -FrozenBufferReady -ArrayName "<数组>" -Rows <行> -Columns <列>
```

两者都在 `connect()` **之前**设置实时选项（`HaltOnConnect=false`、`AutoResetOnConnect=false`、`RestartOnSymbolLoad=false`、`UseLegacyStopMode=false`、`AllowInterruptsWhenHalted=true`、`PoliteRealtimeMode=true`），加载一次、运行、读取，读取期间不 `halt()`；发现目标停机就 `FAILURE:` 退出，不用停核读数冒充运行态读数。固件里的 `ERTM` 与这些选项配合。详细边界见[单会话规则](single-session-read.md)。

就绪条件不要用“等一会儿再读”的旧写法（`-WaitFor` 已删除）。要证明初始化到某个阶段，就在固件里埋一个阶段变量并让读数的心跳/启动窗口判据覆盖它；宽松的 `.bss != 0` 可能只是 RAM 残值。目标显示 running 也不是应用心跳证明，须跨轮核对单调计数器递增。

大数组走 `ti_c2000_read_continuous.ps1`（固件先冻结缓冲或提供版本号）。裸 `connect → halt → readData → runAsynch` 已造成程序中断和继电器释放；[读取事故案例](debug-cases/dsp28335/2026-11-07-read-halt-bulk-array.md)保留原因与证据边界。`readData` 的页、字地址、宽度和数值范围须与表达式读数交叉验证，不因速度快就默认可信。

## 必要的 DSS API 备忘

| 用途 | CCS 12.8 记录 |
|---|---|
| 只装载符号 | `session.symbol.load(out)`；不等于下载程序。 |
| 读表达式 | `session.expression.evaluate(name)`；高频变量逐项读取不是原子快照。 |
| 符号地址 | `session.symbol.getAddress(name)`；本机该版本没有 `lookupSymbol()`。 |
| 读块 | `session.memory.readData(page, address, typeSize, count)`；**`typeSize` 是位宽（8/16/24/32），不是字节**（实测传 1/2 会报 "Invalid type size"）。C28x 用 16 读 16 位字、32 读 long；`page=1` 为数据空间；地址按 16 位字递增。本次 XDS100v2 测得 16 位批量读取约比逐点 `evaluate` 快 39 倍。 |
| 延时 | `java.lang.Thread.sleep(ms)`；Rhino 没有 `env.sleep()`。 |

换 CCS 版本时可先运行不连接目标板的 `scripts/dss_api_probe.js` 查看 API，再按当前版本验证实时选项。历史只读停核、构建后隐式 `loadti -l` 与浮点读回问题分别见[模式修复案例](debug-cases/dsp28335/2026-11-07-realtime-read-implicit-loadonly.md)和[浮点读回案例](debug-cases/dsp28335/2026-10-28-fpu-dss-float-readback.md)。

## 高速数据：由固件采集，JTAG 搬运缓冲

**不要用 DSS 直接读寄存器来做高速采样。** 事实：

| 项 | 数值 |
|---|---|
| DSS/JTAG 单次 `expression.evaluate` | 毫秒级（本机 10 变量/轮约 130 ms，约 13 ms/变量） |
| 等效逐项读取速率 | 本次约 13 ms/变量，即单变量约 77 次/秒；随探针和 CCS 变化 |
| 寄存器历史 | **不保留**：`ADCRESULTx` 只存最近一次转换，下一次即覆盖 |
| 两次 JTAG 读之间 | 几十 µs ~ ms 空档，中间数据全部丢失 |

因此 500 ns / 1 µs / 100 µs 这类采样由固件侧完成；可用 ADC+DMA，也可在经过周期预算验证的中断里写缓冲：

```
独立触发源（ePWM2 / CPU Timer，不占用主发波 ePWM1）
  → ADC SOC → EOC → DMA → RAM 数组（连续采集：ping-pong 双缓冲；
                                单次录制：采满即冻结的单缓冲）
  → 采满冻结（gBufFull=1）→ JTAG 搬数组 → CSV
```

要点：
- 触发源必须独立，改采样率不能改到主发波频率；
- 500 ns 间隔要求 `ACQPS` 很小（当前 `ACQPS=14` 约 510 ns，已超）；
- DMA 源地址、权限和 ADC 结果对齐方式须按当前器件手册与例程核对，不能把 F28379D 寄存器写法套到 DSP28335；
- 1 µs × 0.1 s = 100000 点，16 位原始值为 200 KB/通道；先核对当前器件可用 RAM 和链接布局；
- 不要把 DMA 指向 `AdcMirror`（28335 时代的坑，见 `c28x-pitfalls.md` §4.8.1）。

**读取判据**：见 [data-read-verdict.md](data-read-verdict.md)。按用途分别核对身份、活性、冻结窗口和范围；未提供的证据不得写成通过。

## 下载后要"验证真的在跑"：必须单会话（2026-11-13，F28379D 实测）

`ti_c2000_debug.ps1 -Run` 走 `loadti.bat -r -a`，运行命令后退出该调试会话。此后目标执行路径取决于器件、链接位置、启动配置和会话退出行为；不能一概说“必然从 Flash 启动”。

F28379D + XDS100v2 的现场记录：在同一 DSS server 内调用 `disconnect()` 后，`gMsTick` 从 527 归零，重连看到 `isHalted=true`。在当时 CCS/DSS 配置里尝试 `HaltOnDisconnect`、`ResetOnDisconnect`、`AutoResetOnDisconnect` 均得到 `Option not found`；未找到能复现 CCS GUI“断开不复位”行为的 DSS 选项。这是该组合的实测边界，**不是对全部 CCS 版本、器件、探针的 API 断言**。TI 的 API 将 `disconnect()` 和 `reset()` 列成两个不同方法；不能归因于编译器。该板曾用**现已删除**的另起只读入口尝试，输出如下（保留作坑记录，脚本不再存在）：

```text
SEVERE: C28xx_CPU1: Trouble Reading Register PC: (Error -1142) Device blocked
debug access because it is currently executing non-debuggable code.
READONLY_STATE_ERROR: target halted at connect; no resume attempted
FAILURE: READONLY_ACCESS_ERROR
```

要验证新加载的 RAM 固件，按执行模式在**同一个 DSS 会话里**连接、按需停核/复位、`memory.loadProgram(out)`、`runAsynch()`，然后运行态读数；至少两次读取应用计数器确认递增。程序启动后的读取阶段不再停核。每次调用单会话脚本都会重新加载，先规划好所需变量和数组，避免为补读重复调用。要点：

- 路径字符串用**正斜杠**（`E:/.../x.ccxml`）。JS 里 `\` 是转义符，`E:\3-1...` 会被吃成 `E:` + 制表符，报
  `Cannot read System Setup data from XML file`；
- `session.target.reset()` 在目标状态异常时会失败（`Error reseting target: Target reset failed. Error: -1`），
  改用 `session.target.halt()` + `loadProgram()` 即可；
- 结尾不要 `halt()`；在已出现断开后状态变化的板上，`disconnect()` 后**不能保证程序继续运行**，需要保留输出时应保持调试会话或另做实测；
- 判断"程序在跑"的三条实测判据（本板数值）：
  `gMsTick` 1 s 增量 ≈ 1000、`usMainLoop` 每秒数百万、外设寄存器与代码预期一致
  （如 `SciaRegs.SCICTL1.all == 0x23`、`SCILBAUD == 53`、`GPADIR.GPIO31 == 1`、`CpuTimer2Regs.PRD.all == 19999999`）；
- 输出类现象（LED）可每 200 ms 采样一次 `GpioDataRegs.GPADAT.bit.GPIO31`，序列里每段 2~3 个采样值
  同电平即对应 500 ms 翻转。
