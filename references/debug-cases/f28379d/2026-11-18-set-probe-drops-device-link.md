# set_probe.ps1 重写 ccxml 丢掉 JTAG 链路节点 → invalid processor ID

- **日期**：2026-11-18
- **器件 / 核**：TMS320F28379D / CPU1（LAUNCHXL-F28379D）
- **探针**：XDS100v2，串号 `TI90I42A`
- **工程**：`1-1DMA_Ping-Pong/F28379D_CPU1_Template`
- 状态：**已回归**

## 现象链（两个独立问题叠在一起）

1. 下载报 **`-151`**：`IcePick_C_0: Error connecting ... no XDS100 is plugged in / invalid XDS100 serial number`，
   同时 `xds100serial -l` 报 `No XDS100 emulators were found`。但 PnP 里 COM11 是 OK，
   另有一串 `Unknown / Present=False` 的 XDS100 幽灵实例。
2. 按 skill 记录给 ccxml 加按串号选择时，用 `ti_c2000_set_probe.ps1 -Probe v2 -Serial TI90I42A`
   写入后，DSS 连不上的错误**从 `-151` 变成**：
   `Could not start server: DebugServer.1 ... Can't generate board data file ... An invalid processor ID has been found.`

## 根因

**问题 A（`-151`，配置缺失）**：ccxml 没有 `<Emulator Selection>` 按串号指定，
默认 `Value="0"` = "Only one XDS100 installed"，在多探针/有幽灵实例的机器上会打开到不可用的那块。
处置顺序见 `other-devices-and-probes.md` §3.1：串号 → USB 线/口 → 供电 → 驱动。

**问题 B（invalid processor ID，脚本 bug）**：`set_probe.ps1` 旧版第 6 步从零拼出整份 ccxml，
只保留一行 `devices` instance + 一个 c28x driver，丢掉了：

- `tixds100v2icepick_c.xml` / `tixds100v2cla1.xml` / `tixds100v2cs_child.xml` 三个 driver
- 整个 `<device>` 节点：`partnum="TMS320F28379D"` + `ICEPick_C` router + `Subpath_1`（JTAG 链路定义）
- configuration id 从 `...Debug Probe_0` 泛化成 `configuration_0`

对比备份 `.bak` 即可一眼看出。**这是脚本回归，不是探针/板子故障**——该工程此前 LOAD #102 一直成功。

## 修复

`set_probe.ps1` 改为**最小侵入式改写**，不再重建整份文件：

1. 读原 ccxml，定位 connection instance / device instance / platform；缺任一即 `CCXML_INCOMPLETE` 拒绝改写。
2. 只做三处替换：连接 desc/id（整串替换，保留 `_\d` 实例后缀）、connection 文件名、driver 前缀。
3. driver 逐节点处理：目标前缀文件在 targetdb 存在才换名，不存在则**原样保留 + NOTE**，
   **一个节点都不删**（v1 本就没有 cs_child，不能强求所有 driver 都有对应版本）。
4. `<device>` / ICEPick_C router / Subpath / platform 文本完全不动。
5. 串号块已有则改 Value，无则在 `<platform>` 前插入。

现场恢复：从 `.bak` 恢复完整 ccxml，再只手插串号块，LOAD #103 成功。

## 回归测试（保证不再犯）

`tests/test_set_probe_bruteforce.ps1`：用完整的 F28379D ccxml fixture（4 driver + device +
ICEPick_C router + Subpath + 串号），60 轮随机 v1/v2/v3 切换 + 格式变体 + 幂等 + .bak，
每轮断言：driver 节点数恒为 4、c28x 前缀跟随目标版本、device/partnum/router/Subpath/串号/configuration 后缀
（原先的 `test_set_probe_preserves_link.ps1` 已并入本测试并删除，它的"前缀必须真的改过去"断言保留在 `Assert-Complete` 里）
全部保留、XML 合法。旧脚本在此测试下会因丢节点而失败。

`tests/test_set_probe_bruteforce.ps1`（暴力测试，2026-11-18 用户要求）：六个 section——
A) 固定 seed 的 60 轮 v1/v2/v3 伪随机切换（专抓累积损坏/二次换前缀）
B) 8 种 fixture 格式变体（CRLF/LF × 有/无串号 × 有/无 `_0` 后缀）
C) 3 种非法参数必须拒绝且不改动文件
D) 幂等性（重复同一调用应为 no-op）
E) `.bak` 必须等于切换前的精确内容
F) 对真实工程 ccxml 再做 30 轮随机切换
每个断言都检查：4 个 driver 节点、每个 driver 文件在 targetdb 真实存在、device/partnum/
ICEPick_C router/Subpath/串号/configuration 后缀齐全、XML 可解析、无重复前缀。
**变异测试已验证**：把旧"从零重建"bug 重新注入一次性 skill 副本后，暴力测试立刻 FAIL
并逐条列出丢失节点——证明该测试确实能抓住这类回归，不是空跑。

## 可复用教训

1. **配置改写脚本一律"最小侵入"，不要从零重建 XML**——重建时"以为无关"的节点（device/router/
   非 c28x driver）恰恰是链路定义。缺字段的模板比旧的好配置更危险。
2. **`invalid processor ID` = ccxml 的器件/链路定义丢了**，不是探针坏；第一时间 diff `.bak`。
3. **不同探针版本的 driver 集合不同**（v1 无 cs_child），换前缀必须"存在才换 + 保留节点"，
   不能删节点也不能强校验"全部存在"。
4. **`-151` 先查 ccxml 是否按串号选探针**，别上来就让人拔 USB（本轮走过这个弯路）。

## 相关

- 串号选择规则与本机探针事实：`references/other-devices-and-probes.md` §3.1 / §3.2
- 错误码离线查询：`references/error-index.json`（`-151`、`CCXML_INCOMPLETE`）
- 回归测试：`tests/test_set_probe_bruteforce.ps1`（已取代并删除 `test_set_probe_preserves_link.ps1`）
