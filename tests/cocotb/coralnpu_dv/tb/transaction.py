# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

import enum
from dataclasses import dataclass, field

import numpy as np
from cocotb.triggers import Event


class TxnKind(enum.Enum):
    WRITE = enum.auto()
    READ = enum.auto()


class AxiResp(enum.IntEnum):
    OKAY = 0
    EXOKAY = 1
    SLVERR = 2
    DECERR = 3


def _empty_bytes() -> np.ndarray:
    return np.zeros(0, dtype=np.uint8)


@dataclass(eq=False)
class AxiTransaction:
    kind: TxnKind
    addr: int
    data: np.ndarray = field(default_factory=_empty_bytes)
    n_bytes: int = 0
    resp: AxiResp = AxiResp.OKAY
    axi_id: int = 0
    burst_len: int = 0
    size: int = 0
    done: Event = field(default_factory=Event, repr=False)

    def compare(self, other: "AxiTransaction") -> bool:
        return (
            self.kind == other.kind and self.addr == other.addr
            and np.array_equal(self.data, other.data)
        )

    def __str__(self) -> str:
        data = np.asarray(self.data, dtype=np.uint8)
        resp = "" if self.resp == AxiResp.OKAY else f" resp={self.resp.name}"
        return (
            f"{self.kind.name} addr={self.addr:#x} len={len(data)}"
            f" data={data.tobytes().hex()}{resp}"
        )
