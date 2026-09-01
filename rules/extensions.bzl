load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")
load("//rules:host_cpus.bzl", "host_cpus")
load("//rules:repos.bzl", "cvfpu_repos", "rvvi_repos")

def _coralnpu_deps_ext_impl(ctx):
    # Call non-conflicting legacy repo definitions
    host_cpus(name = "coralnpu_host_cpus")
    cvfpu_repos()
    rvvi_repos()

    # uvm
    http_archive(
        name = "uvm",
        urls = ["https://github.com/chipsalliance/uvm-verilator/archive/5a37baacfed0722b523b05decc9b94fe3e9efbe4.tar.gz"],
        sha256 = "2c5b24ac5d6527824ca62f30c0c6695e4779481ad835d84a9ad1da85300a1b27",
        strip_prefix = "uvm-verilator-5a37baacfed0722b523b05decc9b94fe3e9efbe4",
        build_file_content = """
filegroup(
    name = "uvm_src",
    srcs = glob(["**"]),
    visibility = ["//visibility:public"],
)
""",
    )

    # freertos
    http_archive(
        name = "freertos",
        urls = ["https://github.com/FreeRTOS/FreeRTOS-Kernel/archive/refs/tags/V11.1.0.tar.gz"],
        sha256 = "0e21928b3bcc4f9bcaf7333fb1c8c0299d97e2ec9e13e3faa2c5a7ac8a3bc573",
        strip_prefix = "FreeRTOS-Kernel-11.1.0",
        build_file = "@coralnpu_hw//third_party/freertos:freertos.BUILD",
    )

    # llvm_firtool
    http_archive(
        name = "llvm_firtool",
        urls = ["https://repo1.maven.org/maven2/org/chipsalliance/llvm-firtool/1.114.0/llvm-firtool-1.114.0.jar"],
        build_file = "@coralnpu_hw//third_party/llvm-firtool:BUILD.bazel",
        sha256 = "f93a831e6b5696df2e3327626df3cc183e223bf0c9c0fddf9ae9e51f502d0492",
    )

    # libsystemctlm_soc
    http_archive(
        name = "libsystemctlm_soc",
        urls = [
            "https://github.com/Xilinx/libsystemctlm-soc/archive/79d624f3c7300a2ead97ca35e683c38f0b6f5021.zip",
        ],
        strip_prefix = "libsystemctlm-soc-79d624f3c7300a2ead97ca35e683c38f0b6f5021",
        sha256 = "5c9d08bd33eb6738e3b4a0dda81e24a6d30067e8149bada6ae05aedcab5b786c",
        build_file = "@coralnpu_hw//third_party/libsystemctlm-soc:BUILD.bazel",
    )

    # chipsalliance_rocket_chip
    http_archive(
        name = "chipsalliance_rocket_chip",
        build_file = "@coralnpu_hw//third_party/rocket_chip:BUILD.bazel",
        urls = ["https://github.com/chipsalliance/rocket-chip/archive/f517abbf41abb65cea37421d3559f9739efd00a9.zip"],
        sha256 = "e77bb13328e919ca43ba83a1c110b5314900841125b9ff22813a4b9fe73672a2",
        strip_prefix = "rocket-chip-f517abbf41abb65cea37421d3559f9739efd00a9",
    )

    # chipsalliance_diplomacy
    http_archive(
        name = "chipsalliance_diplomacy",
        urls = ["https://github.com/chipsalliance/diplomacy/archive/6590276fa4dac315ae7c7c01371b954c5687a473.zip"],
        sha256 = "3f536b2eba360eb71a542d2a201eabe3a45cfa86302f14d1d565def0ed43ee20",
        strip_prefix = "diplomacy-6590276fa4dac315ae7c7c01371b954c5687a473",
        build_file_content = """
exports_files(["diplomacy/src/diplomacy/nodes/HeterogeneousBag.scala"])
        """,
    )

    # srecord
    http_archive(
        name = "srecord",
        urls = ["https://sourceforge.net/projects/srecord/files/srecord/1.65/srecord-1.65.0-Source.tar.gz/download"],
        type = "tar.gz",
        sha256 = "81c3d07cf15ce50441f43a82cefd0ac32767c535b5291bcc41bd2311d1337644",
        strip_prefix = "srecord-1.65.0-Source",
        build_file = "@coralnpu_hw//third_party/srecord:srecord.BUILD",
        patches = [
            "@coralnpu_hw//third_party/srecord:0001-Disable-docs-and-tests.patch",
        ],
        patch_args = ["-p1"],
    )

    # riscv-tests
    http_archive(
        name = "riscv-tests",
        urls = ["https://github.com/riscv-software-src/riscv-tests/archive/fd4e6cdd033d9075632be9dd207c848181ca474c.zip"],
        sha256 = "e7d84eaa149b57c0e5ff69a76c80f35f4ee64c5dc985dbba5c287adf8b56ec5d",
        strip_prefix = "riscv-tests-fd4e6cdd033d9075632be9dd207c848181ca474c",
        patches = [
            "@coralnpu_hw//third_party/riscv-tests:0001-Find-env-from-environment.patch",
        ],
        patch_args = ["-p1"],
        build_file_content = """
package(default_visibility = ["//visibility:public"])
exports_files(glob(["**"]))
filegroup(
    name = "all_srcs",
    srcs = glob([
        "**/*",
    ]),
)
        """,
    )

    # accellera_systemc
    http_archive(
        name = "accellera_systemc",
        build_file = "@coralnpu_hw//third_party/systemc:systemc.BUILD",
        sha256 = "bfb309485a8ad35a08ee78827d1647a451ec5455767b25136e74522a6f41e0ea",
        strip_prefix = "systemc-2.3.4",
        urls = [
            "https://github.com/accellera-official/systemc/archive/refs/tags/2.3.4.tar.gz",
        ],
    )

    # riscv_isa_sim
    http_archive(
        name = "riscv_isa_sim",
        build_file = "@coralnpu_hw//third_party:spike.BUILD",
        sha256 = "850f3c736f98536e306b7cf070b07996fb557014e2150353ec0118efac14674d",
        strip_prefix = "riscv-isa-sim-fd72ee2d3e0d1703451c446d467387ff0576e492",
        patches = [
            "@coralnpu_hw//third_party/spike:0001-Add-mpause.patch",
            "@coralnpu_hw//third_party/spike:0002-Coral-Deviations.patch",
            "@coralnpu_hw//third_party/spike:0003-Dump-GPRs-on-EBREAK.patch",
            "@coralnpu_hw//third_party/spike:0004-Add-custom-CoralNPU-CSRs-and-update-MVENDORID-MARCHI.patch",
            "@coralnpu_hw//third_party/spike:0005-Force-logging-in-vcompress.patch",
            "@coralnpu_hw//third_party/spike:0006-Hardwire-misa-as-read-only-WARL.patch",
        ],
        patch_args = ["-p1"],
        urls = [
            "https://github.com/riscv-software-src/riscv-isa-sim/archive/fd72ee2d3e0d1703451c446d467387ff0576e492.tar.gz",
        ],
    )

coralnpu_deps_ext = module_extension(implementation = _coralnpu_deps_ext_impl)
