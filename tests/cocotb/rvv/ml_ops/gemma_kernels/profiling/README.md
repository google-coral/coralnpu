# Gemma RVV 算子 Profiling

这个目录用于采集 `gemma_kernels` 下每个可执行算子的性能数据，并保留数据来源、读取方法和原始日志。它统计的是**真实运行的 NPU cycle**，不使用静态估算值替代实测值。

## 覆盖范围

| 算子 | 实现 | 主要特性 |
| --- | --- | --- |
| RMSNorm | FP32、BF16 | 动态序列长度与 hidden size |
| Residual Add | FP32、BF16 | 逐元素残差相加 |
| Tanh-GELU × Up | FP32、BF16 | Gemma MLP 激活和逐元素乘法 |
| MatMul / GeMV | FP32、BF16 | M=1 的 decode GeMV 与 2D prefill MatMul |
| INT8 MatMul / GeMV | INT8 输入、INT32 输出 | 覆盖 K/N 尾块 |
| FlashAttention | FP32、BF16 | prefill、decode、MQA/GQA 形状 |
| Gemma Decoder Layer（mytest） | BF16 | 端到端单层：Attention、MLP、RMSNorm、残差 |

## cycle 数据的准确来源

每条 `kernel_cycles` 都来自同一条运行时链路：

1. **C++ runner 写入数据**：例如 `rvv_bf16_matmul_runner.cc` 在目标 kernel 调用前后执行 `mcycle_read()`，并将 `end - start` 写入全局变量 `cycle_count`。
2. **ELF 符号表定位地址**：Cocotb 测试调用 `Fixture.load_elf_and_lookup_symbols()`；底层 `CoreMiniAxiInterface.lookup_symbol()` 用 `pyelftools.ELFFile` 遍历 `SHT_SYMTAB`，取得 `cycle_count` 的 `st_value` 地址。
3. **AXI 读取数值**：测试执行完成后调用 `fixture.read('cycle_count', 4)` 或 `fixture.read_word('cycle_count')`，从仿真 NPU 的该地址读回 32 位 cycle 值。
4. **日志保存与解析**：测试中的 `sw/utils/metrics.py` 打印 `PERFORMANCE METRICS` 块；本目录的脚本先保存完整 Bazel/Cocotb 原始日志，再解析 `Total Cycles`、`Total MACs` 或 `Total Elements`。

因此，`kernel_cycles` 的含义是：**runner 中被测 kernel 调用区间内的 RISC-V `mcycle` 差值**。它不是 Python/host 耗时，也不必然等于 `run_to_halt()` 的仿真总时钟数。

`run_to_halt()` 返回的是从执行入口到 `io_halted` 的仿真时钟数，包含程序启动和退出开销；若要对比两者，应在测试中显式记录它。默认报告优先使用更贴近 kernel 的 `cycle_count`。

## 使用方法

在仓库根目录运行全部算子：

```bash
python3 tests/cocotb/rvv/ml_ops/gemma_kernels/profiling/profile_gemma_operators.py \
    --workspace . \
    --execute
```

只跑部分算子：

```bash
python3 tests/cocotb/rvv/ml_ops/gemma_kernels/profiling/profile_gemma_operators.py \
    --workspace . \
    --execute \
    --operators matmul flashattention gemma_decoder_layer
```

实验性 ELF 或运行参数可以通过 `--test-env KEY=VALUE` 传给 Bazel test；例如选择
软件-only 的 BF16 GeMV pair-load 变体：

```bash
python3 tests/cocotb/rvv/ml_ops/gemma_kernels/profiling/profile_gemma_operators.py \
    --workspace . \
    --execute \
    --operators matmul \
    --test-env BF16_MATMUL_ELF=rvv_bf16_matmul_pair_load.elf \
    --output-dir tests/cocotb/rvv/ml_ops/gemma_kernels/profiling/results/pair_load
```

`vlseg2e16.v` 的 packed-weight 实验同时设置 ELF 和输入布局开关：

```bash
python3 tests/cocotb/rvv/ml_ops/gemma_kernels/profiling/profile_gemma_operators.py \
    --workspace . \
    --execute \
    --operators matmul \
    --test-env BF16_MATMUL_ELF=rvv_bf16_matmul_seg2.elf \
    --test-env BF16_MATMUL_PACKED_B=1 \
    --output-dir tests/cocotb/rvv/ml_ops/gemma_kernels/profiling/results/seg2
```

完整 synthetic Gemma layer 也可切换到同一 packed projection 方案：

```bash
python3 tests/cocotb/rvv/ml_ops/gemma_kernels/profiling/profile_gemma_operators.py \
    --workspace . \
    --execute \
    --operators gemma_decoder_layer \
    --test-env GEMMA_PROFILE_ELF=rvv_bf16_gemma_decoder_layer_profile_seg2.elf \
    --test-env GEMMA_PACKED_PROJECTIONS=1 \
    --output-dir tests/cocotb/rvv/ml_ops/gemma_kernels/profiling/results/z19_seg2_decoder
```

`4e376279` 新增的 A-cache 和 block-major 变体使用以下开关。A-cache 只改变
`A[K]` 的存放位置，不需要改变 B 的布局；seg2 变体需要 per-row packed B，
block-seg2 变体需要 block-major packed B。

```bash
# A-cache，保持原始 row-major B
python3 tests/cocotb/rvv/ml_ops/gemma_kernels/profiling/profile_gemma_operators.py \
    --workspace . \
    --execute \
    --operators matmul \
    --test-env BF16_MATMUL_ELF=rvv_bf16_matmul_a_cache.elf \
    --output-dir tests/cocotb/rvv/ml_ops/gemma_kernels/profiling/results/z19_a_cache_real

# row-seg2 + A-cache
python3 tests/cocotb/rvv/ml_ops/gemma_kernels/profiling/profile_gemma_operators.py \
    --workspace . \
    --execute \
    --operators matmul \
    --test-env BF16_MATMUL_ELF=rvv_bf16_matmul_seg2_a_cache.elf \
    --test-env BF16_MATMUL_PACKED_B=1 \
    --output-dir tests/cocotb/rvv/ml_ops/gemma_kernels/profiling/results/z19_seg2_a_cache

# block-seg2；两个开关都必须设置，避免退回默认 baseline ELF/布局
python3 tests/cocotb/rvv/ml_ops/gemma_kernels/profiling/profile_gemma_operators.py \
    --workspace . \
    --execute \
    --operators matmul \
    --test-env BF16_MATMUL_ELF=rvv_bf16_matmul_block_seg2.elf \
    --test-env BF16_MATMUL_BLOCK_PACKED_B=1 \
    --output-dir tests/cocotb/rvv/ml_ops/gemma_kernels/profiling/results/z19_block_seg2_validated

# block-seg2 + A-cache
python3 tests/cocotb/rvv/ml_ops/gemma_kernels/profiling/profile_gemma_operators.py \
    --workspace . \
    --execute \
    --operators matmul \
    --test-env BF16_MATMUL_ELF=rvv_bf16_matmul_block_seg2_a_cache.elf \
    --test-env BF16_MATMUL_BLOCK_PACKED_B=1 \
    --output-dir tests/cocotb/rvv/ml_ops/gemma_kernels/profiling/results/z19_block_seg2_a_cache
```

完整 synthetic Gemma layer 的 block-seg2 + A-cache 版本：

```bash
python3 tests/cocotb/rvv/ml_ops/gemma_kernels/profiling/profile_gemma_operators.py \
    --workspace . \
    --execute \
    --operators gemma_decoder_layer \
    --test-env GEMMA_PROFILE_ELF=rvv_bf16_gemma_decoder_layer_profile_block_seg2_a_cache.elf \
    --test-env GEMMA_BLOCK_PACKED_PROJECTIONS=1 \
    --output-dir tests/cocotb/rvv/ml_ops/gemma_kernels/profiling/results/z19_block_seg2_a_cache_decoder
```

额外环境变量会写入报告的 `data_reading_method.extra_test_env`，以便区分同一
Cocotb testcase 下的不同软件 schedule。

不重跑仿真、仅解析已有日志：

```bash
python3 tests/cocotb/rvv/ml_ops/gemma_kernels/profiling/profile_gemma_operators.py \
    --workspace . \
    --from-log /path/to/bazel-test.log
```

默认输出到 `profiling/results/`：

- `raw_logs/*.log`：Bazel/Cocotb 原始输出，是每条数字的可审计证据。
- `profile_report.json`：完整结构化结果，含源码行号、数据来源和读取方法。
- `profile_samples.csv`：每条 shape/配置的一行，便于 Excel、pandas 或绘图。
- `profile_report.md`：面向阅读的汇总表。
- `real_gemma_layer0_comparison.md`：真实 Hugging Face Gemma 第 0 层整层与
  19 个逐阶段 cycle 的等条件对比、`mcycle_read` 校正和 MAC/cycle 公式。

执行 `--execute` 时，Bazel 输出会同时显示在终端并写入 `raw_logs/`；首次构建
Verilator/Cocotb 依赖可能耗时较长，但可以从终端进度判断当前阶段。

## Host 编译环境

脚本使用 Bazel 默认探测到的 host toolchain，不强制选择仓库中的
`host_clang_platform`。后者可能包含工作站相关的 LLVM 安装路径，不适合作为
profiling 的隐式依赖。脚本仍固定使用 `bazel --batch`，避免复用携带旧
`JAVA_HOME` 的 Bazel server。

Gemma layer 的独立算子采集会通过 Bazel `--test_filter` 运行对应 BF16
testcase，并通过仅在脚本中设置的 `GEMMA_PROFILE_ONLY=1` 选择 layer 实际使用的
shape。直接运行原 Cocotb target 时不设置该变量，其默认测试范围保持不变。

## Decoder profiling 隔离说明

`mytest/` 保存带 19 个逐阶段 cycle 计数器的 Decoder profiling 版本，并由
`//tests/cocotb/rvv/ml_ops/gemma_kernels/profiling/mytest:rvv_gemma_decoder_layer_profile_cocotb_test`
独立构建和运行。原有 `decoder_layer/` 下的通过性测试、源码和 Bazel target
保持不变；profiling 使用独立 ELF，避免计时代码改变通过性测试主体或覆盖其产物。
