# 入口参数没生效是真 bug；但「入口点导致 -1041」已被 A/B 实测推翻

- **日期**：2026-11-18
- **器件 / 核**：TMS320F28379D / CPU1（LAUNCHXL-F28379D）
- **探针**：XDS100v2，串号 `TI90I42A`
- **工程**：`1-1DMA_Ping-Pong/F28379D_CPU1_Template`（`CPU1_RAM`，25 源文件）
- 状态：**部分推翻**（参数 bug 已修并回归；「入口点是 -1041 根因」这一推论被 A/B 否掉）

> **先读这一条，避免被本文后半段误导**
>
> 2026-11-18 20:xx 做了对照实验，`_c_int00` 版与 `code_start` 版**各连续 3 次全部 `RESULT: OK`**：
>
> | 镜像 | 入口（`ofd2000`）| 结果 |
> |---|---|---|
> | 592,642 B，sha `2FAC8707E265` | `0x0000942d`（`_c_int00`）| #121 / #122 / #123 OK |
> | 592,642 B，sha `262FB26A2E04` | `0x00000000`（`code_start`）| #124 / #125 / #126 OK |
>
> **所以入口点不是 `-1041` 的成因。**
>
> 仍然成立的是：**`-e <symbol>` 短形式被 cl2000 吞掉，日志却照打 "overridden"** ——
> 这个参数 bug 是真的，它导致 11-15 的错误归因，并进而催生了 18:14 的错误门禁。
> `-1041` 的实际成因**至今未隔离**（见文末「仍未隔离」）。

## 现象

`service.ps1 -Start -ConfirmLoad` 反复失败，**连接和复位都成功，只有写 RAM 失败**：

```text
DSS: connected
DSS: reset
SEVERE: C28xx_CPU1: Trouble Writing Memory Block at 0x8000 on Page 0 of Length 0x16a8:
        (Error -1041 @ 0xFFFFFF66) The debug probe reported an error.
SEVERE: IcePick_C_0: Error: (Error -150 @ 0x0) One of the FTDI driver functions used
        during configuration returned a invalid status or an error.
DSS: load failed, attempt 3
FAILURE: LOAD_FAILED
```

**关键特征**：`DSS: connected` 与 `DSS: reset` 都成功，**只有 `loadProgram` 写第一块失败**。
同一块板、同一探针、同一 `.ccxml` 下，历史 `LOAD #103`（16:21:18）曾成功。

## 三份证据（缺一不能定案）

| 证据 | 失败镜像（skill 编译） | 成功镜像（CCS GUI 编译，`LOAD #103` 用的） |
|---|---|---|
| `.out` 大小 | **592,642 B** | **553,851 B** |
| `ofd2000 --obj_display=header` | **`Entry Point: 0x0000942d`** | `Entry Point: 0x00000000` |
| `.map` 的 `ENTRY POINT SYMBOL` | **`"_c_int00"  address: 0000942d`** | `"code_start"  address: 00000000` |
| `.text` | `0x8000`，`0x16a8`（单块） | `0x8000`，`0x166a`（单块） |

**两份镜像的 `.text` 都是单块**（`RAMCODE` 0x8000~0xA7FF），差异只有入口点。
**所以 `-1041` 与段布局、跨片、块大小、探针、USB、GEL、TCLK 全部无关。**

## 根因

`ti_c2000_build.ps1` 用**短形式**追加链接选项：

```powershell
$lflags += @('-e', $EntryPoint)      # 追加在 -z ... --reread_libs $romModel 之后
```

日志因此打印 `LINK : entry point overridden to code_start`，但 `cl2000` **没有采纳**：
`ofd2000` 读出的入口仍是 `0x0000942d`（`_c_int00`）。

**为什么 `_c_int00` 会导致 -1041**：`_c_int00` 位于 `.text`（`0x942d`）。
`loadProgram` 在写完 `BEGIN`（`0x0`，仅 2 字）之后、`.text`（`0x8000` 起）之前就会把 PC 指向入口。
此时 `.text` 还是未初始化内存，CPU 执行到它即跑飞，总线被占，`0x8000` 的写入被仲裁拒绝 → `-1041`。
`code_start` 位于 `BEGIN`（`0x0`），是关狗后跳到 `_c_int00` 的合法短跳转，PC 落地即安全。

**为什么 CCS GUI 编译的能成功**：`.cproject` 的 `linkerID.ENTRY_POINT=code_start` 被 CCS 正常透传，
所以 `CPU1_RAM\1-1DMA_Ping_Pong.out` 的入口是 `code_start`，与 `LOAD #103` 成功一致。

## 决策链（这条 bug 是怎么被一步步埋进去的）

技术上是一个符号没传进去，但**真正让问题活了两天的是三次错误决策**。`git log -S` 可复现：

| 时间 | 提交 | 决策 | 后果 |
|---|---|---|---|
| 11-15 之前 | — | `build.ps1` **自动**读 `.cproject` 的 `linkerID.ENTRY_POINT` 并追加 `-e <sym>` | 代码本身合理，但用了会静默失效的短形式 |
| 11-15 20:20 | — | `LOAD #27` 成功（`.out` 入口 `_c_int00`）| 基线 |
| 11-15 同日 | — | 16 次 `-Start` 连续失败 | 现象 |
| **11-15 22:05** | `b72cae3` | 归因为"加了 `-e code_start` 才失败"，于是把参数改成 **opt-in（默认不传）**，注释写死「DO NOT pass `-EntryPoint code_start`」 | **错误决策 ①**：归因错，因为 `-e` 根本没生效，加不加它 `.out` 入口都是 `_c_int00`，行为不可能因此改变 |
| **11-18 18:14** | `bffcb15` | 把上一结论固化成硬拦截 `NON_DEFAULT_ENTRY_POINT`：`.map` 里入口只要不是 `_c_int00` 就 `exit 4` | **错误决策 ②**：把 `.cproject` 声明的正确入口挡在门外，且拒绝理由写的是"请重新构建且不要传 -EntryPoint" |
| **11-18 19:04** | 本轮 | 用 `ofd2000` 实测发现 `.out` 入口始终是 `0x942d`；改长形式 + map 校验；拦截判据改为与 `.cproject` 声明比对 | **修正** |

**这条链的教训比技术细节更重要**：

1. **归因必须能解释"机制"**。当时只看到"加了 A 之后失败"，没有验证"A 是否真的生效"，
   于是把一个无关变量当成根因，并据此写了硬规则。
2. **一旦把猜测写成 `exit 4` 的硬拦截，错误就会被固化**——后续所有人（包括 AI）都会被它挡住，
   而且拦截图里写的 HINT 会继续传播错误结论。
3. **"日志打印了"不等于"生效了"**。这一条在 `-1133`/`-1138` 的历史里已经出现过（错误码只在 stdout），
   这里是同一类问题的另一种形态：**参数只在日志里出现过，没进命令行**。

## 修复（两处，都已落地）

**① `ti_c2000_build.ps1`：短形式改长形式，并**自动校验**

```powershell
$lflags += "--entry_point=$EntryPoint"
```

并且**不再相信日志**：链接成功后用 `ofd2000 --obj_display=header` 读出实际入口，
与请求值比对，不一致直接 `FAILURE: ENTRY_POINT_NOT_APPLIED`（见该脚本 link 段末尾的校验块）。
这条校验把"打印了但没生效"变成**构建期失败**，不再留到下载阶段才暴露。

**② `ti_c2000_service.ps1`：`NON_DEFAULT_ENTRY_POINT` 不再无条件拒绝**

原实现在 `.map` 里看到入口不是 `_c_int00` 就 `exit 4` 拒绝。但 `code_start` **正是 `.cproject`
声明的入口**，也是本工程唯一成功过的入口——一刀切拒绝等于把正确镜像挡在门外。

改为：读 `.cproject` 的 `linkerID.ENTRY_POINT`，**若 `.out` 的入口与声明一致则放行**；
只有"既不是 `_c_int00`、也不是 `.cproject` 声明的值"才拒绝。`-AllowNonDefaultEntry` 仍可强制放行。

## 排查时走过的错误方向（不要再走）

同一现象下逐条排除过，**逐条都与根因无关**：

| 试过的方向 | 结果 |
|---|---|
| `.text` 跨片（`check_ram_layout` 的 `[BAD]`）| 合并成 `RAMCODE` 单块后**仍 `-1041`**；后来改回分片也**仍 `-1041`** |
| 降低 TCLK（1 MHz → 500 kHz）| 错误码不变 |
| 在 `.ccxml` 里禁用 GEL | 只让报错换个形状 |
| 换 USB 线 / 换口 | `-154` 一度消失，但 `-1041` 不变 |
| 清理幽灵探针实例 | 无权限，且事后证明不是原因 |
| 清 `CPU1_RAM\` / `Debug\` 的 obj | 解决了另一个问题（`_RamfuncsLoadStart` 未定义），与 `-1041` 无关 |
| 用 `loadti` 替代 `service.ps1` | 报 `___c_args__ not defined`（`loadti` 自己的检查），绕不过 |

## 可复用教训

1. **`-e <symbol>` 在 `-z ... --reread_libs` 之后可能不生效**。判断入口是否真的改了，
   **只能用 `ofd2000 --obj_display=header`（读 `.out`）或 `.map` 的 `ENTRY POINT SYMBOL`，不能信脚本打印的日志**。
2. **"连接成功 + 复位成功 + 只有写内存失败"这一组特征，优先怀疑 PC 落点，而不是探针或线材。**
   写 `.text` 之前 PC 不能落在 `.text` 里。
3. **`.cproject` 里声明的 `ENTRY_POINT` 是权威**。skill 的检查若与它冲突，
   先怀疑检查本身（本例 `NON_DEFAULT_ENTRY_POINT` 就是误拦）。
4. **别的对话能下、你不能下时，先对比 `.out` 的三样东西**：大小、`ofd2000` 入口、`.map` 的入口行。
   三样里只要入口不同，就先解决入口，别去碰硬件。
5. **一次只验证一个变量**：本例中 `.text` 布局被改了三次（单块→分片→单块），
   每次都伴随失败，反而掩盖了真正稳定的差异（入口）。**布局不是变量时不要动它。**

## 仍未隔离：`-1041` 到底因何而来

把已知事实按时间摊开，只剩一个观察：

```
18:07-18:54  #104~#115  同一 sha（FEC8547F6695）12 次 loaded   ← 当时另一侧也在跑
18:59        #116       code_start 成功
19:0x        #117 #118  code_start 成功
20:xx        #121~#123  _c_int00  3/3 成功
20:xx        #124~#126  code_start 3/3 成功
```

**现在两版都稳定成功（6/6），所以 `-1041` 在当前状态下已无法复现。**

已知被排除的：段布局（单块/分片都试过）、入口点（A/B 各 3 次）、TCLK、GEL、USB 线、幽灵实例、obj 污染。

**最可能的解释（未证实）**：当时两个会话交替占用同一块探针，我这边撞在对方持有期间隙上；
`DSS: connected` + `DSS: reset` 成功但 `loadProgram` 首块失败，符合"链路被另一个进程打断"的形态。
**但这只是推测** —— 没有当时的完整 `server.log`（每次 `-Start` 覆盖）能证明。

**下次若复现，第一件事是抓 `server.log` 全文并记下另一侧是否在跑**，而不是先改代码或改配置。

## 相关

- 入口点与 `.cmd` 的关系：`references/ram-and-linker.md`「入口点」
- 成功侧记录：`references/debug-cases/f28379d/2026-11-18-ram-download-success-path.md`
- 另一条 `-1041` 成因（`.text` 跨片，属混合场景）：`2026-11-18-text-cross-block-and-flash-erase-brick.md`
- 工程文档：`DOWNLOAD-SUCCESS.md` §2.3（`.text` 单块）与 §5（`LOAD #103` 成功证据）
