# 第一类：器件、外设与 CCS 工程

用于换 C2000 器件/板卡、接探针、建工程、配置 CPU1/CPU2、外设、编译器和链接脚本。这里的“器件”包括 DSP28335、F28379D 等；eCAP/ADC/SCI 的寄存器和驱动配置也从这里进入。具体故障复盘归第三类。

## 先确认当前工程

1. 从实际 `.cproject`、`.ccsproject`、`.ccxml`、链接 `.cmd`、源码头文件和板卡资料确认器件、核心、CCS/编译器、COFF/EABI、bitfield/driverlib、RAM/Flash 配置。不要仅凭工程文件夹名推断。
2. 写 ePWM、ADC、eCAP、SCI、SPI、I²C、DAC 或其他外设前，读[官方例程模板规则](peripheral-examples.md)。用 `scripts/list_peripheral_examples.ps1 -SdkRoot <SDK目录> -DeviceFamily <器件族> -Peripheral <模块>` 列全同器件例程，再打开选中的源码和工程配置；`c2000ware_find.ps1` 可作跨 SDK 的辅助检索，但其默认输出有条数上限。eCAP 例如在本机 SDK 的 `driverlib/f2837xd/examples/cpu1/ecap/` 有捕获及 APWM 例程；换器件时应重新定位。
3. 在现有工程中匹配引脚、时钟、PIE/中断、`.cmd` 内存段、库路径和被排除的源文件。只改当前工程需要的部分。

## 按问题继续读

| 问题 | 资料 |
|---|---|
| 28335 bitfield 写法、ISR、原子快照 | [TI 例程写法](ti-official-style.md)；具体例程从本机 TI SDK 核对 |
| F28379D + XDS100v2、`f28379d.xml`、CPU1/CPU2、探针串号 | [器件与探针对照](other-devices-and-probes.md) §3.2、§4；[实机记录](environment.md) |
| 新器件、driverlib、SysConfig、器件例程结构 | [C2000Ware 指南](c2000ware-guide.md) 与 [例程索引](c2000ware-index.md) |
| 按 TI 模板写或迁移任意外设 | [官方例程模板规则](peripheral-examples.md)：同器件源码、配置契约、构建及上板重复验证 |
| `.cmd`、RAM/Flash、链接内存、编码 | [RAM 与链接](ram-and-linker.md)；必要时用 `scripts/check_ram_layout.ps1` |
| 构建、下载、DSS、寄存器读回 | [现场操作手册](field-guide.md) 与 [DSS 调试](dss-debug.md) |
| **改了 `.cproject` 的宏定义后链接报未定义符号** | 见下方[切换宏定义后必须清构建目录](#切换宏定义后必须清构建目录的-obj) |
| 示例 F28335 工程的模块和引脚 | 只有确认是该工程后才读 [工程地图](project-map.md)；其他板以自身源码和原理图为准 |

本技能有 DSP28335 + XDS100v1（`2-1SOGI_PLL`）、DSP28335 + XDS100v2（旧工程）和 F28379D + XDS100v2 的记录。探针型号以当前板的硬件描述、序列号和 `.ccxml` 为准；家族表里列出的其他型号表示有适配资料，不表示已上板验证。

## 切换宏定义后必须清构建目录的 obj

**CCS 的构建目录是 `<配置名>\`，不是 `Debug\`。**

工程 `.cproject` 里 `<configuration ... name="CPU1_RAM">` 的配置名直接决定输出目录：
`CPU1_RAM\`、`CPU1_FLASH\` 等。`.cproject` 里只写了 `buildPath="${BuildDirectory}"`，展开后就是配置名。
`Debug\` 只是旧版 CCS 或本 skill 自建产物的位置，**不要拿它当 CCS 的构建目录去清**。

**触发条件**：改过 `.cproject` 的 `compilerID.DEFINE`（增删 `_FLASH`、换器件宏等）之后，
CCS 的增量构建**只看源文件时间戳**，不会因为宏变了就重编。于是它把旧 obj 直接拿去链接，
而旧 obj 里带着上一个宏组合才有的符号引用，链接就报未定义。

**实测（2026-11-18，F28379D，`CPU1_RAM` 配置）**：为了验证 Flash 版临时给
`.cproject` 加了 `-D_FLASH`，随后撤销。撤销后 CCS 构建报：

```text
undefined          first referenced
_RamfuncsLoadSize  ./ti/common/source/F2837xD_SysCtrl.obj
_RamfuncsLoadStart ./ti/common/source/F2837xD_SysCtrl.obj
_RamfuncsRunStart  ./ti/common/source/F2837xD_SysCtrl.obj
error #10234-D: unresolved symbols remain
```

三个符号只在 `F2837xD_SysCtrl.c` 的 `#ifdef _FLASH` 块里的
`memcpy(&RamfuncsRunStart, ...)` 出现。而当时的构建命令行、`.cproject`、所有 `.mk`
**都没有 `_FLASH`**——引用完全来自 `CPU1_RAM\ti\common\source\F2837xD_SysCtrl.obj`
那个 14:16 留下的旧产物。

**处理：删构建目录里的 obj，不删 `*.mk`。**

```powershell
# <bd> = <工程>\<配置名>，例如 ...\F28379D_CPU1_Template\CPU1_RAM
Get-ChildItem <bd> -Recurse -File -Include *.obj,*.out,*.map,*.xml | Remove-Item -Force
```

保留 `makefile`、`*.mk`、`*.opt`、`*.d`：它们由 CCS 从 `.cproject` 重新生成，
删了也不影响，但没必要。

**等价做法**：CCS GUI 的 `Project → Clean…`。命令行/脚本环境下用上面这条更可控。

**判据**：清理后再构建，`warning #10247-D: dclfuncs` 这类无害告警可以留；
但 `error #10234-D` 必须消失。若仍出现同一个未定义符号，说明清错了目录——
再确认 `.cproject` 的 `name=` 与实际的构建目录名是否一致。

**配套规则**：切换宏属于改构建配置，**先清 obj 再构建**；不要用"多改一处、再看现象"的方式试，
否则无法区分是宏的问题还是旧 obj 的问题。
