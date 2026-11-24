---
name: ti-c2000-ccs-auto
description: 审查、编译和调试 TI C2000 CCS 工程。先选单步/连续运行模式与只读/本次加载读模式，再进入器件与 CCS、TI 算法库、调试经验三类资料；错误用独立离线查询模式。读数据保持同一 DSS 会话，下载须用户明确同意。
---

# TI C2000 / CCS 工程

本 skill 有**两种运行模式 × 两种读模式**，共用**三类资料入口**；另有只查记录的 **Error 模式**。模式由脚本互锁，不靠 AI 自觉。选定实际工程、器件、目标核、探针和任务后，先读工程入口文件，再调用本 skill 的脚本。用户没有要求上板时，只做文件与离线测试。

> **先交数据，再判可信度**：RAM/Flash、目标核、`.map` 与 `gRamProofTick` 是来源信息，不能作为数据判据，也不能因为位置未知或在 Flash 就拒绝下载、扣留已读数据。能访问目标时交付当次 CSV，并在同一次输出中写 `verdict.txt` 的 `OK/FAIL` 与具体原因。目标无法应答、没有常驻会话时没有当次数据可交。运行位置不靠 PC 或固定地址推测；有 `.map` 和[RAM 自证契约](references/ram-proof-firmware.md)时报告证据，否则标 `UNKNOWN`。这一调整仅完成离线验证，尚未上板复核。

## 三条硬约束（优先级高于本文其余所有内容）

### ① 修改本 skill 必须先获得用户授权

**未经用户明确同意，不得改动本 skill 的任何文件**（`SKILL.md`、`references/`、`scripts/`、`tests/`、`tools/`）。

- **回答提问 ≠ 授权修改。** 用户问「会不会…」「是否实现…」「为什么…」时，**只回答，不动手**。
- 用户提到某个机制"不错"、某种做法"应该有"，也**不等于**让把它做成实现。
- 要改就先说明：**改哪个文件的哪一段、改成什么、为什么**，等用户明确说「改」再动手。
- **一次授权只覆盖那一次改动**；下一次改动重新征求，不能顺延成"以后都能改"。
- 已改完的部分，用户说回滚就回滚，不保留"我觉得对所以留着"。

### ② 改动前必须做影响评估：不挖坑、不埋 bug、不隐瞒验证程度

**适用范围（2026-11-24 用户澄清）：本节只约束 ① 列出的五类 skill 文件。**

**工程源码（`.c`/`.h`/`.cmd`/`.cproject`/`.ccxml` 等 DSP 程序文件）的改动不属于本节**——
不套用下面五问，也不要求按本节格式交付。程序改动的检验由编译器、链接器、`.map` 与上板数据完成，
交付写「改动 / 编译 / 上板 / 数据」四项即可。**把本节格式套到程序改动上属于误用**：
它会让"编译能查出来的问题"和"必须上板才知道的问题"混成一份不产生任何约束力的自述。

**授权只是准许动手，不等于评估通过。** 每次改动前先回答下面五个问题，答不全就不许写文件；
交付时必须把答案一起报出来，不许只报"改好了"。

| # | 必须回答 | 不合格的表现 |
|---|---|---|
| 1 | **改动落在哪一层**：文档 / 测试 / 判据 / 运行脚本（`scripts/`、`tools/`）？ | 把"改文档"说成"修 bug"；说不清改的是解释还是行为 |
| 2 | **谁依赖它**：调用链上有哪些脚本、工具、测试、CI 步骤、其他文档读到它？ | 只改一处，不知道参数契约（`-Rows`/`-Columns`/`-FrozenFlag`）、错误码、CSV 列名、文档措辞还有谁在依赖 |
| 3 | **会不会挖坑**：是否新增失败路径、新拦截、新误报？ | 让原本能过的读变成 `FAIL`；让原本能下的镜像被拒；让文档契约测试因正常改措辞而误报；把推测固化成硬门禁（与 ③ 冲突） |
| 4 | **是否需要同步三件套**：代码、文档、测试 | 改了行为却没更新文档 → 下一个 AI 照旧写法重犯；改了行为却没加测试 → 下次被无声改回去 |
| 5 | **验证到什么程度**：跑了什么、没跑什么？ | 没跑测试就说"应该没问题"；没上板却写成"已验证"；拿离线结果冒充上板结论 |

**验证状态必须如实标注**（不强制必须上板，但不许含糊）：

- 涉及 DSS 会话、下载/连接时序、DMA 或 ISR 采样链、冻结标志、判据实际输出、CSV 形状、
  器件寄存器行为的改动：**建议上板**（用户同意后）。上了就写 `LOAD #N` 与关键读数
  （`CHECK count/frozen/heartbeat`、数组 min/max）。
- **没上板就写"未上板"，并说清只验证到哪一层**（编译 / 离线测试 / 仅文档）。
  只要写清楚，纯文档、纯参数校验、测试脚本自身的改动**可以不上板**。
- 任何情况下都不许用"应该没问题""已验证"这类措辞掩盖没做的验证；
  上板结论不能拿离线测试代替。

**怎么让它真的被执行（不设硬门禁，只加可见约束）**：

1. **评估必须写进回复里**：五项答案要在动手前输出给用户看，不许只在心里过一遍。
   用户看不到 = 没做。
2. **改完 skill 跑一次** `tests/test_skill_change_rule.ps1`：它检查本节五项、`未上板` 措辞、
   交付格式是否还在。规则被删或被稀释时它会变红（只是测试红，**不拦截任何操作**）。
3. 这条规则本身不挂 hooks、不进 `check_project_entry`、不产生 `exit` 非零 ——
   发现它和 ③ 冲突时，以 ③ 为准。

**交付格式（缺一项都不算完成）**：

```
改动：<文件列表 + 每处一句话>
影响：<哪条调用链 / 哪些契约 / 有没有破坏面>
验证：<跑过的脚本 + exit code 或 RESULT> ；上板：<LOAD #N 或 "未上板（只验证到 XX 层）">
遗留：<没验证的部分 / 已知副作用 / 需要用户决定的事>
```

### ③ 不得以任何方式阻碍下载

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

> 这三条是用户 2026-11-18 / 11-19 明确要求的，**不允许以"更好的工程实践"为理由绕过**。
> 其中 ② 是用户 2026-11-19 的原话要求：「改动范围会不会挖坑、埋 bug？分析对整个 skill 的
> 结合与耦合、有什么影响？这个新改动有无上机实测？」

## 先让 AI 找到正确入口

在新 CCS 工程创建之初，用 `tools/init_project_entry.ps1 -ProjectPath <工程>` 生成相同的 `AGENTS.md`、`CODEBUDDY.md`、`CLAUDE.md`；它遇到已有不同内容会拒绝覆盖，需人工合并。随后用 `tools/init_firmware_contract.ps1 -ProjectPath <工程>` 生成固件侧的判据模块（`ti_c2000_contract.h/.c`：`gFwId`、心跳、RAM 自证、DMA 帧符号，全部带中文注释说明为什么是判据）。该工具**只在显式调用时运行**，不随编译/下载自动改写源码；检测到工程已有同名符号就 `SKIP`，不覆盖手写代码。它只生成声明和 tick 函数，仍需人在 1 ms ISR / 主循环各调一次、并在 `.cmd` 里映射 `ramgs1` 等段名（输出会打印 `NEXT:` 提示）；可用 `-Identity/-Heartbeat/-RamProof/-DmaFrame` 只生成部分模块。开始工程操作前，读本文件和工程 `AGENTS.md`，再运行已安装 skill 的 `scripts/check_project_entry.ps1 -ProjectPath <工程>`。只有退出码 0 且 `RESULT: OK` 才继续；先清理工程里的旧 `ti_c2000_*.ps1/.js` 副本。每次脚本输出必须有 `SKILL   : ti-c2000-ccs-auto@<版本>`；版本由入口、运行脚本、资料和维护工具的内容哈希生成，脚本单独变更也会换号。成功还须退出码 0 与 `RESULT: OK` 同时成立。

CodeBuddy 源目录 `~/.codebuddy/skills/ti-c2000-ccs-auto` 是唯一维护源。改完先运行 `tools/sync_platform_copies.ps1 -DryRun` 检查 `PRUNE` 清单，再同步到 Codex 等平台副本；不要直接编辑平台副本。

## 三个硬性校验点（调用本 skill 时必须逐条做到）

| # | 时机 | 怎么做 | 不做的后果 |
|---|---|---|---|
| **① 入口** | 任何操作前 | `check_project_entry.ps1 -ProjectPath <工程>`，认 `RESULT: OK` | 工程里有 skill 脚本副本 / 入口文档缺失 → 实际跑的是副本而不是 skill |
| **② 运行** | 每次脚本输出 | 必须有 `SKILL   : ti-c2000-ccs-auto@<version>` | **没有这一行 = 这次操作不是 skill 跑的，结果不可信，停下来重做** |
| **③ 事后** | 收尾 / 怀疑走偏 | `check_project_entry.ps1 -ProjectPath <工程> -MaxRunAgeMinutes 10`，认 `RESULT: OK` | 无法证明最近一次操作来自本 skill |

**三者分别是事前阻断 / 事中自证 / 事后追查**，任一环独立生效：即使跳过了 ①，②③ 也能把"没走 skill"暴露出来。

**第 ① 条不是"检查报告"，而是"自动触发"**——它在一次调用里就补齐所有缺的东西：

| 缺失项 | 自动动作 | 输出里能看到 |
|---|---|---|
| `BUILD_VERIFICATION.txt` | 创建（带表头，只追加不覆盖）| `CHECK : created BUILD_VERIFICATION.txt` |
| `AGENTS.md` / `CODEBUDDY.md` / `CLAUDE.md` | 调 `tools\init_project_entry.ps1` 生成三份**内容一致**的入口文档 | `CHECK : init: CREATED : ...\AGENTS.md` |
| 三份已存在但内容不同 | **不自动覆盖**（可能有人手写了规则）→ 报 VIOLATION 让人合并 | `VIOLATION: ... differ` |

> `init_project_entry.ps1` 要求目录里有 `.cproject`；没有就 `USAGE: NO_PROJECT`（不是工程，不生成入口文档）。

**且 `build.ps1` / `service.ps1` 成功后会各追加一条**（输出里出现 `chglog :` / `CHGLOG  :`）：

```
2026-11-18 20:35:01 | build | config CPU1_RAM, compile OK, link OK, 0 warning(s), 25 source(s) | out 592,642 B, entry=code_start
2026-11-18 20:35:33 | load  | LOAD #139 OK, SingleStep | out 592,642 B sha 625DD203DC0A
```

**工程改动留痕不再依赖 AI 自觉**——2026-11-18 实测过：同一工程两个会话，一个写了 5 条、另一个 0 条。

> **留痕文件位置**：写在 `-ProjectPath` 所指目录下的 `BUILD_VERIFICATION.txt`。
> 若工程有父目录（例如 `1-1DMA_Ping-Pong\F28379D_CPU1_Template`），父目录可能另有一份历史记录，
> **以 `-ProjectPath` 下的为准**；要合并就人工合并，脚本不跨目录写。

## 模式、入口与互锁

**先分清两个正交的维度 —— "读模式"不是一个东西：**

| 维度 | 取值 | 决定什么 |
|---|---|---|
| **交易模式**（要不要下载）| `ReadOnly` / `LoadRead` | 这个进程会不会碰板子 |
| **怎么读**（唯一途径：**连续录波**，读固件冻结好的数组）| 点数按用途选：**200 点**（20 ms，快速验证）/ **1000~5000 点**（取波形）| 数据从哪来 |

**数据只有一种读法：连续录波（先冻结、再读）。点数按用途选：**

| 点数 | 入口 | 用途 | 时长（10 kHz 控制）|
|---|---|---|---|
| **200** | `ti_c2000_read_continuous.ps1 -FrozenBufferReady -ArrayName <数组> -Rows 200 -Columns <字段数>` | **快速验证**：参数是否收敛、运行变量是否在预期范围 | **20 ms = 1 个工频周期**（改完参数立刻能验）|
| **1000~5000** | 同上，`-Rows <元素数> -Columns <字段数>` | **取波形**：周期、相位、频率、THD、看瞬态 | 100~500 ms = 5~25 个周期（不超单个 RAMGS 块）|

**`-Rows` 是元素个数，`-Columns` 是每个元素的字段数**（实际读取字数 = `Rows × Columns`）：

| 固件里的数组 | `-Rows` | `-Columns` |
|---|---|---|
| `Uint16 BuffA[5000]` | 5000 | 1（可省略）|
| `CtrlLog_t { Uint16 ia; Uint16 dac; } gCtrlFrozen[1000]` | **1000**（不是 2000）| **2** |

结构体数组必须传 `-Columns 2`：此时 anchor 无法 evaluate 结构体，脚本打
`CHECK anchor : SKIPPED (multi-field element)`，**count 是结构判据、不算失败**，
CSV 输出 `index,c1,c2`（每行一个元素，`c1=ia`、`c2=dac`，不用自己按奇偶拆）。
传 `-Columns 1`（默认）会退回单列严格路径 → `anchor ... could not be evaluated` → `DATA_UNRELIABLE`，
数据其实完整，是参数语义用错了。

**机制始终是「ISR 采满 → 置冻结标志 → ISR 停止写入 → JTAG 读静态数组」，只差点数。**
JTAG 在 DMA/ISR 持续覆写内存的同时直读，实测会读到接缝甚至掉链路（见
[读模式](references/single-session-read.md) 的原始数据），**所以不在运行时直读是硬约束，不是偏好。**

**`run_read.ps1 -Variables` 承担「数据可靠性校验」—— 它既是交付数据的前提，也是判据的产出者。**
完整判据见 [读取数据的硬性判据](references/data-read-verdict.md)，下面是必须落在同一次输出里的关键项。

**顺序固定为「先校验、再取数」：**

```powershell
# 第 1 步：数据可靠性校验（读前证据 + 读后判据，结果同时写进 verdict.txt）
ti_c2000_run_read.ps1 -ProjectPath <工程> -Variables gMsTick,gAmpFb,gCtrlLogFrozen -Mode ReadOnly
#   读前（data-read-verdict.md「读前：先告知来源与状态」5 条）
#     ALIVE    : 心跳在两次请求间推进；不够时不能用 PID / isHalted()==false 代替
#     固件身份  : gFwId 等于本会话加载时记录的值
#     镜像     : .out 不比源码旧，SHA256 等于会话加载记录
#     探针/目标 : 枚举 + 会话活着 + 目标实际应答
#     加载次数  : 报告累计成功加载数与本会话序号
#   读后（「读后：四级判据」的 1/2/4 级）
#     HEARTBEAT: OK（跨轮心跳推进；给了 -RateVar 则按 Δ计数/Δ秒 检查容差）
#     每个数值可解析且有限；给了 -ValueMin/-ValueMax 则逐点检查
#     ⚠ -ValueMin/-ValueMax 作用于 -Variables 里的**每一个**变量：
#       量程只给要限定的量，计数器交给心跳（-RateVar / 契约候选），不要混进来。
#       反例（实测 2026-11-18）：-Variables gMsTick,gAmpFb -ValueMax 2200
#       → RANGE gMsTick: max 52923 > 2200 → 误判 FAIL
#       正例：-Variables gAmpFb -ValueMin 1000 -ValueMax 2200 → RANGE: OK

# 第 2 步：取数（只有冻结数组可信）
ti_c2000_read_continuous.ps1 -ProjectPath <工程> -FrozenBufferReady `
  -ArrayName <数组> -Rows <元素数> -Columns <字段数> -Mode ReadOnly
#   数组读要过四级判据的第 3 级：完成标志等于指定值（默认 1）、
#   复制前后标志及序号不变、返回点数 = Rows×Columns、首元素 evaluate 与 readData 一致
#   ⚠ 结构体数组（CtrlLog_t{Uint16 ia; Uint16 dac;} a[1000]）：Rows=1000（元素数）、Columns=2（字段数）。
#     此时 anchor 无法 evaluate 结构体，输出 "CHECK anchor : SKIPPED (multi-field element)"，
#     count 是结构判据，不算失败；CSV 为 index,c1..cN，每行一个元素。
#     传默认 Columns=1 会退回严格路径，报 "could not be evaluated" → DATA_UNRELIABLE（数据其实完整）。
```

**为什么它是前提而不是可选项**：不先过这一步，第 2 步读到的数字可能来自
① 早已停机、② 上一轮的残留数组、③ 加载的是另一份固件。**这三种情况下数字都"看起来正常"**——
所以「有数字」不等于「数据可信」，**身份/活性/结构/数值任一项失败都要判 `result: FAIL`**，
不能先写 `result: OK` 再输出失败。

**它本身的局限（所以只能用做校验，不能用来取数）**：每秒最多 2~3 次采样，
**不能还原 100 ms 级序列，也不能量相位或频率**。

**`LoadRead` ≠ 连续录波。**
`LoadRead` 只是"本次允许下载一次、然后读"，属于**交易模式**；
连续录波（含 200 点小数组）是**数据读法**，与它正交：
`-Mode LoadRead` 下载完可以接着读冻结数组；服务已由别人启动时，也可以只 `read_continuous` 不下载。

**以下表格里 `ReadOnly`/`LoadRead` 指交易模式，`run_read` 指数据可靠性校验（读慢变量 + 出判据），`read_continuous` 指连续录波取数。**

| 维度 | 入口与行为 |
|---|---|
| 单步运行（默认） | `scripts/ti_c2000_service.ps1 -Start -ConfirmLoad [-Build] [-CorePattern <核名匹配式>]`：获准后构建、选定 `.out`、加载一次、运行并保留 DSS 会话。自动选择唯一 C28xx 核；多个 C28xx 核时默认 CPU1 并记录实际核名，选其他核才传 `-CorePattern`。只有列表确实无法确定核时才报参数错误。`-Status` 只报告；`-Stop` 会结束会话，可能使探针重新枚举，只在明确结束/更换镜像时使用。 |
| 连续运行（用户点名才启用） | `scripts/ti_c2000_iterate.ps1 -UserApproved -Expect ...`：最多 20 轮；每轮构建、加载、运行、读、判据。相邻下载尝试至少隔 5 秒；连接重试和探针恢复应留间隔。运行期间其他读/加载/Stop 由锁拒绝。 |
| `ReadOnly`（默认读） | `scripts/ti_c2000_run_read.ps1 -ProjectPath <工程> -Variables ...` 读慢变量；`scripts/ti_c2000_read_continuous.ps1 -FrozenBufferReady -ArrayName ...` 读**连续录波冻结的数组**——这是唯一把波形取出来的方式。零构建、零加载、零重连、零因读而 `halt`；附着现有服务，在程序运行时读取。连续录波的原理、参数询问、RAM 算法与导出规范见[读模式](references/single-session-read.md)。 |
| `LoadRead`（本次获准加载后读） | 同一公开读入口加 `-Mode LoadRead -ConfirmLoad [-Build]`。若旧会话存在，先明确停止；服务加载新镜像并**留在该会话**，再调用正常 `ReadOnly` 判据；读完不 `halt`/断开。`-Standalone` 是同一路径的旧别名。`-MaxLoads/-Expect` 的循环每轮仍受 5 秒门限。`-CcsRoot` 可用（2026-11-18 修复 `Invoke-RetainedLoadRead` 的数组拼接 bug：原先开关与取值被并成一个字符串 → `FAILURE: SERVICE_PROTOCOL`；修后实测 `LOAD #135` + `HEARTBEAT: OK`）。 |
| Error（离线） | 一出现 `USAGE:` 或 `FAILURE:`，**先查** `scripts/ti_c2000_error.ps1 -Code <错误码>` 或 `-LogPath <日志>`，再读[错误索引](references/error-index.json)。输出 `CATEGORY`：parameter、validation、data_verdict、download_probe。查询不连接、不构建、不复位、不下载；新故障经实测复盘后录入第三类。 |

下载只能在用户明确同意后传 `-ConfirmLoad`，连续运行还要求用户明确提出反复运行并传 `-UserApproved`。`ReadOnly` 与 `-Build/-ConfirmLoad/-Expect/-MaxLoads>1` 互斥；`-NoProbeCheck/-AllowUnverified/-NoHeartbeat` 的只读绕过已禁用。`RESULT: FAIL`、缺 `RESULT: OK`、非零退出码都不是成功；不得用另一次烧录“凑出”读数。

其余入口职责：`scripts/ti_c2000_build.ps1` 只编译；`scripts/ti_c2000_debug.ps1` 只做探针检查或获准的显式加载/运行；`scripts/ti_c2000_readmode.ps1` 管互锁与时间门限；`scripts/ti_c2000_loadcount.ps1` 管成功加载记录；`scripts/ti_c2000_check_read.ps1` 离线核对 CSV。这些脚本不提供另一条绕过常驻服务的读数路径。

## 一次成功下载的固定顺序（2026-11-18 F28379D/CPU1 + XDS100v2 实测）

```powershell
pwsh -NoProfile -File scripts\ti_c2000_build.ps1   -ProjectPath <工程>            # 不用传 -EntryPoint，默认取 .cproject
pwsh -NoProfile -File scripts\ti_c2000_service.ps1 -ProjectPath <工程> -Start -ConfirmLoad
pwsh -NoProfile -File scripts\ti_c2000_run_read.ps1 -ProjectPath <工程> -Variables <变量,寄存器>   # 只读附着，不重烧
```

**入口点跟随 `.cproject` 的 `linkerID.ENTRY_POINT`，本工程就是 `code_start`。**
关键不在"选哪个符号"，而在**参数形式**：短形式 `-e <sym>` 实测会被吞掉，必须用长形式
`--entry_point=<sym>`，并在链接后用 `.map` 复核。三行日志齐全才算生效：

```text
LINK    : entry point taken from .cproject = code_start     # 没传参时自动取声明值
LINK    : entry point requested = code_start (declared in .cproject: code_start)
LINK    : entry point verified in map = code_start          # 复核，不一致则构建失败
```

不一致会直接构建失败（`ENTRY_POINT_NOT_APPLIED requested=... actual=...`），
所以"打印了但没生效"不可能再溜过去。实测不传任何参数：`ENTRY : code_start` → `LOAD #119 RESULT: OK`。

`service.ps1` 的前置判据是**"与 `.cproject` 声明冲突"**，不是"不等于 `_c_int00`"
（旧判据曾把唯一能成功的镜像挡在门外，已修）。真冲突才报
`FAILURE: NON_DEFAULT_ENTRY_POINT`（exit 4）；逃生开关 `-AllowNonDefaultEntry`。

> **历史坑（别重犯）**：2026-11-18 有一版把"短形式 `-e` 不生效导致的失败"误判为"`code_start`
> 这个符号不能用于 RAM 下载"，于是在文档里写下"必须 `_c_int00`、绝不能传 `code_start`"，
> 并加了"非 `_c_int00` 即拒绝"的门禁。那次误判的产物是 592810 B、`.text` 按 `0x800` 分片；
> 换成 `--entry_point=code_start` 后镜像正常、`LOAD #116/#119` 连续成功。
> **教训：先怀疑参数是否真的生效，再怀疑符号选择。**

成功必须三条同时成立，缺一不得写"下载成功"：`.map` 里 `FLASHA~FLASHN` 的 used 全为 0
**且 `ENTRY POINT SYMBOL` 与 `.cproject` 声明一致**；日志出现 `DSS: loaded`（即
`memory.loadProgram` 成功）；`runAsynch` 后应用计数器跨轮递增。细节见
[RAM 与链接](references/ram-and-linker.md)「入口点」。

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
#    期望：ENTRY : code_start（跟随 .cproject）/ LOAD : #N / RESULT: OK

# 3) 只读验活（零下载）
pwsh -NoProfile -File scripts\ti_c2000_run_read.ps1 -ProjectPath <工程> -Variables gMsTick,usMainLoop -Mode ReadOnly
pwsh -NoProfile -File scripts\ti_c2000_read_continuous.ps1 -ProjectPath <工程> -FrozenBufferReady -ArrayName BuffA -Rows 5000 -Columns 1 -Mode ReadOnly
```

实测成功记录：**LOAD #103/#104/#105 连续三次 `RESULT: OK`**，`gFwId=65537`，`gMsTick` 跨轮递增，
`read_continuous BuffA` 5000 点全量返回。四个必须同时满足的指纹：

| 项 | 正确值 | 错了会怎样 |
|---|---|---|
| `.ccxml` 的 `Emulator Selection` | `Value="1"` + 串号 `TI90I42A` | 默认 "Only one XDS100" 会打开**幽灵实例** → `-151`（PnP 看着全 OK） |
| `.out` 入口 vs `.cproject` 声明 | **一致**（本工程 `code_start`，`ofd2000` 读 `0x00000000`） | 不一致说明 `--entry_point` 没生效 → 构建期就该被 `ENTRY_POINT_NOT_APPLIED` 拦下。**但入口点本身不是 `-1041` 的成因**：2026-11-18 A/B 实测 `_c_int00` 3/3 `RESULT: OK`、`code_start` 3/3 `RESULT: OK`（LOAD #121~#126） |
| connect 前 realtime 选项 | **不设**（session 默认 off） | 设 `PoliteRealtimeMode=true` → `-1133` 直接拒绝连接 |
| `.text` 段布局 | `> RAMCODE` 单块（0x8000~0xA7FF） | `>>` 跨片 → `-1041`（`Length 0x7ff/0x800` 是分片指纹） |

排查顺序固定为：**探针串号 → 入口点 → realtime → 段布局 → 才怀疑硬件**。
`reset failed. Error: -1` / `target is not connected` 先原样重试一次，仍失败再断电。

### 探针自检的 5 层判据，以及"什么时候才允许动硬件"

| 层 | 判据 | 失败含义 | 该改什么 |
|---|---|---|---|
| 1 Windows 枚举 | 可用设备数 / 幽灵数（`Unknown` 或 `Present=False`） | 0 个可用 → `NO_PROBE` | **只有这一层代表"真的没插"**，此时才让人查插线/供电 |
| 2 句柄占用 / 串号可读性 | 残留 `dss`/`java` 进程；`xds100serial -l` 能否列出探针 | **不是判据**（见下） | 清理残留进程后重试；有活跃会话时属正常 |
| 3 实物串号 | `xds100serial` 输出的串号（PnP 的 InstanceId 末尾多一位，`...TI90I42AB` → `TI90I42A`） | 读不到 | 只做身份记录，不据此判故障 |
| 4 ccxml 选择 | `Emulator Selection` 是否按串号、且该串号在实物列表里 | 多块**实物**在场且无法确定 → `PROBE_SELECTION_AMBIGUOUS`；串号不符 → 自动生成副本适配 | **只改 ccxml / probe-serial.txt 一行**。**不拔线、不改 BOOT** |
| 4b DSS 试连（`-Deep`） | DSS 能否 `connect → isConnected → disconnect` | 打不开 → `PROBE_DSS_CONNECT_FAILED` | 先查第 4 层，再换口/线 |
| 5 结论 | 上面各层 | — | 软件层全过就明确写"不要动硬件"，不写含糊的硬件建议 |

> **两条实测结论（2026-11-18，同一块板、同一分钟，别再用推测替代）**
>
> 1. `xds100serial -l` 报 "No XDS100 emulators were found" **不能证明探针坏**：DSS 会话正常运行
>    （`LOAD #108`）时它正是这么报的，`-Stop` 后 3 秒立刻读到 `0403/a6d0 XDS100v1/v2 TI90I42A`；
>    同一颗 FTDI 芯片的串口通道（`COM11 @460800`）全程能打开、能写入。该工具只反映
>    "FTDI 句柄此刻是否被 DSS 占着"。
> 2. **失败的是"自动选择探针"这条路径，不是"幽灵被打开"。** A/B 对照（间隔统一 10 s，唯一变量
>    是 ccxml 选择）：`Emulator Selection = Only one` → `-215` 信号量超时、连不上；
>    改成按串号 `TI90I42A` → `LOAD #113` OK。幽灵实例 `Present=False` 物理不存在、DSS 根本打不开，
>    所以正确表述是"自动枚举在残留实例的机器上会超时"，而不是"选中了幽灵"。
>
> 因此：**先让"自动选择"本身可用——清掉幽灵实例**（`tools\clean_ghost_probes.ps1 -Confirm`，需管理员；
> 只删 `Status≠OK` 的历史记录，在用的探针不会被碰）；仍失败再查残留 `dss`/`java` 客户端；**不要**因此让人
> 拔线、换线或改 BOOT。
>
> **硬性设计原则：串号只用于「探针确认」，其他功能一律不依赖它。**
>
> 上机前 skill 自动识别当前实物探针（XDS100 → `xds100serial -l`；XDS110 → `xdsdfu -e`；
> 其他型号 → PnP / DSS 试连），把得到的串号**最小改写**进工程 `.ccxml`
> （只动 `-- Enter the serial number` 的 Value，driver / device / ICEPick_C / Subpath
> 一个都不碰；写前做 XML 合法性 + driver 节点数 + 串号存在性三重校验，失败就不写；
> 写入前自动留 `.bak`），让 DSS 精确寻址一块已知设备，**而不是去枚举**
> ——枚举在有多组残留实例的机器上会 `-215` 信号量超时（同路径 A/B 两次复现）。
>
> **编译 / 下载 / 读取 / 判据 / 报告都不读串号。** 读不到串号时什么都不改，也不判失败。
> 需要人工干预时可用 `-ProbeSerial`、`$env:TI_C2000_PROBE_SERIAL` 或
> `targetConfigs\probe-serial.txt` 覆盖自动发现（都是可选，不是前提）。
>
> 实测（2026-11-18）：ccxml 里删掉串号块 → 直接 `-Start -Build -ConfirmLoad`
> → `PROBE : confirmed TI90I42A (source=discovered)` + `serial written into the project .ccxml`
> → `LOAD #117 RESULT: OK`，写回后 4 个 driver / device / router / Subpath 全部完好。

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

**CCS Graph（用户自己开 `Tools → Graph` 看波形）**：参数换算见
[调试经验索引](references/debugging-experience.md) 里的
`2026-11-18-ccs-graph-acquisition-buffer` 案例（F28379D + CCS 12.8.1 实测，用户问「graph 参数」时以它为例）。
一句话规则：

```
CCS 实际读取字数 = Acquisition Buffer Size × Index Increment   ≤  数组字数
```

结构体数组 `{Uint16 ia; Uint16 dac;}[1000]`（2000 字）对应 **`Index=2`**，
`Start Address` 用**变量名** `gCtrlFrozen`（静止一帧）/ `gCtrlLog`（实时环形），符号解析失败才填 `0x00D000` / `0x00C000`。
控制链 10 kHz → 每点 100 µs，所以 `Sampling Rate=10000`、`Time Display=ms`，
且 **`Display Data Size` 直接决定时间刻度**：`200` = 20 ms（1 个 50 Hz 周期），`1000` = 100 ms（5 个周期）；
`Acquisition Buffer Size` 填同样的点数（200 / 1000，**不是字数**，20 ms 填 200 不是 400）。
填 2000 就是 4000 字，越界后 CCS 不报错、只画一张空图（X 轴缩到 1e-5）。
注意这里的 `Acquisition Buffer Size` 是**采样点数**，与 `read_continuous.ps1 -Rows` 的**字数**语义不同，不要互相套用。

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

> 🔴 **改这个 skill 之前，先读它的 git 历史。**
>
> 本目录是独立 git 仓库（`git remote -v` → `sabeeeer/ti-c2000-ccs-auto`，85+ 提交）。动手前三步：
>
> ```powershell
> git log --oneline -15          # 最近改了什么、为什么改
> git log -S '<关键词>' --oneline  # 某条结论是哪次提交引入的
> git status --short             # 有没有别人留下的未提交改动
> ```
>
> **为什么必须：** 今天两条错误结论（"必须 `_c_int00`"、"`code_start` 不能下 RAM"）都是
> **"没读历史就改"** 的产物 —— 11-15 的误判（19:56 前的 `b72cae3`）被 11-18 另一个会话当成事实继续加固，
> 最后变成 `exit 4` 的硬门禁，把唯一能成功的镜像挡在门外。
> **只看当前文档，无法分辨一条规则是实测结论还是上一次误判的残留。**
>
> **改完必须 `git commit`（本地）。** 留一堆未提交改动，下一个 AI 就分不清哪些是"已确认"、哪些是"半成品"。

> ⚠️ **改了 skill 文件 ≠ 立即生效。已开启的会话不会重读 SKILL.md / references。**
> 2026-11-18 实测：修好本文档里 `-EntryPoint code_start` 那条错误指令后，另一个**早已开启**的
> 会话仍按旧指令构建，持续把 `code_start` 镜像写回 `Debug\`，门禁反复报
> `NON_DEFAULT_ENTRY_POINT`，看起来像"修了没用"。
> **改完 skill 必须让相关会话重开**（或明确把新规则告知该会话），否则两个会话会按两套规则
> 互相覆盖同一份产物。判断是否踩到这一条：`.out` 的时间戳晚于你最后一次编译，且入口点不是
> 你期望的那个。

> **诊断探针问题时的两个实验开关**（没有它们做不出干净对照）：
> - `-NoProbeResolve`（`service.ps1`）：禁用"探针确认"，`.ccxml` 原样使用。
>   否则 resolver 会自动把 `Only one` 改回按串号，**A/B 实验直接失效**（第一次就踩了这个坑）。
> - `tools/clean_ghost_probes.ps1 [-Confirm]`：列出/删除 `Status≠OK` 的历史探针记录
>   （默认只列；需管理员；`Status=OK` 的在用探针绝不会被碰）。用于让 `Only one` 自己在
>   多残留实例的机器上可用。
>
> 做对照实验的硬要求：**同一路径、统一间隔、只改一个因子、至少重复一次**。
> 这次的教训是"改 ccxml 后成功"其实只是"改文件花的时间让 FTDI 句柄释放了"。

固件符号和时间门限先改 `references/firmware-contract.json`，再运行 `tools/audit_fw_contract.ps1`。出错先用 Error 模式；新增错误先写 `references/error-index.json` 的处理步骤及类别，再运行 `tools/audit_error_index.ps1` 和 `tools/audit_error_prefix.ps1`，实测案例另归第三类。新增器件进第一类，新增 TI 库进第二类。改后运行离线 `tests/test_*.ps1`（不运行需真机的 `test_e2e_readonly.ps1`）、`tools/audit_js_identifiers.ps1`、`tools/audit_dead_params.ps1`、`tools/audit_fw_contract.ps1`、`scripts/check_debug_catalog.ps1` 和 Codex `quick_validate.py`，检查输出与退出码。**测试脚本自身必须在成功路径末尾显式 `exit 0`**：否则 `LASTEXITCODE` 会残留最后一次子进程调用的失败码（实测 `test_run_modes.ps1` 因最后一步是故意拒绝而输出 `RESULT: OK`/exit 3，`test_compiler_selection.ps1` 因最后一步是故意失败的编译而输出 `RESULT: OK`/exit 1），显示通过却是失败退出码。上板结论必须另标“实测”，不能拿离线测试代替。
