---
name: ti-c2000-ccs-auto
description: 审查、编译和调试 TI C2000 CCS 工程。先选单步/连续运行模式与只读/本次加载读模式，再进入器件与 CCS、TI 算法库、调试经验三类资料；错误用独立离线查询模式。读数据保持同一 DSS 会话，下载须用户明确同意。
---

# TI C2000 / CCS 工程

本 skill 有**两种运行模式 × 两种读模式**，共用**三类资料入口**；另有只查记录的 **Error 模式**。模式由脚本互锁，不靠 AI 自觉。选定实际工程、器件、目标核、探针和任务后，先读工程入口文件，再调用本 skill 的脚本。用户没有要求上板时，只做文件与离线测试。

> **先交数据，再判可信度**：RAM/Flash、目标核、`.map` 与 `gRamProofTick` 是来源信息，不能作为数据判据，也不能因为位置未知或在 Flash 就拒绝下载、扣留已读数据。能访问目标时交付当次 CSV，并在同一次输出中写 `verdict.txt` 的 `OK/FAIL` 与具体原因。目标无法应答、没有常驻会话时没有当次数据可交。运行位置不靠 PC 或固定地址推测；有 `.map` 和[RAM 自证契约](references/ram-proof-firmware.md)时报告证据，否则标 `UNKNOWN`。这一调整仅完成离线验证，尚未上板复核。

## 两条硬约束（优先级高于本文其余所有内容）

### ① 修改本 skill 必须先获得用户授权

**未经用户明确同意，不得改动本 skill 的任何文件**（`SKILL.md`、`references/`、`scripts/`、`tests/`、`tools/`）。

- **回答提问 ≠ 授权修改。** 用户问「会不会…」「是否实现…」「为什么…」时，**只回答，不动手**。
- 用户提到某个机制"不错"、某种做法"应该有"，也**不等于**让把它做成实现。
- 要改就先说明：**改哪个文件的哪一段、改成什么、为什么**，等用户明确说「改」再动手。
- **一次授权只覆盖那一次改动**；下一次改动重新征求，不能顺延成"以后都能改"。
- 已改完的部分，用户说回滚就回滚，不保留"我觉得对所以留着"。

### ② 不得以任何方式阻碍下载

**本 skill 的任何脚本、判据、门禁都不得成为下载的障碍。** 下载只受一条约束：
**用户明确同意**（`-ConfirmLoad`）。除此之外不新增任何前置条件。

明确禁止：

- 新增「必须先进某项检查 / 必须有某条记录 / 必须某个文件存在」才允许 `-Start -ConfirmLoad` 的拦截；
- 把**推断性结论**固化成 `exit 4` 的硬拦截 —— 历史上的 `NON_DEFAULT_ENTRY_POINT` 就是这样把
  `.cproject` 声明的唯一正确入口挡在门外，代价是整个下午；
- 以 `ENTRY_CHECK_REQUIRED` / `MUTUALLY_EXCLUSIVE` / `STALE_*` 等名义扩大拒绝面。

**允许拒绝的只有两类**：① 缺 `-ConfirmLoad`（用户没同意下载）；② 探针或目标物理上不可用
（`NO_PROBE`、`TARGET_NOT_CONNECTED`）。
**其余情况一律放行**，把疑点写进输出作为 `WARN`/`CHECK` 提示，**不得 `exit` 非零**。

> 这两条是用户 2026-11-18 明确要求的，**不允许以"更好的工程实践"为理由绕过**。

## 先让 AI 找到正确入口

在新 CCS 工程创建之初，用 `tools/init_project_entry.ps1 -ProjectPath <工程>` 生成相同的 `AGENTS.md`、`CODEBUDDY.md`、`CLAUDE.md`；它遇到已有不同内容会拒绝覆盖，需人工合并。随后用 `tools/init_firmware_contract.ps1 -ProjectPath <工程>` 生成固件侧的判据模块（`ti_c2000_contract.h/.c`：`gFwId`、心跳、RAM 自证、DMA 帧符号，全部带中文注释说明为什么是判据）。该工具**只在显式调用时运行**，不随编译/下载自动改写源码；检测到工程已有同名符号就 `SKIP`，不覆盖手写代码。它只生成声明和 tick 函数，仍需人在 1 ms ISR / 主循环各调一次、并在 `.cmd` 里映射 `ramgs1` 等段名（输出会打印 `NEXT:` 提示）；可用 `-Identity/-Heartbeat/-RamProof/-DmaFrame` 只生成部分模块。开始工程操作前，读本文件和工程 `AGENTS.md`，再运行已安装 skill 的 `scripts/check_project_entry.ps1 -ProjectPath <工程>`。只有退出码 0 且 `RESULT: OK` 才继续；先清理工程里的旧 `ti_c2000_*.ps1/.js` 副本。每次脚本输出必须有 `SKILL   : ti-c2000-ccs-auto@<版本>`；版本由入口、运行脚本、资料和维护工具的内容哈希生成，脚本单独变更也会换号。成功还须退出码 0 与 `RESULT: OK` 同时成立。

CodeBuddy 源目录 `~/.codebuddy/skills/ti-c2000-ccs-auto` 是唯一维护源。改完先运行 `tools/sync_platform_copies.ps1 -DryRun` 检查 `PRUNE` 清单，再同步到 Codex 等平台副本；不要直接编辑平台副本。

## 模式、入口与互锁

| 维度 | 入口与行为 |
|---|---|
| 单步运行（默认） | `scripts/ti_c2000_service.ps1 -Start -ConfirmLoad [-Build] [-CorePattern <核名匹配式>]`：获准后构建、选定 `.out`、加载一次、运行并保留 DSS 会话。自动选择唯一 C28xx 核；多个 C28xx 核时默认 CPU1 并记录实际核名，选其他核才传 `-CorePattern`。只有列表确实无法确定核时才报参数错误。`-Status` 只报告；`-Stop` 会结束会话，可能使探针重新枚举，只在明确结束/更换镜像时使用。 |
| 连续运行（用户点名才启用） | `scripts/ti_c2000_iterate.ps1 -UserApproved -Expect ...`：最多 20 轮；每轮构建、加载、运行、读、判据。相邻下载尝试至少隔 5 秒；连接重试和探针恢复应留间隔。运行期间其他读/加载/Stop 由锁拒绝。 |
| `ReadOnly`（默认读） | `scripts/ti_c2000_run_read.ps1 -ProjectPath <工程> -Variables ...` 读慢变量；`scripts/ti_c2000_read_dma.ps1 -FrozenBufferReady -ArrayName ...` 读**连续录波冻结的数组**——这是唯一把波形取出来的方式。零构建、零加载、零重连、零因读而 `halt`；附着现有服务，在程序运行时读取。连续录波的原理、参数询问、RAM 算法与导出规范见[读模式](references/single-session-read.md)。 |
| `LoadRead`（本次获准加载后读） | 同一公开读入口加 `-Mode LoadRead -ConfirmLoad [-Build]`。若旧会话存在，先明确停止；服务加载新镜像并**留在该会话**，再调用正常 `ReadOnly` 判据；读完不 `halt`/断开。`-Standalone` 是同一路径的旧别名。`-MaxLoads/-Expect` 的循环每轮仍受 5 秒门限。 |
| Error（离线） | 一出现 `USAGE:` 或 `FAILURE:`，**先查** `scripts/ti_c2000_error.ps1 -Code <错误码>` 或 `-LogPath <日志>`，再读[错误索引](references/error-index.json)。输出 `CATEGORY`：parameter、validation、data_verdict、download_probe。查询不连接、不构建、不复位、不下载；新故障经实测复盘后录入第三类。 |

下载只能在用户明确同意后传 `-ConfirmLoad`，连续运行还要求用户明确提出反复运行并传 `-UserApproved`。`ReadOnly` 与 `-Build/-ConfirmLoad/-Expect/-MaxLoads>1` 互斥；`-NoProbeCheck/-AllowUnverified/-NoHeartbeat` 的只读绕过已禁用。`RESULT: FAIL`、缺 `RESULT: OK`、非零退出码都不是成功；不得用另一次烧录“凑出”读数。

其余入口职责：`scripts/ti_c2000_build.ps1` 只编译；`scripts/ti_c2000_debug.ps1` 只做探针检查或获准的显式加载/运行；`scripts/ti_c2000_readmode.ps1` 管互锁与时间门限；`scripts/ti_c2000_loadcount.ps1` 管成功加载记录；`scripts/ti_c2000_check_read.ps1` 离线核对 CSV。这些脚本不提供另一条绕过常驻服务的读数路径。

## 一次成功下载的固定顺序（2026-11-18 F28379D/CPU1 + XDS100v2 实测）

```powershell
pwsh -NoProfile -File scripts\ti_c2000_build.ps1   -ProjectPath <工程>            # 不要传 -EntryPoint
pwsh -NoProfile -File scripts\ti_c2000_service.ps1 -ProjectPath <工程> -Start -ConfirmLoad
pwsh -NoProfile -File scripts\ti_c2000_run_read.ps1 -ProjectPath <工程> -Variables <变量,寄存器>   # 只读附着，不重烧
```

**入口点必须是 `_c_int00`。绝不能传 `-EntryPoint code_start`**（2026-11-18 两次实测，代价是整个下午）：

| 构建方式 | `.out` | `.map` 入口 | 首块写入 | 结果 |
|---|---|---|---|---|
| 不传（默认） | 592642 B | `_c_int00` | `0x16a8` 整块 | LOAD #103/#104 `RESULT: OK` |
| `-EntryPoint code_start` | 592810 B | `code_start` | `0x800`（一个 RAMLS 块） | `-1041` + FTDI `-150`，且把 CPU 推进不可调试状态 |

`.cproject` 里的 `ENTRY_POINT=code_start` 是给 **Flash 构建**用的；强加给 RAM 下载会让加载器分片写。
`service.ps1` 现在下载前检查 `.map` 的 `ENTRY POINT SYMBOL`，非 `_c_int00` 直接
`FAILURE: NON_DEFAULT_ENTRY_POINT`（exit 4）拒绝、不碰板子；逃生需显式 `-AllowNonDefaultEntry`。

成功必须三条同时成立，缺一不得写"下载成功"：`.map` 里 `FLASHA~FLASHN` 的 used 全为 0 **且 `ENTRY POINT SYMBOL: "_c_int00"`**；日志出现 `DSS: loaded`（即 `memory.loadProgram` 成功）；`runAsynch` 后应用计数器跨轮递增。入口走 `_c_int00` 会跳过 `codestart` 里的 `WD_DISABLE` 分支，本工程由 `InitSysCtrl()` 内的 `DisableDog()` 兜底（104 次加载无看门狗复位），细节见[RAM 与链接](references/ram-and-linker.md)「入口点」。

### 成功案例（2026-11-18 实测，照抄可复现）

环境：F28379D/CPU1（LAUNCHXL-F28379D）+ **XDS100v2，实物串号 `TI90I42A`** + CCS 12.8.1（F:\ccs）+ 编译器 15.12.1.LTS。

```powershell
# 0) 探针自检（5 层判据；软件层优先，失败会明确说"改 ccxml"，不会让你动硬件）
pwsh -NoProfile -File scripts\ti_c2000_debug.ps1 -ProjectPath <工程> -ProbeCheckOnly
#    期望 5 行齐全：
#      [1/5] Windows 枚举 : 3 个可用设备 / 9 个幽灵(Unknown 或 Present=False)
#      [2/5] FTDI 驱动    : OK（xds100serial 能打开探针）
#      [3/5] 实物串号     : 0403/a6d0  XDS100v1/v2  TI90I42A  Texas Instruments Inc.XDS100 Ver 2.0
#      [4/5] ccxml 选择   : 按串号 TI90I42A
#      [5/5] 结论         : 软件层全部通过（ccxml 串号与实物一致）—— 不要动硬件

# 1) 编译（不要带 -EntryPoint）
pwsh -NoProfile -File scripts\ti_c2000_build.ps1 -ProjectPath <工程> -CcsRoot F:\ccs
#    期望：compile OK / link OK / 0 warnings；Debug 里 .out 大小与入口点见下表

# 2) 下载到 RAM 并常驻（用户明确同意后才加 -ConfirmLoad）
pwsh -NoProfile -File scripts\ti_c2000_service.ps1 -ProjectPath <工程> -Start -Build -ConfirmLoad
#    期望：ENTRY : _c_int00 / LOAD : #N / RESULT: OK

# 3) 只读验活（零下载）
pwsh -NoProfile -File scripts\ti_c2000_run_read.ps1 -ProjectPath <工程> -Variables gMsTick,usMainLoop -Mode ReadOnly
pwsh -NoProfile -File scripts\ti_c2000_read_dma.ps1 -ProjectPath <工程> -FrozenBufferReady -ArrayName BuffA -Rows 5000 -Mode ReadOnly
```

实测成功记录：**LOAD #103/#104/#105 连续三次 `RESULT: OK`**，`gFwId=65537`，`gMsTick` 跨轮递增，
`read_dma BuffA` 5000 点全量返回。四个必须同时满足的指纹：

| 项 | 正确值 | 错了会怎样 |
|---|---|---|
| `.ccxml` 的 `Emulator Selection` | `Value="1"` + 串号 `TI90I42A` | 默认 "Only one XDS100" 会打开**幽灵实例** → `-151`（PnP 看着全 OK） |
| `.out` 大小 / `.map` 入口 | 592642 B / `_c_int00` | 592810 B / `code_start` → `.text` 按 `0x800` 分片写 → `-1041` + `-150` |
| connect 前 realtime 选项 | **不设**（session 默认 off） | 设 `PoliteRealtimeMode=true` → `-1133` 直接拒绝连接 |
| `.text` 段布局 | `> RAMCODE` 单块（0x8000~0xA7FF） | `>>` 跨片 → `-1041`（`Length 0x7ff/0x800` 是分片指纹） |

排查顺序固定为：**探针串号 → 入口点 → realtime → 段布局 → 才怀疑硬件**。
`reset failed. Error: -1` / `target is not connected` 先原样重试一次，仍失败再断电。

### 探针自检的 5 层判据，以及"什么时候才允许动硬件"

| 层 | 判据 | 失败含义 | 该改什么 |
|---|---|---|---|
| 1 Windows 枚举 | 可用设备数 / 幽灵数（`Unknown` 或 `Present=False`） | 0 个可用 → `NO_PROBE` | **只有这一层代表"真的没插"**，此时才让人查插线/供电 |
| 2 FTDI 驱动 | `xds100serial -l` 能否列出探针 | 打不开 | 先看第 4 层；**有活跃 DSS 会话时本层 SKIP**（会话占着 FTDI 句柄，属正常，不是故障） |
| 3 实物串号 | `xds100serial` 输出的串号（PnP 的 InstanceId 末尾多一位，`...TI90I42AB` → `TI90I42A`） | 读不到 | 会话占用属正常；否则看第 2 层 |
| 4 ccxml 选择 | `Emulator Selection` 是否按串号、且该串号在实物列表里 | 默认 `Only one` + 有幽灵 → `PROBE_SELECTION_AMBIGUOUS`；串号不符 → `PROBE_SERIAL_MISMATCH` | **只改 ccxml 一行**（`-- Enter the serial number`）。**不拔线、不改 BOOT** |
| 5 结论 | 上面四层 | — | 软件层全过就明确写"不要动硬件"，不写含糊的硬件建议 |

**型号无关**：`-ProbeCheckOnly -Deep` 会额外让 DSS 自己开一次探针（connect → isConnected → disconnect，
**不加载程序**），这是唯一对 XDS100/XDS110/XDS200/XDS560v2/板载探针都成立的判据（xds100serial 只认识
XDS100；XDS200 没有串号工具；`dbgjtag` 只吃 CCS 生成的 `.dat`）。各型号的枚举名、串号工具、复用方式
（`-ProbeSerial` / `TI_C2000_PROBE_SERIAL` / `targetConfigs\probe-serial.txt` / 自动发现）见
[探针型号与识别](references/probe-models-and-detection.md)。

**硬规则（2026-11-18 惨痛教训）：**

- **`BOOT` 引脚只决定目标从哪里启动，与探针能否被 DSS 打开无关。** 任何探针层报错都不该拿 BOOT 当对策。
- **拔插 USB 只在两种情况下提出**：① 第 1 层 0 个可用；② 第 2 层失败 **且** 第 4 层已正确按串号选、无幽灵、无会话占用。
- **幽灵实例只有 `Get-PnpDevice` 数得出来**，`Get-CimInstance Win32_PnPEntity` 只返回当前存在的设备（实测 3 条 vs 12 条），所以别用后者判断"是否有多块探针"。

详细版（含全部原始输出与 `.bak` 恢复步骤）见工程根的 `DOWNLOAD-SUCCESS.md`。

失败先看 `<工程>\readout\.service\server.log`，不要先怀疑硬件：

- `Error -1133` 之后紧跟 `DSS: PoliteRealtimeMode off, retrying connect for -1133` 是**自动降级并重连**的过程，不是失败；实时选项只属于当次会话，下一次下载会重新以 realtime on 开始、再自己降级，**不需要人工去关**；`loadti` 从不设它，所以 `loadti` 也报 `-1133` 时原因就不在实时模式；
- `-150` 判据看**影响**不看位置：本次 `DSS: connected` **之前** 3 次（GEL 试探读）、链路建立后还有 1 次 `JTAG Communication Error`，都没阻止 `DSS: loaded`；只有同一操作反复失败、出现 `Target failed to write`、或探针掉出 PnP 才按真故障处理；
- `reset()` 报 `-6310`/`Target reset failed` 仍可继续到 `loadProgram`，只有 `DSS: loaded` 才算写成功；
- `loadProgram` 真失败时先跑 `scripts\check_ram_layout.ps1` 看是否 `[BAD]` 跨片（`-1041` 典型），再查该 `.out` 是否 Flash 链接。

读回寄存器和变量用**当前器件**的符号名，不要照抄别的芯片：F2837xD 是 `AdcaRegs.ADCCTL1/ADCCTL2/ADCSOC0CTL`，**没有** `AdcRegs`、**没有** `ADCTRL1`（那是 2833x）；`EPwm*Regs.CMPA.all` 可能读回超过 16 位的拼合值，一律读 `.bit.CMPA`。多值参数写 `-Variables a,b`（不加引号）或用 `& 脚本.ps1 -Variables 'a','b'`；`pwsh -File` 会把带引号的整串当成**一个**字符串，触发 `USAGE: INVALID_READ_REQUEST`。细节与原始日志见[DSS 下载与运行态读取](references/dss-debug.md)。

## 读前告知、读后判据

读前先报告：所选 `.out/.map` 与 SHA256、工程内源码和构建配置是否比该产物新、目标核与 RAM/Flash 自证、探针是否枚举且可用、DSS 进程与目标连接是否仍有效、运行的固件身份、累计成功加载次数及本会话加载序号、应用心跳是否在推进。工程外链接源码的新旧不能靠工程内时间戳证明，须结合构建记录和唯一 `gFwId`。仅有进程 PID、`connect()` 没抛异常、`isHalted()==false`、符号能解析，任何一项都不构成充分证明。`dssLinkIsUp` 要显式验证 `target.isConnected(true)` 再查询目标。

读后还要查：采样轮次完整，心跳/可选速率、固件身份、数值有限性与指定范围；连续录波数组另查完成标志、复制前后标志和点数是否齐全。疑点应让当次数据和 `result: FAIL` 判据同时交付，清除旧成功结论；不能把“取到数字”写成“数据可靠”。变量轮询不能还原快速波形。详细阈值见[读数判据](references/data-read-verdict.md)。

**时间门限**由 `references/firmware-contract.json` 维护：下载尝试之间至少 5000 ms；连续数据请求之间至少 400 ms；重连至少留 400 ms 且须再次验证探针可用。编译成功后加载的必须是**选定的那份** `.out`，比源文件旧就拒绝。`readout/load-count.json` 记录成功加载次数；失败或部分写入的 `loadProgram` 尝试还需看 DSS 日志，不能把该计数当成所有物理写入次数。

连续运行的当前实现每轮会显式 `-Stop` 再 `-Start`，因此**仍会在不同下载轮次间重连**。Stop 后先等 Windows 重新枚举；Start 时按所选 `.ccxml` 的历史记录计算 Stop→DSS 接入间隔，首次连接失败且尚未加载时增加 5 秒并用新 DSS 进程重试一次，成功与失败时间供下次二分估计。PnP 不等于驱动可打开，只有 DSS 连接并验证目标才算接入成功。普通连续读保持同一会话。若 Stop 未干净退出或探针未恢复，循环中止；此恢复算法只有离线测试，当前板和探针的实际秒数待上板测定。

## 三类资料入口（两个运行模式共用）

| 类别 | 进入时机 | 首先读 |
|---|---|---|
| 一、器件与 CCS 工程 | 换 DSP28335、F28379D 或新芯片，处理板、探针、核、`.cproject`、`.ccxml`、编译器、`.cmd/.map`、启动与外设配置。 | [器件与工程](references/device-platform.md)、[RAM/链接](references/ram-and-linker.md)、[TI 同器件外设例程](references/peripheral-examples.md)。探针与器件差异仅放在本类。**换探针型号/串号一律用 `scripts/ti_c2000_set_probe.ps1 -Probe v1\|v2\|v3 -Serial <串号> [-DryRun]`（`-List` 列可选连接）：它只做最小改写，遇到缺 connection/device/platform 的半个 `.ccxml` 会拒绝并报 `FAILURE: CCXML_INCOMPLETE`，不会删节点。** |
| 二、TI 算法库 | 找现成 DCL、DMC、C2000Ware、controlSUITE、SolarLib，或移植控制/测量/PLL 等。 | [库入口](references/ti-algorithm-libraries.md)、[SolarLib 目录](references/solarlib-catalog.md)。SPLL 另读[完整 SolarLib PLL 文档](references/spll-pll-algorithms.md)；dq/abc 另读[变换规范](references/dq-transforms.md)。先查本机库、示例、头文件和链接要求。 |

**写正弦/余弦前先看 TMU**：目标器件带 TMU（F2837xD/F2838x/F2807x/F28004x/F28P5x 等）时，一律先用 `__sinpuf32()` 实时算，**不要默认离线查表**——查表会让幅值/频率在运行期不可改，等需求变成"PI 在线调幅"就得推翻重写。哪些器件有 TMU、什么时候才允许降级到查表，见[库入口的正弦章](references/ti-algorithm-libraries.md)。
| 三、调试经验 | ADC、SCI 串口、SPI、原子访问、eCAP 等任何器件/模块的实测异常。 | [调试经验索引与归档规则](references/debugging-experience.md)、[判据](references/data-read-verdict.md)。保存症状、原始数据/日志、器件和模块、复现条件、根因证据及适用范围；新案例登记索引并运行 `scripts/check_debug_catalog.ps1`。 |

同一任务可查多类，但只把新事实归入其主类：eCAP 配置与官方模板在第一类，eCAP 实测故障在第三类。不能把 DSP28335 或某个 XDS 的现场现象推广到所有芯片/探针。第二类的 SolarLib、DCL、DMC 文档和第一类的 28379D 功能不得因精简入口而删除。

## 维护与离线复核

固件符号和时间门限先改 `references/firmware-contract.json`，再运行 `tools/audit_fw_contract.ps1`。出错先用 Error 模式；新增错误先写 `references/error-index.json` 的处理步骤及类别，再运行 `tools/audit_error_index.ps1` 和 `tools/audit_error_prefix.ps1`，实测案例另归第三类。新增器件进第一类，新增 TI 库进第二类。改后运行离线 `tests/test_*.ps1`（不运行需真机的 `test_e2e_readonly.ps1`）、`tools/audit_js_identifiers.ps1`、`tools/audit_dead_params.ps1`、`tools/audit_fw_contract.ps1`、`scripts/check_debug_catalog.ps1` 和 Codex `quick_validate.py`，检查输出与退出码。**测试脚本自身必须在成功路径末尾显式 `exit 0`**：否则 `LASTEXITCODE` 会残留最后一次子进程调用的失败码（实测 `test_run_modes.ps1` 因最后一步是故意拒绝而输出 `RESULT: OK`/exit 3，`test_compiler_selection.ps1` 因最后一步是故意失败的编译而输出 `RESULT: OK`/exit 1），显示通过却是失败退出码。上板结论必须另标“实测”，不能拿离线测试代替。
