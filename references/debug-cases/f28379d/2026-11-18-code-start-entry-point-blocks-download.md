# `-EntryPoint code_start` 的镜像把 `.text` 按 0x800 分片写，-1041 之后板子锁死

- **日期**：2026-11-18
- **器件 / 核**：TMS320F28379D / CPU1（LAUNCHXL-F28379D）
- **探针**：XDS100v2，串号 `TI90I42A`
- **工程**：`1-1DMA_Ping-Pong/F28379D_CPU1_Template`
- 状态：**已回归**

## 现象：一个对话永远下不进去，另一个几分钟前刚成功

同一天、同一块板、同一个 `.ccxml`：

| 时间 | 谁 | 结果 |
|---|---|---|
| 16:21 | 本次会话 | **LOAD #103 `RESULT: OK`** |
| 17:54 | 另一个对话 | 反复失败 |
| 18:00 | 本次会话（复用 skill） | 也失败 |

失败日志（17:54）：

```text
DSS: connected
DSS: reset
Trouble Writing Memory Block at 0x8000 on Page 0 of Length 0x800: (Error -1041)
IcePick_C_0: Error: (Error -150) One of the FTDI driver functions ... invalid status
File Loader: Verification failed: Target failed to write 0x008000@Program
```

随后：

```text
Failed CPU Reset: (Error -6310) PRSC module failed to read a register
Target reset failed. Error: -1
Cannot perform operation, target is not connected.
```

## 判别：`Length` 就是指纹

| 构建方式 | `.out` 大小 | map 入口点 | 第一块写入长度 | 结果 |
|---|---|---|---|---|
| 默认（`build.ps1` 不传 `-e`） | 592642 B | `_c_int00` | **`0x16a8`**（整块 `.text`） | 成功 |
| `-EntryPoint code_start` | 592810 B | `code_start` | **`0x800`**（一个 RAMLS 块） | `-1041` + `-150` |

验证方式（30 秒可查完）：

```powershell
get-childitem <proj>\Debug\*.out | select Name,Length,LastWriteTime
Select-String -Path <proj>\Debug\*.map -Pattern 'ENTRY POINT SYMBOL'
```

`ENTRY POINT SYMBOL: "code_start"` ⇒ 镜像不可下载。

## 根因链

1. `.cproject` 声明 `ENTRY_POINT=code_start`。`build.ps1` **默认拒绝采用**并打印
   `LINK : .cproject declares ENTRY_POINT=code_start; NOT applied`。
2. **真正的源头：`SKILL.md` 与 `ram-and-linker.md` 当时写的是"构建命令固定写
   `-EntryPoint code_start`"、"判据是入口打印 `code_start`"。** 另一个对话严格照做，
   于是产出了坏镜像。这不是它乱传参数——**是 skill 记反了**（已于同日修正）。
3. 该镜像的加载布局让加载器把 `.text` 按 `0x800` 分片写，第一片就 `-1041`，
   同时 FTDI `-150`。
4. **失败不止一次下载（但可自愈）**：CPU 被推进不可调试状态，紧接着的加载会报
   `Target reset failed. Error: -1` / `target is not connected`。实测 2026-11-18 18:07：
   换成正确镜像后**原样重跑一次 `-Start -ConfirmLoad` 即 `LOAD #104 RESULT: OK`**，
   无需断电。连续两次仍失败才需要拔 USB 断电。
5. 更隐蔽的循环：坏镜像被 stage 在 `Debug\`。之后只跑 `-Start`（不带 `-Build`）
   每次都在重放它 —— 看起来"怎么试都不行"。

这与 `2026-11-15-dss-timing-and-build-audit.md` 的历史记录一致：那次加 `-e code_start`
之后 16 次成功变成 0 次，回退后才恢复。

## 修复：从警告升级为硬门禁

`ti_c2000_service.ps1` 在**触碰板子之前**读选定 `.map`：

```text
ENTRY POINT SYMBOL: "<sym>"
```

若 `<sym> != _c_int00`：

```text
FAILURE: NON_DEFAULT_ENTRY_POINT
RESULT: FAIL
REASON: the selected .out links with ENTRY POINT SYMBOL 'code_start', not _c_int00
HINT    : rebuild WITHOUT -EntryPoint ... a code_start image writes .text in 0x800 pieces,
          fails -1041 / FTDI -150 on the first block, and leaves the core needing a power cycle.
exit 4
```

逃生开关 `-AllowNonDefaultEntry`（显式、可审计），并在 fresh-process 重试中透传。
`iterate.ps1` 不传该开关：连续模式遇到坏镜像直接 `hardFail` 停止，不空转。

新错误码登记在 `error-index.json`（validation 类）。

## 回归测试

`tests/test_entry_point_gate.ps1`：
- `code_start` 的 map → exit 4 + `FAILURE: NON_DEFAULT_ENTRY_POINT`，且**断言没起 DSS**
  （不得出现 `readout\.service\server.log`）——门禁必须在碰板子之前
- `_c_int00` 的 map → 不拒绝，打印 `ENTRY : _c_int00`
- 加 `-AllowNonDefaultEntry` → 放行

## 可复用教训

1. **"另一个对话能复现、这个对话不能"时，先 diff 产物指纹**：`.out` 大小 / 哈希 / map 的
   `ENTRY POINT SYMBOL`。三样一比，问题立刻收敛，不必猜硬件。
2. **警告型保护不够**：只要参数存在，就一定会有人传。要把"会让板子锁死"的输入做成
   **下载前硬拒**，而不是打印一行 NOTE。
3. **失败会残留**：坏镜像留在 `Debug\`，之后每一轮 `-Start` 都在重放。诊断时必须同时看
   （a）当前 `.map` 入口点（b）板子是否已被锁死。
4. **`Length 0x800` 是分片写的指纹**（一个 RAMLS 块），`0x16a8` 才是整块。这与
   `2026-11-18-text-cross-block-and-flash-erase-brick.md` 里 `0x7ff` 的判断方法同源。
5. **`reset failed. Error: -1` 时先重试，不要急着断电**：本轮一度把"重试一次能通"误判成
   "板子锁死、必须断电"，是过度诊断。正确顺序是：确认 `.map` 入口点正确 → 原样重跑一次
   `-Start -ConfirmLoad` → 仍失败再断电。
6. **最该记的一条：文档写错比代码写错更致命。** 代码错了会被脚本门禁挡住；文档错了会让
   另一个会话"正确地"执行错误步骤，而且它没有任何理由怀疑。凡是把"某条命令/某个判据"
   固化成 skill 文档时，必须附上**当时的 `.out` 大小 / `.map` 入口点 / 实际日志**作为证据，
   并且在同一节写明"如果不这样做会看到什么"。本条的判据就是
   `592642 B + _c_int00 + Length 0x16a8` 三项同时成立。
7. **同一结论只能有一个副本**：本轮发现 `SKILL.md`、`ram-and-linker.md`、`dss-debug.md`、
   `2026-11-18-ram-download-success-path.md` 共 4 处各写了一遍 code_start 的错误指引，
   改一处不够。发现规则类错误时，必须全库 grep 同一个关键词，一处不漏地改完再验证。

## 相关

- 同类段布局判据：`2026-11-18-text-cross-block-and-flash-erase-brick.md`
- 构建选项审计：`2026-11-15-dss-timing-and-build-audit.md`
- 错误码：`references/error-index.json`（`NON_DEFAULT_ENTRY_POINT`、`-1041`、`-150`）
- 回归测试：`tests/test_entry_point_gate.ps1`
