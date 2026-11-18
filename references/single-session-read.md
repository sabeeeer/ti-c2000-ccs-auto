# 常驻 DSS 会话读取

调试阶段先加载 RAM 镜像，再在**同一个仍在线的 DSS 会话**中运行和读取。不能把断开后的新连接当成这次 RAM 运行的延续。DSP28335 和 F28379D 的历史现场见各自调试案例；这是一条保守的跨器件工作规则，不能推断每块芯片断开都必然复位。

## 入口与状态

| 操作 | 行为 |
|---|---|
| `ti_c2000_service.ps1 -Start -ConfirmLoad [-Build]` | 用户同意后选择精确 `.out`、连接、验证连接、复位或有效链路上 halt 兜底、加载、运行，DSS 常驻。 |
| `ti_c2000_run_read.ps1 -Mode ReadOnly` | 读慢变量；不编译、不下载、不连接、不 halt。 |
| `ti_c2000_read_dma.ps1 -Mode ReadOnly -FrozenBufferReady` | 读固件冻结的**连续录波数组**——这是本 skill 唯一的数组读法，见下文「连续录波」。（点数按用途选：200 点约 20 ms，用于快速验证参数；1000~5000 点用于看波形。）DMA 双缓冲与 bank 选择已于 2026-11-18 移除。 |
| 两个读入口的 `-Mode LoadRead -ConfirmLoad` | 必要时停止旧会话，调用常驻服务加载一次，再经相同 ReadOnly 判据读取；读完保留服务。`-Standalone` 仅是此路径的旧别名。 |
| `ti_c2000_iterate.ps1 -UserApproved -Expect ...` | 只有用户明确要求连续运行才重复构建/加载/读/判据；最多 20 轮，下载间隔至少 5 秒。 |
| `ti_c2000_service.ps1 -Stop` | 显式结束会话。DSS 需要释放调试状态，可能暂时使探针重新枚举；不是普通读数步骤。 |

连续运行时的目标锁禁止外部 ReadOnly、LoadRead、Start/Stop 与第二个 Iterate 抢占。ReadOnly 与 `-Build/-ConfirmLoad/-Expect/-MaxLoads>1` 互斥；LoadRead 缺 `-ConfirmLoad` 拒绝。只读绕过开关 `-NoProbeCheck/-AllowUnverified/-NoHeartbeat` 已禁用。下载计数在 `readout/load-count.json`，只计**成功加载**；失败或部分 `loadProgram` 尝试看 DSS 日志。

## 读前必须呈现的证据

1. 工程入口检查通过，目标核和所选 `.out` 明确；精确 `.out` 不比源文件旧，SHA256 与会话加载记录一致。
2. 探针通过枚举和可用性检查，DSS 会话 PID 活着，目标实际应答。`connect()` 无异常或 `isHalted()==false` 都不够。
3. RAM/Flash 来源信息：若有 `.map` 与[RAM 自证契约](ram-proof-firmware.md)，报告 `.text` 所在区域及 `gRamProofTick` 是否推进；缺证据则报告 `UNKNOWN`。运行位置不作为下载或交付数据的门禁。
4. 本会话加载时记录过固件身份，读前身份仍相同，应用计数器跨时间窗推进。`gFwId` 必须随构建唯一变化；重复 ID 会留下旧固件冒充的风险。
5. 输出成功加载累计次数和本会话序号。两个读之间次数变化，数据属于不同运行。

链路掉线或会话不存在时没有当次数据可交；Flash、身份不符、计数器不动等情况仍交付实际读到的数值，并在同一次 `verdict.txt` 明确标 `FAIL` 或来源未知。开始新读时清理旧成功判据，不能把残留数字冒充当次结果。

## 读后校验

慢变量读：检查轮数、数值是否为有限数字、指定上下限、固件身份再次匹配、心跳推进，可选速率是否落在容差内。数组读：检查完成标志到位、复制前后标志及序号未变、点数齐全、首元素的表达式读与 `readData` 锚点一致。读到数字不等于数据可靠；最终以 `check/verdict.txt`、退出码 0 和 `RESULT: OK` 一起判定。详见[数据判据](data-read-verdict.md)。

## 连续录波：唯一的数据读取方式

**读数组之前必须先过心跳校验 —— 这是前提，不是可选项。**

```powershell
# 前提：确认程序在跑、数组确实冻结（缺这步，下面的数字不可信）
ti_c2000_run_read.ps1 -Variables gMsTick,gAmpFb,gCtrlLogFrozen -Mode ReadOnly   # 要 HEARTBEAT: OK
# 取数：
ti_c2000_read_dma.ps1 -FrozenBufferReady -ArrayName <数组> -Rows <点数> -Mode ReadOnly
```

不先验活就直接读数组，数字可能来自「早已停机」「上一轮残留数组」「另一份固件」，
而**这三种情况下数字都看起来正常**。心跳（`gMsTick` 递增）+ 冻结标志（`gCtrlLogFrozen=1`）
+ 固件身份一致，是判断"这批数据属于当次运行"的唯一依据。

**要把波形取出来，只有这一条路。** 机制始终是「ISR 采满 → 置冻结标志 → ISR 停止写入 →
JTAG 读静态数组」，**点数按用途选**（10 kHz 控制下）：

| 点数 | 时长（10 kHz 控制）| 用途 |
|---|---|---|
| **200**（冻结小数组）| **20 ms = 1 个工频周期** | **快速验证**：系统参数是否收敛、关键运行变量是否在预期范围 |
| 1000~5000（连续录波）| 100~500 ms = 5~25 个工频周期 | **量周期、相位、频率、THD、观察瞬态** |

**同一个 `ti_c2000_read_dma.ps1 -FrozenBufferReady` 入口，只差 `-ArrayName` 和 `-Rows`。**
小数组的意义是"够快就能多验几次"：200 点只要 20 ms 就采满，参数一改就能立刻验证；
大数组是为了一次看清波形形状。

DMA 双缓冲、ping-pong、bank 选择那一套已于 2026-11-18 从本 skill 移除——它要求 JTAG 在 DMA 持续覆写内存的同时去读，实测结果是：

```
6 槽环形快照：读 512 字全部返回 0x200000，随后 target is not connected
BuffA 直读：  每次 1~7 处接缝（读的 20~70 ms 里被覆写 1~7 次）
```

**根因不是"读得慢"，而是"读的时候有人在写"。** 连续录波换成"采满就停"，写的人先退出，问题自然消失。

### 原理

```
控制中断（每秒 f_ctrl 次）
   ↓ 每拍存一组变量到数组
gLog[N]   （N = f_ctrl × 录波时长）
   ↓ 存满 → 置冻结标志，ISR 不再写入
JTAG 读静态数组（读 72 ms 还是 720 ms 都不变）
```

对 50 Hz 系统，**20 ms 就是一个工频周期**。10 kHz 控制周期下：

| 录波时长 | 点数 | 含几个工频周期 |
|---|---|---|
| 20 ms | 200 | 1 |
| 100 ms | 1000 | **5** |
| 200 ms | 2000 | 10 |

### DMA 的使用边界：录波不用，其他照常用

**「录波不用 DMA」指的是"把 ADC 结果搬进数组"这一步**，不是整个工程禁用 DMA：

| 用途 | 用什么 | 说明 |
|---|---|---|
| **录波**（ADC → 数组）| **ISR 里逐点写** | 10 kHz 控制 ISR 直接 `gLog[idx].ia = ADCRESULT1` |
| **50 kHz 高频录波** | **同样用 ISR** | 每 20 µs 一次，ISR 约 40 周期 = 200 ns，占 1% CPU。**实测**（2026-11-18，F28379D）与 10 kHz 控制 ISR + 1 ms 定时器同时跑：定时器仍 1000 Hz、控制仍 9998 Hz、5000 点无接缝 |
| DAC 正弦输出 | **DMA 可以** | 查表 → DACVALS，不涉及"边写边读" |
| SCI 发送 | **DMA 可以** | 缓冲 → 外设，单向 |
| 内存间大块搬运 | **DMA 可以** | 单向 |

**为什么录波不能用 DMA**：DMA 写数组的同时 JTAG 在读，必然撕裂（实测 1~7 处接缝，或直接
`0x200000` 打挂链路）；而且 `BURST_SIZE = 0`（一次触发 1 字）时 `DST_BURST_STEP` 不推进
地址，整块缓冲只写 `[0]`。这两条都是本项目实测踩过的。

**不要把这个结论扩大到"整个工程不能用 DMA"**——DAC、SCI、内存搬运用 DMA 是正确且更省
CPU 的做法，禁掉反而亏。

### 必须先问用户四个参数

**不要替用户默认**——同样的 100 ms，10 kHz 是 1000 点，50 kHz 就是 5000 点，RAM 差 5 倍。

| 参数 | 典型值 | 决定什么 |
|---|---|---|
| **控制频率** `f_ctrl` | 10 kHz | 每秒采多少次 |
| **录波时长** `T` | 20 ms | 采多长时间 |
| **每点存几个数** `V` | 1 / 3 / 5 | 每次采样记录几个变量（ia / vref / error / pi / duty）|
| **目标器件** | F28379D / F28335 | 可用容量不同（168 KB vs 68 KB）|

**别把"每点几个数"和"ADC 通道"搞混**：

| 说法 | 含义 |
|---|---|
| ADC 通道 | 芯片引脚（ADCINA0、ADCINB1）|
| **点数** | 同一通道采了多少次，由 `f_ctrl × T` 决定 |
| **每点几个数** | 每次采样记几个派生量 |

存 ia/vref/error/pi/duty 五个，是**1 个通道 × 5 个变量**，不是 5 个通道。

### 先算 RAM 再写代码

**关于"字"**：C28x 是 16 位机，内存按 **word（字）** 寻址，**1 字 = 16 位 = 2 字节**，
`Uint16` 正好占 1 字，`Uint32` 占 2 字。下文"内存单元"就是这个 16 位单元。

```
点数 N        = f_ctrl × T
内存（字）    = N × 每点几个数
内存（字节）  = 内存（字）× 2
```

| 场景 | 点数 | 存 1 个数 | 存 3 个数 | 存 5 个数 |
|---|---|---|---|---|
| 10 kHz × 20 ms | 200 | 200 字 / 0.4 KB / **0.24%** | 600 字 / 0.72% | 1000 字 / 2 KB / **1.20%** |
| 10 kHz × 100 ms | 1000 | 1000 字 / 2 KB / 1.20% | 3000 字 / 3.6% | 5000 字 / 10 KB / **5.98%** |
| 50 kHz × 20 ms | 1000 | 1000 字 / 2 KB / 1.20% | 3000 字 / 3.6% | 5000 字 / 10 KB / 5.98% |

占比按 F28379D 实测总容量 83,661 字算；F28335 只有 34K 字，同样配置占比要乘约 2.5 倍。

**容量约束（必须检查，否则链接直接失败）**：

1. **单个 RAMGS 块只有 4096 字**。`N × V > 4096` 时必须把两块合并成一个 MEMORY 条目：
   ```
   /* MEMORY 里：把 RAMGS2 与 RAMGS3 合并（地址本就连续 0x0E000 + 0x1000 = 0x0F000）*/
   RAMGS23 : origin = 0x00E000, length = 0x002000
   /* SECTIONS 里 */
   ramgs23 : > RAMGS23, PAGE = 1
   ```
   **注意**：`>> RAMGS2 | RAMGS3` 这种写法对**单个大数组无效**——C28x 链接器不允许单个对象跨 MEMORY 条目，会报 `placement with alignment/blocking fails`。必须合并条目。
2. **合并后原块名消失，引用它们的段会立刻报 `program will not fit into available memory`**。TI 的 RAM 链接脚本里这几类段默认挂在 RAMGS0..RAMGS7 上，合并时必须一起处理：

   | 段名 | 默认块 | 处理 |
   |---|---|---|
   | `Filter1_RegsFile` | RAMGS1 | 不动 |
   | **`Filter2_RegsFile`** | RAMGS2 | 注释或改指向新段 |
   | **`Filter3_RegsFile`** | RAMGS3 | 同上 |
   | **`Filter4_RegsFile`** | RAMGS4 | 同上 |
   | **`Filter5_RegsFile`** | RAMGS5 | 同上 |
   | **`Difference_RegsFile`** | RAMGS4 | 同上 |

   这些都是 size 0 的示例占位段，注释掉不影响功能（实测 2026-11-18 合并 RAMGS2/3 与 RAMGS4/5 时逐个踩到）。

3. **`.ebss` / `.econst` / `.esysmem` 在 RAM 调试脚本里共用 `RAMLS5`（2048 字）**，往 `.ebss` 加几百字就会把 `.econst` 挤出去。大数组一律用 `#pragma DATA_SECTION` 放到 GS RAM。
4. 总占用建议 **< 可用 RAM 的 30%**，给栈、代码和后续扩展留余量；F28335 只有 34K 字，长窗口要先砍变量数。

### 改点数前先 grep 一遍共用同一宏的数组

`#define ..._SAMPLE_COUNT` 这类宏往往被**多个数组**共用，改一个数会连带把别的数组也撑大：

```
grep -rn "SAMPLE_COUNT" Hardware/ Framework/
```

**实测教训**：把 `CTRL_SAMPLE_COUNT` 从 200 改成 1000 时，`gCtrlSamples[1000]` 和
`gCtrlLog[1000]` 同时膨胀，`.ebss` 从 1000 字涨到 2236 字，超过 `RAMLS5` 的 2048，
链接直接失败（`program will not fit into available memory. .ebss size 0x8bc`）。
而 `gCtrlSamples` 与 `gCtrlLog[i].ia` 字段完全重复——删掉它，问题立刻消失。

**规则**：改点数前先列出所有用该宏的数组，**功能重复的删掉只留一份**，再算 RAM。

### 固件模板

```c
/* ---- 参数：改这三个数就够，其余自动推导 ---- */
#define LOG_FS_HZ     10000U                        /* 控制周期频率 */
#define LOG_MS        100U                          /* 录波时长 ms */
#define LOG_POINTS    ((LOG_FS_HZ / 1000U) * LOG_MS) /* 10 kHz×100 ms = 1000 点 */

/* ---- 每点存什么：按用户需要裁剪，变量越少 RAM 越省 ---- */
typedef struct {
    Uint16 ia;      /* ADCRESULTx */
    Uint16 vref;    /* 参考 */
    int16  error;   /* 误差（int16！导出要按有符号解析）*/
    int16  pi;      /* 控制器输出 */
    Uint16 duty;    /* 占空比 */
} LogPoint_t;

#pragma DATA_SECTION(gLog, "ramgs1")     /* 大数组必须指定段，别留在 .ebss */
volatile LogPoint_t gLog[LOG_POINTS];
volatile Uint16     gLogIdx    = 0U;
volatile Uint16     gLogFrozen = 0U;     /* 1 = 采满，可读 */

/* ---- 控制 ISR 里：每拍存一组 ---- */
static __interrupt void CtrlISR(void)
{
    if (gLogFrozen == 0U)
    {
        LogPoint_t *p = (LogPoint_t *)&gLog[gLogIdx];
        p->ia    = AdcaResultRegs.ADCRESULT1;
        p->vref  = 2048U;
        p->error = (int16)2048 - (int16)p->ia;
        p->pi    = p->error;
        p->duty  = EPwm1Regs.CMPA.bit.CMPA;

        gLogIdx++;
        if (gLogIdx >= LOG_POINTS)
        {
            gLogIdx    = 0U;
            gLogFrozen = 1U;      /* 冻结：ISR 之后不再写，数组静止 */
        }
    }
    /* ... 其余控制代码照常跑 ... */
}
```

**两个坑**：

- **采满那一刻的数据可能是"收敛前"的**。若上层还有 PI/软启动，上电 20~100 ms 就采满的话抓到的是过渡过程。做法：延时 N 秒后再启动采集（实测用 1 ms 任务在 `gMsTick > 3000` 时清数组并解冻）。
- **导出期间禁止任何会解冻/清数组的后台任务**（例如"发完 UART 自动 Resume"）。否则读到的是"清空后写一半"，表现为前一半有值、后一半为 0。

### 判据

| 项 | 要求 |
|---|---|
| `gLogFrozen` | 读到 1，且复制前后两次读一致（不能靠"一直为 0 所以没变"）|
| 点数 | 等于 `N`，非零元素数 = `N` |
| 段地址 | 在 map 里确认落在预期段，且不与 `.ebss` 重叠 |
| 数值范围 | 无 65494 这类"负数被当无符号"的值；`int16` 字段按有符号解析 |
| 无接缝 | 相邻差不应出现单点跳 3000 以上（正弦 50 Hz @ 50 kHz 时单点最大差约 130）|

### 导出：固定用 out/ 目录

每次录波单独一个子目录，**数据、脚本、图放一起**，便于回溯：

```
out/
  01-first-20ms-record/
    record50k-20ms.csv       数据（index,t_us,raw,volts）
    plot.py                  绘图脚本（从 CSV 读，不依赖工程）
    record-20ms.png
  02-50hz-pi-closed-loop/
  03-100ms-continuous/
    record50k-100ms.csv      5000 行
    record-100ms.png
    plot_100ms.py
```

**CSV 列规范**：至少含 `index` 与 `t_us`（或 `t_ms`），再加各变量；`int16` 字段导出前转成有符号。**不要**把 JTAG 一次读出的原始字直接当数值交付。



每次**数据请求**至少间隔 400 ms，另有 DSS 求值与文件往返开销。因此慢变量读取每秒最多约 2.5 次，实际更慢；默认 `-IntervalMs 500` 再增加等待。它只能看较慢的状态和趋势，不能还原 100 ms 一次的序列，更不能量相位、频率或脉冲。要看每个采样点，先在固件侧由定时器/ISR/DMA 采集到 RAM，冻结后在同一会话传出；JTAG 传输可长于采样窗口。

不应把“32 位变量看起来有值”当原子性保证：固件与主机的读写并发需要快照、序号或专用冻结协议。也不要把正在变化的 ADC 结果寄存器当成等间隔波形。
