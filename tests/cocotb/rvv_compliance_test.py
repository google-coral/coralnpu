"""riscv-vector-tests compliance: run ALL 516 tests on Chisel RVV (highmem model)."""
import cocotb
import os, sys, glob, time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from coralnpu_test_utils.core_mini_axi_interface import CoreMiniAxiInterface

ELFDIR = "/Users/ust/coralnpu/third_party/riscv_vector_tests/out"
TIMEOUT_US = 15_000_000

async def _run_elf(dut, elf_path):
    name = os.path.basename(elf_path).replace(".elf", "")
    core = CoreMiniAxiInterface(dut)
    await core.init()
    await core.reset()
    with open(elf_path, "rb") as f:
        await core.load_elf(f)
    await core.execute_from(0)
    await core.wait_for_halted(timeout_us=TIMEOUT_US)
    a0 = await core.read_gpr(10)
    return name, a0 == 0, a0


@cocotb.test()
async def test_all_compliance(dut):
    """Run ALL 516 riscv-vector-tests against Chisel RVV on highmem model."""
    elfs = sorted(glob.glob(os.path.join(ELFDIR, "*.elf")))
    cocotb.log.info(f"=== Running {len(elfs)} riscv-vector-tests on Chisel RVV ===")

    passed, failed = [], []
    t0 = time.time()
    for i, elf in enumerate(elfs):
        name, ok, a0 = await _run_elf(dut, elf)
        if ok:
            passed.append(name)
        else:
            failed.append((name, a0))
        if (i + 1) % 50 == 0 or not ok:
            cocotb.log.info(f"  [{i+1:4d}/{len(elfs)}] {len(passed)}P/{len(failed)}F "
                           f"- {name}: {'PASS' if ok else f'FAIL(a0={a0})'}")

    elapsed = time.time() - t0
    cocotb.log.info(f"\n{'='*60}")
    cocotb.log.info(f"COMPLETE in {elapsed:.0f}s: {len(passed)}/{len(elfs)} PASS")
    if failed:
        cocotb.log.error(f"FAILURES ({len(failed)}):")
        for name, a0 in failed:
            cocotb.log.error(f"  {name}: a0={a0}")
    cocotb.log.info(f"{'='*60}")
    assert len(failed) == 0, f"{len(failed)}/{len(elfs)} tests FAILED"
