#!/usr/bin/env bash
# Stage this repository's Coral CL into an initialized aws-fpga checkout.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORAL_ROOT="$(cd "$HERE/../../.." && pwd)"
AWS_FPGA_DIR="${AWS_FPGA_DIR:-$HOME/aws-fpga}"
CL_DIR="$AWS_FPGA_DIR/hdk/cl/examples/cl_coralnpu"
RTL="$CORAL_ROOT/bazel-bin/hdl/chisel/src/coralnpu/prod/RvvCoreMiniAxi.sv"

if [ ! -d "$AWS_FPGA_DIR/hdk" ]; then
  echo "AWS_FPGA_DIR does not point to an aws-fpga checkout: $AWS_FPGA_DIR" >&2
  exit 2
fi
if [ ! -f "$RTL" ]; then
  echo "Missing generated RTL: $RTL" >&2
  echo "Run: bazel build --repo_env=CC=/usr/bin/gcc //hdl/chisel/src/coralnpu/prod:rvv_core_mini_axi_prod_cc_library_emit_verilog" >&2
  exit 2
fi

mkdir -p "$CL_DIR/design" "$CL_DIR/build/scripts" "$CL_DIR/build/constraints" "$CL_DIR/software/runtime"
cp "$CORAL_ROOT/fpga/aws_f2/design/"*.sv "$CL_DIR/design/"
cp "$CORAL_ROOT/fpga/aws_f2/design/"*.vh "$CL_DIR/design/"
cp "$RTL" "$CL_DIR/design/RvvCoreMiniAxi.sv"
cp "$CORAL_ROOT/fpga/aws_f2/build/scripts/"*.tcl "$CL_DIR/build/scripts/"
cp "$CORAL_ROOT/fpga/aws_f2/build/constraints/"*.xdc "$CL_DIR/build/constraints/"
cp "$CORAL_ROOT/fpga/aws_f2/software/coralnpu_runner.c" "$CL_DIR/software/runtime/"
cp "$CORAL_ROOT/fpga/aws_f2/software/Makefile" "$CL_DIR/software/runtime/"

echo "Staged cl_coralnpu at $CL_DIR"
