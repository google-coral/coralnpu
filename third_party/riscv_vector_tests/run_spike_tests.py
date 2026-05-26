#!/usr/bin/env python3
"""Run all compiled riscv-vector-tests on Spike and report results."""

import subprocess, os, glob, sys

OUTDIR = "/Users/ust/coralnpu/third_party/riscv_vector_tests/out"

def run_spike_test(elf_path):
    """Run a single test on Spike. Returns (passed, output)."""
    cmd = [
        "bazel", "run", "@spike//:spike", "--",
        f"--isa=rv32imf_zve32f",
        "-l",
        elf_path,
    ]
    env = os.environ.copy()
    env["JAVA_HOME"] = "/opt/homebrew/opt/openjdk@17"
    env["PATH"] = "/opt/homebrew/opt/openjdk@17/bin:" + env.get("PATH", "")
    
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, 
                               timeout=30, env=env)
        # Spike exits with code 0 on success (EBREAK with no error)
        passed = result.returncode == 0
        return passed, result.stderr[:200] if not passed else ""
    except subprocess.TimeoutExpired:
        return False, "TIMEOUT"
    except Exception as e:
        return False, str(e)[:200]

def main():
    elfs = sorted(glob.glob(os.path.join(OUTDIR, "*.elf")))
    if not elfs:
        print("No ELF files found!")
        return

    print(f"Running {len(elfs)} tests on Spike (rv32imf_zve32f)...\n")
    
    passed = []
    failed = []
    for i, elf in enumerate(elfs):
        name = os.path.splitext(os.path.basename(elf))[0]
        ok, msg = run_spike_test(elf)
        if ok:
            passed.append(name)
            status = "PASS"
        else:
            failed.append((name, msg))
            status = f"FAIL ({msg[:60]})"
        
        if (i + 1) % 20 == 0 or not ok:
            print(f"  [{i+1:4d}/{len(elfs)}] {name:40s} {status}")

    total = len(elfs)
    print(f"\n{'='*70}")
    print(f"Spike RESULTS: {len(passed)}/{total} PASS ({100*len(passed)//total if total else 0}%)")
    if failed:
        print(f"\nFAILURES ({len(failed)}):")
        for name, msg in failed[:30]:
            print(f"  {name}: {msg[:100]}")
    print(f"{'='*70}")

if __name__ == "__main__":
    main()
