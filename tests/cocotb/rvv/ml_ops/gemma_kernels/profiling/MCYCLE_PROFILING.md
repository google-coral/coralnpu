# Gemma Decoder Layer 的 `mcycle` 分阶段 Cycle Profiling

本文说明 CoralNPU 中 `mcycle` 的责任边界、计数原理，以及如何为顺序执行的
Gemma decoder layer 算子得到可信的 cycle 数据。这里的 cycle 是目标 RISC-V
核的硬件时钟周期，不是 Cocotb/Python 在 host 上的耗时。

## 结论与责任边界

`mcycle` **由硬件 CSR 模块维护**，不是 C++ runner、kernel 或 Cocotb 维护的
软件变量。

| 层次 | 责任 | 相关位置 |
| --- | --- | --- |
| RTL | 保存 64-bit 计数值，每个 CSR 模块时钟周期自动加一，支持 CSR 读写 | `hdl/chisel/src/coralnpu/scalar/Csr.scala` |
| C++ 工具函数 | 通过 `csrr` 读取一致的 64-bit 快照 | `sw/utils/utils.h` 中的 `mcycle_read()` |
| Decoder runner | 在整层或单个阶段的起止边界读取快照，并把差值写进 ELF 全局符号 | `rvv_bf16_gemma_decoder_layer_profile_runner.cc`、`rvv_gemma_decoder_layer_profile.cc` |
| Cocotb | 按 ELF 符号地址读回结果、打印和校验；不参与计数 | `cocotb_tests/rvv_gemma_decoder_layer_profile_cocotb_test.py` |

因此，若问题是“谁负责让计数器走动”，答案是 `Csr` RTL；若问题是“谁决定
某个 cycle 归属哪个算子”，答案是 profiling runner 中放置的时间戳边界。

## RTL 原理

`Csr.scala` 中的 `mcycle` 是一个复位为零的 64-bit 寄存器：

```scala
val mcycle = RegInit(0.U(64.W))
...
mcycle := Mux(mcycle_written, mcycle_t, mcycle + 1.U)
```

在 RV32 配置中：

- `mcycle`（CSR `0xB00`）读写低 32 位；
- `mcycleh`（CSR `0xB80`）读写高 32 位；
- 非 CSR 写周期执行 `mcycle + 1`；写入 `mcycle` 或 `mcycleh` 的周期以写值为准，
  不再额外加一；
- 低 32 位自然回绕并进位到高 32 位。

当前实现没有 `mcountinhibit` 或按“是否退休”使能的条件。因此只要 CSR 模块的
时钟在运行，`mcycle` 就递增；它统计的是经过的硬件周期，包含访存停顿、流水线
停顿、函数调用和计时代码本身。它不同于 `minstret`，后者按退休指令数累加。

## 为什么要用高—低—高读取

RV32 一次 CSR 读取只能得到 32 位。`mcycle_read()` 按下列顺序读取：

```text
high_1 = mcycleh
low    = mcycle
high_2 = mcycleh
若 high_1 != high_2，重试
返回 (high_1 << 32) | low
```

若 `low` 读取前后发生低 32 位回绕，两次高位会不同；重试可避免把回绕前的高位与
回绕后的低位拼成一个从未存在过的时间戳。调用方应使用 `uint64_t` 保存结果并做
无符号差值：`end - start`。

## 顺序算子的测量含义

对于顺序执行的阶段 `op_i`，定义：

```text
t_start = mcycle_read()
执行 op_i
t_end   = mcycle_read()
C_raw(i) = t_end - t_start
```

`C_raw(i)` 是从起始采样点到结束采样点的**端到端阶段周期**。它包括：

- 算子指令本身、RVV 执行、访存和流水线等待；
- 该算子内部的循环、尾块处理与函数调用；
- 两端 `mcycle_read()` 之间不可避免的少量计时边界开销。

它不包括开始时间戳之前的 layer 初始化，也不包括结束时间戳之后把数值写到
`gemma_stage_cycles[]` 的存储开销。相邻阶段之间的控制代码（例如计算
`attention_length`）则不属于任何单独阶段；它会体现在整层总时间与阶段和的差中。

这种定义适合回答“该算子在当前核心、当前内存状态和当前 shape 下让程序向前推进了
多少周期”。它并不等同于脱离系统影响的纯计算单元 latency。

如果某个算子只提交异步任务，函数立即返回，则上述差值只测到提交成本。结束时间戳
必须放在该任务的完成同步或 `wait` 之后，才能测到完整执行时间。当前 decoder layer
中的 RVV kernel 是顺序函数调用，故可直接用函数调用边界测量。

## 当前 decoder-layer profiling 的对应关系

当前 profiling 变体已将真实调用顺序拆为 19 个阶段：

```text
input RMSNorm
Q / K / V projection
Q RMSNorm / K RMSNorm / RoPE / cache append / FlashAttention
output projection / post-attention RMSNorm / residual add
pre-FFN RMSNorm / gate projection / up projection / Tanh-GELU×Up
down projection / post-FFN RMSNorm / final residual add
```

`rvv_gemma_decoder_layer_profile.cc` 的 `PROFILE_STAGE` 宏在每个阶段调用前后
读取 `mcycle`，将差写到 `gemma_stage_cycles[stage]`。runner 同时提供两个模式：

- `kRunWholeLayer`：调用没有内部时间戳的 `Gemma270mDecoderLayerBf16Whole()`，
  得到最接近真实端到端 layer 的总周期；
- `kRunProfiledStages`：调用带 19 对时间戳的版本，得到阶段归因数据。

两种模式应在相同输入、权重、cache length、ELF 布局和复位条件下分别执行。
不要拿“带 19 对计时”的整层时间直接当作未插桩 layer 的性能，因为它包含所有
内部 profiler 的扰动。

runner 还通过重复 32 次空区间 `mcycle_read(); mcycle_read();`，取最小差值，得到
`mcycle_read_overhead_cycles`。对第 `i` 个阶段，可报告：

```text
C_raw(i)       = stage_end - stage_start
C_corrected(i) = max(0, C_raw(i) - C_read_overhead)
```

这里的 corrected 值是便于比较小算子的近似校正值，而不是硬件“真实算子周期”的
绝对真值。对大型 GeMV/GEMM，读取开销通常很小；对 cache append、残差或其他很短的
阶段，应同时保留 raw 和 corrected 两列。

## 建议的结果解释

建议一次 profile 至少输出以下数据：

| 指标 | 用途 |
| --- | --- |
| `whole_layer_cycles_raw` | 未插桩内层路径的端到端 layer 基线 |
| `stage_cycles_raw[i]` | 每个阶段真实边界之间的时间，最可审计 |
| `mcycle_read_overhead_cycles` | 空测量基线 |
| `stage_cycles_corrected[i]` | 用于小阶段横向比较的近似值 |
| `sum(stage_cycles_raw)` | 已归因阶段的总和 |
| `whole_layer - sum(stage)` | 未归因控制开销，或两种模式之间的插桩扰动 |
| cache length、position、shape、数据位置 | 解释 attention 与访存变化所必需的条件 |

对于矩阵类阶段，可额外报告 `MACs / cycle`；对于 RMSNorm、RoPE、GELU、残差和
cache append，更适合报告 `cycles / element`。不要将非矩阵算子强行转换成 MAC/cycle。

每一种比较都应固定下列条件：BF16 kernel 版本、编译优化选项、时钟配置、输入 shape、
cache length、权重/激活所在存储区域、DUT reset 策略。FlashAttention 的周期尤其会随
`cache_length + 1` 改变，因此不同 cache length 的结果必须分开报告。

## 实现建议

1. **计数器不用每个算子复位。** 一次运行内读取同一个自由运行的 64-bit `mcycle`，
   用差值计算即可。每个阶段重置会引入额外 CSR 写操作，也破坏同一时间轴上的总量关系。
2. **内部时间戳使用 64 bit。** `mcycle_read()` 已返回 `uint64_t`；所有局部 start、end
   和差值最好也保持 `uint64_t`。若最终 ELF 导出符号仍是 `uint32_t`，当测量区间超过
   `2^32` cycles 时会静默截断。需要覆盖超长 Gemma run 时，应将导出数组和 Cocotb
   读取宽度一起升级为 64 bit。
3. **为计时边界建立编译器屏障。** 若被测区域未来变为同一编译单元中的内联代码，
   可在读数两侧加入 `asm volatile("" ::: "memory")`，避免编译器把普通内存访问跨越
   时间戳重排。若边界涉及异步 MMIO/DMA，还需按硬件协议增加所需的 RISC-V `fence` 和
   完成等待；编译器屏障不能替代硬件同步。
4. **保留无内部插桩的基线。** 当前 `Gemma270mDecoderLayerBf16Whole()` 与逐阶段版本
   分离是正确做法：前者用于发布 layer 总周期，后者用于定位瓶颈。
5. **报告阶段和与整层差值。** 差值大时，先检查是否有未包围的控制逻辑、不同运行模式
   的代码布局差异、首次访问冷启动效应，或异步工作尚未完成。
6. **在 Cocotb 中从 ELF 符号读取结果。** 将统计值声明为 `used, retain` 的全局数据，
   通过 `cycle_count`、`gemma_stage_cycles` 等符号读取，避免依赖仿真器日志格式或 host
   wall-clock。

## 推荐的阶段包装形式

下面是适用于同步算子的形式。生产实现可将结果写到 64-bit 数组中：

```cpp
inline uint64_t ProfileTimestamp() {
  asm volatile("" ::: "memory");
  const uint64_t value = mcycle_read();
  asm volatile("" ::: "memory");
  return value;
}

#define PROFILE_STAGE(stage, call) do {                 \
  const uint64_t begin = ProfileTimestamp();             \
  call;                                                  \
  const uint64_t end = ProfileTimestamp();               \
  gemma_stage_cycles[stage] = end - begin;               \
} while (false)
```

`mcycle_read()` 的高—低—高重试已经处理 RV32 的 32-bit 分片一致性；不需要、也不应
在 profile 代码中手动拆分 `mcycleh`/`mcycle` 后再做 32-bit 回绕判断。

## 验证清单

- 用 `perf_counters.cc` 验证 `mcycle` 的高低位回绕和读写语义。
- 确认 profiling ELF 与 correctness ELF 分开，避免为性能数字牺牲通过性测试的可读性。
- 在同一输入和同一 reset 条件下运行 whole-layer 与 profiled-stages 两个模式。
- 确认每个 `gemma_stage_cycles[i]` 对应的输出张量仍通过数值正确性校验。
- 对很小阶段同时审阅 raw 与 corrected；对大阶段优先使用 raw。
- 发生大于 32-bit 的 cycle 差值风险时，端到端切换到 64-bit 导出和读取。
