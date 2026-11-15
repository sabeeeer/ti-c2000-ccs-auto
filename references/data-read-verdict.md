# 读取数据的判据（通用，四级）

**任何"读到了数据"都不等于"读对了"。** 本页把判定条件固定下来，实时读、数组读、运行态记录、DMA 缓冲都用同一套判据。判据脚本：`scripts/ti_c2000_check_read.ps1`。

## 0. 为什么高速数据不能靠 JTAG 直读

| 事实 | 数值 |
|---|---|
| DSS/JTAG 单次 `expression.evaluate` | 毫秒级（本机 10 变量/轮约 130 ms，约 13 ms/变量） |
| 本机逐项读取速率 | 约 13 ms/变量，即单变量约 77 次/秒；依探针和 CCS 变化，不能当作高速连续采样 |
| 寄存器保留历史 | **不保留**。`ADCRESULTx` 只存最近一次转换，下次转换即覆盖 |
| 两次 JTAG 读之间 | 有几十 µs ~ ms 空档，中间数据全部丢失 |

因此 **µs 级波形（电力电子的 500 ns / 1 µs / 100 µs 采样）必须由固件侧采集**；DMA 是一种实现，经过周期预算验证的 ISR 缓冲也是一种实现：

```
独立触发源（ePWM2/CPU Timer）→ ADC SOC → EOC → DMA → RAM 数组
    → 连续采集：ping-pong 双缓冲；单次录制：采满即冻结的单缓冲
    → 冻结（gBufFull=1）→ JTAG 只负责搬已冻结的缓冲 → CSV
```

JTAG 不参与实时采样，只搬历史数据。**不做固件侧缓冲就直接读寄存器，高速数据一定是错的。**

## 0.5 固件契约：与芯片 / boot / 探针都无关的判据

前面那些判据里，凡是用"地址"说话的都带着设备假设：`PC < 0x080000` 假设 C28x 的 Flash 从这里开始（28335 就在 0x300000），段表假设 `.out` 里有可读的布局，读 `PC` 假设探针支持寄存器读。芯片一换、boot 一改、探针一换，这些假设就失效。

**固件自己声明的三样东西不需要任何假设，只需要"能读内存"这一项能力**：

```c
/* 1. 身份：改固件就 +1，读数对不上 = 烧错了镜像 */
#define FW_ID  0x00010001UL
volatile unsigned long gFwId = FW_ID;

/* 2. 中断存活：1 ms 定时器中断里 ++（多数工程的 gMsTick 已经是这个） */
volatile unsigned long gMsTick;      /* 已在 A0 里 gMsTick++ */

/* 3. 主循环存活：后台 for(;;) 里 ++（多数工程的 usMainLoop 已经是这个） */
volatile unsigned long usMainLoop;   /* 已在 main 的 for(;;) 里 usMainLoop++ */
```

对应的判据：

```powershell
pwsh -NoProfile -File scripts/ti_c2000_run_read.ps1 -ProjectPath <工程> `
  -Variables gMsTick -Mode ReadOnly -Rounds 4 -IntervalMs 300 `
  -ExpectFwId 0x00010001 `
  -RateVar gMsTick -ExpectedRatePerSec 1000 -RateTolerancePct 20
```

| 检查 | 通过条件 | 失败分类 |
|---|---|---|
| 身份 | 读回 `gFwId` 等于 `-ExpectFwId` | `FW_ID_MISMATCH` / `FW_ID_UNREADABLE` |
| 中断在跑 | `gMsTick` 跨轮递增 | `HEARTBEAT_FAIL` |
| 主循环在跑 | `usMainLoop` 跨轮递增 | `HEARTBEAT_FAIL` |
| 速率 | `Δ值 / Δ主机时间` 落在 `±RateTolerancePct` | `HEARTBEAT_RATE` |

**为什么这比地址判据强**：

- 换器件（28335 / 28379D / 将来任何 C28x）：同一套判据，只要那几个变量还在；
- 改 boot 配置（RAM / Flash / 自定义引导）：判据不问代码从哪来，只问它是不是在按声明运行；
- 换探针（XDS100 / XDS110 / 其他）：只要它能读内存；
- 不需要 `-CcsRoot`、不需要 `.map`、不需要 `ofd2000`、不需要读 `PC`。

**两个计数器要一起看**：只有中断在跑、主循环卡死时，`gMsTick` 仍然递增。要求"至少一个递增"证明有东西在跑，但**两个都递增**才说明中断与主循环都在服务——这是地址判据给不出的信息。

**代价**：固件里必须真的存在这几个变量。没有就退回地址判据（`PC` + 段表），并在输出里说明用了哪种。

## 0.6 读前门禁（PREFLIGHT）：先报告，再决定要不要读

"读完再判"有个致命顺序问题：失败时数据已经落盘，而结论错误时只留下一句泛化的失败原因。所以每个读入口在**采样之前**先打印这份报告，硬性条件不满足就**不读**：

```text
PREFLIGHT: 读之前必须确认的事
  LOCATION : RAM (PC = 0x00008870, region RAMLS1)
  BUILD    : <out>   sha256 9F9EBDF603577961
  LOADS    : #16 total for this project; this session is load #16 (started 19:49:16)
  IMAGE    : gFwId = 65537 (same build as this session loaded)
  ALIVE    : gMsTick 2748 -> 3033, advanced by 285 in 150 ms
PREFLIGHT: all conditions hold - reading
```

| 行 | 数据来源 | 不满足时 |
|---|---|---|
| `LOCATION` | 读 `PC`，落在本工程 `.map` 的哪个 MEMORY 区（`RAMLS0` / `FLASHA`…） | 默认只 `WARN`（Flash 调试合法）；`-RequireRam` 时 `NOT_RAM_IMAGE` |
| `BUILD` | `sha256(.out)` 与会话记录 | `STALE_SERVICE` |
| `LOADS` | `load-count.json` 与 `state.loadIndex` | 仅报告 |
| `IMAGE` | 固件声明的 `gFwId` 与 **`-Start` 时记录的值** 比对 | `PREFLIGHT_FAILED` |
| `ALIVE` | 间隔 150 ms 读两次计数器，必须递增 | `PREFLIGHT_FAILED` |

两点要求：

- **身份比对是自动的**：`-Start` 成功后就读一次 `gFwId` 存进 `state.json`，读时直接比对，不需要调用方记得传 `-ExpectFwId`。没有该变量的旧固件只提示"身份仅靠 sha256"。
- **拒绝必须清除旧结论**：`PREFLIGHT_FAILED` 时删掉 `data\*.csv` 并把 `check\verdict.txt` 改写成 `result: FAIL`，否则上一次的 `result: OK` 会被误用。

## 0.4 固件契约：唯一一处声明

本 skill 只认识**固件自己声明的**几个符号，全部写在 `references\firmware-contract.json`：

| 项 | 默认 | 作用 |
|---|---|---|
| `identity.var` | `gFwId` | 固件身份常数；`-Start` 时记录，每次读比对 |
| `heartbeat.candidates` | `gMsTick` / `usMainLoop` / `gRunMs` | **任一**递增即证明在跑；多一个能区分"中断在跑但主循环卡死" |
| `rate.var` / `perSec` | `gMsTick` / 1000 | 计数器必须按声明的速率推进 |
| `frozenBuffer.array` / `flag` / `flagValue` / `seq` | `gBuf` / `gBufFull` / `1` / `gBufSeq` | DMA 冻结窗口：标志必须**等于**期望值且拷贝期间不变 |

改固件变量时**先改这个文件**，再让脚本跟上（顺序不能反）。

为什么要有这个文件：这些名字曾经硬编码在 **12 处**，而且已经漂移——`FrozenValue` 在 `live_read` 里是 `'true'`、在 `read_dma` 里是 `'1'`；心跳候选在四个文件里出现了三种不同的集合与顺序。散在十二份拷贝里的契约不是契约。

`tools/audit_fw_contract.ps1` 用 **AST** 只读 `param()` 的默认值（不扫注释，注释里引用变量名是正常的），任何脚本与契约不一致即 `FAILURE: FW_CONTRACT_DRIFT`。它自带 `-SelfTest`，植入三类漂移必须被抓到、注释里的举例必须不被误报。

> 除这几个名字外，本 skill 对目标的一切（Flash 基址、段表、内存布局、探针型号）都是**运行时发现**，不做假设。

## 1. 四级判据

### 判据 1：固件身份（静态）

| 检查 | 通过条件 | 失败分类 |
|---|---|---|
| `.out` 与加载记录一致 | SHA256 等于 `Debug/.ti_c2000_loaded.json` 记录值；只证明主机文件与上次本脚本记录一致 | `SYMBOL_MISMATCH` |
| 固件指纹（**推荐**） | 固件里 `volatile unsigned long gFwId = FW_ID;`，`-ExpectFwId <值>` 读回比对。读一个数即可，**不依赖 Flash 基地址、PC、段表或探针型号** | `FW_ID_MISMATCH` / `FW_ID_UNREADABLE` |

没有板上可核对的固件标识或同一会话内的加载记录时标注 `UNVERIFIED_ID`，**不能声称"确认是本次固件"**。`PC` 所在 Flash/RAM 区也只能排除某些镜像，不能单独确认版本。

### 判据 2：运行活性（必须有）

| 检查 | 通过条件 | 失败分类 |
|---|---|---|
| 心跳递增 | 候选里**所有可读的**都参与判定，但**只要有一个递增即证明活性**（与实时读取脚本一致）。单个候选停滞会在逐项检查里显示 `row N not increasing` 并计入 `X/Y candidates advanced`，不单独判失败——多个计数器里停滞一个只说明那个计数器停止更新。两轮读取必须增加；三轮以上允许一次相邻同值，但连续两段不增即失败。一次同值会被记录，不能描述为"每轮都增加" | `HEARTBEAT_FAIL` |
| 启动窗口 | 仅在本次单会话刚加载并运行后，按实际预热时间检查计数器；`run_read`/`read_dma` 都适用。计数器已在递增但首值超过窗口 → 镜像不是刚加载的那一份 | `STALE_PROGRAM` |
| 速率（**推荐**） | `-RateVar <计数器> -ExpectedRatePerSec <n> -RateTolerancePct <默认20>`：按主机时间算实测速率（32 位回绕已处理），不在容差内即失败。"在递增"只说明动过；"速率对"才说明按固件声明的频率在跑 | `HEARTBEAT_RATE` |
| 至少一个心跳可用 | 指定的应用计数器必须可读；不能从任意递增列自动推断它是心跳 | `NO_HEARTBEAT` |
| 目标在应答且执行本镜像（前置） | 探针被枚举、会话进程活着、`sha256` 一致都成立**仍不够**：`.out` 符号表求值在 JTAG 断开时照样返回地址（实测 `V main 35469`）。**读 `PC`，判断它是否落在本镜像自己的代码段内**（段表取自 `.map` 或 `ofd2000`，不硬编码 Flash 基址）：读不到 = 链路断；落在段内 = 正在执行这份镜像；落在段外 = 在跑 Flash 或别的镜像。无布局可用时退化为设备地址表并明示 `fallback` | `TARGET_NOT_CONNECTED`（环境故障，无开关可绕过）/ `NOT_RAM_IMAGE` |
| 单行数据 | 一行无法建立"推进过"的证据；除显式 `-AllowNoHeartbeat` 外一律失败 | `NO_LIVENESS_INTERVAL` |

以上四个分类（`HEARTBEAT_FAIL` / `STALE_PROGRAM` / `NO_HEARTBEAT` / `NO_LIVENESS_INTERVAL`）以及范围判据的 `VALUE_OUT_OF_RANGE`，都由 `ti_c2000_check_read.ps1` 实际输出 `FAILURE:` 行；脚本整体失败时另给一条最终 `RESULT: FAIL`，退出码 1。

**要报告“程序持续运行”，必须有判据 2 的活性证据。** 仅验证冻结数组的文件结构和范围时，`-AllowNoHeartbeat` 会把活性标为 `SKIPPED`，不能据此宣称程序在跑。

28335 反例（2026-11-07 案例）：一轮现场 `gRunMs` 两次都是 `11460`，PC 位于 Flash，而本次 `.out` 的入口/主程序在 RAM；脚本曾返回 `RESULT: OK`。这说明“能连上、能读到值”不能验收本次 RAM 固件。Flash 中代码的版本和执行路径改变的原因仍未核实。F28379D 的另一次现场出现 `-1142`，不可直接推广到全部器件。

### 判据 3：冻结窗口（波形采集缓冲适用）

| 检查 | 通过条件 | 失败分类 |
|---|---|---|
| 录满标志 | 默认要求 `gBufFull == 1`，也可用 `-FrozenValue` 指定该固件实际的完成值；读前、读后都须匹配 | `BUF_NOT_READY` / `BUF_CHANGED` |
| 序号一致 | 读前 `gBufSeq` == 读后 `gBufSeq`（读期间未重录） | `BUF_CHANGED` |
| 点数一致 | 脚本检查 JTAG 返回条数等于请求的 `Rows×Columns`；若固件提供 `gBufCount`，还应核对**实际填充数**等于预期点数。当前脚本尚未自动核对固件计数，缺失时标为未验证 | `COUNT_MISMATCH` |

用于**波形采集**的缓冲必须在“采满即冻结”后停止写入；若持续 ping-pong 写入，须在读前切换到冻结缓冲或读副本。单会话内读普通 RAM 数组不要求录满标志。

### 判据 4：数据范围

| 数据 | 合法范围 | 失败分类 |
|---|---|---|
| 12 bit ADC（右对齐） | 0 ~ 4095 | `VALUE_OUT_OF_RANGE` |
| 12 bit ADC（左对齐原始） | 0 ~ 65535，且低 4 位为 0；当前通用脚本只查数值与上下限，**低 4 位须按工程另行核对** | `VALUE_OUT_OF_RANGE` |
| 16 bit 计数器 | 0 ~ 65535（注意回绕） | `VALUE_OUT_OF_RANGE` |

超范围通常意味着符号/地址错、对齐没做、或读到了别的内存。

## 2. 通用规则

1. **变量名全部参数化**，不硬编码 `gMsTick`、`gBufFull` 之类的工程专属名。
2. **缺失判据标注 `SKIPPED`，不默认通过**；要声称程序持续运行，必须有判据 2 的实测证据。
3. 判据顺序：身份 → 活性 → 冻结 → 范围；失败立即给分类与 `REASON`。
4. 判据 3 只在"数组/DMA 缓冲"场景适用；实时读单值不适用，标注 `SKIPPED`。
5. 输出必须含逐项结果与**唯一一条**最终 `RESULT: OK|FAIL`，退出码 0/1；只看最后一条 `RESULT:` 与退出码，中间出现的 `RESULT` 字样一律不作为依据。

## 3. 命令

```powershell
pwsh -NoProfile -File "<skill>\scripts\ti_c2000_check_read.ps1" `
  -CsvPath "<run>\data\data.csv" `
  -HeartbeatVars "gMsTick,usMainLoop" `
  -RangeVars "adcValue" -ValueMin 0 -ValueMax 4095 `
  -StartupMaxMs 10000
```

`ti_c2000_check_read.ps1` 只检查给定 CSV 的心跳列、行数、指定列的数值性与可选范围；它无法从 CSV 证明板上固件身份，也不核对心跳速率或 ADC 对齐位。给了 `-RangeVars` 却未给上下限时，仍要逐值确认可解析为有限数字，范围标 `SKIPPED`。`read_dma` 脚本另核对冻结标志的预期值及读后保持、可选序号及运行态心跳；`.ti_c2000_loaded.json` 只记录主机曾加载的 `.out`，不能单独证明当前板上仍运行它。

## 4. 模式与判据分离

**模式只决定「怎么拿到数据」，判据只决定「拿到的是否可信」。** 同一套四级判据适用于所有模式。

| 模式 | 取数方式 | 需要 DMA | 适用 | 入口 |
|---|---|---|---|---|
| 低速连续读 | 同一会话内逐项 `evaluate`，按间隔循环 | 否 | 慢变量、状态机、计数器、故障标志 | `ti_c2000_run_read.ps1` |
| 高速 DMA 读 | 同一会话内 `memory.readData` 搬冻结数组 | 是（固件侧） | µs 级波形、连续高速采集 | `ti_c2000_read_dma.ps1 -FrozenBufferReady` |

注意：**DMA 不是独立的读取方式**；读取侧仍是 `readData`。**断开调试连接后禁止再读**：F28379D 断开会复位跑 Flash，DSP28335 可能读到 Flash 旧程序。旧的独立只读入口已禁用。

实测耗时（2026-11-14，XDS100v2，单点 `evaluate` 14.0 ms、批量 0.36 ms/点）：

| 采样窗口 | 点数 | 逐点读 | 批量读 |
|---|---|---|---|
| 快速 500 ns × 1 ms | 2000 | ≈ 28 s | ≈ 0.7 s |
| 慢速 100 µs × 5 s | 50000 | ≈ 11.7 min | ≈ 18 s |
| 中速 1 µs × 0.1 s | 100000 | ≈ 23 min | ≈ 36 s |

结论：2000 点以内可逐点**搬运已存在的 RAM 缓冲**；是否需要 DMA 取决于固件采样周期和 CPU 预算。50000 / 100000 点优先批量搬运，但 RAM 容量和缓冲冻结仍是前提。

批量大小与单点成本（2026-11-14 实测，同一地址重复 3 次取平均）：

| 批量（点/次） | 单次耗时 | 单点成本 |
|---|---|---|
| 200 | 75.3 ms | 0.377 ms |
| 320 | 106 ms | 0.331 ms |
| 1000 | 302 ms | 0.302 ms |
| 2000 | 592 ms | 0.296 ms |
| 4000 | 1154 ms | 0.289 ms |

这组 XDS100v2 测量显示批量比逐项读取快；不要把所列耗时推广到其他探针或 CCS 版本。10 kHz / 1 ms 的 1000 点：按本次样本估算批量约 0.30 s，逐点约 14 s；要连续观察更高速数据，先由固件采样并管理缓冲。

冻结缓冲的前提必须从当前固件核对：RAM 数组、冻结标志（默认 `gBufFull`）以及可选序号（默认 `gBufSeq`）。`ti_c2000_read_dma.ps1` 要求显式 `-FrozenBufferReady`；确为 DMA 工程时仍可用兼容参数 `-DmaReady`。两种入口都只加载一次，但每调用一次会重新加载。

## 5. 单会话脚本的输出目录

`ti_c2000_run_read.ps1` 和 `ti_c2000_read_dma.ps1` 都把结果写到**同一个固定目录** `<工程>\readout\`（默认在工程根，可用 `-OutRoot` 改主输出位置）。**没有时间戳目录、没有 `Tools/out` 镜像、没有额外副本**：一次读取就是一次覆盖，避免同一批数据存在两份互相矛盾的副本。`ti_c2000_read_dma.ps1 -OutputPath` 只是可选的**额外 CSV 副本**，规范数据仍写在 `readout\data\array.csv`。

```
<工程>\readout\                   固定目录，每次读取覆盖
    README.txt                  本目录用途：check/ 与 data/ 各文件是干嘛的
    check\                      校验 / 判据
        README.txt              本子文件夹用途
        variables.csv           校验变量映射：role,name,first,last,delta,status
        verdict.txt             判据结论：固件 SHA256、模式、参数、结论
    data\                       实际读到的数据
        README.txt              本子文件夹用途
        data.csv                运行态记录（宽表：round,hostMs,hostTime,<变量...>）
        array.csv               DMA / 数组读取（长表：expression,value）
        variables.csv           可选：单会话数组读取前后的标量值
```

规则：
- **只有一个输出位置**，不要再加镜像、时间戳目录或第二份副本；需要保留历史就在读完后自行另存。输出路径见 `verdict.txt` 的 `data csv` 行。
- 根目录、`check\`、`data\` 各有一份 `README.txt`，打开任意一层都能看懂该层文件用途，不用回查本文档。
- `check\variables.csv` 逐行记录校验变量角色：`heartbeat`（活性）、`frozen`（冻结标志）、`sequence`（序号）、`array`（数据数组），以及首末值与判据状态；
- `data\` 只放数据，不混入判据信息；
- **失败必须覆盖旧结论**：只要本次读取在拿到数据前失败（连接、下载、解析、变量名不存在、轮次不全），脚本立即把 `verdict.txt` 改写为 `result: FAIL` + `failure:` + `reason:`，并删除上一轮遗留的 `data.csv` / `array.csv` / `variables.csv`。绝不留下上一次的 `result: OK`，也不留下可被误用的旧数据。
- **控制台只有一个 `RESULT:` 行**（就是最后一行）：成功分支不再回显校验器自己的 `RESULT`，失败分支的诊断回显会过滤掉内层 `RESULT`。判定顺序永远是"看最后一条 `RESULT:` + 退出码"，不看中间出现的字样。
- 校验失败（心跳不增、范围越界）同样写 `FAIL` 结论；此时数据文件按本次实测保留，供排查，但**未通过判据的数据不得当作有效读数**。

## 6. 强制接入（硬性要求）

所有读数据入口在输出 `RESULT: OK` 前必须调用 `scripts/ti_c2000_check_read.ps1`：

| 入口 | 接入方式 |
|---|---|
| `ti_c2000_run_read.ps1` | 写完 `data/data.csv` 后调用，指定读取变量必须是有限数字 |
| `ti_c2000_read_dma.ps1` | 写完 `data/array.csv` 后调用（长表：`-AllowNoHeartbeat -RangeVars value`） |

旧的 `ti_c2000_read_runtime.ps1` / `ti_c2000_read_array_runtime.ps1` / `ti_c2000_debug.ps1 -ReadOnly` 已从 skill 删除（不是禁用），不参与判据；`ti_c2000_debug.ps1` 只做编译/下载/运行。

规则：
- 判据失败 → `FAILURE: VERDICT_FAILED` + `RESULT: FAIL`，退出码 1；不允许"先返回成功、后提示校验"。
- 缺判据脚本 → `FAILURE: ENV_NO_VERDICT_SCRIPT`，拒绝读取。
- 单行 CSV 不能证明心跳递增；未显式 `-AllowNoHeartbeat` 时判据失败。只读脚本另在同一连接中读心跳前后值，并把这两值交给判据脚本。
- 数组表没有心跳列时用 `-AllowNoHeartbeat`，仍须查点数与每个 `value` 是否为有限数字；具体上下限未给时范围标 `SKIPPED`。数组脚本在同一 DSS 会话另查应用心跳。
