#!/usr/bin/env python3
"""Run all 516 riscv-vector-tests via Spike and report results."""

import subprocess, os, glob, sys, time

OUTDIR = "/Users/ust/coralnpu/third_party/riscv_vector_tests/out"
SPIKE_CMD = ["bazel", "run", "@spike//:spike", "--", "--isa=rv32imf_zve32f"]
ENV = {**os.environ, "JAVA_HOME": "/opt/homebrew/opt/openjdk@17",
       "PATH": "/opt/homebrew/opt/openjdk@17/bin:" + os.environ.get("PATH", "")}

def run_test(elf):
    name = os.path.splitext(os.path.basename(elf))[0]
    start = time.time()
    try:
        r = subprocess.run(SPIKE_CMD + [elf], capture_output=True, text=True,
                          timeout=60, env=ENV)
        elapsed = time.time() - start
        passed = r.returncode == 0
        return name, passed, f"{elapsed:.1f}s", r.stderr[:100] if not passed else ""
    except subprocess.TimeoutExpired:
        return name, False, "TIMEOUT", ""
    except Exception as e:
        return name, False, f"{time.time()-start:.1f}s", str(e)[:100]

def main():
    elfs = sorted(glob.glob(os.path.join(OUTDIR, "*.elf")))
    if not elfs:
        print("No ELFs found!"); return
    
    print(f"Running {len(elfs)} riscv-vector-tests on Spike (rv32imf_zve32f)...\n")
    
    passed, failed = [], []
    t0 = time.time()
    
    for i, elf in enumerate(elfs):
        name, ok, dur, msg = run_test(elf)
        if ok:
            passed.append(name)
            if (i+1) % 50 == 0:
                print(f"  [{i+1:4d}/{len(elfs)}] {len(passed)} pass, {len(failed)} fail ...")
        else:
            failed.append((name, msg))
            print(f"  [{i+1:4d}/{len(elfs)}] {name:45s} FAIL ({msg[:80]})")
    
    total_t = time.time() - t0
    print(f"\n{'='*70}")
    print(f"Spike RESULTS ({total_t:.0f}s): {len(passed)}/{len(elfs)} PASS "
          f"({100*len(passed)//len(elfs)}%)")
    if failed:
        print(f"\n{len(failed)} FAILURES:")
        for name, msg in failed[:40]:
            print(f"  {name}: {msg[:100]}")
    print(f"{'='*70}")
    
    # Write detailed results
    with open(os.path.join(OUTDIR, "spike_results.txt"), "w") as f:
        f.write(f"total={len(elfs)} pass={len(passed)} fail={len(failed)}\n")
        for name in passed:
            f.write(f"PASS {name}\n")
        for name, msg in failed:
            f.write(f"FAIL {name}: {msg}\n")
    
    return len(failed) == 0

if __name__ == "__main__":
    sys.exit(0 if main() else 1)
