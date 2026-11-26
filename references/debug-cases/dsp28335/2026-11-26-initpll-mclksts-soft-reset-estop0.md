# InitPll() 遇到 MCLKSTS 历史锁存残留直接 ESTOP0 停机，导致开环占空比停在初值 0.5

## 身份与适用范围

- 器件、板卡版本、目标核：TMS320F28335（`C28xx` 核），三相两电平逆变器控制板（外部 30 MHz 晶振，150 MHz 系统主频）
- 模块/接口、工程与版本：`DSP2833x_SysCtrl.c`（`InitPll()`）、`1-1Two_Level_OpenLoop_Demonstrate`（开环模式 `APP_MODE_OPENLOOP`，RAM 链接 `28335_RAM_lnk.cmd`）
- CCS、编译器、C2000Ware/其他库、探针：CCS `12.8.1.00005`（`F:\ccs`）、编译器 `ti-cgt-c2000_15.12.1.LTS`、XDS100v2（`0403/a6d0`，串号 `TIAAXJEA`）
- 状态：**已回归**（已完成目标板上板修复前后对比实测）
- 已验证的器件/板卡；未验证的范围：已在 DSP28335 两电平逆变器控制板实测回归；未在 F28379D 或无外部晶振条件下验证（若硬件确实无外部时钟，清零复检后仍会进入 `ESTOP0`）

## 现象和复现

- 现象、检索词、出现频率：
  - 现象：下载到 RAM 运行后，继电器不吸合、无实验现象，CCS Expressions 窗口里 `gDutyShow[0]` 一直保持 `.cinit` 初值 `0.5`；`ti_c2000_run_read.ps1 -Mode LoadRead -ConfirmLoad` 报 `FAILURE: SERVICE_START_FAILED / REASON: TARGET_HALTED_AFTER_RUN`。
  - 检索词：`InitPll`、`MCLKSTS`、`MCLKCLR`、`PLLSTS=0x109`、`0xa794`、`ESTOP0`、`TARGET_HALTED_AFTER_RUN`、`gDutyShow=0.5`、软复位锁存、硬件PLL vs 软件SPLL
  - 出现频率：一旦 `PLLSTS.bit.MCLKSTS` 在热复位/时钟切换瞬态被置位，不拉 `XRSn` 断电则每次软复位后 100% 复现
- 复现条件与最小步骤：
  1. 目标板之前因复位瞬态或调试切换留下 `PLLSTS = 0x109`（`bit3 MCLKSTS = 1`）。
  2. 通过 DSS 执行 `session.target.reset()`（CPU 软复位）并加载运行。
  3. 程序在 `vSystemInit()` -> `InitSysCtrl()` -> `InitPll()` 处立即触发 `ESTOP0` 停机。
- 期望值与实测值（带单位、时间或采样率）：
  - 期望：完成 `InitSysCtrl()`、约 `3 s` ADC 校零（`usZeroDone=1`）并吸合继电器（`gFlagRelay=1`），`gBootStage=8`，`gDutyShow` 在 `[0.35, 0.65]`（`M=0.3`）按 `50 Hz` 正弦变化。
  - 修复前实测：`EARLY_HALT at t=1s PC=0xa794`，`gBootStage=1`，`ClAdcCtrl.usSocCnt=0`，`SpwmCtrl.usEnable=0`，`gDutyShow[0]` 保持初值 `0.5`；而同一块板在 CCS GUI 界面（有 `f28335.gel`）之前一直可吸合继电器。
- 原始证据：
  - 反汇编 `Debug\1-1Two_Level_OpenLoop_Demonstrate.out`：
    - `0x0000a78e _InitPll:`
    - `0x0000a790 TBIT @0x11, #0x3`（测试 `PLLSTS.bit.MCLKSTS`）
    - `0x0000a794 ESTOP0`
  - DSS 寄存器实测（软复位前后）：
    - `BEFORE_RESET PC=0x3ff9ce PLLSTS=0x109 PLLCR=0xa`
    - `AFTER_RESET PLLSTS=0x109 PLLCR=0xa`

## 排查与结论

- 查过的当前器件 TI 例程、手册和工程配置：
  - 核对工程头 `DSP2833x_SysCtrl.h` 中 `PLLSTS_BITS`：`bit0=PLLLOCKS`、`bit3=MCLKSTS`（`0x0008`）、`bit4=MCLKCLR`（`0x0010`）、`bit8:7=DIVSEL`。
  - 对比 `F:\ccs\ccs_base\emulation\gel\f28335.gel` 及工程内 `DSP2833x_Libraries\DSP2833x_SysCtrl.c`。
- 已排除的原因及证据：
  - 已排除“刷新太快导致 `gDutyShow` 看起来像 0.5”或“没接直流源导致占空比不算”：`vSPWM_Run()` 不依赖直流采样，且实测在 `gBootStage=1` 就已停机，根本未走到 `vOpenLoop_Start()`。
  - 已排除“外部晶振硬件彻底损坏”：用户之前同板在 CCS GUI 下继电器一直吸合，且寄存器读回 `PLLSTS=0x109` 中 `PLLLOCKS=1`、`PLLCR=0xa`、`MCLKSTS=1`。
- 根因（已证实）：
  1. DSS 的 `session.target.reset()` 属于 CPU 软复位（不拉外部硬件 `XRSn` 引脚），`PLLSTS` 与 `PLLCR` 保留上一轮数值，因此一旦 `MCLKSTS` 锁存为 `1`，`reset()` 后依然是 `0x109`。
  2. 工程原版 `DSP2833x_SysCtrl.c` 的 `InitPll()` 只要检测到 `SysCtrlRegs.PLLSTS.bit.MCLKSTS != 0`，未先写 `MCLKCLR = 1` 清除历史锁存并复检，就直接执行 `asm(" ESTOP0")`，导致程序在 `vSystemInit()` 第 37 行卡死，后续 `vCL_ADC_Init()`、`vOpenLoop_Init()`、`vOpenLoop_Start()` 与 `vSPWM_Run()` 一句未跑。
  3. **易混淆区分**：此处报错的是**硬件系统时钟 PLL**（`InitPll()`，开环上电也必须执行，否则无 150 MHz 系统主频），**不能**删掉或挪到闭环；闭环初始化中的 `sogi_pll` 是**软件并网锁相环**，开环并未调用。
- 修复/绕过措施与代码位置：
  - 在 `E:\1-1Demonstrate_Program\1-1Two_Level_OpenLoop_Demonstrate\DSP2833x_Libraries\DSP2833x_SysCtrl.c` 的 `InitPll()` 中，先判断若 `SysCtrlRegs.PLLSTS.bit.MCLKSTS != 0`，则执行 `EALLOW; SysCtrlRegs.PLLSTS.bit.MCLKCLR = 1; EDIS; DELAY_US(100L);` 清除锁存并等待时钟检测窗口复检，确认仍为 `!= 0` 时再 `ESTOP0`。
- 回归方式、构建结果、上板结果；修复前后同条件数据与未完成项：
  - 构建：`ti_c2000_build.ps1 -Stage` 编译链接 OK（48 源文件，3 warnings，`349,482 B`）。
  - 下载：`ti_c2000_service.ps1 -Start -ConfirmLoad` `LOAD #1 RESULT: OK`（`sha A8024BC36AA3`）。
  - 上板对比：
    - 修复前：`PC=0xa794`、`PLLSTS=0x109`、`gBootStage=1`、`gFlagRelay=0`、`gFlagPwm=0`、`usSocCnt=0`、`gDutyShow[0]=0.5`。
    - 修复后：`PLLSTS=0x101`（`PLLLOCKS=1`、`MCLKSTS=0`）、`gBootStage=8`、`gFlagZeroCalib=1`、`gFlagZeroTimeout=0`、`usZeroDone=1`（`usZeroTimeMs=3026 ms`）、`gFlagRelay=1`、`gFlagPwm=1`、`SpwmEnable=1`；间隔采样 `gRunMs` 从 `1771` 增至 `2633`、`usSocCnt` 从 `15123` 增至 `23748`；`gDutyShow=[0.3875, 0.6422, 0.4704]`（和为 `1.5000`）。
- 与旧案例/其他器件的相同点和差异：
  - 与 `2026-11-18-pieack-blocks-interrupts` 类似，都是只读到表层输出不更新（中断/变量不动）误以为算法或刷新频率异常，必须实测停机 `PC` 与寄存器标志位才可定因；该现象与 F28335 `PLLSTS.MCLKSTS` 锁存机制强相关。
