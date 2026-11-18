# 误诊复盘：幽灵探针假设被 A/B 推翻；以及"旧会话继续用旧 SKILL.md"如何持续污染构建

- **日期**：2026-11-18
- **器件 / 核**：TMS320F28379D / CPU1（LAUNCHXL-F28379D）
- **探针**：XDS100v2，实物串号 `TI90I42A`（PnP InstanceId `...TI90I42AB` 去掉末位）
- **工程**：`1-1DMA_Ping-Pong/F28379D_CPU1_Template`
- 状态：**已回归**

## 一、我犯的错：把"幽灵探针"当成了根因

当时观察到的现象：

```text
DSS  : Error -151 (SC_ERR_FTDI_OPEN) "no XDS100 is plugged in / invalid serial"
xds100serial -l : No XDS100 emulators were found on the system
PnP  : 3 个 OK（COM11 + Debug + Aux）+ 9 个 Unknown/Present=False 的 XDS100
```

我据此推断："`.ccxml` 用默认 `Only one XDS100`，DSS 挑中了幽灵实例 → D2XX 打不开 → `-151`"，
并把它写进了 SKILL.md 和 error-index，还据此让人拔 USB、改 BOOT。

**这个推断是错的。** 用户质疑"你这个前提不够硬吧"，质疑成立。

## 二、证伪：两个控制实验

### 实验 1 —— `xds100serial` 的结论根本不能用来判探针好坏

同一块板、同一分钟：

| 条件 | `xds100serial -l` | 板子实际状态 |
|---|---|---|
| DSS 会话**正常运行**（`LOAD #108`，程序在跑） | **"No XDS100 emulators were found"** | 正常 |
| `service -Stop` 后 3 秒 | **`0403/a6d0 XDS100v1/v2 TI90I42A`** | — |

补充证据：同一颗 FTDI 芯片的 UART 通道（`COM11 @460800`）**全程都能打开、能写入**。

→ 该工具只反映"FTDI 句柄此刻是否被 DSS 占着"，**不是**探针健康判据。
→ 首次实验之所以看起来"找到就成功、找不到就失败"，纯粹是**句柄释放的时间关系**（混淆变量）。

### 实验 2 —— 同路径 A/B，只改串号选择

第一版 A/B 有缺陷：A 组用的是临时目录里的**新 ccxml 路径**，而 CCS 会按 ccxml 路径缓存
board data file，换路径本身就可能失败。于是重做：**在原文件上**只改 `Emulator Selection`。

| 轮次 | Emulator Selection | 间隔 | 结果 |
|---|---|---|---|
| A | `Only one`（`Value="0"`） | 10 s | **FAIL — `Error -215`** |
| A(复测) | `Only one` | 10 s | **FAIL — `-215`** |
| B | 按串号 `TI90I42A` | 10 s | **OK — `LOAD #113`** |

`-215` 原文：

```
The semaphore for the test bus controller is in a time-out state.
Unified-SCIF was unable to acquire the semaphore used to express ownership
of a controller by a utility or debugger. You may have to exit other clients.
```

### 结论（硬）

- 串号选择**确实是必要条件**（A 两次失败 / B 成功，变量已控制）。
- **但机制不是"幽灵被打开"**：幽灵 `Present=False`、物理不存在，DSS 不可能打开一个
  不存在的设备。真正失败的是**"自动选择 → 枚举/取控制器"这条路径**，它超时报 `-215`。
- 换成按串号是**直接寻址一块已知设备**，不触发枚举，所以能过。

## 三、第二个、也是更贵的坑：旧会话继续用旧 SKILL.md

修好 SKILL.md（删掉 `-EntryPoint code_start` 那条错误指令）之后，`Debug` 里的 `.out`
**又被覆盖成 `code_start` 版本**（时间戳 18:57:28），门禁反复报：

```text
FAILURE: NON_DEFAULT_ENTRY_POINT
REASON: the selected .out links with ENTRY POINT symbol 'code_start', not _c_int00
```

原因：**skill 的指令是会话启动时载入上下文的**。另一个对话的会话在我改文件之前就已开启，
它内存里仍是旧规则，所以每轮构建都继续传 `-EntryPoint code_start`，不断覆盖 `Debug\`。
我这边每次都得重新编译才能抢到窗口。

**这条必须写进 skill**：改了 SKILL.md / references 之后，**已开启的会话不会自动更新**，
必须让那些会话重开，否则会持续按旧规则产生坏产物。

## 四、最终落地的设计（串号只做"探针确认"）

用户定的架构：

> 串号可以依赖，但**只用于上机时确认"现在插着哪一块"**，并把它写进 `.ccxml`；
> 其他功能（编译/下载/读取/判据/报告）一律不依赖它。

实现 `Sync-ProbeSerialToCcxml`：

1. 自动识别实物探针：XDS100 → `xds100serial -l`；XDS110 → `xdsdfu -e`；其他 → PnP / DSS。
2. 与 `.ccxml` 现有串号比对；一致就**不写文件**。
3. 不一致或缺失 → **最小改写**（只动 `-- Enter the serial number` 的 Value；没有块则插入），
   `driver` / `device` / `ICEPick_C` / `Subpath` 一个字节不碰。
4. 写前三重自校验：XML 合法 + driver 节点数不变 + 串号确实在；任一不过就**放弃写入**。
5. 写入前自动留 `.bak`。
6. 读不到串号时**什么都不改，也不判失败**。

实测（把 ccxml 里串号块整块删掉，模拟"手上没有串号"）：

```text
ENTRY : _c_int00
PROBE : confirmed TI90I42A (source=discovered) - identity only, no other check depends on it
CCXML : serial written into the project .ccxml (previous copy kept as .bak)
LOAD  : #117
RESULT: OK
```

写回后复查：4 个 driver + device/partnum/ICEPick_C/Subpath 全在，XML 合法。

## 五、可复用教训

1. **"相关"不等于"因果"。** 改 ccxml 后成功，可能只是"改文件花掉的时间让句柄释放了"。
   要证明因果，必须**控制变量**：同路径、同间隔、只改一个因子，并且**重复一次**。
2. **先问"这个判据本身可靠吗"。** `xds100serial` 的成败受会话占用影响，我却拿它当探针健康判据，
   于是把一个正常状态判成故障，还据此让人动硬件。
3. **反证要能证伪自己。** 我主动做了"同路径 + Only one"实验，结果推翻了自己之前写进文档的结论。
   这比"找一个能解释现象的故事"有价值得多。
4. **skill 文件改了 ≠ 生效。** 已开启的会话仍用旧指令。改完必须让相关会话重开，
   否则会出现"两个会话按两套规则互相覆盖产物"的诡异局面。
5. **产物指纹是最快的判别器。** `.out` 大小 592642 vs 592810、`ENTRY POINT SYMBOL`、
   日志 `Length 0x16a8` vs `0x800`——三样一比，问题立刻收敛，不用猜硬件。

## 六、复现这些实验（可重跑）

```powershell
# 1) 串口/句柄占用对 xds100serial 的影响
ti_c2000_service.ps1 -ProjectPath <工程> -Status        # 会话在跑
xds100serial.exe -l                                      # 必然报找不到
ti_c2000_service.ps1 -ProjectPath <工程> -Stop
Start-Sleep 3; xds100serial.exe -l                       # 立刻能找到

# 2) 同路径 A/B（-NoProbeResolve 是关键：否则 resolver 会自动把 Only one 改回按串号）
#    备份 ccxml -> 把 Emulator Selection 的 Value 改成 0
ti_c2000_service.ps1 -ProjectPath <工程> -Start -ConfirmLoad -NoProbeResolve
```

## 相关

- 入口点判定：`2026-11-18-code-start-entry-point-blocks-download.md`
- 探针型号与识别：`references/probe-models-and-detection.md`
- 错误码：`-151`、`-215`、`PROBE_DSS_CONNECT_FAILED`、`NON_DEFAULT_ENTRY_POINT`
- 清理历史实例：`tools/clean_ghost_probes.ps1`
