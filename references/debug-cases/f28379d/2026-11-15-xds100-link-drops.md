# 2026-11-15 XDS100v2 的 JTAG 链路会自己断（表面一切正常）

> 本文保留当时的 PC 判据作为故障演变记录。现行通用读入口不读 PC，RAM/Flash 只作来源信息；目标应答由常驻 DSS 会话验证，数据可靠性由本次 CSV 和判据决定。不要把下文旧门禁复制到新脚本。

## 身份与适用范围

- 器件、板卡版本、目标核：TMS320F28379D（LAUNCHXL-F28379D）CPU1
- 模块/接口、工程与版本：JTAG/DSS 常驻会话；`F28379D_CPU1_Template`（`CPU1_RAM`）
- CCS、编译器、探针：CCS 12.8.1（`F:\ccs`）、`ti-c2000_15.12.1.LTS`、XDS100v2（板载）
- 状态：**已定位**（现象与判据已固化；掉线诱因未确认）
- 已验证的器件/板卡：F28379D + XDS100v2；未验证范围：DSP28335、XDS110、其他 USB 主机/线缆

## 现象和复现

同一天出现两次，两次都是"看起来在跑，其实已经读不了了"：

```text
SERVICE : RUNNING (pid 54920, since 2026-11-14 16:43:28)   ← 进程活着
PROBE   : XDS100 Class Debug Port / Auxiliary / USB Serial (COM11)  ← PnP 枚举正常
JUDGE   : image matches this build (sha256 B0E747A4BC1719BD)        ← hash 一致
JUDGE   : running from RAM: main = 0x00008A8D < 0x080000            ← 这一条"通过"
FAILURE: VALUE_READ_FAILED
REASON: ... Could not read 0x0000AC48@Data: target is not connected
```

逐项确认过的四个"假阳性"：

| 检查 | 掉线时的结果 | 说明 |
|---|---|---|
| Windows 枚举探针 | 正常，`PROBE : XDS100 ...` | PnP 层没掉 |
| 会话进程 | 存活，pid 不变 | DSS server 还在 |
| `sha256(.out)` 与会话记录 | 一致 | 主机文件没变 |
| 符号求值 `main` | **成功返回 `V main 35469`** | **符号表求值不需要目标应答** |
| 寄存器读 `PC` | **`E PC ... target is not connected`** | 唯一能证明链路活的检查 |

诱因未确认：两次都发生在连续多轮读/多次 `-Status`（含 PnP 枚举）之后，不排除 USB 线材、板载 FT2232 供电或主机 USB 选择性挂起。

## 排查与结论

- 已排除：程序跑飞（`gMsTick` 之前正常递增）；`.out` 被改（sha256 未变）；会话进程崩溃（pid 在）；探针被拔（PnP 仍在）。
- 根因（已证实）：**DSS 与目标之间的 JTAG 链路断开，而 DSS server 进程和 PnP 枚举都还在**。断开后 `target.connect()` 不会被旧会话自动重做。
- 修复/绕过：`-Stop` 然后 `-Start -ConfirmLoad`（换一个 LOAD 号）。旧会话不能自愈。
- 判据改动（2026-11-15）：第 ④ 道证明改为**直接读 `PC`**（寄存器，必须连接才应答），一次读取同时给出"链路是否活着"和"是否在 RAM 执行"：`PC` 读不到 → `TARGET_NOT_CONNECTED`（exit 4，**无开关**，`-AllowUnverified` 的语义只是"镜像可能是别的版本"）；`PC` ≥ 0x080000 → `NOT_RAM_IMAGE`。原来的 `main` 符号判据降级为交叉核对并打印在括号里，**因为它断线也算成功**。
- `service -Status` 现在默认枚举探针（`-NoProbeCheck` 可跳过），避免"RUNNING 却是死的"。
- 同日把第 ④ 道判据通用化：不再写死 `PC < 0x080000`，改为**用镜像自己的段表**判断 PC 是否落在本镜像的代码段内（段表来自 `<out>.map` 或 `ofd2000 --section_info`），换器件、改 boot 配置、改链接脚本都跟着镜像走；两者都拿不到时退化为设备地址表并**在输出里明示 fallback**。实测输出：`executing this image: PC = 0x00008A9A inside .text.2 (0x00008800..0x00008AC1, layout from ofd2000)`。

## 回归方式

- `tests/test_read_proofs.ps1` 第 5 组：无会话时 `Assert-TargetConnected` 必须 exit 4 + `TARGET_NOT_CONNECTED`，并且提示"`-AllowUnverified` 不适用"。
- 现场：掉线时 `run_read -Mode ReadOnly` 报 `TARGET_NOT_CONNECTED`；恢复后同一命令 `RESULT: OK`，`gMsTick` 递增。
- 未完成项：掉线的**触发条件**没有复现出来。若要定位，需要在 `server.log` 里找 `target is not connected` 之前最后一条 DSS 调用，并核对 Windows 事件日志里的 USB 选择性挂起记录。

## 与旧案例关系

与 [2026-11-14-on-target-audit](2026-11-14-on-target-audit.md) 同属"证明链不够硬"这一类，但那次的缺陷是"遗留 iterate 会话挡住只读"和"心跳取值路径"，这次是"链路断开仍被判定为健康"。两者都靠"符号表 ≠ 连接"这一条串起来。
