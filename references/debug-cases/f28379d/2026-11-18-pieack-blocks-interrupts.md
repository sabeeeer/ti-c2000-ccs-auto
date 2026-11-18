# F28379D 中断全部不响应：PIEACK 未释放 + 受 EALLOW 保护

## 身份与适用范围

- 器件、板卡版本、目标核：TMS320F28379D，LAUNCHXL-F28379D，CPU1
- 模块/接口、工程与版本：PIE / ePWM2（128 kHz DAC 定时）/ ePWM4（10 kHz 控制）
- CCS、编译器、C2000Ware/其他库、探针：CCS 6.2 + ti-cgt-c2000 15.12.1.LTS，XDS100v2
- 状态：**已回归**（LOAD #89 起 ePWM2/ePWM4 中断全部恢复，实测 128,084 Hz / 10,003 Hz）
- 已验证的器件/板卡：F28379D LaunchPad；未验证的范围：其他 C2000 器件（PIE 结构相同，寄存器地址不同）

## 现象和复现

- 现象、检索词：PIE 中断"全部不响应"、`IFR` 恒 0、`PIEIFR` 置位、`ETFLG` 置位、ISR 一次都不进、`gXxxIsrCount` 恒 0；`PIEACK`
- 复现条件与最小步骤：新增一个 ePWM 定时中断（本项目把 DAC 正弦从"DMA 查表"改成"TMU 实时算 + ePWM2 中断"），重新下载后该中断与原有的 ePWM4 中断同时失效
- 期望值与实测值：
  - 期望 `gDacIsrCount` 每秒涨 128,000、`gCtrlTick` 每秒涨 10,000
  - 实测两者均为 0，`gDacLastCode` 恒为中点 2048
- 原始证据（LOAD #87/#88，均可复现）：

```
PC                        = 36277 (0x8DB5)   ← 在主循环 $C$L1，CPU 没卡死
IFR                       = 0                ← CPU 级中断标志全 0
IER                       = 0x44             ← INT3 + INT7 都已使能
PieCtrlRegs.PIEIER3.all   = 0x0A             ← INT3.2(ePWM2) + INT3.4(ePWM4) 都已使能
PieCtrlRegs.PIEACK.all    = 4                ← GROUP3 的应答位为 1（未释放）
PieCtrlRegs.PIEIFR3.all   = 0x0A             ← 两个中断都挂起
EPwm2Regs.ETFLG.all       = 1                ← INT 标志一直置位（ISR 从未清）
EPwm4Regs.ETFLG.all       = 5
EPwm2Regs.TBCTR           = 760 / 709 / 748  ← 计数器在走，时基正常
ClkCfgRegs.PERCLKDIVSEL.bit.EPWMCLKDIV = 1   ← EPWMCLK 100 MHz
EPwm2Regs.TBPRD           = 780              ← 100 MHz / 781 = 128,043 Hz，配置正确
```

## 排查与结论

### 走过的弯路（都排除了）

1. **怀疑时基被冻结**：`EPwm2Regs.TBCTL.all == 0` 看起来像 `TB_FREEZE`。**错**——TI 的 `F2837xD_EPwm_defines.h` 里 `#define TB_COUNT_UP 0x0`，而 `TB_FREEZE` 是 `0x3`。`TBCTL.all = 0` 恰恰就是"向上计数、不分频"，并且 `TBCTR` 在变化已证明时基正常。
2. **怀疑向量表没指到 ISR**：读 `PieVectTable.EPWM2_INT` = 35793，与 `EPWM2_DacISR` 地址 35793 完全一致，向量正确。
3. **怀疑 PIE 组号错**：TI 头文件 `F2837xD_PieVect.h` 注释明确 `EPWM2_INT // 3.2`、`EPWM4_INT // 3.4`，`PIEIER3.bit.INTx2/INTx4` 配置正确。
4. **怀疑中断使能没开**：`IER = 0x44`（INT3+INT7）、`PIECTRL.ENPIE = 1`，都正确。

### 根因（已用对照实验确认）

**`PIEACK` 未在首次中断前释放**。`PIEACK` 表示"该组中断已被 CPU 取走、等待 ISR 应答"，为 1 时 PIE 不再把该组请求送给 CPU。该工程 `main()` 只写了 `EINT; ERTM;`，**没有执行 TI 标准 `EnableInterrupts()` 里的 `PieCtrlRegs.PIEACK.all = 0xFFFF`**，于是 `PIEACK` 停在"待应答"状态，GROUP3 的请求永远送不到 CPU。

### 修复

`main()` 里 `EINT` 之前统一释放（TI 标准流程，`F2837xD_PieCtrl.c:101-117`）：

```c
PieCtrlRegs.PIEACK.all = 0xFFFFU;   /* 释放所有组的待应答位 */
EINT;
ERTM;
```

### 排除掉的错误结论（必须记住，否则会写错规则）

调试过程中曾判断"`PIEACK` 受 `EALLOW` 保护，写在 `EDIS` 之后无效"，并据此把清除语句挪进 `EALLOW` 块。**这个结论是错的**，已用对照实验证伪：

- 把 `PieCtrlRegs.PIEACK.all = PIEACK_GROUP3;` 移回 `EDIS` 之后（同时保留 `main` 里的整体释放），重新下载后一切正常（LOAD #90，`gDacIsrCount` 128 kHz、`gCtrlTick` 10 kHz 都在涨，`PIEACK = 0`）
- TI 自己的证据：`F2837xD_PieCtrl.c` 的 `InitPieCtrl()` 与 `EnableInterrupts()` **整个函数没有 EALLOW**，`adc_ppb_delay_cpu01.c:362` 的 ISR 里也是直接 `PieCtrlRegs.PIEACK.all = PIEACK_GROUP1;`

**教训**：一次修复同时改了两处（`main` 加整体释放 + `dac.c` 挪 EALLOW 位置），无法区分哪处起作用，于是把"恰好同时生效"误当成因果。**多改一处就必须做对照实验**，否则会写下错误的规则。

### 回归结果

```
gDacIsrCount  : 128,084 Hz   （理论 128,043 = 100 MHz / 781，误差 0.03%）
gCtrlTick     :  10,003 Hz   （理论 10,000）
gDacLastCode  : 在 451..3654 之间变化（正弦在输出）
PieCtrlRegs.PIEACK.all = 0
PieCtrlRegs.PIEIFR3.all = 0
ADC 采样（gCtrlSamples 前 20 点）：1850, 2856, 3654, 3654, 3120, 2169, 1184, 451, 451, 930, ...
                                  每 10 点重复 = 1 kHz 正弦（10 kHz 采样）
```

### 可复用教训

1. **"中断不进"的三层定位顺序**：先看 `IFR`（CPU 层）→ 再看 `PIEIFR`（PIE 层）→ 再看外设 `ETFLG`/`IFR`。`IFR=0` 而 `PIEIFR≠0` 一定卡在 `PIEACK`。
2. **打开中断必须执行 TI `EnableInterrupts()` 的完整流程**：`ENPIE = 1` + **`PIEACK.all = 0xFFFF`** + `EINT`。只写 `EINT` 会留下"待应答"位，对应组的中断永远送不到 CPU。
3. **`TBCTL.all == 0` 不是冻结**：`TB_COUNT_UP == 0x0`，判断时基是否在跑要看 `TBCTR` 是否变化，不要看 `CTRMODE` 的数值。
4. **`gMsTick` 在主循环里轮询定时器标志递增**，它正常增长**不能**证明中断在响应。判断中断是否真的在跑，必须用 `ISR 内的计数器`。
5. **新增中断时同步检查四件事**：`PieVectTable.X = &ISR`、`PIEIERx.bit.INTxn = 1`、`IER |= M_INTx`、**该组 `PIEACK` 是否为 0**。前三项都对、第四项没做，现象就是"配置全对但一次都不进"。
6. **一次改多处 = 无法归因**：修复必须一次只改一个变量。本案例中把"加 `PIEACK` 整体释放"和"把 `PIEACK` 挪进 `EALLOW`"同时做了，结果把"恰好同时生效"误判成 `EALLOW` 依赖，白写了一条错规则。

### 与旧案例的异同

- 与 `2026-11-15-xds100-link-drops` 不同：那次是 JTAG 链路问题，寄存器根本读不到；本次寄存器全部可读且值正确，只有中断不响应
- 与 `2026-11-15-preflight-and-link-drops` 不同：那次是下载/连接阶段失败；本次下载成功、程序在跑，只是中断服务没被调用
