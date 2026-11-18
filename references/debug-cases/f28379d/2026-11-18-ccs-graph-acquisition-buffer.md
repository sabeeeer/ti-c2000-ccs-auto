# CCS Graph 画面全空：Acquisition Buffer Size × Index Increment 超过数组字数

检索词：graph 参数、Graph 不出波形、图空、只有一次正弦、全 0、X 轴 1e-5、
Acquisition Buffer Size、Index Increment、Display Data Size、16 bit unsigned、
结构体数组、gCtrlFrozen、gCtrlLog、CCS 12 对话框

## 身份与适用范围

- 器件、板卡版本、目标核：TMS320F28379D（LAUNCHXL-F28379D），CPU1
- 模块/接口、工程与版本：`1-1DMA_Ping-Pong\F28379D_CPU1_Template`；
  控制链录波 `CtrlLog_t gCtrlLog[1000]`（0x00C000）与 `CtrlLog_t gCtrlFrozen[1000]`（0x00D000），各 2000 字
- CCS、编译器、探针：CCS 12.8.1（F:\ccs）、C2000 CGT 15.12.1.LTS、XDS100v2（串号 TI90I42A）
- 状态：**已回归**
- 已验证：F28379D + CCS 12.8.1 + XDS100v2（LOAD #149 实测）；未验证：CCS 6/10 的字段名与默认值不同

## 现象和复现

- 现象：程序在跑（`gMsTick` 持续增长，Memory Browser 里数组有数据），但 Graph 窗口一条曲线都没有；
  Y 轴自动缩到 0~0.9，X 轴缩到 `-0.00001 ~ +0.00007`（单位 ms）。反复 Refresh 无变化，
  另有一次只在某个时刻看到过一帧正弦，之后一直是空图。
- 复现条件（错误参数）：Start Address `0x00D000`、Dsp Data Type `16 bit unsigned`、
  Index Increment `2`、**Acquisition Buffer Size `2000`**、Display Data Size `1000`、
  Sampling Rate `10000`、Time Display `ms`、Auto Scale `true`
- 期望值与实测值：期望 1000 点 / 100 ms（5 个 50 Hz 周期）；实测 0 个有效点
- 原始证据：Memory Browser 在 `0x00D000` 读到 380~3712 交替的 ia/dac；
  `read_continuous.ps1` 读回 2000 字（1000 组），统计 min/max/mean = 380 / 3711 / 2026.0，
  过零 5 次 —— 说明数据本身完好，问题只在 Graph 参数

## 排查与结论

- 查过的：Memory Browser 直读数组首地址（有数据）、`gCtrlFrozenReady = 1`、`gCtrlFrozenSeq ≥ 1`、
  探针与会话状态（正常）、map 里 `_gCtrlFrozen = 0x00D000`、Graph 各字段逐项核对
- 已排除：程序没跑（`gMsTick` 涨）、数组没数据（Memory Browser 有）、地址写错（map 核对一致）、
  数据类型选错（16 bit unsigned 正确）、探针掉线（串号可读、会话活着）
- 根因（已证实）：CCS Graph 实际向目标读取的字数 = **Acquisition Buffer Size × Index Increment**。
  填 2000 × 2 = 4000 字，而数组只有 2000 字 → 越界读 2000 字 → CCS 判定整块无效，
  于是一个采样点都画不出来（表现为坐标轴被缩到接近 0 的极值范围，而不是画出一堆 0）
- 修复：`Acquisition Buffer Size` 改成 **1000**（单位是采样点数，不是字数），其余不动，立即出图
- 回归：同一 `.out`、同一会话（LOAD #149），仅改这一个字段：2000 → 全空；1000 → 5 个完整周期；
  Display Data Size 改 200 后 X 轴变为 0~20 ms、正好一个工频周期
- 与旧案例的差异：**不要和 DSS 脚本读数互相套用**。`read_continuous.ps1 -Rows 2000` 的 `Rows`
  是"16 位字数"，结构体数组正好 2000 字；Graph 的 `Acquisition Buffer Size` 是"点数"，
  两者语义不同，混用就会越界

## 正确参数（本工程可直接照抄）

| 字段 | 看 `gCtrlFrozen`（0x00D000）| 看 `gCtrlLog`（0x00C000）|
|---|---|---|
| Start Address | `0x00D000` | `0x00C000` |
| **Acquisition Buffer Size** | **1000** | **1000** |
| Index Increment | **2** | **2** |
| Display Data Size | 1000（想看 20 ms 改 200）| 1000 |
| Dsp Data Type | 16 Bit Unsigned Integer | 同 |
| Sampling Rate | 10000 | 同 |
| Time Display | ms | 同 |
| Auto Scale | true | 同 |

看 dac 列把 Start 改成 `0x00D001` / `0x00C001`，其余不变。

## 通用换算规则

| 数组形态 | Index Increment | Acquisition Buffer Size |
|---|---|---|
| `Uint16 a[N]` | 1 | N |
| `struct { Uint16 x, y; } a[N]`，只看 x | 2 | **N**（元素个数）|
| `Uint32 a[N]`（类型选 32 位）| 1 | N |
| 只看前 200 点（10 kHz 下 20 ms）| 2 | 200 |

**判据：`Acquisition Buffer Size × Index Increment ≤ 数组字数`。**
超了不报错、不提示，只画一张空图 —— 这是本条最容易误判的地方。
