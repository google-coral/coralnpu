#include <cstring>
#include <string_view>
#include <type_traits>

#include "coralnpu_test_utils/rvv_cpp_util.h"

#ifndef MAX_VREG_GROUP_BYTES
#define MAX_VREG_GROUP_BYTES 128
#endif

size_t vl __attribute__((section(".data"))) = 16;
uint8_t vs1[MAX_VREG_GROUP_BYTES] __attribute__((section(".data")))
    __attribute__((aligned(16)));
uint8_t vs2[MAX_VREG_GROUP_BYTES] __attribute__((section(".data")))
    __attribute__((aligned(16)));
uint64_t xs2 __attribute__((section(".data")));

template <typename U>
inline U get_xs2_as() {
  static_assert(sizeof(U) <= sizeof(xs2),
                "Type U exceeds the size of xs2 buffer");
  U val;
  std::memcpy(&val, &xs2, sizeof(U));
  return val;
}
uint8_t v0_buf[MAX_VREG_GROUP_BYTES / 8] __attribute__((section(".data")))
    __attribute__((aligned(16)));
uint8_t vd[MAX_VREG_GROUP_BYTES] __attribute__((section(".data")))
    __attribute__((aligned(16)));

#ifndef VX_FUNCTION
#define VX_FUNCTION Vadd
#endif

// Define a safe trait that degrades gracefully for floats
template <typename T>
using safe_make_unsigned_t =
    std::conditional_t<std::is_integral_v<T>, std::make_unsigned_t<T>, T>;

// Helper to determine if we should call _vx or _vf
template <typename T, Lmul lmul>
inline auto call_vx_or_vf(RvvType<T, lmul> v1, T s2, size_t vl) {
  constexpr uint32_t vxrm = 0;  // RNU
  if constexpr (std::is_floating_point_v<T>) {
    return VX_FUNCTION<T, lmul>(v1, s2, vl);
  } else {
    // Some functions need vxrm
    auto fn = [](auto v1, auto s2, size_t vl) {
#define STR(x) #x
#define XSTR(x) STR(x)
      if constexpr (std::string_view(XSTR(VX_FUNCTION)) == "Vaadd" ||
                    std::string_view(XSTR(VX_FUNCTION)) == "Vasub" ||
                    std::string_view(XSTR(VX_FUNCTION)) == "Vsmul") {
        return VX_FUNCTION<T, lmul, vxrm>(v1, s2, vl);
      } else {
        return VX_FUNCTION<T, lmul>(v1, s2, vl);
      }
    };
#ifdef FORCE_X_UNSIGNED
    return fn(v1, static_cast<safe_make_unsigned_t<T>>(s2), vl);
#else
    return fn(v1, static_cast<T>(s2), vl);
#endif
  }
}

#if defined(TEST_VI)
template <typename T, Lmul lmul>
inline void test_vi_op() {
  const auto v1 = Vle<T, lmul>(reinterpret_cast<const T*>(vs1), vl);
  const auto result = VI_FUNCTION<T, lmul>(v1, vl);
  (void)v1;
  Vse<T, lmul>(reinterpret_cast<T*>(vd), result, vl);
}
#endif

#if defined(TEST_TERNARY)
template <typename T, Lmul lmul>
inline void test_ternary_op() {
  const auto vd_orig = Vle<T, lmul>(reinterpret_cast<const T*>(vd), vl);
  const auto v1 = Vle<T, lmul>(reinterpret_cast<const T*>(vs1), vl);
  const auto result = VX_FUNCTION<T, lmul>(vd_orig, get_xs2_as<T>(), v1, vl);
  Vse<T, lmul>(reinterpret_cast<T*>(vd), result, vl);
}
#endif

#if defined(TEST_BINARY_VV)
template <typename T, Lmul lmul>
inline void test_binary_vv_op() {
  const auto v1 = Vle<T, lmul>(reinterpret_cast<const T*>(vs1), vl);
  const auto v2 = Vle<T, lmul>(reinterpret_cast<const T*>(vs2), vl);
  const auto result = VV_FUNCTION<T, lmul>(v1, v2, vl);
  Vse<T, lmul>(reinterpret_cast<T*>(vd), result, vl);
}
#endif

#if defined(TEST_CARRY)
template <typename T, Lmul lmul>
inline void test_carry_op() {
  const auto v2 = Vle<T, lmul>(reinterpret_cast<const T*>(vs2), vl);
  const auto v1 = Vle<T, lmul>(reinterpret_cast<const T*>(vs1), vl);
  const auto v0 = Vlm<T, lmul>(v0_buf, vl);
  const auto result = CARRY_FUNCTION<T, lmul>(v2, v1, v0, vl);
  Vse<T, lmul>(reinterpret_cast<T*>(vd), result, vl);
}
#endif

#if defined(TEST_CARRY_VX)
template <typename T, Lmul lmul>
inline void test_carry_vx_op() {
  const auto v2 = Vle<T, lmul>(reinterpret_cast<const T*>(vs2), vl);
  const auto v0 = Vlm<T, lmul>(v0_buf, vl);
  const auto result = CARRY_FUNCTION<T, lmul>(v2, get_xs2_as<T>(), v0, vl);
  Vse<T, lmul>(reinterpret_cast<T*>(vd), result, vl);
}
#endif

#if defined(TEST_MADV)
template <typename T, Lmul lmul>
inline void test_madv_op() {
  const auto v2 = Vle<T, lmul>(reinterpret_cast<const T*>(vs2), vl);
  const auto v1 = Vle<T, lmul>(reinterpret_cast<const T*>(vs1), vl);
  const auto v0 = Vlm<T, lmul>(v0_buf, vl);
  const auto result = CARRY_FUNCTION<T, lmul>(v2, v1, v0, vl);
  Vsm<T, lmul>(vd, result, vl);
}
#endif

#if defined(TEST_MADV_VX)
template <typename T, Lmul lmul>
inline void test_madv_vx_op() {
  const auto v2 = Vle<T, lmul>(reinterpret_cast<const T*>(vs2), vl);
  const auto v0 = Vlm<T, lmul>(v0_buf, vl);
  const auto result = CARRY_FUNCTION<T, lmul>(v2, get_xs2_as<T>(), v0, vl);
  Vsm<T, lmul>(vd, result, vl);
}
#endif

#if defined(TEST_MADV_NO_M)
template <typename T, Lmul lmul>
inline void test_madv_no_m_op() {
  const auto v2 = Vle<T, lmul>(reinterpret_cast<const T*>(vs2), vl);
  const auto v1 = Vle<T, lmul>(reinterpret_cast<const T*>(vs1), vl);
  const auto result = CARRY_FUNCTION<T, lmul>(v2, v1, vl);
  Vsm<T, lmul>(vd, result, vl);
}
#endif

#if defined(TEST_MADV_NO_M_VX)
template <typename T, Lmul lmul>
inline void test_madv_no_m_vx_op() {
  const auto v2 = Vle<T, lmul>(reinterpret_cast<const T*>(vs2), vl);
  const auto result = CARRY_FUNCTION<T, lmul>(v2, get_xs2_as<T>(), vl);
  Vsm<T, lmul>(vd, result, vl);
}
#endif

#if defined(TEST_MERGE)
template <typename T, Lmul lmul>
inline void test_merge_op() {
  const auto v2 = Vle<T, lmul>(reinterpret_cast<const T*>(vs2), vl);
  const auto v1 = Vle<T, lmul>(reinterpret_cast<const T*>(vs1), vl);
  const auto v0 = Vlm<T, lmul>(v0_buf, vl);
  const auto result = Vmerge<T, lmul>(v2, v1, v0, vl);
  Vse<T, lmul>(reinterpret_cast<T*>(vd), result, vl);
}
#endif

#if defined(TEST_VMV)
template <typename T, Lmul lmul>
inline void test_vmv_op() {
  const auto v1 = Vle<T, lmul>(reinterpret_cast<const T*>(vs1), vl);
  const auto result = Vmv<T, lmul>(v1, vl);
  Vse<T, lmul>(reinterpret_cast<T*>(vd), result, vl);
}
#endif

#if defined(TEST_COMP_VV)
template <typename T, Lmul lmul>
inline void test_comp_vv_op() {
  const auto v2 = Vle<T, lmul>(reinterpret_cast<const T*>(vs2), vl);
  const auto v1 = Vle<T, lmul>(reinterpret_cast<const T*>(vs1), vl);
  const auto result = COMP_FUNCTION<T, lmul>(v2, v1, vl);
  Vsm<T, lmul>(vd, result, vl);
}
#endif

#if defined(TEST_COMP_VX)
template <typename T, Lmul lmul>
inline void test_comp_vx_op() {
  const auto v2 = Vle<T, lmul>(reinterpret_cast<const T*>(vs2), vl);
  const auto result = COMP_FUNCTION<T, lmul>(v2, get_xs2_as<T>(), vl);
  Vsm<T, lmul>(vd, result, vl);
}
#endif

#if defined(TEST_EXT)
template <typename T, Lmul lmul>
inline void test_ext_op() {
  if constexpr (WidenFactor(lmul, EXT_FACTOR) != Lmul::INVALID &&
                sizeof(T) * 8 / EXT_FACTOR >= 8) {
    const auto v2 = Vle<NarrowScalarType<T, EXT_FACTOR>, Narrow(lmul, EXT_FACTOR)>(
        reinterpret_cast<const NarrowScalarType<T, EXT_FACTOR>*>(vs1), vl);
    const auto result = EXT_FUNCTION<T, lmul>(v2, vl);
    Vse<T, lmul>(reinterpret_cast<T*>(vd), result, vl);
  }
}
#endif

template <typename T, Lmul lmul>
inline void test_op() {
#if defined(TEST_VI)
  test_vi_op<T, lmul>();
#elif defined(TEST_EXT)
  test_ext_op<T, lmul>();
#elif defined(TEST_TERNARY)
  test_ternary_op<T, lmul>();
#elif defined(TEST_BINARY_VV)
  test_binary_vv_op<T, lmul>();
#elif defined(TEST_CARRY)
  test_carry_op<T, lmul>();
#elif defined(TEST_CARRY_VX)
  test_carry_vx_op<T, lmul>();
#elif defined(TEST_MADV)
  test_madv_op<T, lmul>();
#elif defined(TEST_MADV_VX)
  test_madv_vx_op<T, lmul>();
#elif defined(TEST_MADV_NO_M)
  test_madv_no_m_op<T, lmul>();
#elif defined(TEST_MADV_NO_M_VX)
  test_madv_no_m_vx_op<T, lmul>();
#elif defined(TEST_MERGE)
  test_merge_op<T, lmul>();
#elif defined(TEST_VMV)
  test_vmv_op<T, lmul>();
#elif defined(TEST_COMP_VV)
  test_comp_vv_op<T, lmul>();
#elif defined(TEST_COMP_VX)
  test_comp_vx_op<T, lmul>();
#else
#if defined(TEST_WIDEN_VX)
  if constexpr (!std::is_same_v<T, int32_t> && !std::is_same_v<T, uint32_t> &&
                Widen(lmul) != Lmul::INVALID) {
    const auto v1 = Vle<T, lmul>(reinterpret_cast<const T*>(vs1), vl);
    const auto result = call_vx_or_vf<T, lmul>(v1, get_xs2_as<T>(), vl);
    using W = WidenType<T>;
    Vse<W, Widen(lmul)>(reinterpret_cast<W*>(vd), result, vl);
  }
#else
  const auto v1 = Vle<T, lmul>(reinterpret_cast<const T*>(vs1), vl);
  const auto result = call_vx_or_vf<T, lmul>(v1, get_xs2_as<T>(), vl);
  Vse<T, lmul>(reinterpret_cast<T*>(vd), result, vl);
#endif
#endif
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
FN_ATTR void test_i8_m8() { test_op<int8_t, Lmul::M8>(); }
FN_ATTR void test_i16_mf2() { test_op<int16_t, Lmul::MF2>(); }
FN_ATTR void test_i16_m1() { test_op<int16_t, Lmul::M1>(); }
FN_ATTR void test_i16_m2() { test_op<int16_t, Lmul::M2>(); }
FN_ATTR void test_i16_m4() { test_op<int16_t, Lmul::M4>(); }
FN_ATTR void test_i16_m8() { test_op<int16_t, Lmul::M8>(); }
FN_ATTR void test_i32_m1() { test_op<int32_t, Lmul::M1>(); }
FN_ATTR void test_i32_m2() { test_op<int32_t, Lmul::M2>(); }
FN_ATTR void test_i32_m4() { test_op<int32_t, Lmul::M4>(); }
FN_ATTR void test_i32_m8() { test_op<int32_t, Lmul::M8>(); }
#endif

#ifndef SIGNED_ONLY
FN_ATTR void test_u8_mf4() { test_op<uint8_t, Lmul::MF4>(); }
FN_ATTR void test_u8_mf2() { test_op<uint8_t, Lmul::MF2>(); }
FN_ATTR void test_u8_m1() { test_op<uint8_t, Lmul::M1>(); }
FN_ATTR void test_u8_m2() { test_op<uint8_t, Lmul::M2>(); }
FN_ATTR void test_u8_m4() { test_op<uint8_t, Lmul::M4>(); }
FN_ATTR void test_u8_m8() { test_op<uint8_t, Lmul::M8>(); }
FN_ATTR void test_u16_mf2() { test_op<uint16_t, Lmul::MF2>(); }
FN_ATTR void test_u16_m1() { test_op<uint16_t, Lmul::M1>(); }
FN_ATTR void test_u16_m2() { test_op<uint16_t, Lmul::M2>(); }
FN_ATTR void test_u16_m4() { test_op<uint16_t, Lmul::M4>(); }
FN_ATTR void test_u16_m8() { test_op<uint16_t, Lmul::M8>(); }
FN_ATTR void test_u32_m1() { test_op<uint32_t, Lmul::M1>(); }
FN_ATTR void test_u32_m2() { test_op<uint32_t, Lmul::M2>(); }
FN_ATTR void test_u32_m4() { test_op<uint32_t, Lmul::M4>(); }
FN_ATTR void test_u32_m8() { test_op<uint32_t, Lmul::M8>(); }
#endif
#endif

#ifdef TEST_FLOAT
FN_ATTR void test_f32_m1() { test_op<float, Lmul::M1>(); }
FN_ATTR void test_f32_m2() { test_op<float, Lmul::M2>(); }
FN_ATTR void test_f32_m4() { test_op<float, Lmul::M4>(); }
FN_ATTR void test_f32_m8() { test_op<float, Lmul::M8>(); }
#endif
}

#ifdef TEST_FLOAT
void (*impl)() __attribute__((section(".data"))) = &test_f32_m1;
#else
#ifdef UNSIGNED_ONLY
void (*impl)() __attribute__((section(".data"))) = &test_u8_m1;
#else
void (*impl)() __attribute__((section(".data"))) = &test_i8_m1;
#endif
#endif


int main() {
  impl();
  return 0;
}