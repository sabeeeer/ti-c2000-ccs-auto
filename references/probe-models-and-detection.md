# TI 调试探针：型号、识别方式与型号无关的可用性判据

> 本文回答三件事：**这块探针是什么型号** → **怎么拿到它的唯一身份（串号）** → **怎么证明它现在真的能用**。
> 资料来源：本机 CCS 12.8.1 的 `targetdb` 与 `uscif` 工具实测，加上 TI 官方 XDS110 文档
> (`software-dl.ti.com/ccs/esd/documents/xdsdebugprobes/emu_xds110.html`)。
> 原则：**不假设型号**。任何判据都必须能对 XDS100 / XDS110 / XDS200 / XDS560v2 / 板载探针同时成立。

## 1. CCS 实际支持的探针驱动（本机 `dbgjtag` 内置清单）

```powershell
& "$ccs\ccs_base\common\uscif\dbgjtag.exe" -X inform,content=builtins
```

本机 CCS 12.8.1 输出（这是"这台机器能驱动哪些探针"的第一手清单）：

| name | mode | title |
|---|---|---|
| `xds100v1` | jtag | TI XDS100v1 USB |
| `xds100v2` | jtag | TI XDS100v2 USB |
| `xds100v3` / `xds100v3cjtag` | jtag / cjtag | TI XDS100v3 USB |
| `xds110` / `xds110swd` / `xds110cjtag` | jtag / swd / cjtag | TI XDS110 USB |
| `xds200` / `xds200swd` / `xds200cjtag` | jtag / swd / cjtag | TI XDS200 USB |
| `bh560m` / `bh560v2` / `bh560v2cjtag` | jtag / cjtag | BH XDS560M / v2 USB |
| `sd560v2` / `sd560v2cjtag` | jtag / cjtag | SD XDS560v2 USB |

`targetdb\connections` 里另有 LAN 版本与第三方探针：`TIXDS2XXLAN_Connection.xml`、
`SD560V2LAN_Connection.xml`、`BH-XDS560v2-LAN_Connection.xml`、`segger_j-link_connection.xml`、
`uart_connection.xml`（串口 Bootloader，不是 JTAG）。

## 2. 各型号怎么识别（设备管理器名 + 串号工具）

| 型号 | Windows 枚举名（`Get-PnpDevice`） | 串号工具（本机路径） | 备注 |
|---|---|---|---|
| XDS100v1/v2/v3 | `XDS100 Class Debug Port` + `XDS100 Class Auxiliary Port` + `XDS100 Class USB Serial Port (COMx)` | `ccs_base\common\uscif\xds100serial.exe -l` | FTDI；输出 `0403/a6d0 XDS100v1/v2 <串号> ...`。**一组 3 个设备**，多于 3 个说明有幽灵实例 |
| XDS110 | `Texas Instruments Debug Probes` → `XDS110 Class Data Port` + `XDS110 Class Debug Probe` | `ccs_base\common\uscif\xds110\xdsdfu.exe -e` | CDC；`-e` 打印串号/模式/固件版本。串号 8 字符、可打印 ASCII、**不含逗号**。变砖时只剩 `Stellaris DFU`；ROM DFU = VID `0x1cbe` / PID `0x00ff`，串号显示 `00000000`（**不是真串号**） |
| XDS200 | `Texas Instruments XDS2xx USB Debug Probe` | emupack 内**没有**串号工具（只有 `xds2xx_conf.exe` / `xds2xx_portchk.exe` / `update_xds2xx.bat` 等） | 靠 PnP InstanceId 或 DSS 试连 |
| XDS560v2（SD/BH） | `SD XDS560v2` / `BH XDS560v2` | `Sd560v2Config.exe`（配置类，非串号枚举） | LAN 版在 ccxml 里填 IP |
| 板载 XDS110（LaunchPad） | 同 XDS110 | 同上 | 探针串号 ≠ LaunchPad 串号；LP-XDS110 用 `xdsdfu -p` 设板级串号 |

> **串号陷阱**：PnP 的 `InstanceId` 末尾会多一个字符（`...TI90I42AB`），而 CCS 能用的串号是
> 去掉末位的 `TI90I42A`。**以串号工具打印的值为准**，不要抄 InstanceId。

## 3. 型号无关的可用性判据：让 DSS 自己开一次

型号专用工具都有覆盖盲区（XDS100 有 `xds100serial`，XDS110 有 `xdsdfu`，XDS200 没有；
`dbgjtag` 又只吃 CCS 生成的 `.dat` board file，不吃工程 `.ccxml`）。唯一**对所有型号都成立**的判据是：

> **用下载时同一条 DSS 代码路径，做一次"只连接、不加载"的试连。**

已经实现在 `scripts/ti_c2000_probe.ps1` 的 `Test-ProbeOpenableByDss`：

```
openSession(core) -> target.connect() -> isConnected(true) -> isHalted() -> disconnect -> terminate
```

判据与输出：

```text
PROBE_OPENABLE 1 C28xx_CPU1          ← 探针能打开、目标能应答
PROBE_OPENABLE 0 CONNECT_NOT_VERIFIED
PROBE_OPENABLE 0 <异常文本>
PROBE_OPENABLE 0 NO_TARGET_CORE [...]   ← 连上了但没有 C28xx 核（器件/ccxml 选错）
```

用法：

```powershell
pwsh -NoProfile -File scripts\ti_c2000_debug.ps1 -ProjectPath <工程> -ProbeCheckOnly -Deep
```

- 不加 `-Deep`：只做快速判据（PnP + 型号串号工具），几毫秒级，用于每次 `-Start` 前的门禁。
- 加 `-Deep`：额外跑 DSS 试连（几秒），**换型号 / 换机器 / 怀疑探针时用它**。
- 有活跃 DSS 会话时本项自动 `SKIP`（会话已占着探针，属正常）。

## 4. 串号怎么在工程间复用（不绑定某块探针）

工程 `.ccxml` **不需要**写死任何串号。运行时按以下优先级解析（`Resolve-ProbeTargetConfig`）：

| 优先级 | 来源 | 适用场景 |
|---|---|---|
| 1 | `-ProbeSerial <串号>` | 一次性指定，最高 |
| 2 | `$env:TI_C2000_PROBE_SERIAL` | 换机器 / CI / 多台设备共用一份工程 |
| 3 | `<工程>\targetConfigs\probe-serial.txt` | 工程级约定（每行一个串号，`#` 注释） |
| 4 | **自动发现**：XDS100→`xds100serial`、XDS110→`xdsdfu` | 默认走这条，插上就能用 |
| 5 | `.ccxml` 里原有的串号 | 最后兜底 |

决策：工程文件已 pin 同一串号 → 原样用；pin 了别的串号或仍是 `Only one` → 在
`readout\.service\resolved-<串号>.ccxml` 生成**最小改写的副本**给 DSS，**工程文件不动**。

## 5. 分层判据（探针自检的 5 层，按"软件优先"排序）

| 层 | 判据 | 失败码 | 该改什么 |
|---|---|---|---|
| L1 | PnP 可用设备数 / 幽灵数 | `NO_PROBE` | 只有这里才是真没插 |
| L2 | 型号串号工具能否打开 | `PROBE_DRIVER_UNUSABLE` | 先看 L4 |
| L3 | 实物串号 | — | 会话占用时属正常 |
| L4 | ccxml 选择 vs 实物 | `PROBE_SELECTION_AMBIGUOUS` | **只改 ccxml / probe-serial.txt** |
| L4b | DSS 试连（`-Deep`） | `PROBE_DSS_CONNECT_FAILED` | 先查 L4，再换口/线 |
| L5 | 结论 | — | 软件层全过就写"不要动硬件" |

**硬规则**：`BOOT` 引脚只决定目标从哪里启动，**与探针能否被打开无关**；任何探针层报错都不该拿 BOOT 当对策。

## 6. 已验证 / 未验证（诚实边界）

- **已验证**（XDS100v2，串号 `TI90I42A`）：`xds100serial -l` 解析、5 层判据、运行时串号自动适配
  （用假串号 `FAKEPROBE9` 实测能自动改副本并 `LOAD #107 RESULT: OK`）、`-Deep` DSS 试连
  （`PROBE_OPENABLE 1 C28xx_CPU1`）。
- **未验证**：XDS110 / XDS200 / XDS560v2 的真机路径（本机没有这些探针）。
  代码走的是同一套"型号无关"分支，但**它们的串号解析与 PnP 名称只在文档层面确认过**，
  第一次上真机时必须用 `-ProbeCheckOnly -Deep` 复核并把实际输出补进本文档。
