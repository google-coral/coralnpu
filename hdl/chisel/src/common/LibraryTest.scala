// Copyright 2019 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
package coral.common

import chisel3._
import chisel3.iotesters.PeekPokeTester

class LibraryTest(dut: Library) extends PeekPokeTester(dut) {
  // Use a fixed set of test vectors for determinism. This avoids using
  // scala.util.Random, which can be flagged by security scanners, while
  // preserving the test's reproducibility. An explicit edge case for
  // division by zero (b=0) has been included.
  val testVectors = Seq(
    (198, 137), (13, 133), (138, 22), (106, 184), (130, 122),
    (229, 196), (133, 113), (232, 133), (121, 19), (42, 0)
  )

  for ((a, b) <- testVectors) {
    poke(dut.io.a, a)
    poke(dut.io.b, b)
    step(1)
    expect(dut.io.sum, (a + b) & 0xff)
    expect(dut.io.diff, (a - b) & 0xff)
    expect(dut.io.prod, (a * b) & 0xff)
    expect(dut.io.quot, if (b == 0) 0 else a / b)
    expect(dut.io.rem, if (b == 0) a else a % b)
  }
}
