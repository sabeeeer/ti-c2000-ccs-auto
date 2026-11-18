# `.text` 跨块导致 -1041；违反「只走 RAM」烧 Flash 把板子搞成不可连

- **日期**：2026-11-18
- **器件 / 核**：TMS320F28379D / CPU1（LAUNCHXL-F28379D）
- **探针**：XDS100v2，串号 `TI90I42A`（全程可枚举，从未丢失）
- **工程**：`1-1DMA_Ping-Pong/F28379D_CPU1_Template`
- 状态：**已定位**（`.text` 段已修；CPU 跑飞需硬件/CCS 复位，DSS 无解）

## 现象

RAM 下载在写第一块时失败，反复重试不退：

```text
C28xx_CPU1: Trouble Writing Memory Block at 0x8000 on Page 0 of Length 0x7ff:
(Error -1041 @ 0xFFFFFF66) The debug probe reported an error.
Confirm debug probe configuration and connections, reset the debug probe, and retry.
IcePick_C_0: Error: (Error -150 @ 0x0) One of the FTDI driver functions ... returned a invalid status
C28xx_CPU1: File Loader: Verification failed: Target failed to write 0x008000@Program
```

同一块板、同一个 `.ccxml`、同一个探针，官方 `blinky` 例程的 RAM 下载**曾经成功过**（另一份记录），
说明链路本身可用，差异只在被测工程。

## 根因一：`.text` 被排到多个不连续的内存块（可修）

`check_ram_layout.ps1` 直接报出来：

```text
.text : >> RAMD0 | RAMLS0 | RAMLS1 | RAMLS2 | RAMLS3 | RAMLS4   <== 跨片
[BAD] 这些段被放在多个内存块里（跨片）：.text
```

`RAMD0` 的 origin 是 **0xB000**，`RAMLS0` 是 **0x8000** —— 链接脚本把高地址块排在前面，
地址先跳到 0xB000 再回落到 0x8000。加载器只能按块分片写，第一片 `0x8000` 长 `0x7ff` 就失败。

**修复**：`RAMLS0~RAMLS4` 本来连续（0x8000~0xA7FF，10240 字），合并成一个 MEMORY 条目：

```text
RAMCODE : origin = 0x008000, length = 0x002800   /* LS0~LS4 = 10240 字 */
.text   : > RAMCODE, PAGE = 0                   /* 单块，不是 >> */
```

改完错误里的长度从 `0x7ff`（分片）变成 `0x16a8`（整块 5800 字），证明合并生效；
`check_ram_layout.ps1` 的 `[BAD]` 消失。

**注意**：仅把 `>>` 的块顺序改成地址升序不够 —— 检查脚本仍判 `[BAD]`，因为 `>>` 本身就表示
"允许分片"。必须合并 MEMORY 条目并改用单块 `>`。

## 根因二：`service.ps1` 在 -1133 时没有任何降级（已修）

CPU 跑飞后，常驻服务报：

```text
Error -1133 @ 0x0: Device blocked debug access because it is currently
executing non-debuggable code. You may retry after the device has had time to
enter debuggable code, or you may cancel, disable realtime mode, and then attempt to connect.
```

**TI 在错误原文里就给了出路，而 `ti_c2000_dss_boot.js` 的 `dssConnectVerified` 只有"连一次、失败就返回 false"。**

对比证据（同一天、同一分钟、同一 `.ccxml`）：

| 入口 | 是否设置实时模式 | 能否 connect |
|---|---|---|
| `loadti.bat`（`ti_c2000_debug.ps1`）| 不设置 | **能**（输出 `Done`）|
| `ti_c2000_service.ps1` | `PoliteRealtimeMode = true`、`AllowInterruptsWhenHalted = true` | 不能（`CONNECT_FAILED`）|

**`ln` 的实时选项正是 `-1133` 拒绝的东西。**

**修复**：`dssConnectVerified` 捕获异常后，若消息含 `-1133` / `non-debuggable code` / **`emulation failure`**，
则断开、关闭 `PoliteRealtimeMode` 与 `AllowInterruptsWhenHalted`、重连一次。

**关键坑**：真实错误码只出现在 DSS 的 **stdout**，Java 异常消息只有 `emulation failure occurred`。
只匹配 `-1133` 不会触发降级（实测：日志里只有 SEVERE 的 `-1133`，没有降级轨迹）。
这与同目录 `2026-11-18-pieack-blocks-interrupts.md` 记录的 `-1138` 藏在 GEL stdout 是同一类问题。

修完后实测：错误从 `CONNECT_FAILED` 变成 `LOAD_FAILED`，说明 connect 这一段已经通了。

## 根因三（最严重）：违反工程约定去烧 Flash，把板子搞成 DSS 不可连

该工程 `AGENTS.md` 第一条就写着：

> TMS320F28379D（LAUNCHXL-F28379D）CPU1、bitfield 寄存器工程，**只走 RAM 调试，不烧 Flash**。

为了"验证 Flash 版本"，临时把链接脚本换成 `2837xD_FLASH_lnk_cpu1.cmd` + `-D_FLASH` 去烧 Flash。
烧写过程失败（`-1041`、`-150`、`target is not connected`），**很可能已经把 Flash 擦成部分写入状态**。
之后 CPU 从空 Flash 启动执行非法指令，JTAG 被硬件屏蔽，于是：

- 服务 connect：`-1133`
- `loadti`：`Done` 之后写 RAM 报 `-1041`
- 按住 RESET：`-1137 Device is held in reset`（复位中不能写 RAM）
- BOOT=111 + 断电：`-2131`（ICEPick 层）
- 降 TCLK 到 500 kHz：`-1041` 不变
- `.ccxml` 里禁用 GEL：只把报错换个形状

**结论：DSS 层没有任何办法把这种状态的 CPU 救回来。**

## 决定性对照：官方 blinky 在同一处失败

为了排除"被测工程配置错"，用 TI 官方 blinky 做基线（源码 SHA256
`B462E8EA0FADFEE69830423E4C4960DF508E2E2BB5EC6D5009B62952199C3241`，
与另一份记录里"RAM 下载成功过"的那份逐字节相同）。

复现方式（**不污染官方目录**，全部在工作副本里做）：

```text
$work = %TEMP%\blinky_baseline
复制 blinky_cpu01.c + 9 个 TI 公共源到 $work：
  F2837xD_CodeStartBranch.asm   F2837xD_DefaultISR.c     F2837xD_GlobalVariableDefs.c
  F2837xD_Gpio.c                F2837xD_Ipc.c            F2837xD_PieCtrl.c
  F2837xD_PieVect.c             F2837xD_SysCtrl.c        F2837xD_usDelay.asm
  （GlobalVariableDefs.c 在 headers\source\，其余在 common\source\）
复制 .cproject / .project / .ccsproject
把 .cproject 的 INSTALLROOT_F2837XD 由 ${PROJECT_ROOT}/../../../../.. 改成绝对路径
  （工作副本不在原位置，相对路径会失效）

ti_c2000_build.ps1 -ProjectPath $work -CcsRoot F:\ccs `
  -LinkCmd "<root>\common\cmd\2837xD_RAM_lnk_cpu1.cmd,<root>\headers\cmd\F2837xD_Headers_nonBIOS_cpu1.cmd"
  # 注意：不要加 -EntryPoint code_start（本文件当时的命令带了它，是当日稍后被推翻的做法；
  # 传了会让 .text 按 0x800 分片写并 -1041，见 2026-11-18-code-start-entry-point-blocks-download.md）
```

结果：**`SOURCES : 10`、0 警告、`RESULT: OK`**，与另一份记录里的"10 源文件"一致。

下载结果：

```text
blinky .text.1 = 0x8000 长 0x6a2
Trouble Writing Memory Block at 0x8000 on Page 0 of Length 0x6a2:
(Error -1041 @ 0xFFFFFF66)
```

**与 1-1DMA 工程一字不差的同一个错误、同一个地址、同一个错误码。** 间隔 20 秒重试仍复现。

**所以：`-1041` 与工程配置无关，是板子/CPU 状态问题。**
另一份记录里 blinky 的 RAM 下载曾成功过一次，那次成功发生在该记录中"Flash 尝试可能部分擦写"**之前** ——
时间顺序本身就是证据。

## 正确做法

**1. 严格按工程约定，不做未被要求的 Flash 操作。**
`AGENTS.md` 写了「只走 RAM 调试，不烧 Flash」，就不该"顺手验证一下 Flash 版"。
RAM 工程换 Flash 链接脚本不是改两行的事：要 `-D_FLASH`、`ramfuncs` 的 LOAD/RUN、独立的
CCS build configuration；靠临时改名 `.cmd` 硬切，失败一次就可能擦掉 Flash。

**2. `-1133` / 跑飞的恢复顺序（前两条只在 CCS GUI 里可用）：**

```text
CCS GUI：Run → Reset → CPU Reset → Connect Target      ← GUI 有 DSS 拿不到的"连接时复位"
或      BOOT=111 (Wait boot) + 拔 USB 断电 5 秒         ← CPU 停在 bootloader，不执行 Flash
或      按住 RESET + 连接（注意：复位状态下写 RAM 会报 -1137）
```

DSS 的三个入口（`service` / `run_read` / `read_dma`）在这两种情况下都无能为力，
`2026-11-14-disconnect-then-read-is-a-bug.md:36` 已经写过："CCS GUI 有对应设置，DSS 脚本层拿不到"。

**3. 先跑 `check_ram_layout.ps1` 再下载。**
`[BAD] 跨片` 是可以离线发现的，不该等到下载失败才查。

## 可复用教训

1. **`-1041` 写第一块就失败时，先查 `check_ram_layout.ps1` 的 `[BAD]`**，不要先怀疑探针或线。
   `0x7ff` 这种"刚好一个 LS 块"的长度是分片的典型特征。
2. **`>>` 不等于"连续"**：地址升序排列仍被判跨片，必须合并 MEMORY 条目 + 单块 `>`。
3. **DSS 的真实错误码在 stdout，不在 Java 异常里**。异常只有 `emulation failure occurred`；
   任何基于错误码的自动降级都必须同时匹配这个笼统消息。
4. **`loadti` 和常驻服务的选项不同**是排查"一个能连一个不能连"的第一切入点：
   `loadti` 不设实时选项，服务设了 `PoliteRealtimeMode=true`。
5. **工程 `AGENTS.md` 的约定是硬约束**。"只走 RAM"的工程不要碰 Flash ——
   一次失败的擦写就能让板子进入 DSS 无法恢复的状态，代价是整个调试链路中断。
6. **不要一次改多处**（延续 `2026-11-18-pieack-blocks-interrupts.md` 的教训）：
   本轮同时改了 `.cmd`、`.cproject`、`.ccxml`、临时 JS 脚本，导致每个现象都难以归因。

## 相关

- 段布局规则与改造步骤：`references/ram-and-linker.md` §3
- 工程约定：该工程 `AGENTS.md` 第 1、3 节
- 同类错误码处理：`2026-11-18-pieack-blocks-interrupts.md`（`-1138` 在 GEL stdout）
- DSS 能力边界：`2026-11-14-disconnect-then-read-is-a-bug.md:36`
