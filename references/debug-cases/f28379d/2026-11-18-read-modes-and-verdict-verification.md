# 读模式与数据判据的上板验证（8 正/负项，含两处会误判的用法）

- **日期**：2026-11-18
- **器件 / 核**：TMS320F28379D / CPU1（LAUNCHXL-F28379D）
- **探针**：XDS100v2，串号 `TI90I42A`
- **工程**：`1-1DMA_Ping-Pong/F28379D_CPU1_Template`（`gFwId=65537`，`BuffA` 5000 点）
- 状态：**已验证**

## 为什么要做这一轮

改了 `run_read` / `read_continuous` / `LoadRead` 相关文档与代码后，只跑成功路径是不够的：
**判据如果永远返回 OK，它就等于没有判据。** 所以每个判据都补了负向用例。

## 正向用例（4 项）

| # | 用例 | 命令要点 | 实测输出 |
|---|---|---|---|
| 1 | `ReadOnly` 心跳 + 范围（正确区间）| `-Variables gAmpFb -ValueMin 1000 -ValueMax 2200` | `HEARTBEAT: OK (all candidates increased)` / `RANGE: OK` / `RESULT: OK` |
| 2 | 速率判据 | `-Variables gMsTick -RateVar gMsTick -ExpectedRatePerSec 1000 -RateTolerancePct 30` | `HEARTBEAT: OK` / `RESULT: OK` |
| 3 | 冻结小数组 200 点 | `read_continuous -FrozenBufferReady -ArrayName BuffA -Rows 200 -Columns 1` | `ROWS 200` / `VALUES 200 (requested 200)` / `RESULT: OK` |
| 4 | 连续录波 5000 点 | 同上 `-Rows 5000` | `ROWS 5000` / `VALUES 5000` / `RESULT: OK` |

200 点 = 20 ms = 一个工频周期（10 kHz 控制），用作「快速验证」；5000 点用于看波形。
**两者是同一条读法、同一个入口，只差点数。**

## 负向用例（4 项，必须拒绝）

| # | 用例 | 实测输出 | 退出码 |
|---|---|---|---|
| 5 | 范围给错：`-Variables gAmpFb -ValueMin 5000 -ValueMax 6000`（实际 1637）| `RANGE gAmpFb: min 1637 < 5000` → `RANGE: FAIL` → `FAILURE: VERDICT_FAILED` | 1 |
| 6 | 数组读不带 `-FrozenBufferReady` | `USAGE: BUFFER_NOT_CONFIRMED` / `REASON: confirm the firmware fills and freezes this RAM buffer` | 2 |
| 7 | `ReadOnly` 带 `-ConfirmLoad`（互斥）| `USAGE: MUTUALLY_EXCLUSIVE` / `REASON: ReadOnly never downloads` | 2 |
| 8 | `check_read` 对无心跳列的 CSV 不加开关 | `HEARTBEAT: FAIL` / `RESULT: FAIL` | 非零 |

**第 5 项是关键**：它证明「有数字」和「数字可信」是两件事——1637 是个完全正常的读数，
但不在预期区间时必须判 FAIL，而不是照样写 `RESULT: OK`。

## `LoadRead` 组合路径

| 用例 | 命令要点 | 实测 |
|---|---|---|
| `LoadRead` + `read_continuous` | `-Mode LoadRead -ConfirmLoad -CcsRoot F:\ccs -FrozenBufferReady -Rows 200` | `LOAD #138` → `ROWS 200` / `VALUES 200` / `RESULT: OK` |

这条同时回归了 `Invoke-RetainedLoadRead` 的参数拼接修复（原先 `'-' + $key, $value`
被求值成单个字符串，`pwsh -File` 收到参数名 `CcsRoot F` → `SERVICE_PROTOCOL`）。

## 两处会误判的用法（本轮实测踩到）

### ① `-ValueMin/-ValueMax` 作用于 `-Variables` 里的**每一个**变量

```powershell
# 反例（误判）
-Variables gMsTick,gAmpFb -ValueMin 1000 -ValueMax 2200
  → RANGE gMsTick: max 52923 > 2200 → RANGE: FAIL

# 正例
-Variables gAmpFb -ValueMin 1000 -ValueMax 2200
  → RANGE: OK
```

**计数器要交给心跳**（`-RateVar` 或契约里的候选），**不要和量程变量混在同一份 `-Variables` 里。**
`run_read.ps1` 的注释早已写明这条（"counters such as gMsTick must not be mixed into an ADC range"），
但 SKILL.md 原先没有，容易照抄错误示例。

### ② `check_read` 对 CSV 列的要求

| CSV 内容 | 命令 | 结果 |
|---|---|---|
| 只有 `gAmpFb`（无心跳列）| 加 `-AllowNoHeartbeat` | `HEARTBEAT: SKIPPED (-AllowNoHeartbeat)` / `RANGE: OK` / exit 0 |
| 有 `gMsTick` + `gAmpFb` | 不用开关 | `CHECK gMsTick: 103608 -> 117122` / `HEARTBEAT: OK` / `RANGE: OK` / OK |

**`-AllowNoHeartbeat` 只证明文件结构与范围，不构成板上活性证明**——活性还要用 `run_read` 单独验。

## 一个容易误读的行为：失败会删掉旧 CSV

范围判据失败后立刻跑 `check_read` 会得到：

```text
FAILURE: NO_CSV
RESULT: FAIL
```

**这是设计行为**，不是磁盘错误：失败轮次要清理旧成功件，防止把上一轮 CSV 当本轮数据
（`data-read-verdict.md` 已写明）。正确做法是**先成功读一次生成新 CSV，再离线核对**。

## 可复用教训

1. **判据必须做负向测试**。只跑成功路径，无法区分"判据在正常工作"和"判据永远放行"。
2. **量程参数的作用域要写进用法示例**。`-ValueMax` 是整份 `-Variables` 的约束，
   不是"给某个变量设的量程"；混入计数器会产生看似合理的 FAIL。
3. **`NO_CSV`、`HEARTBEAT: SKIPPED`、`BUFFER_NOT_CONFIRMED` 都是设计行为**，
   遇到它们先查对应文档，不要当成脚本 bug 去改脚本。

## 相关

- 判据原文：[读取数据的硬性判据](../../data-read-verdict.md)
- 读法说明：[常驻 DSS 会话读取](../../single-session-read.md)
- 入口点记忆：[2026-11-18-entry-point-not-applied-causes-1041](2026-11-18-entry-point-not-applied-causes-1041.md)
