# Gemma RVV Kernels & Cocotb Verification

This directory contains RISC-V Vector (RVV) optimized kernels for Gemma model layers, including:

- **FlashAttention** (`rvv_flashattention_kernel.cc`, `rvv_flashattention_runner.cc`, `rvv_bf16_flashattention_runner.cc`)
- **Matrix Multiplication** (`rvv_matmul.cc`, `rvv_int8_matmul.cc`, `rvv_bf16_matmul.cc`)
- **RMS Normalization** (`rvv_rms_norm.cc`, `rvv_bf16_rms_norm.cc`, `rms_norm_runner.cc`)
- **Activations & Elementwise Ops** (`rvv_tanh_gelu_mul.cc`, `rvv_residual_add.cc`)

---

## Test Data & Verification Methodology

The test suite in [`cocotb_tests/rvv_flashattention_cocotb_test.py`](cocotb_tests/rvv_flashattention_cocotb_test.py) tests multi-head FlashAttention on simulated Kelvin/CoralNPU cores.

### Automated CI Test Execution (Synthetic Vectors)

In automated CI and offline airgapped presubmit pipelines, the test suite does not require external model downloads. If real model tensors are not present in `test_data/`, the test automatically generates deterministic synthetic float32 vectors (`np.random.seed(42); np.random.normal(...)`) to verify numerical correctness against a NumPy golden reference model.

Run the test suite via Bazel:

```bash
bazel test //tests/cocotb/rvv/ml_ops/gemma_kernels:rvv_flashattention_cocotb_test
```

### Manual Reference Tensor Extraction (Real Weights)

To evaluate the kernels against real weights extracted from `google/gemma-3-270m-it`:

1. Set up a Python environment with PyTorch and Hugging Face Transformers:

   ```bash
   python3 -m venv .venv
   source .venv/bin/activate
   pip install -r third_party/gemma_requirements.txt
   ```

2. Run the extraction utility:

   ```bash
   python3 tests/cocotb/dump_gemma_tensors.py --out_dir tests/cocotb/rvv/ml_ops/gemma_kernels/test_data
   ```

3. Re-run the Cocotb test suite:

   ```bash
   bazel test //tests/cocotb/rvv/ml_ops/gemma_kernels:rvv_flashattention_cocotb_test
   ```

   The test will automatically detect the real Gemma tensors in `test_data/` and compute the unmasked multi-head golden model against the real extracted weights.

> **Note on De-Bazeling**:
> The `@gemma_deps` Bazel pip hub was removed during the Bzlmod airgap migration (September 2026). Because `bazel vendor //...` vendors all external dependencies across the repository for offline airgap CI, including heavy PyTorch/Transformers wheels in the Bazel module graph would add multi-gigabyte bloat for dependencies that cannot run in airgapped environments (since model downloading requires public internet access). The extraction script is therefore maintained as a standalone manual utility.
