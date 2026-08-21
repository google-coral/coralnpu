// Copyright 2024 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package coralnpu

import chisel3._
import chisel3.simulator.scalatest.ChiselSim
import org.scalatest.freespec.AnyFreeSpec

class FRegfileSpec extends AnyFreeSpec with ChiselSim {
  val p = new Parameters
  "Initialization" in {
    simulate(new FRegfile(p, 1, 1)) { dut =>
      dut.io.scoreboard.expect(0)
      for (i <- 0 until 32) {
        dut.io.read_ports(0).valid.poke(true.B)
        dut.io.read_ports(0).addr.poke(i)
        dut.io.read_ports(0).data.sign.expect(0)
        dut.io.read_ports(0).data.exponent.expect(0)
        dut.io.read_ports(0).data.mantissa.expect(0)
      }
    }
  }

  "Basic read/write" in {
    simulate(new FRegfile(p, 1, 1)) { dut =>
      for (i <- 0 until 32) {
        dut.io.scoreboard_set.poke((BigInt(1) << i).U)
        dut.clock.step()
        dut.io.write_ports(0).valid.poke(true.B)
        dut.io.write_ports(0).addr.poke(i)
        dut.io.write_ports(0).data.sign.poke(0)
        dut.io.write_ports(0).data.exponent.poke(i + 127)
        dut.io.write_ports(0).data.mantissa.poke(0)
        dut.clock.step()
      }

      for (i <- 0 until 32) {
        dut.io.read_ports(0).valid.poke(true.B)
        dut.io.read_ports(0).addr.poke(i)
        dut.io.read_ports(0).data.sign.expect(0)
        dut.io.read_ports(0).data.exponent.expect(i + 127)
        dut.io.read_ports(0).data.mantissa.expect(0)
      }
    }
  }

  "Multiread" in {
    simulate(new FRegfile(p, 2, 1)) { dut =>
      for (i <- 0 until 32) {
        dut.io.scoreboard_set.poke((BigInt(1) << i).U)
        dut.clock.step()
        dut.io.write_ports(0).valid.poke(true.B)
        dut.io.write_ports(0).addr.poke(i)
        dut.io.write_ports(0).data.sign.poke(0)
        dut.io.write_ports(0).data.exponent.poke(i + 127)
        dut.io.write_ports(0).data.mantissa.poke(0)
        dut.clock.step()
      }

      dut.io.write_ports(0).valid.poke(false.B)

      dut.io.read_ports(0).valid.poke(true.B)
      dut.io.read_ports(0).addr.poke(0)
      dut.io.read_ports(0).data.sign.expect(0)
      dut.io.read_ports(0).data.exponent.expect(127)
      dut.io.read_ports(0).data.mantissa.expect(0)

      dut.io.read_ports(1).valid.poke(true.B)
      dut.io.read_ports(1).addr.poke(20)
      dut.io.read_ports(1).data.sign.expect(0)
      dut.io.read_ports(1).data.exponent.expect(147)
      dut.io.read_ports(1).data.mantissa.expect(0)
    }
  }

  "Multiwrite" in {
    simulate(new FRegfile(p, 2, 2)) { dut =>
      for (i <- 0 until 32) {
        dut.io.scoreboard_set.poke((BigInt(1) << i).U)
        dut.clock.step()
        dut.io.write_ports(0).valid.poke(true.B)
        dut.io.write_ports(0).addr.poke(i)
        dut.io.write_ports(0).data.sign.poke(0)
        dut.io.write_ports(0).data.exponent.poke(0)
        dut.io.write_ports(0).data.mantissa.poke(0)
        dut.clock.step()
      }

      dut.io.scoreboard_set.poke((BigInt(1) << 3).U)
      dut.clock.step()
      dut.io.write_ports(0).valid.poke(true.B)
      dut.io.write_ports(0).addr.poke(3)
      dut.io.write_ports(0).data.sign.poke(0)
      dut.io.write_ports(0).data.exponent.poke(37)
      dut.io.write_ports(0).data.mantissa.poke(44)

      dut.io.scoreboard_set.poke((BigInt(1) << 12).U)
      dut.clock.step()
      dut.io.write_ports(1).valid.poke(true.B)
      dut.io.write_ports(1).addr.poke(12)
      dut.io.write_ports(1).data.sign.poke(0)
      dut.io.write_ports(1).data.exponent.poke(14)
      dut.io.write_ports(1).data.mantissa.poke(560)

      dut.clock.step()

      dut.io.read_ports(0).valid.poke(true.B)
      dut.io.read_ports(0).addr.poke(3)
      dut.io.read_ports(0).data.sign.expect(0)
      dut.io.read_ports(0).data.exponent.expect(37)
      dut.io.read_ports(0).data.mantissa.expect(44)

      dut.io.read_ports(1).valid.poke(true.B)
      dut.io.read_ports(1).addr.poke(12)
      dut.io.read_ports(1).data.sign.expect(0)
      dut.io.read_ports(1).data.exponent.expect(14)
      dut.io.read_ports(1).data.mantissa.expect(560)
    }
  }

  "Scoreboard" in {
    simulate(new FRegfile(p, 1, 2)) { dut =>
      dut.io.scoreboard.expect(0)
      dut.io.scoreboard_set.poke(31)
      dut.clock.step()
      dut.io.scoreboard.expect(31)

      // Clear the two LSBs
      dut.io.scoreboard_set.poke(0)
      dut.io.write_ports(0).valid.poke(true.B)
      dut.io.write_ports(0).addr.poke(0)
      dut.io.write_ports(1).valid.poke(true.B)
      dut.io.write_ports(1).addr.poke(1)
      dut.clock.step()
      dut.io.scoreboard.expect(28)

      // Clear the two entries and set 1 in the same cycle
      dut.io.scoreboard_set.poke(1)
      dut.io.write_ports(0).valid.poke(true.B)
      dut.io.write_ports(0).addr.poke(2)
      dut.io.write_ports(1).valid.poke(true.B)
      dut.io.write_ports(1).addr.poke(3)
      dut.clock.step()
      dut.io.scoreboard.expect(17)
    }
  }

  "Multiwrite Exception" in {
    simulate(new FRegfile(p, 2, 2)) { dut =>
      for (i <- 0 until 32) {
        dut.io.scoreboard_set.poke((BigInt(1) << i).U)
        dut.clock.step()
        dut.io.write_ports(0).valid.poke(true.B)
        dut.io.write_ports(0).addr.poke(i)
        dut.io.write_ports(0).data.sign.poke(0)
        dut.io.write_ports(0).data.exponent.poke(0)
        dut.io.write_ports(0).data.mantissa.poke(0)
        dut.clock.step()
      }

      dut.io.write_ports(0).valid.poke(true.B)
      dut.io.write_ports(0).addr.poke(3)
      dut.io.write_ports(0).data.sign.poke(0)
      dut.io.write_ports(0).data.exponent.poke(37)
      dut.io.write_ports(0).data.mantissa.poke(44)

      dut.io.write_ports(1).valid.poke(true.B)
      dut.io.write_ports(1).addr.poke(3)
      dut.io.write_ports(1).data.sign.poke(0)
      dut.io.write_ports(1).data.exponent.poke(14)
      dut.io.write_ports(1).data.mantissa.poke(560)

      dut.io.exception.expect(1)
    }
  }

  "Pipeline Flush with writeback" in {
    simulate(new FRegfile(p, 1, 2)) { dut =>
      dut.io.scoreboard_set.poke(31)
      dut.clock.step()
      dut.io.scoreboard.expect(31)

      // Flush pipeline - scoreboard resets to 0
      dut.io.pipelineFlush.poke(true.B)
      dut.io.scoreboard_set.poke(0)
      dut.clock.step()
      dut.io.scoreboard.expect(0)
      dut.io.pipelineFlush.poke(false.B)

      // An in-flight instruction arrives and writes back to f2
      dut.io.write_ports(0).valid.poke(true.B)
      dut.io.write_ports(0).addr.poke(2)
      dut.clock.step()
    }
  }
}
