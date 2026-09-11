# Gemma decoder layer tests

This directory contains the end-to-end BF16 Gemma 3 270M decoder-layer test.
The implementation combines the existing RMSNorm, matrix multiplication,
GELU, residual-add, and flash-attention kernels into one NPU binary. The
synthetic test runs without external model files; the real-data test compares
the same layer against a local Hugging Face checkpoint.

## Build the NPU binary

From the repository root:

```sh
bazel build //tests/cocotb/rvv/ml_ops/gemma_kernels/decoder_layer:rvv_bf16_gemma_decoder_layer
```

The generated ELF is packaged as
`rvv_bf16_gemma_decoder_layer.elf` and is consumed automatically by both
Cocotb suites.

## Run the synthetic test

```sh
bazel test --test_output=streamed \
  //tests/cocotb/rvv/ml_ops/gemma_kernels/decoder_layer:rvv_gemma_decoder_layer_cocotb_test
```

The test validates intermediate tensors as well as the final decoder-layer
output using deterministic synthetic Gemma 3 270M-shaped inputs.

## Dependencies and model access

The synthetic test only requires the repository's normal Bazel/Cocotb
environment. The real-data flow additionally requires:

- A Hugging Face account with access to the gated
  [`google/gemma-3-270m`](https://huggingface.co/google/gemma-3-270m) model.
- A Hugging Face `read` access token. Accept the Gemma usage terms on the
  model page before downloading the checkpoint.
- The Python packages declared by the `prepare_real_gemma_layer` Bazel target:
  `numpy`, `safetensors`, `torch`, and `transformers`.
- The `ml_dtypes` package used by the Cocotb test for BF16 conversion.

The Bazel workspace supplies these Python packages through the `gemma_deps`
and regular Python requirement repositories. You do not need to install them
globally when using the Bazel targets below. The Hugging Face CLI is only
needed for downloading the model:

```sh
pip install --user "huggingface_hub[cli]"
hf auth login
```

The checkpoint is gated and must be downloaded before running the preparation
script. Store it outside the Git worktree, for example:

```sh
hf download google/gemma-3-270m \
  --local-dir ~/models/gemma-3-270m
```

The local model directory should contain `config.json`, tokenizer files, and
the model `*.safetensors` files. The preparation script uses
`local_files_only=True`, so it does not download missing files or contact
Hugging Face during the Bazel run.

## Run with a real checkpoint

First prepare layer-0 inputs from a local Gemma 3 270M checkpoint.

```sh
bazel run //tests/cocotb/rvv/ml_ops/gemma_kernels/decoder_layer:prepare_real_gemma_layer -- \
  --model_dir ~/models/gemma-3-270m \
  --output_dir /tmp/gemma-layer0
```

Run the real-data suite by passing the directory through Bazel's test
environment:

```sh
bazel test --test_output=streamed \
  --test_env=GEMMA_LAYER0_DATA=/tmp/gemma-layer0 \
  //tests/cocotb/rvv/ml_ops/gemma_kernels/decoder_layer:rvv_real_gemma_decoder_layer_cocotb_test
```

The checkpoint is loaded with `local_files_only=True`; no network download is
performed. The preparation script currently validates the Gemma 3 270M
configuration (`hidden_size=640`, `intermediate_size=2048`, four query heads,
one KV head, and `head_dim=256`).

## Useful targets

| Target | Purpose |
| --- | --- |
| `:rvv_bf16_gemma_decoder_layer` | Build the NPU ELF |
| `:rvv_gemma_decoder_layer_cocotb_test` | Synthetic decoder-layer test |
| `:rvv_real_gemma_decoder_layer_cocotb_test` | Real checkpoint comparison |
| `:prepare_real_gemma_layer` | Convert checkpoint tensors to test data |
