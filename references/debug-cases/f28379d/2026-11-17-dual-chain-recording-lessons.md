# F28379D 双链录波（10 kHz 控制 + 50 kHz 波形）实现过程中的可复用教训

## 身份与适用范围

- 器件、板卡版本、目标核：TMS320F28379D，LAUNCHXL-F28379D，CPU1
- 模块/接口、工程与版本：ADC-A / DMA CH2 / ePWM3(50 kHz) / ePWM4(10 kHz) / SCI-A；工程 `1-1DMA_Ping-Pong\F28379D_CPU1_Template`
- CCS、编译器、C2000Ware/其他库、探针：CCS 6.2 + ti-cgt-c2000 15.12.1.LTS，XDS100v2
- 状态：**已回归**（双链并行 + 20 ms 冻结 + CSV 导出 + RAM 统计均实测通过，LOAD #84）
- 已验证的器件/板卡：F28379D LaunchPad；未验证的范围：其他 C28x 器件、其他探针、F28335 的 DMA 行为

## 现象和复现

- 现象、检索词、出现频率：录波链路多次出现"数据撕裂 / 只有 `[0]` 有值 / 上传卡死 / JTAG 读报 `0x200000` 并断链"，每一轮现象不同但根因都在方法层面
- 复现条件与最小步骤：见下列各条的"触发条件"
- 期望值与实测值：
  - 期望 20 ms 无接缝波形；实测曾出现 `BuffA` 只有 `[0]`=1476、其余 511 点为 0（LOAD #71~#75）
  - 期望 JTAG 读静止数组；实测读到 512 个字全部 `Error: 0x200000`，随后 `target is not connected`
- 原始证据：`out\01-first-20ms-record\`（record50k-20ms.csv、record10k-ctrl-20ms.csv、record_compare.png、ram_usage.txt）；工程内 `BUILD_VERIFICATION.txt` 有 LOAD 编号与关键读数

## 排查与结论

### 可复用教训（按编号，按"下次先查这里"的顺序排列）

1. **用等待时间推断 I/O 耗时，而不是实测**
   触发条件：脚本里有 `Start-Sleep`，随后把总耗时归因于读取本身。
   本例：把 `Start-Sleep -Milliseconds 2500` 当成"JTAG 读 512 点要 2.5 秒"，据此推断"DMA 覆盖 244 次、必须做 CPU 快照"，实际读 1000 点约 140 ms，图上只有 1 处跳变。
   正确做法：读写前后各取一次 `gMsTick`，差值才是真实耗时；`Sleep` 是"等一下"，不是"读多久"。

2. **图上能数出来的东西，不要用公式推翻它**
   触发条件：文字结论与刚生成的波形图矛盾。
   本例：图上只有 1 处接缝，文字写"244 次覆盖"。
   正确做法：先信图，再解释图；矛盾时优先怀疑自己的推算。

3. **先问"能不能停下来"，只有不能停才需要缓冲**
   触发条件：要做录波、要读数组。
   本例：一开始就上 ping-pong + memcpy + 环形缓冲 + 触发冻结，绕了十几轮；最终"采满 20 ms 让 DMA 停住、数组冻结、JTAG 随便读"一次成功。
   正确做法：单次抓取优先用"采满即停"（`CONTINUOUS=0` + 关 `PERINTE`），连续录波才上 ping-pong + 快照。

4. **涉及采样率/帧长/控制率/读取耗时的改动，先画时间轴**
   触发条件：改 `EPWM3_CTRL_FREQ_HZ` 或 `DMA_BUFFER_POINTS`。
   本例：把采样率从 50 kHz 改到 128 kHz 只算了"1:1 对应"的好处，没算帧变短导致读取期间覆盖次数变多。
   正确做法：列出 采样周期、帧时间、帧率、读取耗时 四个量，确认"读取耗时 < 帧时间"再动手。

5. **外设寄存器先看官方例程的实际参数，不按名字猜单位**
   触发条件：配 `DST_BURST_STEP` / `DST_TRANSFER_STEP` / `BURST_SIZE`。
   本例：把 `DST_BURST_STEP` 设成 1，以为"前进一个字"；C28x DMA 地址按字节计，一个 `Uint16` 是 2 字节，官方 `DMACH1BurstConfig(15, 2, 2)` 的两个 2 就是字节步进。
   正确做法：打开 `device_support/<器件>/examples/cpu1/` 对应例程，照抄参数再理解。

6. **同一机制失败两次就停下来查根因，不要靠换参数蒙**
   触发条件：已经改了两轮参数仍然不对。
   本例：单通道 + 影子改写做 ping-pong 试了 5 次下载（LOAD #71~#75），根因是 `BURST_SIZE=0` 时两个步进寄存器都不推进地址。
   正确做法：连失败两次就转向查手册/例程，或换方案。

7. **"数据看起来乱"不要先归因成硬件连接**
   触发条件：ADC 读数与预期不符。
   本例：判断"DACOUTA 和 ADCINA0 没连、要接跳线"；TI 三个 buffdac 例程的注释都写 `DACOUTA/ADCINA0 (HSEC Pin 9)`，是同一引脚。
   正确做法：先查芯片手册与官方例程确认硬件事实，再怀疑接线。

8. **两条独立采集链必须用各自的 SOC 和结果寄存器**
   触发条件：控制链与录波链并行。
   本例：控制链读 `ADCRESULT0`，而它属于 50 kHz 录波链，采样时刻在 0~20 µs 间浮动。
   正确做法：控制链配独立 SOC（本例 `SOC1`，`TRIGSEL=11` 指向 ePWM4 SOCA），读 `ADCRESULT1`，相位才确定。

9. **导出前必须停掉所有会写该数组的后台任务**
   触发条件：数组由中断写，同时有上传/统计任务会修改或清空它。
   本例：UART 上传发完调 `CtrlLog_Resume()` 解冻并清零数组，JTAG 读到"清空后写一半"的数据（200 组里只有 95 组合法）。
   正确做法：导出前确认冻结标志稳定、`gXxxTotal` 不再增长；把自动解冻的任务临时摘掉。

10. **结构体导出前确认每个字段的符号性**
    触发条件：字段含负数。
    本例：`error`/`pi` 是 `int16`，按 `Uint16` 读出变成 64108。
    正确做法：导出时按 `>=32768 减 65536` 转有符号；校验一行 `error == vref - ia` 就能立刻发现。

11. **新增周期性传输前先算总带宽**
    触发条件：往同一个串口/总线加第二个数据源。
    本例：SCI 115200 每 ms 只有 11.5 字节，`Wave_Task1ms` 已占 6 字节，`CtrlLog` 又想每 ms 发 12 字节，FIFO 永远满、上传卡死（`UploadFrames` 恒为 0）。
    正确做法：所有生产者字节数之和 < 链路带宽 × 80%；本例改成每拍 2 字节（合计 8 B/ms）才通。

12. **动手前先列工作区已有的脚本和工具，能改就不新建**
    触发条件：需要写新脚本。
    本例：`Tools\` 下已有 `dac_adc_compare.py`、`dma_pipeline_diagram.py`，仍新写了一份 `plot_record.py`。
    正确做法：先 `Get-ChildItem Tools`，能扩展就扩展，避免同一功能多份实现。

13. **先明确工程是"测试平台"还是"目标原型"**
    触发条件：讨论"实际工程怎么做"。
    本例：多次把 1.28 MSPS / 640 点的 DMA 压力测试当成"实际控制环"，绕回 50 kHz 录波 + 10 kHz 控制才清晰。
    正确做法：先写清当前目标是验证吞吐、还是复刻控制环，两者的采样率、DMA 需求、判据完全不同。

14. **同一个坑第二次出现，说明第一次的修复没固化**
    触发条件：又踩到熟悉的错误。
    本例：`SINGLE` 模式下不关 `PERINTE` 导致 ISR 空转（`gDmaSeq` 冲到 13 万/秒），代码里曾留着同样的问题。
    正确做法：修完立刻写进工程注释或本技能案例，让下次检索得到。

### 查过的当前器件资料

- `examples/cpu1/adc_soc_continuous_dma/cpu01/adc_soc_continuous_dma_cpu01.c`：`DMACH1BurstConfig(15, 2, 2)`、`DMACH1TransferConfig(63, -14, 2)`
- `common/source/F2837xD_Dma.c`：`DST_BURST_STEP` 注释为 "between each word"，`TRANSFER_STEP` 为 "between each burst, ignored when WRAP occurs"
- `examples/cpu1/buffdac_enable|random|sine_dma`：`DACOUTA/ADCINA0 (HSEC Pin 9)`
- `F2837xD_adc.h`：`TRIGSEL` 5~16 依次为 ePWM1~6 的 SOCA/SOCB（`10` = ePWM3 SOCB，`11` = ePWM4 SOCA）

### 已排除的原因

- 不是 DAC 与 ADC 未连接：同引脚，见教训 7
- 不是 DMA 配置缺失：`EALLOW`、`RUN`、`PERINTE`、`SOFTRESET` 均已确认
- 不是链路硬件故障：每次断链都发生在"对中断高频写入的内存做批量读之后"，重建会话即恢复

### 根因（已证实）

- 单通道 ping-pong 失败：`BURST_SIZE=0` 时地址步进不生效，整块缓冲只写 `[0]`
- JTAG 读中断高频写入区必失败：`memory.readData` 返回 `0x200000`，随后断链
- 上传卡死：SCI 带宽被两个生产者超额占用

### 修复与代码位置

- `Hardware/DMA/h/dma.h`：`DMA_MODE = DMA_MODE_SINGLE`，`DMA_BUFFER_POINTS = 1000`
- `Hardware/DMA/c/dma_single.c`：ISR 里关 `PERINTE`/`RUN` 冻结；新增 `DMA_CaptureRestart()`
- `Hardware/ADC/c/adc.c`：`SOC0`→ePWM3 SOCB（录波），`SOC1`→ePWM4 SOCA（控制）
- `Hardware/EPWM/c/epwm.c`：`EPWM4_Init()` 开 SOCA；`EPWM4_CtrlISR` 里写 `gCtrlLog[200]` 并在满 200 组时置 `gCtrlLogFrozen`
- `Hardware/EPWM/h/epwm.h`：`CtrlLog_t`（ia/vref/error/pi/duty）+ `CtrlLog_Resume()`
- `Hardware/UART/c/wave.c`：`CtrlLog_UploadTask()` 每拍 2 字节的字节状态机（当前未挂到调度器，导出期间不能自动解冻）

### 回归结果

- 双链并行：`gCtrlLogTotal` 与 `gDmaSeq` 同时正常推进，`gCtrlTick` 约 10 kHz
- 20 ms 冻结：`BuffA[1000]` 1000 点全非零、大跳变 0 处；`gCtrlLog[200]` 200 组合法、`error == vref - ia` 逐行成立
- RAM：总使用 9,964 字 = 19.46 KB / 163.40 KB（11.9%）；录波新增仅约 2.2 KB
- 数据与图：`out\01-first-20ms-record\`

### 与旧案例的异同

- 与 `2026-11-15-xds100-link-drops` 相同：断链的表象相似；不同：本次断链由"对高频写入内存批量读"触发，可稳定复现
- 与 `2026-11-07-read-halt-bulk-array` 相同：都是"读活跃内存"的问题；不同：本次结论是"要么采满停住，要么先 HALT DMA"，而不是靠加缓冲绕
