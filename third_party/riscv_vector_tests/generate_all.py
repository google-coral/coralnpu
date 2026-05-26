#!/usr/bin/env python3
"""Generate and compile all riscv-vector-tests for CoralNPU."""

import subprocess
import os
import glob
import sys

RISCV_VECTOR_TESTS = "/Users/ust/riscv-vector-tests"
GENERATOR = "/Users/ust/coralnpu/third_party/riscv_vector_tests/generator"
OUTDIR = "/Users/ust/coralnpu/third_party/riscv_vector_tests/out"
HEADER = "/Users/ust/coralnpu/third_party/riscv_vector_tests/coralnpu_test_header.h"
LINKSCRIPT = "/Users/ust/coralnpu/third_party/riscv_vector_tests/coralnpu.ld"
GCC = "riscv64-elf-gcc"
MARCH = "rv32imf_zve32f_zicsr_zifencei_zbb"
MABI = "ilp32"

os.makedirs(OUTDIR, exist_ok=True)

def generate_test(config_path):
    """Generate assembly for one test config."""
    name = os.path.splitext(os.path.basename(config_path))[0]
    asm_out = os.path.join(OUTDIR, f"{name}.S")
    
    cmd = [
        GENERATOR,
        "-VLEN", "128",
        "-XLEN", "32",
        "-float16=false",
        "-configfile", config_path,
        "-outputfile", asm_out,
    ]
    
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    if result.returncode != 0:
        return name, "GEN_FAILED", result.stderr[:200]
    
    # Replace test_macros.h include with CoralNPU header
    with open(asm_out, 'r') as f:
        content = f.read()
    
    # Replace includes with our coralnpu header
    content = content.replace('#include "test_macros.h"', f'#include "{HEADER}"')
    
    # Remove riscv_test.h includes and RVTEST_RV macros (our header provides stubs)
    lines = content.split('\n')
    filtered = [l for l in lines if 'riscv_test.h' not in l and 'RVTEST_RV' not in l]
    content = '\n'.join(filtered)
    
    with open(asm_out, 'w') as f:
        f.write(content)
    
    return name, "GEN_OK", ""


def compile_test(name):
    """Compile one test assembly to ELF."""
    asm_file = os.path.join(OUTDIR, f"{name}.S")
    elf_file = os.path.join(OUTDIR, f"{name}.elf")
    
    cmd = [
        GCC,
        f"-march={MARCH}",
        f"-mabi={MABI}",
        "-nostdlib", "-nostartfiles",
        f"-I{os.path.dirname(HEADER)}",
        f"-T{LINKSCRIPT}",
        "-o", elf_file,
        asm_file,
    ]
    
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    if result.returncode != 0:
        return name, "COMPILE_FAILED", result.stderr[:200]
    
    return name, "COMPILE_OK", ""


def main():
    configs = sorted(glob.glob(os.path.join(RISCV_VECTOR_TESTS, "configs/v/*.toml")))
    total = len(configs)
    results = {"GEN_OK": 0, "GEN_FAILED": 0, "COMPILE_OK": 0, "COMPILE_FAILED": 0}
    failures = []
    
    print(f"Found {total} test configs")
    
    for i, config in enumerate(configs):
        name = os.path.splitext(os.path.basename(config))[0]
        
        # Generate
        gen_name, gen_status, gen_err = generate_test(config)
        if gen_status == "GEN_FAILED":
            results["GEN_FAILED"] += 1
            failures.append((name, "GEN", gen_err))
            if i % 20 == 0:
                print(f"  [{i+1}/{total}] {name}: {gen_status}")
            continue
        
        # Compile
        comp_name, comp_status, comp_err = compile_test(gen_name)
        results[comp_status] += 1
        if comp_status == "COMPILE_FAILED":
            failures.append((name, "COMPILE", comp_err))
        
        if i % 20 == 0 or comp_status == "COMPILE_FAILED":
            print(f"  [{i+1}/{total}] {name}: {comp_status}")
    
    # Summary
    print(f"\n{'='*60}")
    print(f"RESULTS: {total} configs")
    print(f"  Generated:     {results['GEN_OK']} OK, {results['GEN_FAILED']} failed")
    print(f"  Compiled:      {results['COMPILE_OK']} OK, {results['COMPILE_FAILED']} failed")
    
    if failures:
        print(f"\nFAILURES ({len(failures)}):")
        for name, stage, err in failures[:20]:
            print(f"  {stage}: {name}")
            if err:
                print(f"    {err[:150]}")
    
    # Write results file
    with open(os.path.join(OUTDIR, "results.txt"), "w") as f:
        f.write(f"total={total}\n")
        f.write(f"gen_ok={results['GEN_OK']}\n")
        f.write(f"gen_failed={results['GEN_FAILED']}\n")
        f.write(f"compile_ok={results['COMPILE_OK']}\n")
        f.write(f"compile_failed={results['COMPILE_FAILED']}\n")
        f.write("failures:\n")
        for name, stage, err in failures:
            f.write(f"  {stage}:{name}\n")

if __name__ == "__main__":
    main()
