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

import socket
import queue
import subprocess
import tempfile
import threading

from bazel_tools.tools.python.runfiles import runfiles
from enum import Enum
from cocotb.triggers import ClockCycles
from pyocd.board.board import Board
from pyocd.core import exceptions
from pyocd.core.core_registers import CoreRegistersIndex, CoreRegisterInfo
from pyocd.core.memory_map import RamRegion, MemoryMap
from pyocd.core.session import Session
from pyocd.core.target import Target
from pyocd.debug.context import DebugContext
from pyocd.gdbserver.gdbserver import GDBServer
from pyocd.probe.debug_probe import DebugProbe


class CoreMiniAxiDebugOps(Enum):
    HALT = 0
    READ_MEMORY_BLOCK8 = 1
    READ_REG = 2
    RESUME = 3
    SET_BREAKPOINT = 4
    REMOVE_BREAKPOINT = 5
    STEP = 6
    WRITE_MEMORY_BLOCK8 = 7


class CoreMiniAxiProbe(DebugProbe):

    def __init__(self, session):
        super().__init__()
        self.session = session
        self._protocol = None

    def open(self):
        pass

    def set_clock(self, frequency):
        pass

    @property
    def capabilities(self):
        return {}

    @property
    def supported_wire_protocols(self):
        return [DebugProbe.Protocol.DEFAULT]

    @property
    def wire_protocol(self):
        return self._protocol

    def connect(self, protocol=None):
        self._protocol = protocol


class CoreMiniAxiCore(object):

    def __init__(self, session):
        self.session = session
        self._core_registers = CoreRegistersIndex()
        self._core_registers.add_group([
            # Scalar registers
            CoreRegisterInfo(
                'x0', 0, 32, 'int', 'general', 0, 'org.gnu.gdb.riscv.cpu'
            ),
            CoreRegisterInfo(
                'x1', 1, 32, 'int', 'general', 1, 'org.gnu.gdb.riscv.cpu'
            ),
            CoreRegisterInfo(
                'x2', 2, 32, 'int', 'general', 2, 'org.gnu.gdb.riscv.cpu'
            ),
            CoreRegisterInfo(
                'x3', 3, 32, 'int', 'general', 3, 'org.gnu.gdb.riscv.cpu'
            ),
            CoreRegisterInfo(
                'x4', 4, 32, 'int', 'general', 4, 'org.gnu.gdb.riscv.cpu'
            ),
            CoreRegisterInfo(
                'x5', 5, 32, 'int', 'general', 5, 'org.gnu.gdb.riscv.cpu'
            ),
            CoreRegisterInfo(
                'x6', 6, 32, 'int', 'general', 6, 'org.gnu.gdb.riscv.cpu'
            ),
            CoreRegisterInfo(
                'x7', 7, 32, 'int', 'general', 7, 'org.gnu.gdb.riscv.cpu'
            ),
            CoreRegisterInfo(
                'x8', 8, 32, 'int', 'general', 8, 'org.gnu.gdb.riscv.cpu'
            ),
            CoreRegisterInfo(
                'x9', 9, 32, 'int', 'general', 9, 'org.gnu.gdb.riscv.cpu'
            ),
            CoreRegisterInfo(
                'x10', 10, 32, 'int', 'general', 10, 'org.gnu.gdb.riscv.cpu'
            ),
            CoreRegisterInfo(
                'x11', 11, 32, 'int', 'general', 11, 'org.gnu.gdb.riscv.cpu'
            ),
            CoreRegisterInfo(
                'x12', 12, 32, 'int', 'general', 12, 'org.gnu.gdb.riscv.cpu'
            ),
            CoreRegisterInfo(
                'x13', 13, 32, 'int', 'general', 13, 'org.gnu.gdb.riscv.cpu'
            ),
            CoreRegisterInfo(
                'x14', 14, 32, 'int', 'general', 14, 'org.gnu.gdb.riscv.cpu'
            ),
            CoreRegisterInfo(
                'x15', 15, 32, 'int', 'general', 15, 'org.gnu.gdb.riscv.cpu'
            ),
            CoreRegisterInfo(
                'x16', 16, 32, 'int', 'general', 16, 'org.gnu.gdb.riscv.cpu'
            ),
            CoreRegisterInfo(
                'x17', 17, 32, 'int', 'general', 17, 'org.gnu.gdb.riscv.cpu'
            ),
            CoreRegisterInfo(
                'x18', 18, 32, 'int', 'general', 18, 'org.gnu.gdb.riscv.cpu'
            ),
            CoreRegisterInfo(
                'x19', 19, 32, 'int', 'general', 19, 'org.gnu.gdb.riscv.cpu'
            ),
            CoreRegisterInfo(
                'x20', 20, 32, 'int', 'general', 20, 'org.gnu.gdb.riscv.cpu'
            ),
            CoreRegisterInfo(
                'x21', 21, 32, 'int', 'general', 21, 'org.gnu.gdb.riscv.cpu'
            ),
            CoreRegisterInfo(
                'x22', 22, 32, 'int', 'general', 22, 'org.gnu.gdb.riscv.cpu'
            ),
            CoreRegisterInfo(
                'x23', 23, 32, 'int', 'general', 23, 'org.gnu.gdb.riscv.cpu'
            ),
            CoreRegisterInfo(
                'x24', 24, 32, 'int', 'general', 24, 'org.gnu.gdb.riscv.cpu'
            ),
            CoreRegisterInfo(
                'x25', 25, 32, 'int', 'general', 25, 'org.gnu.gdb.riscv.cpu'
            ),
            CoreRegisterInfo(
                'x26', 26, 32, 'int', 'general', 26, 'org.gnu.gdb.riscv.cpu'
            ),
            CoreRegisterInfo(
                'x27', 27, 32, 'int', 'general', 27, 'org.gnu.gdb.riscv.cpu'
            ),
            CoreRegisterInfo(
                'x28', 28, 32, 'int', 'general', 28, 'org.gnu.gdb.riscv.cpu'
            ),
            CoreRegisterInfo(
                'x29', 29, 32, 'int', 'general', 29, 'org.gnu.gdb.riscv.cpu'
            ),
            CoreRegisterInfo(
                'x30', 30, 32, 'int', 'general', 30, 'org.gnu.gdb.riscv.cpu'
            ),
            CoreRegisterInfo(
                'x31', 31, 32, 'int', 'general', 31, 'org.gnu.gdb.riscv.cpu'
            ),
            CoreRegisterInfo(
                'pc', 32, 32, 'int', 'general', 32, 'org.gnu.gdb.riscv.cpu'
            ),
            CoreRegisterInfo(
                'f0', 33, 32, 'ieee_single', 'float', 33,
                'org.gnu.gdb.riscv.fpu'
            ),
            CoreRegisterInfo(
                'f1', 34, 32, 'ieee_single', 'float', 34,
                'org.gnu.gdb.riscv.fpu'
            ),
            CoreRegisterInfo(
                'f2', 35, 32, 'ieee_single', 'float', 35,
                'org.gnu.gdb.riscv.fpu'
            ),
            CoreRegisterInfo(
                'f3', 36, 32, 'ieee_single', 'float', 36,
                'org.gnu.gdb.riscv.fpu'
            ),
            CoreRegisterInfo(
                'f4', 37, 32, 'ieee_single', 'float', 37,
                'org.gnu.gdb.riscv.fpu'
            ),
            CoreRegisterInfo(
                'f5', 38, 32, 'ieee_single', 'float', 38,
                'org.gnu.gdb.riscv.fpu'
            ),
            CoreRegisterInfo(
                'f6', 39, 32, 'ieee_single', 'float', 39,
                'org.gnu.gdb.riscv.fpu'
            ),
            CoreRegisterInfo(
                'f7', 40, 32, 'ieee_single', 'float', 40,
                'org.gnu.gdb.riscv.fpu'
            ),
            CoreRegisterInfo(
                'f8', 41, 32, 'ieee_single', 'float', 41,
                'org.gnu.gdb.riscv.fpu'
            ),
            CoreRegisterInfo(
                'f9', 42, 32, 'ieee_single', 'float', 42,
                'org.gnu.gdb.riscv.fpu'
            ),
            CoreRegisterInfo(
                'f10', 43, 32, 'ieee_single', 'float', 43,
                'org.gnu.gdb.riscv.fpu'
            ),
            CoreRegisterInfo(
                'f11', 44, 32, 'ieee_single', 'float', 44,
                'org.gnu.gdb.riscv.fpu'
            ),
            CoreRegisterInfo(
                'f12', 45, 32, 'ieee_single', 'float', 45,
                'org.gnu.gdb.riscv.fpu'
            ),
            CoreRegisterInfo(
                'f13', 46, 32, 'ieee_single', 'float', 46,
                'org.gnu.gdb.riscv.fpu'
            ),
            CoreRegisterInfo(
                'f14', 47, 32, 'ieee_single', 'float', 47,
                'org.gnu.gdb.riscv.fpu'
            ),
            CoreRegisterInfo(
                'f15', 48, 32, 'ieee_single', 'float', 48,
                'org.gnu.gdb.riscv.fpu'
            ),
            CoreRegisterInfo(
                'f16', 49, 32, 'ieee_single', 'float', 49,
                'org.gnu.gdb.riscv.fpu'
            ),
            CoreRegisterInfo(
                'f17', 50, 32, 'ieee_single', 'float', 50,
                'org.gnu.gdb.riscv.fpu'
            ),
            CoreRegisterInfo(
                'f18', 51, 32, 'ieee_single', 'float', 51,
                'org.gnu.gdb.riscv.fpu'
            ),
            CoreRegisterInfo(
                'f19', 52, 32, 'ieee_single', 'float', 52,
                'org.gnu.gdb.riscv.fpu'
            ),
            CoreRegisterInfo(
                'f20', 53, 32, 'ieee_single', 'float', 53,
                'org.gnu.gdb.riscv.fpu'
            ),
            CoreRegisterInfo(
                'f21', 54, 32, 'ieee_single', 'float', 54,
                'org.gnu.gdb.riscv.fpu'
            ),
            CoreRegisterInfo(
                'f22', 55, 32, 'ieee_single', 'float', 55,
                'org.gnu.gdb.riscv.fpu'
            ),
            CoreRegisterInfo(
                'f23', 56, 32, 'ieee_single', 'float', 56,
                'org.gnu.gdb.riscv.fpu'
            ),
            CoreRegisterInfo(
                'f24', 57, 32, 'ieee_single', 'float', 57,
                'org.gnu.gdb.riscv.fpu'
            ),
            CoreRegisterInfo(
                'f25', 58, 32, 'ieee_single', 'float', 58,
                'org.gnu.gdb.riscv.fpu'
            ),
            CoreRegisterInfo(
                'f26', 59, 32, 'ieee_single', 'float', 59,
                'org.gnu.gdb.riscv.fpu'
            ),
            CoreRegisterInfo(
                'f27', 60, 32, 'ieee_single', 'float', 60,
                'org.gnu.gdb.riscv.fpu'
            ),
            CoreRegisterInfo(
                'f28', 61, 32, 'ieee_single', 'float', 61,
                'org.gnu.gdb.riscv.fpu'
            ),
            CoreRegisterInfo(
                'f29', 62, 32, 'ieee_single', 'float', 62,
                'org.gnu.gdb.riscv.fpu'
            ),
            CoreRegisterInfo(
                'f30', 63, 32, 'ieee_single', 'float', 63,
                'org.gnu.gdb.riscv.fpu'
            ),
            CoreRegisterInfo(
                'f31', 64, 32, 'ieee_single', 'float', 64,
                'org.gnu.gdb.riscv.fpu'
            ),
            CoreRegisterInfo(
                'fflags', 65, 32, 'ieee_single', 'float', 65,
                'org.gnu.gdb.riscv.fpu'
            ),
            CoreRegisterInfo(
                'frm', 66, 32, 'ieee_single', 'float', 65,
                'org.gnu.gdb.riscv.fpu'
            ),
            CoreRegisterInfo(
                'fcsr', 67, 32, 'ieee_single', 'float', 65,
                'org.gnu.gdb.riscv.fpu'
            ),

            # Stub out some ARM-named registers for pyOCD.
            CoreRegisterInfo(
                'lr', 1, 32, 'int', 'general', 1, 'org.gnu.gdb.arm.core'
            ),
            CoreRegisterInfo(
                'sp', 2, 32, 'int', 'general', 2, 'org.gnu.gdb.arm.core'
            ),
            CoreRegisterInfo(
                'r7', 7, 32, 'int', 'general', 7, 'org.gnu.gdb.arm.core'
            ),
        ])
        self._memory_map = MemoryMap([
            RamRegion(0, 0x1FFF, 0x2000),
            RamRegion(0x10000, 0x17FFF, 0x8000),
        ])

    @property
    def core_registers(self) -> CoreRegistersIndex:
        return self._core_registers

    @property
    def memory_map(self) -> MemoryMap:
        return self._memory_map

    def is_debug_trap(self):
        return True

    def is_vector_catch(self):
        return False

    def get_halt_reason(self):
        return Target.HaltReason.DEBUG

    def exception_number_to_name(self, exc_num):
        return "exc"


class CoreMiniAxiContext(DebugContext):

    def __init__(self, parent, session, dut, target):
        self._parent = parent
        self._core = CoreMiniAxiCore(session)
        self.dut = dut
        self.target = target
        self._halted = False

    def read_core_registers_raw(self, reg_list):
        if not self._halted:
            raise exceptions.CoreRegisterAccessError("Not halted!")
            return []
        return self.target.read_core_registers_raw(reg_list)

    def read_memory_block8(self, addr, size):
        return self.target.read_memory_block8(addr, size)

    def write_memory_block8(self, addr, data) -> None:
        self.target.write_memory_block8(addr, data)

    def flush(self):
        pass


class CoreMiniAxiAccessPort(object):

    def __init__(self):
        pass

    @property
    def address(self):
        return None


class CoreMiniAxiTarget(Target):

    def __init__(self, session, dut, q, q_rsp):
        super().__init__(session)
        self._context = CoreMiniAxiContext(None, session, dut, self)
        self.ap = CoreMiniAxiAccessPort()
        self.aps = {0: self.ap}
        self.dut = dut
        self.q = q
        self.q_rsp = q_rsp

    def init(self):
        pass

    def set_vector_catch(self, enable_mask):
        pass

    def get_state(self):
        return Target.State.HALTED if self._context._halted else Target.State.RUNNING

    def get_target_context(self, core=None):
        return self._context

    def add_target_command_groups(self, command_set):
        pass

    def halt(self):
        e = threading.Event()
        self.q.put((CoreMiniAxiDebugOps.HALT, e, {}))
        e.wait()
        rsp = self.q_rsp.get()
        self._context._halted = True
        return rsp

    def read_memory_block8(self, addr, size):
        e = threading.Event()
        self.q.put((
            CoreMiniAxiDebugOps.READ_MEMORY_BLOCK8, e, {
                'addr': addr,
                'size': size,
            }
        ))
        e.wait()
        rsp = self.q_rsp.get()
        return rsp

    def write_memory_block8(self, addr, size):
        e = threading.Event()
        self.q.put((
            CoreMiniAxiDebugOps.WRITE_MEMORY_BLOCK8, e, {
                'addr': addr,
                'data': size,
            }
        ))
        e.wait()
        rsp = self.q_rsp.get()
        return rsp

    def read_core_registers_raw(self, reg_list):
        ret = []
        for reg in reg_list:
            if reg == 261:  # ARM IPSR
                ret.append(0)
            # if type(reg) == str:
            else:
                reg_str_to_int = {
                    'r7': 7,
                    'sp': 2,
                    'lr': 1,
                    'pc': 32,
                }
                if type(reg) == str:
                    reg = reg_str_to_int[reg]

                # Map from gdb register to DM register
                if reg == 32:  # PC
                    reg = 0x7B1
                elif reg >= 0 and reg < 31:  # Scalar
                    reg = reg + 0x1000
                elif reg >= 33 and reg < 65:  # Float
                    reg = (reg - 33) + 0x1020
                elif reg >= 65 and reg < 68:  # Floating CSRs
                    reg = (reg - 65 + 1)
                else:
                    ret.append(0)
                    continue

                e = threading.Event()
                self.q.put((CoreMiniAxiDebugOps.READ_REG, e, {
                    'addr': reg,
                }))
                rv = self.q_rsp.get()
                ret.append(rv)

        return ret

    def resume(self):
        e = threading.Event()
        self.q.put((CoreMiniAxiDebugOps.RESUME, e, {}))
        e.wait()
        self._context._halted = False
        rsp = self.q_rsp.get()
        return rsp

    def set_breakpoint(self, addr, type=Target.BreakpointType.AUTO):
        e = threading.Event()
        self.q.put((CoreMiniAxiDebugOps.SET_BREAKPOINT, e, {
            'addr': addr,
        }))
        e.wait()
        rsp = self.q_rsp.get()
        return rsp

    def remove_breakpoint(self, addr):
        e = threading.Event()
        self.q.put(
            (CoreMiniAxiDebugOps.REMOVE_BREAKPOINT, e, {
                'addr': addr,
            })
        )
        e.wait()
        rsp = self.q_rsp.get()
        assert rsp == True

    def step(self, disable_interrupts, start, end, hook_cb=None):
        assert (start == end)
        e = threading.Event()
        self.q.put((CoreMiniAxiDebugOps.STEP, e, {}))
        e.wait()
        rsp = self.q_rsp.get()
        self._context._halted = True


class CoreMiniAxiBoard(Board):

    def __init__(self, session, dut, q, q_rsp):
        self._session = session
        self.target = CoreMiniAxiTarget(session, dut, q, q_rsp)
        self._delegate = None


class CoreMiniAxiSession(Session):

    def __init__(self, dut, q, q_rsp, notify_cb, options=None):
        super().__init__(None, options=options)
        self._probe = CoreMiniAxiProbe(self)
        self._board = CoreMiniAxiBoard(self, dut, q, q_rsp)
        self._q = q
        self._q_rsp = q_rsp
        self._notify_cb = notify_cb

    def notify(self, event, source=None, data=None):
        self._notify_cb()

    def halted(self):
        return self._board.target._context._halted

    def bp_halt(self):
        self._board.target._context._halted = True


class CoreMiniAxiGDBServer(object):

    def __init__(self, core_mini_axi):
        self.core_mini_axi = core_mini_axi
        self.finish = queue.Queue()

    async def run(self, elf, gdb_commands):
        entry_point = await self.core_mini_axi.load_elf(elf)

        # Get random free ports for GDB server and Telnet
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s_gdb, \
             socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s_telnet:
            s_gdb.bind(('', 0))
            s_telnet.bind(('', 0))
            gdb_port = s_gdb.getsockname()[1]
            telnet_port = s_telnet.getsockname()[1]

        def exec_gdb():
            try:
                with tempfile.NamedTemporaryFile(mode='w+') as cmdfile:
                    r = runfiles.Create()
                    gdb_path = r.Rlocation("coralnpu_hw/toolchain/gdb")
                    cmds_pre = [
                        'set architecture riscv:rv32',
                        f'target remote :{gdb_port}',
                    ]
                    cmds_post = [
                        'quit',
                    ]
                    cmds = cmds_pre + gdb_commands + cmds_post
                    for cmd in cmds:
                        cmdfile.write(f'{cmd}\n')
                    cmdfile.flush()
                    args = [
                        gdb_path,
                        '-x',
                        cmdfile.name,
                        elf.name,
                    ]
                    ret = subprocess.call(
                        args,
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL,
                    )
                    self.finish.put(ret == 0)
            except Exception:
                self.finish.put(False)

        def notify_cb():
            gdb_daemon = threading.Thread(target=exec_gdb, daemon=True)
            gdb_daemon.start()

        gdbserver_queue = queue.Queue()
        gdbserver_queue_rsp = queue.Queue()
        session = CoreMiniAxiSession(
            self.core_mini_axi,
            gdbserver_queue,
            gdbserver_queue_rsp,
            notify_cb,
            options={
                'gdbserver_port': gdb_port,
                'telnet_port': telnet_port,
            }
        )
        session.open()
        gdb_server = GDBServer(session=session)
        gdb_server.start()

        executed = False
        bp_set = False
        bp_triggered = False
        while True:
            try:
                (t, e, kwargs) = gdbserver_queue.get(timeout=0.0001)
            except queue.Empty:
                if not self.finish.empty():
                    break
                if gdb_server.is_alive():
                    halted = await self.core_mini_axi.dm_check_for_halted()
                    if not session.halted(
                    ) and halted and bp_set and not bp_triggered:
                        bp_triggered = True
                        session.bp_halt()
                    await ClockCycles(self.core_mini_axi.dut.io_aclk, 1)
                    continue
                else:
                    break
            if t == CoreMiniAxiDebugOps.HALT:
                await self.core_mini_axi.dm_request_halt()
                if not executed:
                    await self.core_mini_axi.execute_from(entry_point)
                    executed = True
                await self.core_mini_axi.dm_wait_for_halted()
                gdbserver_queue_rsp.put(True)
            if t == CoreMiniAxiDebugOps.READ_MEMORY_BLOCK8:
                addr = kwargs['addr']
                size = kwargs['size']
                read_data = bytearray()
                current_addr = addr
                remaining_size = size

                while remaining_size > 0:
                    access_size = 1
                    if (current_addr % 4 == 0) and (remaining_size >= 4):
                        access_size = 4
                    elif (current_addr % 2 == 0) and (remaining_size >= 2):
                        access_size = 2

                    val = await self.core_mini_axi.dm_read_mem(
                        current_addr, access_size
                    )
                    val = val & ((1 << (access_size * 8)) - 1)
                    read_data.extend(val.to_bytes(access_size, 'little'))

                    current_addr += access_size
                    remaining_size -= access_size

                gdbserver_queue_rsp.put(bytes(read_data))
            if t == CoreMiniAxiDebugOps.WRITE_MEMORY_BLOCK8:
                addr = kwargs['addr']
                data = kwargs['data']  # data is a bytes object
                current_addr = addr
                current_data_idx = 0
                remaining_size = len(data)

                while remaining_size > 0:
                    access_size = 1
                    if (current_addr % 4 == 0) and (remaining_size >= 4):
                        access_size = 4
                    elif (current_addr % 2 == 0) and (remaining_size >= 2):
                        access_size = 2

                    chunk = data[current_data_idx:current_data_idx +
                                 access_size]
                    val = int.from_bytes(chunk, 'little')

                    await self.core_mini_axi.dm_write_mem(
                        current_addr, val, access_size
                    )

                    current_addr += access_size
                    current_data_idx += access_size
                    remaining_size -= access_size

                gdbserver_queue_rsp.put(True)
            if t == CoreMiniAxiDebugOps.READ_REG:
                data = await self.core_mini_axi.dm_read_reg(kwargs['addr'])
                gdbserver_queue_rsp.put(data)
            if t == CoreMiniAxiDebugOps.RESUME:
                bp_triggered = False
                await self.core_mini_axi.dm_request_resume()
                gdbserver_queue_rsp.put(True)
            if t == CoreMiniAxiDebugOps.SET_BREAKPOINT:
                if bp_set:
                    gdbserver_queue_rsp.put(False)
                else:
                    await self.core_mini_axi.dm_write_reg(0x7A0, 0)
                    await self.core_mini_axi.dm_write_reg(0x7A1, 0)
                    await self.core_mini_axi.dm_write_reg(
                        0x7A2, kwargs['addr']
                    )
                    desired_tdata1 = 0x62431044
                    await self.core_mini_axi.dm_write_reg(
                        0x7A1, desired_tdata1
                    )
                    bp_set = True
                    gdbserver_queue_rsp.put(True)
            if t == CoreMiniAxiDebugOps.REMOVE_BREAKPOINT:
                if not bp_set:
                    gdbserver_queue_rsp.put(False)
                else:
                    await self.core_mini_axi.dm_write_reg(0x7A0, 0)
                    await self.core_mini_axi.dm_write_reg(0x7A1, 0)
                    await self.core_mini_axi.dm_write_reg(0x7A2, 0)
                    bp_set = False
                    gdbserver_queue_rsp.put(True)
            if t == CoreMiniAxiDebugOps.STEP:
                await self.core_mini_axi.dm_wait_for_halted()
                dcsr = await self.core_mini_axi.dm_read_reg(0x7B0)
                dcsr = dcsr | (1 << 2)
                await self.core_mini_axi.dm_write_reg(0x7B0, dcsr)
                await self.core_mini_axi.dm_request_resume()
                await self.core_mini_axi.dm_wait_for_halted()
                dcsr = await self.core_mini_axi.dm_read_reg(0x7B0)
                dcsr = dcsr & ~(1 << 2)
                await self.core_mini_axi.dm_write_reg(0x7B0, dcsr)
                gdbserver_queue_rsp.put(True)
            e.set()

        gdb_server.stop()
        return self.finish.get()
