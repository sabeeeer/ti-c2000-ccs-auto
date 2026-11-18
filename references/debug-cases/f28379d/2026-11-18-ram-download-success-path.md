# RAM 下载一次成功的完整路径；读回符号踩到 2833x 名字与 `.all` 拼合值

## 身份与适用范围

- 器件、板卡版本、目标核：TMS320F28379D / LAUNCHXL-F28379D / CPU1
- 模块/接口、工程与版本：JTAG 下载 + DSS 运行态读取；`F28379D_CPU1_BareMetal`（`CPU1_RAM` 配置，21 个源文件，COFF）
- CCS、编译器、C2000Ware/其他库、探针：CCS 12.8.1（F:\ccs）+ `ti-cgt-c2000_15.12.1.LTS`（C:\ti\ccsv6）；XDS100v2（Windows 枚举为 `XDS100 Class Debug Port`）；目标配置 `targetConfigs\TMS320F28379D.ccxml`
- 状态：**已回归**
- 已验证的器件/板卡：上述一块板 + XDS100v2；未验证：XDS110、DSP28335、CPU2 核

## 现象和复现

- 现象、检索词：工程从未构建过（无 `Debug` 目录），`.cproject` 的 `Linker Command Files` 为空；第一次探针检查 `NO_PROBE`，插上后 `RESULT: OK`；下载一次成功并运行。读回时先后报 `identifier not found: AdcRegs`、`member 'ADCTRL1' not found`、`CMPA.all` 读回 1e8 量级、`USAGE: INVALID_READ_REQUEST`。
- 复现条件与最小步骤：

```powershell
pwsh -NoProfile -File scripts\ti_c2000_build.ps1   -ProjectPath <工程> -Stage -EntryPoint code_start
pwsh -NoProfile -File scripts\ti_c2000_service.ps1 -ProjectPath <工程> -Start -ConfirmLoad
pwsh -NoProfile -Command "& 'scripts\ti_c2000_run_read.ps1' -ProjectPath '<工程>' -Variables usMainLoop,EPwm1Regs.TBPRD -Rounds 4 -IntervalMs 400"
```

- 期望值与实测值：
  - 构建：`sources: 21   warnings: 0`、`compile: OK`、`link: OK`、`RESULT: OK`，`.out` 559948 B。
  - 链接布局（`.map` → `MEMORY CONFIGURATION`）：`codestart 00000000`、`.cinit 00000123`、`.text.1 00008000`、`.text.2 00008800`、`.text.3 0000B000`、`.stack 00000400`；**`FLASHA~FLASHN` 的 used 全部 `00000000`**；`ENTRY POINT SYMBOL: "code_start" address: 00000000`。
  - 下载：`LOAD #1`、`SERVICE: RUNNING (pid 56348)`、`CORE: selected C28xx_CPU1`、`IMAGE: gFwId = 65537`。
  - 运行：`usMainLoop` 369,300,672 → 374,378,552 → 378,189,143（3 轮，间隔 400 ms）；`gFwId = 65537` 跨轮一致；`EPwm1Regs.TBPRD = 4999`；`EPwm1Regs.AQCTLA.all = 18 (0x12)`（ZRO=SET + CAU=CLEAR，与 `epwm.c` 写法一致）；`EPwm1Regs.TBCTL.all = 0`（CTRMODE=UP、分频 /1，**这是正确值**）；`AdcaRegs.ADCCTL1.all = 900 (0x384)` 中 `ADCPWDNZ=1`；`AdcaRegs.ADCCTL2.all = 6`；`AdcaRegs.ADCSOC0CTL.all = 0x50000E`。
- 原始证据：
  - `<工程>\readout\.service\server.log`（2026-11-18 15:59:13 起）、`state.json`（pid/out/outSha256/loadIndex=1）
  - `<工程>\readout\data\data.csv`、`<工程>\readout\check\verdict.txt`（`result: OK`，`preflight_issues: none`）
  - 构建日志 `<TEMP%\ti_c2000_build\F28379D_CPU1_BareMetal\build.log`；`.map`/`.out` 在 `<工程>\Debug\`

## 排查与结论

- 查过的当前器件 TI 例程、手册和工程配置：`ti\headers\include` 的 F2837xD 头文件（`AdcaRegs` 分实例、无 `ADCTRL1`）、`ti\common\cmd\2837xD_RAM_lnk_cpu1.cmd`、工程 `Hardware\EPWM\c\epwm.c`、`.cproject`（`CPU1_RAM`、`OUTPUT_FORMAT=COFF`、`ENTRY_POINT=code_start`）。
- 已排除的原因及证据：
  - 硬件/线/供电：同一探针同一 ccxml 后续连续 3 次只读附着全部 `RESULT: OK`，读数与源码常量吻合。
  - 链接脚本能不能链上：`ti_c2000_build.ps1` 按工程内 `*.cmd` 全量喂链接器，本次自动取到 `2837xD_RAM_lnk_cpu1.cmd` + `F2837xD_Headers_nonBIOS_cpu1.cmd`，链接 0 错误。
  - "是 Flash 镜像"：`.map` 里 Flash 全部 used=0，排除。
- 根因（已证实），四条：
  1. **下载确实只写 RAM**：`.out` 段地址全在 `0x000000~0x01BFFF`，`memory.loadProgram` 不触发 Flash 擦写。
  2. **`-1133` 由服务自动降级解决**：`server.log` 里 `Error -1133 ... non-debuggable code` 后紧跟 `DSS: PoliteRealtimeMode off, retrying connect for -1133`，随后 `DSS: connected (realtime off)`、`DSS: reset`、`DSS: loaded`。降级逻辑见 `2026-11-18-text-cross-block-and-flash-erase-brick.md` 根因二（该案例是失败侧），本条是**成功侧**证据。
  3. **`-150` 是瞬时噪声，`-6310` 不是**：`-150` 本次共 4 次（`DSS: connected` 之前 3 次 GEL 试探读、链路建立后 1 次 `JTAG Communication Error`），都没阻止 `DSS: loaded`；判据是"要做的操作还能不能成功"，不是出现位置。`-6310`（PRSC 读失败）伴随 `Target reset failed. Error: -1`，**真的把链路弄丢了**，靠 `dssResetVerified` 的重连分支（3 次、退避 900/1800/2700 ms）在第 3 次才恢复 —— 它不是"可以忽略的噪声"，但也不是"下载失败"。
  4. **读回失败全是符号名问题**：
     - `AdcRegs` → F2837xD 无此符号，按实例是 `AdcaRegs`；
     - `ADCTRL1/ADCTRL2` → F2837xD 无，控制寄存器是 `ADCCTL1/ADCCTL2`、SOC 是 `ADCSOC0CTL`；
     - `EPwm1Regs.CMPA.all` 读回 128122880 / 34209792 / 236388352 / 106823680（>0xFFFF），与 `TBPRD=4999` 矛盾；同轮 `.bit.CMPA` 读到 3492/1587/1245 且随环路变化，**`.all` 在 16 位比较寄存器上不可信，机制未定位**（`references/environment.md` 另有一例 `CMPA.all=0xCCCC0000`）；
     - `pwsh -File ... -Variables 'a','b'` 会把整串（含单引号）当**一个**参数传入（实测 `COUNT=1 / ITEM=['gFwId','usMainLoop']`），路径正则不匹配 → `USAGE: INVALID_READ_REQUEST`。
- 修复/绕过措施与代码位置：不改固件；SKILL.md 新增"一次成功下载的固定顺序"，`references/dss-debug.md` 新增同名章节（日志判读表 + 读回符号对照表）。工程侧仅按 skill 要求生成 `AGENTS.md`/`CODEBUDDY.md`/`CLAUDE.md`。
- 回归方式、构建结果、上板结果：同条件连续 4 次只读附着（`Rounds 3~6`）全部 `RESULT: OK`，`verdict.txt` `result: OK`；`.map` Flash used 全 0 在两次构建后一致。未完成项：`.all` 拼合值的机制未定位；CPU2 未验证。
- 与旧案例/其他器件的相同点和差异：与 `2026-11-18-text-cross-block-and-flash-erase-brick.md` 互补（那条讲 `-1133` 修好后仍 `LOAD_FAILED`，因为 `.text` 跨片 + Flash 被擦）；与 `2026-11-07-adc-chain-port-audit.md` 的 2833x 写法差异正好是 `AdcRegs` vs `AdcaRegs`。**不要把 2833x 的 `AdcRegs.ADCTRLx` 抄到 F2837xD。**

## 本轮踩到的全部错误（原文 → 根因 → 处理）

同一天、同一块板、同一个探针上出现的 11 条"看起来是错"的输出，逐条给出判据。**其中 3 条根本不是故障（#1 时序、#8、#9），#7 是读数坑而不是固件故障**，把它们当故障会白白怀疑硬件。`-1133` 单独列在 #11 并展开见下节。

| # | 原文（关键行） | 阶段 | 根因 | 处理 / 判据 |
|---|---|---|---|---|
| 1 | `PROBE : NOT FOUND` → `FAILURE: NO_PROBE` → `REASON: no JTAG probe enumerated by Windows (checked: XDS*, Spectrum Digital, Blackhawk, SEGGER, Debug Probe)`，exit 3 | 探针检查 | 当时探针确实没被枚举（用户尚未插好/驱动尚未完成枚举） | 不是结论。插好后**同一条命令**变成 `PROBE : XDS100 Class Debug Port` / `XDS100 Class Auxiliary Port` / `XDS100 Class USB Serial Port (COM11)` + `RESULT: OK`。一次 `NO_PROBE` 不得推出"硬件坏了" |
| 2 | `VIOLATION: project root is missing AI entry file(s): AGENTS.md, CODEBUDDY.md, CLAUDE.md` / `RESULT: FAIL`，exit 1 | 工程入口检查 | 工程是从未接过 skill 的新工程 | `tools/init_project_entry.ps1 -ProjectPath <工程>` 生成三份相同入口文件，复检 `RESULT: OK`（3 份、0 副本） |
| 3 | `LINK : .cproject declares ENTRY_POINT=code_start; NOT applied (use -EntryPoint code_start to force it)`，随后 `.map` 写 `ENTRY POINT SYMBOL: "_c_int00" address: 000088e2` | 构建 | `.cproject` 的 `ENTRY_POINT` 不被构建脚本自动透传，链接器用了默认入口 `_c_int00` | 加 `-EntryPoint code_start`；改后 `.map` 变成 `ENTRY POINT SYMBOL: "code_start" address: 00000000`。后果：默认入口会**跳过 `codestart` 里的 `WD_DISABLE`**（本工程靠 `InitSysCtrl()` 关狗才没出问题，不能依赖） |
| 4 | `USAGE: INVALID_READ_REQUEST` / `REASON: use simple read paths, at least two rounds and nonnegative timing values`，exit 2，连续两次（换变量集也一样） | 读命令解析 | `pwsh -File ... -Variables 'gFwId','usMainLoop'` 把**带单引号的一整串**当**一个**参数传入 | 用临时脚本实测确认：`COUNT=1`、`ITEM=['gFwId','usMainLoop']`（引号是字面量）。改 `-Variables gFwId,usMainLoop`（不加引号）或 `& 脚本.ps1 -Variables 'a','b'` |
| 5 | `FAILURE: VALUE_READ_FAILED` / `REASON: AdcRegs.ADCTRL1.all JavaException: ... Error evaluating "AdcRegs.ADCTRL1.all": identifier not found: AdcRegs` / `HINT : identifier not found - check the exact spelling against the .map of THIS build` | 读回 | F2837xD 没有 `AdcRegs`（那是 2833x 的单一 ADC 包装） | 用实例名 `AdcaRegs`（B/C/D 同理）；同时 F2837xD 也没有 `ADCTRL1/ADCTRL2` |
| 6 | `FAILURE: VALUE_READ_FAILED` / `REASON: AdcaRegs.ADCTRL1.all ... member 'ADCTRL1' not found` / `HINT : member ADCTRL1 was not found; check the selected device header and register field path` | 读回 | 同上：`ADCTRL1` 是 2833x 名字 | F2837xD 用 `ADCCTL1`、`ADCCTL2`、`ADCSOC0CTL`；本次实测 `AdcaRegs.ADCCTL1.all = 900 (0x384)`、`ADCCTL2.all = 6`、`ADCSOC0CTL.all = 0x50000E` |
| 7 | 同一 CSV 列 `EPwm1Regs.CMPA.all` = 128122880 / 34209792 / 236388352 / 106823680 | 读回 | **未定位**。16 位比较寄存器读回 >0xFFFF，与 `TBPRD=4999` 自相矛盾；同轮 `.bit.CMPA` = 3492 / 1587 / 1245（随环路变化，合理）。`references/environment.md` 另有一例 `CMPA.all=0xCCCC0000` | **一律读 `.bit.CMPA`**；看到 `.all` 超过 16 位就丢弃该列，不要拿它算占空比 |
| 8 | `CHECK heartbeat gRunMs: MISSING (not defined in this build)`；`CHECKVAR gMsTick: MISSING/UNREADABLE - skipped`；`CHECKVAR gRunMs: MISSING/UNREADABLE - skipped`；但 `HEARTBEAT: OK` 且 preflight 有 `ALIVE : gMsTick 43126 -> 43520` | 采集后判据 | `CHECKVAR` 只检查 **CSV 列**：心跳候选没写进 `-Variables` 就没有这一列，于是一律报 skipped（`ti_c2000_check_read.ps1:103`）。`gRunMs` 则是该工程确实没定义 | 判据看 `HEARTBEAT: OK`（至少一个候选跨轮递增）+ preflight 的 `ALIVE` 行。**`CHECKVAR ... MISSING/UNREADABLE` 不能推出"固件没有该符号"** |
| 9 | `Get-Content: Cannot find path '...\readout\data\data.csv' because it does not exist.` | 读后 | 上一轮 `VALUE_READ_FAILED` 已按规则清理旧成功文件（`data-read-verdict.md`「开始新读时清理上一轮成功文件」） | 属正常清理，不是磁盘/写入故障。**失败轮次后不得把旧 CSV 当本次数据**；要留证据就读本轮控制台输出与 `verdict.txt` |
| 10 | `FAILURE: TEST_FAILED` / `REASON: bank selector rationale missing` | skill 自身离线测试 | `tools/init_firmware_contract.ps1` 生成的头注释缺 "为什么要有 `gDmaHalf`" 这一句，而 `tests/test_init_firmware_contract.ps1:46` 要求它存在（该工具与测试都是此前未提交的新件） | 在生成器里补一行 `gDmaHalf : 选块标志——读侧无法自己判断哪块缓冲最新...`；复跑 `RESULT: OK` |

| 11 | `C28xx_CPU1: Error connecting to the target: (Error -1133 @ 0x0) Device blocked debug access because it is currently executing non-debuggable code. You may retry after the device has had time to enter debuggable code, or you may cancel, disable realtime mode, and then attempt to connect.` | 下载连接（15:59:13） | `ti_c2000_service.ps1` 为运行态读打开了 `PoliteRealtimeMode=true` + `AllowInterruptsWhenHalted=true`；目标正在跑应用，拒绝带实时访问的连接 | 服务自动降级（见下节）；`DSS: loaded` 之前还经历 `-6310` → reset failed → 链路丢失 → 两次重连失败，第 3 次重连才写入成功。**这不是硬件故障**，也不是"这次下载失败" |

另外两条**看起来像失败、实际是正常元数据**的输出，也记在这里：

- `LOCATION : RAM (ramLinked=True advancing=False (no readable counter among gRamProofTick); updater TiC2000_RamProofTick in not-in-map; ...)` —— 该工程没有固件契约符号，RAM 自证只能靠 `.map`（`ramLinked=True` + Flash used=0）。`advancing=False` 不阻挡下载、不扣留数据（`SKILL.md` 顶部约定）。
- `NOTE : .map and .out timestamps differ by more than two minutes`（本次未出现，但同族）—— 只是提示地图可能描述另一次构建，不拒读。

### 别人给的错误码表与本工程日志的对照（没上板查过的不入库）

| 码 | 本工程 `server.log` 实际出现 | 是否写入 skill |
|---|---|---|
| `-1133` | 2 次（L5 报错、L10 降级重连） | 是（见下节） |
| `-150` | 5 次（L14/L18/L22 连接阶段 + L31 + **L93 链路已建立之后**） | 是，按"影响"判据而不是"位置" |
| `-6310` | 1 次（L29 `Failed CPU Reset`） | 是（本轮新增条目） |
| `-151` | 2 次（L43/L48，重连阶段） | 本轮不入库（探针记录里已有；用户明确"先不管"） |
| `-1137` / `-154` / `-1041` / `-2131` / `-1138` / `-1142` | **0 次** | 否。本工程从未出现，不照抄外部表格 |

结论：外部表格按"CPU 状态 / 探针配置 / FTDI 配置 / FTDI 写入 / probe 通用"分层没有和本工程证据冲突，但本工程**只有 `-1133`、`-150`、`-6310` 带直接日志证据**；其余码不因"表上写了"就入库（`-1041`/`-1138` 的既有条目来自另一块板的实测案例，另行引用）。

## `-1133` 专项：它到底是谁的问题

**结论先行：本项目的 `-1133` 是 skill 自己的连接选项造成的，不是板子、不是 Flash、也不是"CPU 跑飞"。** 它发生在 connect 阶段，服务为了运行态读打开了 `PoliteRealtimeMode=true` + `AllowInterruptsWhenHalted=true`；TI 原文给的出路就是"关实时模式再连"。把降级逻辑（关这两个选项 + 重连）写进 `dssConnectVerified` 之后，这条错误消失，后续连接、复位、写 RAM、运行全部正常。

**因此本记录不保留任何"不可降级的 `-1133` / 硬件损坏类 `-1133`"的说法** —— 那是把本 skill 自己的缺陷误记成板子状态（实测复盘：该错误在修好降级逻辑后即消失）。

### 真实时间线（`server.log` 原文，2026-11-18 15:59:13 起，L 为行号）

| 行 | 日志 | 说明 |
|---|---|---|
| L5 | `Error -1133 ... non-debuggable code ... disable realtime mode, and then attempt to connect` | 第一次 connect 被拒 |
| L10 | `DSS: PoliteRealtimeMode off, retrying connect for -1133` | 自动降级：`disconnect()` → 500 ms → 关 `PoliteRealtimeMode`/`AllowInterruptsWhenHalted` → 重连 |
| ~L12 | `DSS: connected (realtime off)` | 连接建立（括注说明降级生效） |
| L14-L22 | `Trouble Reading Memory Block at 0x5f05e / 0x5f060 / 0x7026d ... (Error -150) ... FTDI driver functions` | 连接阶段 GEL/仿真包试探读失败，不影响后续 |
| L29 | `Failed CPU Reset: (Error -6310) PRSC module failed to read a register` | 复位读 PRSC 失败 |
| L31 | `JTAG Communication Error: (Error -150)` | 同一阶段的链路杂音 |
| L33 | `Failed to remove the debug state from the target before disconnecting` | 断开前残留调试状态（可能残留断点操作码） |
| L35-L40 | `GEL: ... Could not write 0x0005D122@Data: target is not connected` → `Target reset failed. Error: -1` | 复位彻底失败，**链路丢失** |
| L41-L42 | `DSS: reset failed (...)` → `DSS: link lost after connect, reconnecting` | 进入 `dssResetVerified` 的重连分支 |
| L43-L47 | `IcePick_C_0: Error -151 @ 0x0 ...` → `reconnect 1 failed` | 第 1 次重连失败（-151 属探针/FTDI 层，另见器件与探针记录） |
| L48-L52 | 同样 `-151` → `reconnect 2 failed` | 第 2 次仍失败；退避 900 / 1800 ms |
| L53-L57 | `GEL Output: Memory Map Initialization Complete` → `DSS: reset after reconnect (try 3)` → `DSS: loaded` | **第 3 次重连成功**，复位 + 写入完成 |
| L58 | `SERVICE: READY` | 会话就绪，输出 `LOAD #1` |

### 判据

| 观察 | 结论 |
|---|---|
| 出现 `DSS: connected (realtime off)` | 降级成功，属正常过程，继续 |
| 随后 `-6310` / `Target reset failed` / `link lost` | **不是终点**：进入重连分支（最多 3 次，退避 900/1800/2700 ms），本次第 3 次成功 |
| 重连 3 次全失败 | 才需要人工介入（CCS GUI `Run → Reset → CPU Reset → Connect`，或 BOOT=111 + 断电 5 s） |
| 反复 `-1133` 且 `loadti` 也失败 | 先查日志里**有没有执行过** `PoliteRealtimeMode off`（降级是否真的跑过），再查目标状态；**不要先归因到 Flash 或硬件** |

### 两条不要再犯

- **别把 `-1133` 当"硬件坏了"**：本次同一探针、同一 `.ccxml`、同一天，降级后连接、复位、写 RAM、运行、读数全部成功。
- **别把"关实时模式"写成人工作业**：选项按 DSS 会话生效，不写进板子；下一次下载会重新以 realtime on 开始、再自动降级一次。`loadti` 从来不设它，所以 `loadti` 也报 `-1133` 时，原因不在实时模式。

## 未定位项（只记录，不解释）

- `EPwm1Regs.CMPA.all` 为什么能读回 32 位量级：DSS 对该 union 的宽度/地址解释未查清，**没有证据表明固件写坏了 CMPA**（`.bit.CMPA` 与 `TBPRD` 一致）。怀疑与 DWARF 里该 union 的声明宽度有关，未验证。
- 本次未验证 CPU2、未验证 XDS110、未验证 Flash 链接镜像。

