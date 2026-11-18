# 2026-11-15 DSS 时序与编译器选项审计：9 处偏差

## 身份与适用范围

- 器件、板卡版本、目标核：TMS320F28379D（LAUNCHXL-F28379D）CPU1
- 模块/接口、工程与版本：DSS 脚本 API（connect/reset/loadProgram/runAsynch/halt/disconnect）与 `ti_c2000_build.ps1` 的编译链接命令行；`F28379D_CPU1_Template`（`CPU1_RAM`）
- CCS、编译器、探针：CCS 12.8.1（`F:\ccs`）、`ti-cgt-c2000_15.12.1.LTS`、板载 XDS100v2（FTDI FT2232，`VID_0403&PID_6001`）
- 状态：**已回归**（脚本层；`-1138` 类故障需断电，属环境）
- 已验证的器件/板卡：F28379D + XDS100v2；未验证范围：XDS110、其他主机/线缆、CLA/VCU 实际使用

## 一、`connect()` 可以"假成功"

**现象**：日志里 `DSS: connected` 之后紧接：

```text
SEVERE: Error reseting target: Cannot perform operation, target is not connected.
```

之后三次 load 重试都在对着一个已经断开的目标操作。

**根因**：`session.target.connect()` 正常返回**不代表链路可用**。DSS 把某些失败异步上报，connect 不抛异常。

**修复**：connect 后调用 `isHalted()` 验证（它必须触达目标），失败就 disconnect 重连，最多 5 次、等待递增。

```javascript
function linkIsUp() {
    try { session.target.isHalted(); return true; } catch (eV) { return false; }
}
```

同一思路也用在 `reset` 失败分支：先看链路，链路断了就重连再 reset，而不是盲目 `halt` 后继续 load。

## 二、`Error -1138` 之后的重试只会更糟

**现象**：连续 stop/start 六轮，**交替失败**（成功、失败、成功、失败），稳定复现 3/6。

**日志给出完整链条**：

```text
C28xx_CPU1: Failed CPU Reset: (Error -1138 @ 0x0) Device refused to allow debug mode.
             Power-cycle the board. ...
C28xx_CPU1: GEL: Error calling OnPreFileLoaded(): Reset failed: retcode=-1
C28xx_CPU1: Trouble Writing Memory Block at 0x8000 ... (Error -1041) ...
C28xx_CPU1: JTAG Communication Error: (Error -150) ... FTDI driver functions ...
C28xx_CPU1: Failed to remove the debug state from the target before disconnecting ...
```

**-1138 是芯片拒绝进入调试模式**，TI 的答复就是断电重启。原来的代码会在它之后继续 halt+reset+load 三次，每次都把探针往 -1041 / -150 推一步，最后一次连 debug state 都清不掉，于是**下一次会话从更差的状态开始**——这就是"交替失败"的成因。

**修复**：
- JS 侧 `boardRefusedDebug()` 命中即 `throw`，不重试（`error.txt` 写 `BOARD_REFUSED_DEBUG`）
- 父进程给明确步骤并 `exit 3`：

```text
HINT : the chip refused debug mode (Error -1138) - this is a board state, not a script problem
HINT : power-cycle the board: unplug the USB cable, wait 3 s, plug it back in
HINT : repeated -1138 without a power cycle is normal; retrying -Start will not clear it
```

**两次检测都失效过，值得记下**：

1. 异常对象里**没有** `-1138`——GEL 把 `-1138` 打到 stdout，Java 异常消息只有 `Target reset failed. Error: -1`。所以匹配串必须包含 `Target reset failed`。
2. 父进程用 `Get-Content -Tail 12` 找 `-1138` 找不到——GEL 输出在最前面，等三次 load 重试跑完，它已经在几十行之上。改成读整份日志。

## 三、`-Stop` 之后 USB 端口需要时间才回来

`-Stop` 返回时 DSP 进程已经退出（实测 java 计数为 0，无残留），但紧接着 `-Start` 仍可能 `-150`。已加 800 ms 稳定等待。

## 四、编译器：`.cproject` 有 4 项从未被传递

用新写的 `tools/audit_build_options.ps1` 对账（21 项声明），发现 `ti_c2000_build.ps1` 漏了：

| 选项 | 值 | 后果 |
|---|---|---|
| `linkerID.ENTRY_POINT` | `code_start` | **入口点不同**：CCS 构建用 `code_start`(0x0)，skill 构建用默认 `_c_int00` |
| `compilerID.CLA_SUPPORT` | `cla1` | 用 CLA 的工程会编译失败或链接不同库 |
| `compilerID.VCU_SUPPORT` | `vcu2` | 同上 |
| `linkerID.XML_LINK_INFO` | `${ProjName}_linkInfo.xml` | 依赖该产物的脚本会失败 |

**入口点这条最隐蔽**：调试加载时 PC 由调试器设置，所以两边都能跑；但 Flash 启动向量不同，`loadti`、bootloader 行为也不同。这直接违反 `build.ps1` 头注释里"mirrors what CCS really builds"的承诺。

修复后 map 里可验证：

```text
warning #10063-D: entry-point symbol other than "_c_int00" specified: "code_start"
ENTRY POINT SYMBOL: "code_start"  address: 00000000
```

**注意**：`ofd2000 --section_info` 报的 `Entry Point: 0x000089E4` 是 COFF 头的 `f_entry` 字段，TI 工具链不更新它。**判断入口点要看 `.map`，不要看 `ofd2000`**。

## 五、新增对账工具

```powershell
pwsh -NoProfile -File tools/audit_build_options.ps1 -ProjectPath <工程>
```

它把 `.cproject` 里每个 `compilerID.*` / `linkerID.*` 与构建脚本实际映射的清单比对，未映射的报 `FAILURE: BUILD_OPTIONS_UNMAPPED`（exit 1）。这是**手写镜像的防漂移闸**：今后 `.cproject` 多一个选项，对账就会红，而不是静默生成一个不同的 `.out`。

## 六、回归方式

- `tests/test_run_modes.ps1` / `test_compiler_selection.ps1`：构建与模式互锁
- `tools/audit_build_options.ps1`：21 项全部 mapped
- `tools/portability_gate.ps1`：不许硬编码用户路径
- 上机：`-Stop` → `-Start -ConfirmLoad` 应连续成功（板子未进 -1138 时）；进入 -1138 时应 `exit 3` 并给出断电提示

## 八、第二轮五遍通读（同日晚）

通读方式：① 语法 + 函数重复 + 孤立引用；② DSS 模板逐行 + 共享片段调用点；
③ 文件与并发（锁、原子写、编码）；④ 参数契约（文档 vs param 块 vs 是否被读）；
⑤ 上机。

### 抓到的 6 个真问题

| # | 问题 | 危害 | 修法 |
|---|---|---|---|
| 1 | `ti_c2000_read_continuous.ps1` 的 JS 用了 `WARMUP`，模板里从未定义 | **必然失败**：Rhino 抛 `ReferenceError`，一个字节都没读就崩 | 改成字面量 300，并删掉重复的 isHalted 检查 |
| 2 | `live_read` 的 `-FrozenValue` 声明、文档、且被 `read_continuous` 转发，但**从未被读** | DMA 冻结判据只查"拷贝期间不变"；标志恒为 0（还在写）时也通过，读到的可能是撕裂数据 | 加 `Test-FlagEquals`（true/1 归一），要求等于期望值 |
| 3 | `readmode.Get-SessionExpressions` 的 cmd/res 交换未原子化 | 与 `live_read.Send-Request` 同一类竞态：清场失败时返回**上一轮的响应** | 清场重试 10 次 + 临时文件 rename |
| 4 | `dssShutdown` 定义后从未被调用 | 三处各写一份关闭序列（halt/等待/断开/终止），顺序不一致 | 三处统一调用 |
| 5 | `-MapFile` 未传给 `Get-RunLocation` | 文档说"可以自己指定 map"，实际无效 | 透传 |
| 6 | 新写的 JS 标识符检测器**自身是瞎的**（只识别 `@"` 独占一行，实际模板用 `$js = @'`） | 它报"通过"但一个文件都没扫，等于没有检查 | 修正 here-string 识别，并加 `-SelfTest`（植入 bug 必须被抓到） |

### 两个新审计工具（都带自检）

| 工具 | 抓什么 | 为什么必须有 |
|---|---|---|
| `tools/audit_js_identifiers.ps1` | DSS 模板里"用了但没定义"的全大写标识符 | 模板是 PowerShell here-string 里的 JS，**PowerShell 看不见**，只有摘要在板上跑时才报错。问题 1 就是这一类 |
| `tools/audit_dead_params.ps1` | `param()` 里声明、函数体从不读的参数 | 死参数让文档变成谎话：调用方传了以为生效。问题 2 和 5 都是这一类 |

`audit_js_identifiers.ps1 -SelfTest` 会植入 `NOT_DEFINED_ANYWHERE` 和 `ALSO_MISSING`，两个都必须被报出来，否则 `FAILURE: AUDIT_DETECTOR_BLIND`；同时对干净代码误报会报 `AUDIT_DETECTOR_NOISY`。**一个从没抓到过东西的检测器，不能算检测器。**

两个工具都已接入 `tests/test_dss_boot_shared.ps1`，随自动测试集运行。

### 上机结果：-1138，软件无解

三次 `-Start -ConfirmLoad` 全部：

```text
DSS: connected
DSS: reset failed (... Target reset failed. Error: -1)
DSS: board refused debug mode - not retrying
FAILURE: SERVICE_START_FAILED
HINT : the chip refused debug mode (Error -1138) - this is a board state
HINT : power-cycle the board: unplug the USB cable, wait 3 s, plug it back in
exit=3
```

探针 PnP 正常、无残留 java 进程、`.service` 清理干净、等待 12 秒后重试也无效。
**这正是本轮修复想要的行为**：一次就停、不重试、退出码 3、给出断电步骤。以前会在它之后继续 halt+reset+load 三次，把探针推入 -1041 / -150。

断电后的验证清单见下一节，其中第 1 条必须做：`WARMUP` 修复只在 `-Mode LoadRead` 路径生效，静态检查证明"没有未定义常量"，但真正的执行只能上机。

## 七、尚未验证（需板子恢复后补）

| 项 | 为什么要测 |
|---|---|
| `read_continuous -Mode LoadRead -ConfirmLoad` | `WARMUP` 修复所在的路径；静态审计只能说"没有未定义常量"，能否真的跑起来必须上机 |
| `read_continuous -Mode ReadOnly -FrozenBufferReady` | `-FrozenValue` 现在会比对期望值，需要确认正常冻结时不会被误拒 |
|---|---|
| `runAsynch()` 后 300 ms 检查是否足够 | 现有值是经验值；若某个工程初始化 >300 ms，`isHalted()` 可能读到假"在跑" |
| `halt` 后 `isHalted()` 是否立即为真 | 决定 `-Stop` 的 150 ms 等待是否够 |
| 连续 halt/run 20 次稳定性 | 探针在这种循环下的耐受度 |
| `readData` 每批 2000 个字的边界 | 大数组读取时是否会截断 |
| `disconnect` → 立即 `connect` | 决定 800 ms 是否合理 |
