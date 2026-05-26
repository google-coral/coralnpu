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

#include <cstring>
#include <type_traits>

#include "coralnpu_test_utils/rvv_cpp_util.h"

#ifndef MAX_VREG_GROUP_BYTES
#define MAX_VREG_GROUP_BYTES 128
#endif

size_t vl __attribute__((section(".data"))) = 16;
uint8_t vs1[MAX_VREG_GROUP_BYTES] __attribute__((section(".data")))
    __attribute__((aligned(16)));  // vs1 is narrow
uint8_t vs2[MAX_VREG_GROUP_BYTES] __attribute__((section(".data")))
    __attribute__((aligned(16)));  // vs2 is wide
uint64_t xs2 __attribute__((section(".data")));

template <typename U>
inline U get_xs2_as() {
  static_assert(sizeof(U) <= sizeof(xs2),
                "Type U exceeds the size of xs2 buffer");
  U val;
  std::memcpy(&val, &xs2, sizeof(U));
  return val;
}
uint8_t vd[MAX_VREG_GROUP_BYTES] __attribute__((section(".data")))
    __attribute__((aligned(16)));

#ifndef WV_FUNCTION
#define WV_FUNCTION VwaddW
#endif

template <typename T, Lmul lmul>
inline void test_op() {
  if constexpr (Widen(lmul) != Lmul::INVALID && !std::is_same_v<T, int32_t> &&
                !std::is_same_v<T, uint32_t>) {
    using W = WidenType<T>;
    constexpr Lmul w_lmul = Widen(lmul);
    const auto v_wide = Vle<W, w_lmul>(reinterpret_cast<const W*>(vs2), vl);
#if defined(TEST_WIDEN_WV)
    const auto v_narrow = Vle<T, lmul>(reinterpret_cast<const T*>(vs1), vl);
    const auto result = WV_FUNCTION<T, lmul>(v_wide, v_narrow, vl);
#elif defined(TEST_WIDEN_WX)
    const auto result = WV_FUNCTION<T, lmul>(v_wide, get_xs2_as<T>(), vl);
#endif
    Vse<W, w_lmul>(reinterpret_cast<W*>(vd), result, vl);
  } else {
    __builtin_trap();
  }
}

extern "C" {
#define FN_ATTR __attribute__((used, retain))
#ifdef TEST_INT
#ifndef UNSIGNED_ONLY
FN_ATTR void test_i8_mf4() { test_op<int8_t, Lmul::MF4>(); }
FN_ATTR void test_i8_mf2() { test_op<int8_t, Lmul::MF2>(); }
FN_ATTR void test_i8_m1() { test_op<int8_t, Lmul::M1>(); }
FN_ATTR void test_i8_m2() { test_op<int8_t, Lmul::M2>(); }
FN_ATTR void test_i8_m4() { test_op<int8_t, Lmul::M4>(); }
FN_ATTR void test_i16_mf2() { test_op<int16_t, Lmul::MF2>(); }
FN_ATTR void test_i16_m1() { test_op<int16_t, Lmul::M1>(); }
FN_ATTR void test_i16_m2() { test_op<int16_t, Lmul::M2>(); }
FN_ATTR void test_i16_m4() { test_op<int16_t, Lmul::M4>(); }
#endif

#ifndef SIGNED_ONLY
FN_ATTR void test_u8_mf4() { test_op<uint8_t, Lmul::MF4>(); }
FN_ATTR void test_u8_mf2() { test_op<uint8_t, Lmul::MF2>(); }
FN_ATTR void test_u8_m1() { test_op<uint8_t, Lmul::M1>(); }
FN_ATTR void test_u8_m2() { test_op<uint8_t, Lmul::M2>(); }
FN_ATTR void test_u8_m4() { test_op<uint8_t, Lmul::M4>(); }
FN_ATTR void test_u16_mf2() { test_op<uint16_t, Lmul::MF2>(); }
FN_ATTR void test_u16_m1() { test_op<uint16_t, Lmul::M1>(); }
FN_ATTR void test_u16_m2() { test_op<uint16_t, Lmul::M2>(); }
FN_ATTR void test_u16_m4() { test_op<uint16_t, Lmul::M4>(); }
#endif
#endif
}

#ifdef UNSIGNED_ONLY
void (*impl)() __attribute__((section(".data"))) = &test_u8_m1;
#else
void (*impl)() __attribute__((section(".data"))) = &test_i8_m1;
#endif

int main() {
  impl();
  return 0;
}
