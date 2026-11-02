// Copyright 2026 Google LLC
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

package bus

import chisel3.util.log2Ceil

class TLULParameters(
  val dataBits: Int,
  val addrBits: Int,
  val idBits: Int,
  val sinkBits: Int = 1
) {
  val w = dataBits / 8
  val a = addrBits
  val z = log2Ceil(w)
  val o = idBits
  val i = sinkBits

  def withAddrBits(newAddrBits: Int) =
    new TLULParameters(dataBits, newAddrBits, idBits, sinkBits)
  def augmentId(extraBits: Int) =
    new TLULParameters(dataBits, addrBits, idBits + extraBits, sinkBits)
  def shrinkId(extraBits: Int) = {
    require(
      idBits - extraBits >= 0,
      s"Cannot shrink ID bits below 0 (current: $idBits, shrink: $extraBits)"
    )
    new TLULParameters(dataBits, addrBits, idBits - extraBits, sinkBits)
  }
}
