# Copyright 2025 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

import cocotb
import enum
import random

from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge


class TLUL_OpcodeA(enum.IntEnum):
    PutFullData = 0
    PutPartialData = 1
    Get = 4


class TLUL_OpcodeD(enum.IntEnum):
    AccessAck = 0
    AccessAckData = 1


async def reset_dut(dut):
    """Applies reset to the DUT."""
    dut.reset.value = 1
    dut.io_tl_a_valid.value = 0
    dut.io_tl_d_ready.value = 0
    dut.io_tl_a_bits_opcode.value = 0
    dut.io_tl_a_bits_param.value = 0
    dut.io_tl_a_bits_size.value = 0
    dut.io_tl_a_bits_source.value = 0
    dut.io_tl_a_bits_address.value = 0
    dut.io_tl_a_bits_mask.value = 0
    dut.io_tl_a_bits_data.value = 0
    dut.io_tl_a_bits_user_rsvd.value = 0
    dut.io_tl_a_bits_user_instr_type.value = 0x9
    dut.io_tl_a_bits_user_cmd_intg.value = 0
    dut.io_tl_a_bits_user_data_intg.value = 0
    await ClockCycles(dut.clock, 2)
    dut.reset.value = 0
    await ClockCycles(dut.clock, 2)


async def wait_for_signal(clock, signal, timeout_cycles=1000, message=None):
    """Waits for a signal to be asserted."""
    if message is None:
        message = f"Timeout waiting for {signal._name}"

    for _ in range(timeout_cycles):
        await RisingEdge(clock)
        if signal.value:
            return
    else:
        raise RuntimeError(message)


async def tl_send_get(
    dut, address, source, size, instr_type=0x9, timeout_cycles=1000
):
    """Sends a TileLink Get request."""
    dut.io_tl_a_valid.value = 1
    dut.io_tl_a_bits_opcode.value = TLUL_OpcodeA.Get
    dut.io_tl_a_bits_address.value = address
    dut.io_tl_a_bits_source.value = source
    dut.io_tl_a_bits_size.value = size
    dut.io_tl_a_bits_mask.value = 0  # Mask is ignored for Get
    dut.io_tl_a_bits_data.value = 0  # Data is ignored for Get
    dut.io_tl_a_bits_user_instr_type.value = instr_type

    await wait_for_signal(dut.clock, dut.io_tl_a_ready, timeout_cycles)

    dut.io_tl_a_valid.value = 0


async def tl_send_put(
    dut, address, source, size, data, mask, timeout_cycles=1000
):
    """Sends a TileLink PutFullData request."""
    dut.io_tl_a_valid.value = 1
    dut.io_tl_a_bits_opcode.value = TLUL_OpcodeA.PutFullData
    dut.io_tl_a_bits_address.value = address
    dut.io_tl_a_bits_source.value = source
    dut.io_tl_a_bits_size.value = size
    dut.io_tl_a_bits_data.value = data
    dut.io_tl_a_bits_mask.value = mask

    await wait_for_signal(dut.clock, dut.io_tl_a_ready, timeout_cycles)

    dut.io_tl_a_valid.value = 0


@cocotb.test()
async def test_put_request(dut):
    """Tests a simple Put request."""
    clock = Clock(dut.clock, 10, unit="us")
    cocotb.start_soon(clock.start())

    # Reset
    await reset_dut(dut)

    # AXI slave initial state
    dut.io_axi_read_addr_ready.value = 0
    dut.io_axi_write_addr_ready.value = 0
    dut.io_axi_write_data_ready.value = 0
    dut.io_axi_write_resp_valid.value = 0
    dut.io_axi_read_data_valid.value = 0

    # Test parameters
    addr_width = 32
    source_width = 6
    data_width_bytes = 32  # Corresponds to 256 bits
    timeout_cycles = 1000

    size_power = random.randint(0, 5)  # 2**5 = 32 bytes
    test_size = size_power
    num_bytes = 2**size_power

    test_addr = random.randint(0, (2**addr_width) - 1)
    test_source = random.randint(0, (2**source_width) - 1)
    test_data = random.randint(0, (2**(data_width_bytes * 8)) - 1)
    test_mask = (1 << num_bytes) - 1

    # Drive TL Put request
    await tl_send_put(
        dut,
        address=test_addr,
        source=test_source,
        size=test_size,
        data=test_data,
        mask=test_mask,
        timeout_cycles=timeout_cycles
    )

    #
    # Check AXI Write Address and Data Channels
    #
    await wait_for_signal(
        dut.clock, dut.io_axi_write_addr_valid, timeout_cycles,
        "Timeout waiting for AXI AWVALID for Put"
    )

    assert dut.io_axi_write_addr_valid.value, "AXI AWVALID should be high"
    assert dut.io_axi_write_data_valid.value, "AXI WVALID should be high"
    assert dut.io_axi_write_addr_bits_addr.value == test_addr, "AXI AWADDR is incorrect"
    assert dut.io_axi_write_addr_bits_id.value == test_source, "AXI AWID is incorrect"
    assert dut.io_axi_write_addr_bits_size.value == test_size, "AXI AWSIZE is incorrect"
    assert dut.io_axi_write_data_bits_data.value == test_data, "AXI WDATA is incorrect"
    assert dut.io_axi_write_data_bits_strb.value == test_mask, "AXI WSTRB is incorrect"

    # AXI slave accepts the request
    dut.io_axi_write_addr_ready.value = 1
    dut.io_axi_write_data_ready.value = 1
    await RisingEdge(dut.clock)
    dut.io_axi_write_addr_ready.value = 0
    dut.io_axi_write_data_ready.value = 0

    #
    # AXI slave provides write response
    #
    await RisingEdge(dut.clock)
    dut.io_axi_write_resp_valid.value = 1
    dut.io_axi_write_resp_bits_id.value = test_source
    dut.io_axi_write_resp_bits_resp.value = 0  # OKAY

    await wait_for_signal(
        dut.clock, dut.io_axi_write_resp_ready, timeout_cycles
    )

    await RisingEdge(dut.clock)
    dut.io_axi_write_resp_valid.value = 0

    #
    # Check TileLink D Channel
    #
    dut.io_tl_d_ready.value = 1
    await wait_for_signal(
        dut.clock, dut.io_tl_d_valid, timeout_cycles,
        "Timeout waiting for TL D_VALID for Put"
    )

    assert dut.io_tl_d_valid.value, "TL D_VALID should be high"
    assert dut.io_tl_d_bits_opcode.value == TLUL_OpcodeD.AccessAck, "TL D_OPCODE should be AccessAck"
    assert dut.io_tl_d_bits_source.value == test_source, "TL D_SOURCE is incorrect"
    assert not dut.io_tl_d_bits_error.value, "TL D_ERROR should be low"
    dut.io_tl_d_ready.value = 0

    # Allow a few extra cycles for waveform viewing.
    await ClockCycles(dut.clock, 5)


@cocotb.test()
async def test_get_request(dut):
    """Tests a simple Get request."""
    clock = Clock(dut.clock, 10, unit="us")
    cocotb.start_soon(clock.start())

    # Reset
    await reset_dut(dut)

    # AXI slave initial state
    dut.io_axi_read_addr_ready.value = 0
    dut.io_axi_write_addr_ready.value = 0
    dut.io_axi_write_data_ready.value = 0
    dut.io_axi_write_resp_valid.value = 0
    dut.io_axi_read_data_valid.value = 0

    # Test parameters
    addr_width = 32
    source_width = 6
    data_width_bytes = 32
    timeout_cycles = 1000

    size_power = random.randint(0, 5)
    test_size = size_power

    test_addr = random.randint(0, (2**addr_width) - 1)
    test_source = random.randint(0, (2**source_width) - 1)
    test_data = random.randint(0, (2**(data_width_bytes * 8)) - 1)

    # Drive TL Get request
    await tl_send_get(
        dut,
        address=test_addr,
        source=test_source,
        size=test_size,
        timeout_cycles=timeout_cycles
    )

    #
    # Check AXI Read Address Channel
    #
    await RisingEdge(dut.clock)
    assert dut.io_axi_read_addr_valid.value, "AXI ARVALID should be high"
    assert dut.io_axi_read_addr_bits_addr.value == test_addr, "AXI ARADDR is incorrect"
    assert dut.io_axi_read_addr_bits_id.value == test_source, "AXI ARID is incorrect"
    assert dut.io_axi_read_addr_bits_size.value == test_size, "AXI ARSIZE is incorrect"

    # AXI slave accepts the request
    dut.io_axi_read_addr_ready.value = 1
    await RisingEdge(dut.clock)
    dut.io_axi_read_addr_ready.value = 0

    #
    # AXI slave provides read data
    #
    await RisingEdge(dut.clock)
    dut.io_axi_read_data_valid.value = 1
    dut.io_axi_read_data_bits_data.value = test_data
    dut.io_axi_read_data_bits_id.value = test_source
    dut.io_axi_read_data_bits_resp.value = 0  # OKAY

    await wait_for_signal(
        dut.clock, dut.io_axi_read_data_ready, timeout_cycles
    )

    await RisingEdge(dut.clock)
    dut.io_axi_read_data_valid.value = 0

    #
    # Check TileLink D Channel
    #
    dut.io_tl_d_ready.value = 1
    await RisingEdge(dut.clock)

    assert dut.io_tl_d_valid.value, "TL D_VALID should be high"
    assert dut.io_tl_d_bits_opcode.value == TLUL_OpcodeD.AccessAckData, "TL D_OPCODE should be AccessAckData"
    assert dut.io_tl_d_bits_source.value == test_source, "TL D_SOURCE is incorrect"
    assert dut.io_tl_d_bits_data.value == test_data, "TL D_DATA is incorrect"
    assert not dut.io_tl_d_bits_error.value, "TL D_ERROR should be low"
    dut.io_tl_d_ready.value = 0

    # Allow a few extra cycles for waveform viewing.
    await ClockCycles(dut.clock, 5)


@cocotb.test()
async def test_backpressure(dut):
    """Tests backpressure from the AXI slave."""
    clock = Clock(dut.clock, 10, unit="us")
    cocotb.start_soon(clock.start())

    # Reset
    await reset_dut(dut)

    # AXI slave initial state
    dut.io_axi_read_addr_ready.value = 0
    dut.io_axi_write_addr_ready.value = 0
    dut.io_axi_write_data_ready.value = 0
    dut.io_axi_write_resp_valid.value = 0
    dut.io_axi_read_data_valid.value = 0

    # Test parameters
    addr_width = 32
    source_width = 6
    data_width_bytes = 32  # Corresponds to 256 bits
    timeout_cycles = 1000

    size_power = random.randint(0, 5)  # 2**5 = 32 bytes
    test_size = size_power
    num_bytes = 2**size_power

    test_addr = random.randint(0, (2**addr_width) - 1)
    test_source = random.randint(0, (2**source_width) - 1)
    test_data = random.randint(0, (2**(data_width_bytes * 8)) - 1)
    test_mask = (1 << num_bytes) - 1

    # Drive TL Put request
    await tl_send_put(
        dut,
        address=test_addr,
        source=test_source,
        size=test_size,
        data=test_data,
        mask=test_mask,
        timeout_cycles=timeout_cycles
    )

    #
    # Check AXI Write Address and Data Channels
    #
    await wait_for_signal(
        dut.clock, dut.io_axi_write_addr_valid, timeout_cycles,
        "Timeout waiting for AXI AWVALID for Put"
    )

    assert dut.io_axi_write_addr_valid.value, "AXI AWVALID should be high"
    assert dut.io_axi_write_data_valid.value, "AXI WVALID should be high"

    # Apply backpressure to address channel
    dut.io_axi_write_addr_ready.value = 0
    dut.io_axi_write_data_ready.value = 1

    await ClockCycles(dut.clock, 10)

    # Address channel should be stalled, data channel should have cleared
    assert dut.io_axi_write_addr_valid.value, "AXI AWVALID should remain high"
    assert not dut.io_axi_write_data_valid.value, "AXI WVALID should be low"

    # Release backpressure
    dut.io_axi_write_addr_ready.value = 1
    await RisingEdge(dut.clock)
    dut.io_axi_write_addr_ready.value = 0
    dut.io_axi_write_data_ready.value = 0

    #
    # AXI slave provides write response
    #
    await RisingEdge(dut.clock)
    dut.io_axi_write_resp_valid.value = 1
    dut.io_axi_write_resp_bits_id.value = test_source
    dut.io_axi_write_resp_bits_resp.value = 0  # OKAY

    await wait_for_signal(
        dut.clock, dut.io_axi_write_resp_ready, timeout_cycles
    )

    await RisingEdge(dut.clock)
    dut.io_axi_write_resp_valid.value = 0

    #
    # Check TileLink D Channel
    #
    dut.io_tl_d_ready.value = 1
    await wait_for_signal(
        dut.clock, dut.io_tl_d_valid, timeout_cycles,
        "Timeout waiting for TL D_VALID for Put"
    )

    assert dut.io_tl_d_valid.value, "TL D_VALID should be high"
    assert dut.io_tl_d_bits_opcode.value == TLUL_OpcodeD.AccessAck, "TL D_OPCODE should be AccessAck"
    assert dut.io_tl_d_bits_source.value == test_source, "TL D_SOURCE is incorrect"
    assert not dut.io_tl_d_bits_error.value, "TL D_ERROR should be low"
    dut.io_tl_d_ready.value = 0

    # Allow a few extra cycles for waveform viewing.
    await ClockCycles(dut.clock, 5)


@cocotb.test()
async def test_put_then_get(dut):
    """Tests a Put request followed by a Get request."""
    clock = Clock(dut.clock, 10, unit="us")
    cocotb.start_soon(clock.start())

    # Reset
    await reset_dut(dut)

    # AXI slave initial state
    dut.io_axi_read_addr_ready.value = 0
    dut.io_axi_write_addr_ready.value = 0
    dut.io_axi_write_data_ready.value = 0
    dut.io_axi_write_resp_valid.value = 0
    dut.io_axi_read_data_valid.value = 0

    # Test parameters
    addr_width = 32
    source_width = 6
    data_width_bytes = 32
    timeout_cycles = 1000

    # Put parameters
    put_size_power = random.randint(0, 5)
    put_size = put_size_power
    put_num_bytes = 2**put_size_power
    put_addr = random.randint(0, (2**addr_width) - 1)
    put_source = random.randint(0, (2**source_width) - 1)
    put_data = random.randint(0, (2**(data_width_bytes * 8)) - 1)
    put_mask = (1 << put_num_bytes) - 1

    # Get parameters
    get_size_power = random.randint(0, 5)
    get_size = get_size_power
    get_addr = random.randint(0, (2**addr_width) - 1)
    get_source = random.randint(0, (2**source_width) - 1)
    get_data = random.randint(0, (2**(data_width_bytes * 8)) - 1)

    #
    # Complete Put Transaction
    #
    await tl_send_put(
        dut,
        address=put_addr,
        source=put_source,
        size=put_size,
        data=put_data,
        mask=put_mask,
        timeout_cycles=timeout_cycles
    )

    await wait_for_signal(
        dut.clock, dut.io_axi_write_addr_valid, timeout_cycles,
        "Timeout waiting for AXI AWVALID for Put"
    )
    assert dut.io_axi_write_addr_valid.value, "AXI AWVALID should be high for Put"
    assert dut.io_axi_write_data_valid.value, "AXI WVALID should be high for Put"

    dut.io_axi_write_addr_ready.value = 1
    dut.io_axi_write_data_ready.value = 1
    await RisingEdge(dut.clock)
    dut.io_axi_write_addr_ready.value = 0
    dut.io_axi_write_data_ready.value = 0

    await RisingEdge(dut.clock)
    dut.io_axi_write_resp_valid.value = 1
    await wait_for_signal(
        dut.clock, dut.io_axi_write_resp_ready, timeout_cycles
    )
    dut.io_axi_write_resp_valid.value = 0

    dut.io_tl_d_ready.value = 1
    await RisingEdge(dut.clock)
    assert dut.io_tl_d_valid.value, "TL D_VALID should be high for Put"
    assert dut.io_tl_d_bits_opcode.value == TLUL_OpcodeD.AccessAck, "TL D_OPCODE should be AccessAck for Put"
    dut.io_tl_d_ready.value = 0

    #
    # Complete Get Transaction
    #
    await tl_send_get(
        dut,
        address=get_addr,
        source=get_source,
        size=get_size,
        timeout_cycles=timeout_cycles
    )

    await RisingEdge(dut.clock)
    assert dut.io_axi_read_addr_valid.value, "AXI ARVALID should be high for Get"

    dut.io_axi_read_addr_ready.value = 1
    await RisingEdge(dut.clock)
    dut.io_axi_read_addr_ready.value = 0

    await RisingEdge(dut.clock)
    dut.io_axi_read_data_valid.value = 1
    dut.io_axi_read_data_bits_data.value = get_data
    await wait_for_signal(
        dut.clock, dut.io_axi_read_data_ready, timeout_cycles
    )
    dut.io_axi_read_data_valid.value = 0

    dut.io_tl_d_ready.value = 1
    await RisingEdge(dut.clock)
    assert dut.io_tl_d_valid.value, "TL D_VALID should be high for Get"
    assert dut.io_tl_d_bits_opcode.value == TLUL_OpcodeD.AccessAckData, "TL D_OPCODE should be AccessAckData for Get"
    dut.io_tl_d_ready.value = 0

    # Allow a few extra cycles for waveform viewing.
    await ClockCycles(dut.clock, 5)


@cocotb.test()
async def test_instr_type_to_prot_mapping(dut):
    """Verifies OpenTitan MuBi4 instr_type maps to AXI AxPROT[2]."""
    clock = Clock(dut.clock, 10, unit="us")
    cocotb.start_soon(clock.start())

    await reset_dut(dut)
    dut.io_axi_read_addr_ready.value = 0
    dut.io_axi_write_addr_ready.value = 0
    dut.io_axi_write_data_ready.value = 0
    dut.io_axi_write_resp_valid.value = 0
    dut.io_axi_read_data_valid.value = 0

    for source, instr_type, expected_prot in [
        (3, 0x9, 0b000),
        (32, 0x6, 0b100),
    ]:
        await tl_send_get(
            dut,
            address=0x20000000,
            source=source,
            size=4,
            instr_type=instr_type,
        )
        await RisingEdge(dut.clock)
        assert dut.io_axi_read_addr_valid.value
        assert int(dut.io_axi_read_addr_bits_prot.value) == expected_prot

        dut.io_axi_read_addr_ready.value = 1
        await RisingEdge(dut.clock)
        dut.io_axi_read_addr_ready.value = 0

        await RisingEdge(dut.clock)
        dut.io_axi_read_data_valid.value = 1
        dut.io_axi_read_data_bits_id.value = source
        dut.io_axi_read_data_bits_data.value = 0
        dut.io_axi_read_data_bits_resp.value = 0
        dut.io_axi_read_data_bits_last.value = 1
        dut.io_tl_d_ready.value = 1
        await wait_for_signal(dut.clock, dut.io_axi_read_data_ready, 1000)
        await RisingEdge(dut.clock)
        dut.io_axi_read_data_valid.value = 0
        dut.io_tl_d_ready.value = 0
        await ClockCycles(dut.clock, 2)
