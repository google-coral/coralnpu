load("@local_config_cc//:cc_toolchain_config.bzl", "cc_toolchain_config")
load("@rules_cc//cc:defs.bzl", "cc_toolchain")

package(default_visibility = ["//visibility:public"])

constraint_setting(name = "compiler_type")

constraint_value(
    name = "clang_compiler",
    constraint_setting = ":compiler_type",
)

filegroup(
    name = "wrapper_files",
    srcs = glob(["wrappers/**"]),
)

filegroup(
    name = "empty",
    srcs = [],
)

filegroup(
    name = "compiler_files",
    srcs = [
        ":wrapper_files",
        "@local_config_cc//:compiler_deps",
    ],
)

cc_toolchain_config(
    name = "host_clang_config",
    abi_libc_version = "local",
    abi_version = "local",
    compile_flags = [
        "-fstack-protector",
        "-Wall",
        "-Wunused-but-set-parameter",
        "-Wno-free-nonheap-object",
        "-fno-omit-frame-pointer",
        # Clang specific flags
        "-Wno-deprecated-non-prototype",
    ],
    compiler = "clang",
    cpu = "k8",
    # These are used as trusted prefix paths by Bazel's sandbox validator:
    # Bazel accepts any #include that resolves under one of these dirs.
    # The compiler itself finds headers via its own discovery — we just
    # need to cover the roots that host GCC / Clang actually use.
    cxx_builtin_include_directories = [
        "/usr/include",
        "/usr/local/include",
        "/usr/lib",
        "/usr/lib64",
        "/usr/local/lib",
        "/usr/local/lib64",
        "/opt",
        "/opt/rh",
    ],
    cxx_flags = ["-std=c++17"],
    dbg_compile_flags = ["-g"],
    host_system_name = "local",
    link_flags = [
        "-fuse-ld=lld",
        "-Wl,-no-as-needed",
        "-Wl,-z,relro,-z,now",
        "-lm",
        "-lstdc++",
    ],
    opt_compile_flags = [
        "-g0",
        "-O2",
        "-D_FORTIFY_SOURCE=1",
        "-DNDEBUG",
        "-ffunction-sections",
        "-fdata-sections",
    ],
    target_libc = "local",
    target_system_name = "local",
    tool_paths = {
        "ar": "wrappers/ar",
        "ld": "wrappers/ld",
        "cpp": "wrappers/clang++",
        "gcc": "wrappers/clang",
        "dwp": "wrappers/dwp",
        "gcov": "wrappers/gcov",
        "nm": "wrappers/nm",
        "objcopy": "wrappers/objcopy",
        "objdump": "wrappers/objdump",
        "strip": "wrappers/strip",
        "c++filt": "/bin/false",  # Optional
    },
    toolchain_identifier = "host_clang",
)

cc_toolchain(
    name = "host_clang_cc_compiler",
    all_files = ":compiler_files",
    ar_files = ":compiler_files",
    as_files = ":compiler_files",
    compiler_files = ":compiler_files",
    dwp_files = ":empty",
    linker_files = ":compiler_files",
    objcopy_files = ":empty",
    strip_files = ":empty",
    supports_header_parsing = 1,
    supports_param_files = 1,
    toolchain_config = ":host_clang_config",
    toolchain_identifier = "host_clang",
)

toolchain(
    name = "host_clang_toolchain_def",
    exec_compatible_with = [
        "@platforms//cpu:x86_64",
        "@platforms//os:linux",
    ],
    target_compatible_with = [
        "@platforms//cpu:x86_64",
        "@platforms//os:linux",
        ":clang_compiler",
    ],
    toolchain = ":host_clang_cc_compiler",
    toolchain_type = "@bazel_tools//tools/cpp:toolchain_type",
)

platform(
    name = "host_clang_platform",
    constraint_values = [
        "@platforms//cpu:x86_64",
        "@platforms//os:linux",
        ":clang_compiler",
    ],
)
