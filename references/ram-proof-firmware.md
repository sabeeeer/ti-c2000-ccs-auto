# 不读 PC 的 RAM 运行自证

该契约新增两个可选的固件符号：`gRamProofTick` 与 `TiC2000_RamProofTick`。调试代码每 1–10 ms 调用一次更新函数，且**只有此函数写计数器**。上位机在常驻 DSS 会话里核对：加载时钉住的 `.out/.map` SHA、`.text` 的 RAM 运行区、更新函数及计数器的 RAM 地址、计数器在两次请求间递增。证据不足就把运行位置标为未知，不因此拒绝下载或扣留已读数据；不查询 PC，也不使用固定 Flash 基址。

下面是 TI C28x C 编译器示意，移入工程前按当前编译器和 `.cmd` 核对语法：

```c
volatile unsigned long gRamProofTick = 0UL;

#pragma CODE_SECTION(TiC2000_RamProofTick, ".TI.ramfunc")
#pragma FUNC_CANNOT_INLINE(TiC2000_RamProofTick)
void TiC2000_RamProofTick(void)
{
    ++gRamProofTick;
}
```

在实际工程的定时 ISR 或主循环中周期调用 `TiC2000_RamProofTick()`。`FUNC_CANNOT_INLINE` 保留独立函数符号，供 `.map` 与 DSS 符号查询核对。较旧编译器若不支持该 pragma，先按其版本手册改用受支持的禁止内联方式并通过真实编译，不能删掉约束后假称通过。TI 官方的 [C28x 优化指南](https://software-dl.ti.com/C2000/docs/optimization_guide/phase3/memory.html)给出 `ramfunc` 属性、旧编译器 `CODE_SECTION` 和 `LOAD/RUN` 链接示例；[编译器手册](https://downloads.ti.com/docs/esd/SPRU514I/Content/SPRU514I_HTML/tms320c28x_c_c_language_implementation.html)说明 `FUNC_CANNOT_INLINE` 的作用。

若要证明 RAM 运行，`.cmd` 应把 `.text` 与 `.TI.ramfunc` 的**运行地址**指向本芯片 RAM 区，把 `gRamProofTick` 所在数据段指向 RAM。RAM 调试工程可以直接 `> RAM...`；若从 Flash 加载再复制到 RAM，应先执行拷贝。通用位置识别只把 `.map` 中以 `RAM` 命名的内存区识别为 RAM；若工程采用 `BEGIN` 等别名，先在第一类器件资料中核对并建立明确的区域定义，未识别时报告 `UNKNOWN`，不据此拒绝下载或扣留数据，也不凭 boot 名称猜测。不要照抄其他芯片的 RAM 名称或地址。编译后检查所选 `.map` 的 `MEMORY CONFIGURATION` 和 `SECTION ALLOCATION MAP`，并核对 `.out` 与 `.map` 是否属于同一次构建。

**证据边界**：该机制证明 RAM 区中的更新函数确实被周期执行，并检查 `.text` 的 RAM 链接位置；它不自动证明每个自定义代码段都在 RAM，也不能防止别处错误地递增同一变量。工程代码审查必须确认“唯一写者”和其他代码段，`gFwId` 必须对每次构建唯一。尚未在目标板验证之前，只能称离线契约与脚本检查通过。
