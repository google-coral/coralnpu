import numpy as np

from coralnpu_test_utils.coralflow.base_fixture import BaseCoralNPUFixture
from coralnpu_test_utils.coralflow.runner import coralflow_test


@coralflow_test
async def test_vmv_x_s_vl0(fixture: BaseCoralNPUFixture):
    await fixture.load_elf_and_lookup_symbols(
        "tests/cocotb/rvv/rvv_vmv_x_s_vl0_test.elf", ["in_buf", "result"])
    await fixture.write("in_buf", np.array([10, 20, 30, 40], dtype=np.int32))
    await fixture.write("result", np.array([0xDEAD], dtype=np.int32))
    assert await fixture.run_to_halt()
    result = int((await fixture.read("result", dtype=np.int32, shape=(1, )))[0])
    assert result == 10, f"vmv.x.s with vl=0: expected 10, got {result:#x}"


if __name__ == "__main__":
    test_vmv_x_s_vl0()