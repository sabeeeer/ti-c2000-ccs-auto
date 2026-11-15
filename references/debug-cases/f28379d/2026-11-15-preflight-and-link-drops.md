# 2026-11-15 读前门禁（PREFLIGHT）与三次 JTAG 掉线

## 身份与适用范围

- 器件、板卡版本、目标核：TMS320F28379D（LAUNCHXL-F28379D）CPU1
- 模块/接口、工程与版本：JTAG/DSS 常驻会话；`F28379D_CPU1_Template`（`CPU1_RAM`）
- CCS、编译器、探针：CCS 12.8.1（`F:\ccs`）、`ti-c2000_15.12.1.LTS`、板载 XDS100v2
- 状态：**已回归**（PREFLIGHT 有 10 条无板卡用例；掉线为环境现象，已定位影响面）
- 已验证的器件/板卡：F28379D + XDS100v2；未验证范围：XDS110、其他主机/线材

## 一、为什么要在读之前报告，而不是读完再判

用户的原始事故：读 ADC 数据，读到的是**旧工程**的值，而当时没有任何一环说出"现在跑的是别的东西"。
原来的实现是"边读边报"，失败时数据已经落盘；结论错误时也只剩一句 `HEARTBEAT_FAIL`。

改成读之前一次性确认六件事，任何一条硬性条件不满足就**不读**：

```text
PREFLIGHT: 读之前必须确认的事
  LOCATION : RAM (PC = 0x00008870, region RAMLS1)
  BUILD    : ...\F28379D_CPU1_Template.out   sha256 9F9EBDF603577961
  LOADS    : #16 total for this project; this session is load #16 (started 19:49:16)
  IMAGE    : gFwId = 65537 (same build as this session loaded)
  ALIVE    : gMsTick 2748 -> 3033, advanced by 285 in 150 ms
PREFLIGHT: all conditions hold - reading
```

| 项 | 来源 | 失败时 |
|---|---|---|
| LOCATION | 读 `PC` + 本工程 `.map` 的 MEMORY 区名（`RAMLS0` / `FLASHA`…） | `-RequireRam` 时 `NOT_RAM_IMAGE`；否则只 `WARN` |
| BUILD | `sha256(.out)` vs 会话记录 | `STALE_SERVICE` |
| LOADS | `readout\load-count.json` + `state.loadIndex` | 仅报告 |
| IMAGE | `gFwId`（固件声明）vs **`-Start` 时记录的值** | `PREFLIGHT_FAILED` |
| ALIVE | 两次读计数器，间隔 150 ms | `PREFLIGHT_FAILED` |

**身份是自动比对的**：`-Start` 成功后立刻读一次 `gFwId` 存进 `state.json`，读数据时比对，
不需要调用方传 `-ExpectFwId`。没有 `gFwId` 的旧固件只提示"身份仅靠 sha256"。

拒绝时必须清除旧结论，否则上一次的 `result: OK` 会被误用：

```text
HINT    : nothing was read; the previous data.csv and verdict.txt were cleared so no stale result survives
```

回归：`tests/test_preflight.ps1` 10 条（含"拒绝后 `data.csv` 消失、`verdict.txt` 改成 FAIL"）。

## 二、`STOP` 不 halt 会在目标里留下断点操作码

第一次 `-Start` 失败，SEVERE 里写得很清楚：

```text
C28xx_CPU1: Failed to remove the debug state from the target before disconnecting.
There may still be breakpoint op-codes embedded in program memory.
It is recommended that you reset the emulator before you connect and reload your program.
```

原因：`server.js` 收到 `STOP` 直接 `target.disconnect()`，没有先把核心停下。
DSS 需要目标静止才能清除它打进去的断点操作码。

修复两处：
1. `STOP` 分支先 `target.halt()`、等 150 ms 再断开；
2. `loadProgram` 失败时自动 `halt + reset + 重试一次`，不必人手插拔板子。

## 三、XDS100 在连续高频读之后会掉链路（三次实测）

同一天出现三次，特征完全一致：

```text
E PC ... Could not read register PC: target is not connected
V main 35469                      ← 符号表照样返回，说明链路断了而不是会话死了
```

| 次 | 触发场景 | 恢复方式 |
|---|---|---|
| 1 | 16:43 会话之后，隔了一段时间 | `-Stop` + `-Start -ConfirmLoad` |
| 2 | 连续多个只读用例之后 | 同上 |
| 3 | 跑完 12 条 e2e 用例（每条间隔 0 ms）后立即再读 | 同上 |

**结论**：连续背靠背读十几个用例会把链路读掉。这不是判据缺陷（判据准确报出了 `TARGET_NOT_CONNECTED`），
而是板载 FT2232 或 USB 供电路径的限制。测试侧已在 `test_e2e_readonly.ps1` 的每个用例之间加
400 ms 间隔，之后 12/12 稳定通过。

未确认的部分：到底是 USB 供电、线材还是 FT2232 本身的时序余量。若要定位，需要在 `server.log`
里找 `target is not connected` 之前最后一条 DSS 调用，并核对 Windows 事件日志的 USB 挂起记录。

## 四、这次改动带来的输出

读一次成功的数据，现在会先看到 PREFLIGHT 五行，再看到数据通道的输出：

```text
PREFLIGHT: 读之前必须确认的事
  LOCATION : RAM (PC = 0x00008870, region RAMLS1)
  BUILD    : ...F28379D_CPU1_Template.out   sha256 9F9EBDF603577961
  LOADS    : #16 total for this project; this session is load #16 (started 19:49:16)
  IMAGE    : gFwId = 65537 (same build as this session loaded)
  ALIVE    : gMsTick 2748 -> 3033, advanced by 285 in 150 ms
PREFLIGHT: all conditions hold - reading
```

用户问的四件事——在哪跑、是不是新程序、下载了几次、现在是否在运行——都在这五行里，
而且是在**读之前**给出的。
