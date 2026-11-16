---
name: ti-c2000-ccs-auto
description: 审查、编译和调试 TI C2000 CCS 工程。先选单步/连续运行模式与只读/本次加载读模式，再进入器件与 CCS、TI 算法库、调试经验三类资料；错误用独立离线查询模式。读数据保持同一 DSS 会话，下载须用户明确同意。
---

# TI C2000 / CCS 工程

本 skill 有**两种运行模式 × 两种读模式**，共用**三类资料入口**；另有只查记录的 **Error 模式**。模式由脚本互锁，不靠 AI 自觉。选定实际工程、器件、目标核、探针和任务后，先读工程入口文件，再调用本 skill 的脚本。用户没有要求上板时，只做文件与离线测试。

> **RAM 读数前提**：通用读路径不读 PC。固件须按[RAM 自证契约](references/ram-proof-firmware.md)提供只由 RAM 函数更新的 `gRamProofTick`；所选 `.map` 与加载时记录的 SHA256 必须一致，`.text`、更新函数和计数器都须定位到 RAM，计数器还要推进。旧固件缺此契约就拒绝只读，不回退到 PC 或固定地址。该机制已通过离线模拟，尚未上板实测；`gFwId` 重复使用仍会削弱版本证明。

## 先让 AI 找到正确入口

在新 CCS 工程创建之初，用 `tools/init_project_entry.ps1 -ProjectPath <工程>` 生成相同的 `AGENTS.md`、`CODEBUDDY.md`、`CLAUDE.md`；它遇到已有不同内容会拒绝覆盖，需人工合并。开始工程操作前，读本文件和工程 `AGENTS.md`，再运行已安装 skill 的 `scripts/check_project_entry.ps1 -ProjectPath <工程>`。只有退出码 0 且 `RESULT: OK` 才继续；先清理工程里的旧 `ti_c2000_*.ps1/.js` 副本。每次脚本输出必须有 `SKILL   : ti-c2000-ccs-auto@<版本>`；版本由入口、运行脚本、资料和维护工具的内容哈希生成，脚本单独变更也会换号。成功还须退出码 0 与 `RESULT: OK` 同时成立。

CodeBuddy 源目录 `~/.codebuddy/skills/ti-c2000-ccs-auto` 是唯一维护源。改完先运行 `tools/sync_platform_copies.ps1 -DryRun` 检查 `PRUNE` 清单，再同步到 Codex 等平台副本；不要直接编辑平台副本。

## 模式、入口与互锁

| 维度 | 入口与行为 |
|---|---|
| 单步运行（默认） | `scripts/ti_c2000_service.ps1 -Start -ConfirmLoad [-Build] [-CorePattern <核名匹配式>]`：获准后构建、选定 `.out`、加载一次、运行并保留 DSS 会话。仅在 `.ccxml` 有唯一 CPU 时自动选核；多个 CPU 必须明确指定且只匹配一个，记录实际核名。`-Status` 只报告；`-Stop` 会结束会话，可能使探针重新枚举，只在明确结束/更换镜像时使用。 |
| 连续运行（用户点名才启用） | `scripts/ti_c2000_iterate.ps1 -UserApproved -Expect ...`：最多 20 轮；每轮构建、加载、运行、读、判据。相邻下载尝试至少隔 5 秒；连接重试和探针恢复应留间隔。运行期间其他读/加载/Stop 由锁拒绝。 |
| `ReadOnly`（默认读） | `scripts/ti_c2000_run_read.ps1 -ProjectPath <工程> -Variables ...` 读慢变量；`scripts/ti_c2000_read_dma.ps1 -FrozenBufferReady ...` 读固件冻结数组。零构建、零加载、零重连、零因读而 `halt`；附着现有服务，在程序运行时读取。DMA 路径须有固件初始化与冻结/序号协议，目前尚未上板验证。 |
| `LoadRead`（本次获准加载后读） | 同一公开读入口加 `-Mode LoadRead -ConfirmLoad [-Build]`。若旧会话存在，先明确停止；服务加载新镜像并**留在该会话**，再调用正常 `ReadOnly` 判据；读完不 `halt`/断开。`-Standalone` 是同一路径的旧别名。`-MaxLoads/-Expect` 的循环每轮仍受 5 秒门限。 |
| Error（离线） | 失败时**先查** `scripts/ti_c2000_error.ps1 -Code <错误码>` 或 `-LogPath <日志>`，再读[错误索引](references/error-index.json)。查询不连接、不构建、不复位、不下载；新故障经实测复盘后录入第三类。 |

下载只能在用户明确同意后传 `-ConfirmLoad`，连续运行还要求用户明确提出反复运行并传 `-UserApproved`。`ReadOnly` 与 `-Build/-ConfirmLoad/-Expect/-MaxLoads>1` 互斥；`-NoProbeCheck/-AllowUnverified/-NoHeartbeat` 的只读绕过已禁用。`RESULT: FAIL`、缺 `RESULT: OK`、非零退出码都不是成功；不得用另一次烧录“凑出”读数。

其余入口职责：`scripts/ti_c2000_build.ps1` 只编译；`scripts/ti_c2000_debug.ps1` 只做探针检查或获准的显式加载/运行；`scripts/ti_c2000_readmode.ps1` 管互锁与时间门限；`scripts/ti_c2000_loadcount.ps1` 管成功加载记录；`scripts/ti_c2000_check_read.ps1` 离线核对 CSV。这些脚本不提供另一条绕过常驻服务的读数路径。

## 读前告知、读后判据

读前先报告：所选 `.out/.map` 与 SHA256、工程内源码和构建配置是否比该产物新、目标核与 RAM/Flash 自证、探针是否枚举且可用、DSS 进程与目标连接是否仍有效、运行的固件身份、累计成功加载次数及本会话加载序号、应用心跳是否在推进。工程外链接源码的新旧不能靠工程内时间戳证明，须结合构建记录和唯一 `gFwId`。仅有进程 PID、`connect()` 没抛异常、`isHalted()==false`、符号能解析，任何一项都不构成充分证明。`dssLinkIsUp` 要显式验证 `target.isConnected(true)` 再查询目标。

读后还要查：采样轮次完整，心跳/可选速率、固件身份、数值有限性与指定范围；数组另查冻结标志达到完成值、复制前后标志和序号未变、点数与表达式锚点一致。任一证据失败就报告失败，清除旧 `result: OK` 和旧 CSV；不能把“取到数字”写成“数据可靠”。变量轮询不能还原快速波形，µs 级波形由固件先采满、冻结后再传。详细阈值见[读数判据](references/data-read-verdict.md)，DSS 会话边界见[单会话读取](references/single-session-read.md)。

**时间门限**由 `references/firmware-contract.json` 维护：下载尝试之间至少 5000 ms；连续数据请求之间至少 400 ms；重连至少留 400 ms 且须再次验证探针可用。编译成功后加载的必须是**选定的那份** `.out`，比源文件旧就拒绝。`readout/load-count.json` 记录成功加载次数；失败或部分写入的 `loadProgram` 尝试还需看 DSS 日志，不能把该计数当成所有物理写入次数。

连续运行的当前实现每轮会显式 `-Stop` 再 `-Start`，因此**仍会在不同下载轮次间重连**；它会等待探针可用并遵守间隔，但不能称为零重连。普通连续读保持同一会话，不执行这一流程。若 `-Stop` 未干净退出或探针未恢复，循环立即中止；同会话热重载尚未上板验证，不能用推测替代现有受控流程。

## 三类资料入口（两个运行模式共用）

| 类别 | 进入时机 | 首先读 |
|---|---|---|
| 一、器件与 CCS 工程 | 换 DSP28335、F28379D 或新芯片，处理板、探针、核、`.cproject`、`.ccxml`、编译器、`.cmd/.map`、启动与外设配置。 | [器件与工程](references/device-platform.md)、[RAM/链接](references/ram-and-linker.md)、[TI 同器件外设例程](references/peripheral-examples.md)。探针与器件差异仅放在本类。 |
| 二、TI 算法库 | 找现成 DCL、DMC、C2000Ware、controlSUITE、SolarLib，或移植控制/测量/PLL 等。 | [库入口](references/ti-algorithm-libraries.md)、[SolarLib 目录](references/solarlib-catalog.md)。SPLL 另读[完整 SolarLib PLL 文档](references/spll-pll-algorithms.md)；dq/abc 另读[变换规范](references/dq-transforms.md)。先查本机库、示例、头文件和链接要求。 |
| 三、调试经验 | ADC、SCI 串口、SPI、原子访问、eCAP 等任何器件/模块的实测异常。 | [调试经验索引与归档规则](references/debugging-experience.md)、[判据](references/data-read-verdict.md)。保存症状、原始数据/日志、器件和模块、复现条件、根因证据及适用范围；新案例登记索引并运行 `scripts/check_debug_catalog.ps1`。 |

同一任务可查多类，但只把新事实归入其主类：eCAP 配置与官方模板在第一类，eCAP 实测故障在第三类。不能把 DSP28335 或某个 XDS 的现场现象推广到所有芯片/探针。第二类的 SolarLib、DCL、DMC 文档和第一类的 28379D 功能不得因精简入口而删除。

## 维护与离线复核

先改 `references/firmware-contract.json`，再运行 `tools/audit_fw_contract.ps1`，按其 `VIOLATION` 修改脚本，复跑至 `RESULT: OK`。出错先用 Error 模式，再把新证据放入第三类；新增器件进第一类，新增 TI 库进第二类。改后运行离线 `tests/test_*.ps1`（不运行需真机的 `test_e2e_readonly.ps1`）、`tools/audit_js_identifiers.ps1`、`tools/audit_dead_params.ps1`、`tools/audit_fw_contract.ps1`、`scripts/check_debug_catalog.ps1` 和 Codex `quick_validate.py`，检查输出与退出码。上板结论必须另标“实测”，不能拿离线测试代替。
