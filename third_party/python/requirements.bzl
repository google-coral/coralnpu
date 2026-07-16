# Copyright 2025 Google LLC
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

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")

def _clean_name(name):
    return name.replace("-", "_").replace(".", "_").lower()

def requirement(name):
    return "@coralnpu_pip_deps_" + _clean_name(name) + "//:pkg"

def _build_file_content(pypi_name, pypi_version, deps = []):
    return """
package(default_visibility = ["//visibility:public"])
py_library(
    name = "pkg",
    srcs = glob(["**/*.py"]),
    data = [] + glob(["**/*"], exclude=["**/* *", "**/*.dist-info/RECORD", "**/*.py", "**/*.pyc"]),
    imports = ["."],
    deps = {deps},
    tags = ["pypi_name={pypi_name}","pypi_version={pypi_version}"],
)
filegroup(
    name = "verilator_srcs",
    srcs = glob(["cocotb/share/lib/verilator/*.cpp"]),
)
filegroup(
    name = "cocotb_libs",
    srcs = glob(["cocotb/libs/*.so"]),
)

""".format(pypi_name = pypi_name, pypi_version = pypi_version, deps = deps)

def install_deps():
    http_archive(
        name = "coralnpu_pip_deps_tqdm",
        urls = [
            "https://files.pythonhosted.org/packages/d0/30/dc54f88dd4a2b5dc8a0279bdd7270e735851848b762aeb1c1184ed1f6b14/tqdm-4.67.1-py3-none-any.whl",
        ],
        sha256 = "26445eca388f82e72884e0d580d5464cd801a3ea01e63e5601bdff9ba6a48de2",
        type = "zip",
        build_file_content = _build_file_content(pypi_name = "tqdm", pypi_version = "4.67.1"),
    )

    http_archive(
        name = "coralnpu_pip_deps_cocotb",
        urls = [
            "https://files.pythonhosted.org/packages/bd/f7/a999492f0dc19af81b1214d8b4fd98159990062315771262d1dca39837ca/cocotb-2.0.0-cp311-cp311-manylinux_2_17_x86_64.manylinux2014_x86_64.whl",
        ],
        sha256 = "3b8f38037988e1b52e5f44547be748ccce2d8e955d349fb510434a27ad6230b2",
        type = "zip",
        build_file_content = _build_file_content(
            pypi_name = "cocotb",
            pypi_version = "20.0.0.dev0",
            deps = [
                "@coralnpu_pip_deps_find_libpython//:pkg",
                "@coralnpu_pip_deps_pytest//:pkg",
            ],
        ),
    )

    http_archive(
        name = "coralnpu_pip_deps_find_libpython",
        urls = [
            "https://files.pythonhosted.org/packages/1d/89/6b4624122d5c61a86e8aebcebd377866338b705ce4f115c45b046dc09b99/find_libpython-0.4.0-py3-none-any.whl",
        ],
        sha256 = "034a4253bd57da3408aefc59aeac1650150f6c1f42e10fdd31615cf1df0842e3",
        type = "zip",
        build_file_content = _build_file_content(pypi_name = "find_libpython", pypi_version = "0.4.0"),
    )

    http_archive(
        name = "coralnpu_pip_deps_numpy",
        urls = [
            "https://files.pythonhosted.org/packages/bb/32/67e3b0f07b0aba57a078c4ab777a9e8e6bc62f24fb53a2337f75f9691699/numpy-2.3.4-cp311-cp311-manylinux_2_27_x86_64.manylinux_2_28_x86_64.whl",
        ],
        sha256 = "a7b2f9a18b5ff9824a6af80de4f37f4ec3c2aab05ef08f51c77a093f5b89adda",
        type = "zip",
        build_file_content = _build_file_content(pypi_name = "numpy", pypi_version = "2.0.0"),
    )

    http_archive(
        name = "coralnpu_pip_deps_ml_dtypes",
        urls = [
            "https://files.pythonhosted.org/packages/a9/80/19189ea605017473660e43762dc853d2797984b3c7bf30ce656099add30c/ml_dtypes-0.5.4-cp311-cp311-manylinux_2_27_x86_64.manylinux_2_28_x86_64.whl",
        ],
        sha256 = "19b9a53598f21e453ea2fbda8aa783c20faff8e1eeb0d7ab899309a0053f1483",
        type = "zip",
        build_file_content = _build_file_content(pypi_name = "ml_dtypes", pypi_version = "0.5.4", deps = ["@coralnpu_pip_deps_numpy//:pkg"]),
    )

    http_archive(
        name = "coralnpu_pip_deps_pyelftools",
        urls = [
            "https://files.pythonhosted.org/packages/04/7c/867630e6e6293793f838b31034aa1875e1c3bd8c1ec34a0929a2506f350c/pyelftools-0.29-py2.py3-none-any.whl",
        ],
        sha256 = "519f38cf412f073b2d7393aa4682b0190fa901f7c3fa0bff2b82d537690c7fc1",
        type = "zip",
        build_file_content = _build_file_content(pypi_name = "pyelftools", pypi_version = "0.29"),
    )

    http_archive(
        name = "coralnpu_pip_deps_pytest",
        urls = [
            "https://files.pythonhosted.org/packages/30/3d/64ad57c803f1fa1e963a7946b6e0fea4a70df53c1a7fed304586539c2bac/pytest-8.3.5-py3-none-any.whl",
        ],
        sha256 = "c69214aa47deac29fad6c2a4f590b9c4a9fdb16a403176fe154b79c0b4d4d820",
        type = "zip",
        build_file_content = _build_file_content(
            pypi_name = "pytest",
            pypi_version = "8.3.5",
            deps = [
                "@coralnpu_pip_deps_pluggy//:pkg",
                "@coralnpu_pip_deps_iniconfig//:pkg",
                "@coralnpu_pip_deps_packaging//:pkg",
                "@coralnpu_pip_deps_exceptiongroup//:pkg",
            ],
        ),
    )

    http_archive(
        name = "coralnpu_pip_deps_pluggy",
        urls = [
            "https://files.pythonhosted.org/packages/54/20/4d324d65cc6d9205fabedc306948156824eb9f0ee1633355a8f7ec5c66bf/pluggy-1.6.0-py3-none-any.whl",
        ],
        sha256 = "e920276dd6813095e9377c0bc5566d94c932c33b27a3e3945d8389c374dd4746",
        type = "zip",
        build_file_content = _build_file_content(pypi_name = "pluggy", pypi_version = "1.6.0"),
    )

    http_archive(
        name = "coralnpu_pip_deps_iniconfig",
        urls = [
            "https://files.pythonhosted.org/packages/2c/e1/e6716421ea10d38022b952c159d5161ca1193197fb744506875fbb87ea7b/iniconfig-2.1.0-py3-none-any.whl",
        ],
        sha256 = "9deba5723312380e77435581c6bf4935c94cbfab9b1ed33ef8d238ea168eb760",
        type = "zip",
        build_file_content = _build_file_content(pypi_name = "iniconfig", pypi_version = "2.1.0"),
    )

    http_archive(
        name = "coralnpu_pip_deps_packaging",
        urls = [
            "https://files.pythonhosted.org/packages/20/12/38679034af332785aac8774540895e234f4d07f7545804097de4b666afd8/packaging-25.0-py3-none-any.whl",
        ],
        sha256 = "29572ef2b1f17581046b3a2227d5c611fb25ec70ca1ba8554b24b0e69331a484",
        type = "zip",
        build_file_content = _build_file_content(pypi_name = "packaging", pypi_version = "25.0"),
    )

    http_archive(
        name = "coralnpu_pip_deps_exceptiongroup",
        urls = [
            "https://files.pythonhosted.org/packages/36/f4/c6e662dade71f56cd2f3735141b265c3c79293c109549c1e6933b0651ffc/exceptiongroup-1.3.0-py3-none-any.whl",
        ],
        sha256 = "4d111e6e0c13d0644cad6ddaa7ed0261a0b36971f6d23e7ec9b4b9097da78a10",
        type = "zip",
        build_file_content = _build_file_content(
            pypi_name = "exceptiongroup",
            pypi_version = "1.3.0",
            deps = [
                "@coralnpu_pip_deps_typing_extensions//:pkg",
            ],
        ),
    )

    http_archive(
        name = "coralnpu_pip_deps_typing_extensions",
        urls = [
            "https://files.pythonhosted.org/packages/8b/54/b1ae86c0973cc6f0210b53d508ca3641fb6d0c56823f288d108bc7ab3cc8/typing_extensions-4.13.2-py3-none-any.whl",
        ],
        sha256 = "a439e7c04b49fec3e5d3e2beaa21755cadbbdc391694e28ccdd36ca4a1408f8c",
        type = "zip",
        build_file_content = _build_file_content(pypi_name = "typing_extensions", pypi_version = "4.13.2"),
    )

    http_archive(
        name = "coralnpu_pip_deps_sortedcontainers",
        urls = [
            "https://files.pythonhosted.org/packages/32/46/9cb0e58b2deb7f82b84065f37f3bffeb12413f947f9388e4cac22c4621ce/sortedcontainers-2.4.0-py2.py3-none-any.whl",
        ],
        sha256 = "a163dcaede0f1c021485e957a39245190e74249897e2ae4b2aa38595db237ee0",
        type = "zip",
        build_file_content = _build_file_content(pypi_name = "sortedcontainers", pypi_version = "2.4.0"),
    )

    http_archive(
        name = "coralnpu_pip_deps_intervaltree",
        strip_prefix = "intervaltree-3.1.0",
        urls = [
            "https://files.pythonhosted.org/packages/50/fb/396d568039d21344639db96d940d40eb62befe704ef849b27949ded5c3bb/intervaltree-3.1.0.tar.gz",
        ],
        sha256 = "902b1b88936918f9b2a19e0e5eb7ccb430ae45cde4f39ea4b36932920d33952d",
        build_file_content = _build_file_content(
            pypi_name = "intervaltree",
            pypi_version = "3.1.0",
            deps = [
                "@coralnpu_pip_deps_sortedcontainers//:pkg",
            ],
        ),
    )

    http_archive(
        name = "coralnpu_pip_deps_pyyaml",
        urls = [
            "https://files.pythonhosted.org/packages/71/60/917329f640924b18ff085ab889a11c763e0b573da888e8404ff486657602/pyyaml-6.0.3-cp311-cp311-manylinux2014_x86_64.manylinux_2_17_x86_64.manylinux_2_28_x86_64.whl",
        ],
        sha256 = "b8bb0864c5a28024fac8a632c443c87c5aa6f215c0b126c449ae1a150412f31d",
        type = "zip",
        build_file_content = _build_file_content(pypi_name = "PyYAML", pypi_version = "6.0.2"),
    )

    http_archive(
        name = "coralnpu_pip_deps_importlib_metadata",
        urls = [
            "https://files.pythonhosted.org/packages/20/b0/36bd937216ec521246249be3bf9855081de4c5e06a0c9b4219dbeda50373/importlib_metadata-8.7.0-py3-none-any.whl",
        ],
        sha256 = "e5dd1551894c77868a30651cef00984d50e1002d06942a7101d34870c5f02afd",
        type = "zip",
        build_file_content = _build_file_content(pypi_name = "importlib_metadata", pypi_version = "8.7.0"),
    )

    http_archive(
        name = "coralnpu_pip_deps_importlib_resources",
        urls = [
            "https://files.pythonhosted.org/packages/a4/ed/1f1afb2e9e7f38a545d628f864d562a5ae64fe6f7a10e28ffb9b185b4e89/importlib_resources-6.5.2-py3-none-any.whl",
        ],
        sha256 = "789cfdc3ed28c78b67a06acb8126751ced69a3d5f79c095a98298cd8a760ccec",
        type = "zip",
        build_file_content = _build_file_content(pypi_name = "importlib_resources", pypi_version = "6.5.2"),
    )

    http_archive(
        name = "coralnpu_pip_deps_six",
        urls = [
            "https://files.pythonhosted.org/packages/b7/ce/149a00dd41f10bc29e5921b496af8b574d8413afcd5e30dfa0ed46c2cc5e/six-1.17.0-py2.py3-none-any.whl",
        ],
        sha256 = "4721f391ed90541fddacab5acf947aa0d3dc7d27b2e1e8eda2be8970586c3274",
        type = "zip",
        build_file_content = _build_file_content(pypi_name = "six", pypi_version = "1.17.0"),
    )

    http_archive(
        name = "coralnpu_pip_deps_colorama",
        urls = [
            "https://files.pythonhosted.org/packages/d1/d6/3965ed04c63042e047cb6a3e6ed1a63a35087b6a609aa3a15ed8ac56c221/colorama-0.4.6-py2.py3-none-any.whl",
        ],
        sha256 = "4f1d9991f5acc0ca119f9d443620b77f9d6b33703e51011c16baf57afb285fc6",
        type = "zip",
        build_file_content = _build_file_content(pypi_name = "colorama", pypi_version = "0.4.6"),
    )

    http_archive(
        name = "coralnpu_pip_deps_prettytable",
        urls = [
            "https://files.pythonhosted.org/packages/02/c7/5613524e606ea1688b3bdbf48aa64bafb6d0a4ac3750274c43b6158a390f/prettytable-3.16.0-py3-none-any.whl",
        ],
        sha256 = "b5eccfabb82222f5aa46b798ff02a8452cf530a352c31bddfa29be41242863aa",
        type = "zip",
        build_file_content = _build_file_content(pypi_name = "prettytable", pypi_version = "3.16.0"),
    )

    http_archive(
        name = "coralnpu_pip_deps_pyusb",
        urls = [
            "https://files.pythonhosted.org/packages/28/b8/27e6312e86408a44fe16bd28ee12dd98608b39f7e7e57884a24e8f29b573/pyusb-1.3.1-py3-none-any.whl",
        ],
        sha256 = "bf9b754557af4717fe80c2b07cc2b923a9151f5c08d17bdb5345dac09d6a0430",
        type = "zip",
        build_file_content = _build_file_content(pypi_name = "pyusb", pypi_version = "1.3.1"),
    )

    http_archive(
        name = "coralnpu_pip_deps_intelhex",
        urls = [
            "https://files.pythonhosted.org/packages/97/78/79461288da2b13ed0a13deb65c4ad1428acb674b95278fa9abf1cefe62a2/intelhex-2.3.0-py2.py3-none-any.whl",
        ],
        sha256 = "87cc5225657524ec6361354be928adfd56bcf2a3dcc646c40f8f094c39c07db4",
        type = "zip",
        build_file_content = _build_file_content(pypi_name = "intelhex", pypi_version = "2.3.0"),
    )

    http_archive(
        name = "coralnpu_pip_deps_lark",
        urls = [
            "https://files.pythonhosted.org/packages/2d/00/d90b10b962b4277f5e64a78b6609968859ff86889f5b898c1a778c06ec00/lark-1.2.2-py3-none-any.whl",
        ],
        sha256 = "c2276486b02f0f1b90be155f2c8ba4a8e194d42775786db622faccd652d8e80c",
        type = "zip",
        build_file_content = _build_file_content(pypi_name = "lark", pypi_version = "1.2.2"),
    )

    http_archive(
        name = "coralnpu_pip_deps_libusb_package",
        urls = [
            "https://files.pythonhosted.org/packages/c9/0f/fd203fb1fa5eda1d446f345d84205f23533767e6ef837a7c77a2599d5783/libusb_package-1.0.26.3-cp311-cp311-manylinux_2_17_x86_64.manylinux2014_x86_64.whl",
        ],
        sha256 = "80a2041331c087d5887969405837f86c8422120fe9ba3e6faa44bf4810f07b71",
        type = "zip",
        build_file_content = _build_file_content(pypi_name = "libusb_package", pypi_version = "1.0.26.3"),
    )

    http_archive(
        name = "coralnpu_pip_deps_psutil",
        urls = [
            "https://files.pythonhosted.org/packages/bf/b9/b0eb3f3cbcb734d930fdf839431606844a825b23eaf9a6ab371edac8162c/psutil-7.0.0-cp36-abi3-manylinux_2_12_x86_64.manylinux2010_x86_64.manylinux_2_17_x86_64.manylinux2014_x86_64.whl",
        ],
        sha256 = "4b1388a4f6875d7e2aff5c4ca1cc16c545ed41dd8bb596cefea80111db353a34",
        type = "zip",
        build_file_content = _build_file_content(pypi_name = "psutil", pypi_version = "7.0.0"),
    )

    http_archive(
        name = "coralnpu_pip_deps_natsort",
        urls = [
            "https://files.pythonhosted.org/packages/ef/82/7a9d0550484a62c6da82858ee9419f3dd1ccc9aa1c26a1e43da3ecd20b0d/natsort-8.4.0-py3-none-any.whl",
        ],
        sha256 = "4732914fb471f56b5cce04d7bae6f164a592c7712e1c85f9ef585e197299521c",
        type = "zip",
        build_file_content = _build_file_content(pypi_name = "natsort", pypi_version = "8.4.0"),
    )

    http_archive(
        name = "coralnpu_pip_deps_pylink_square",
        urls = [
            "https://files.pythonhosted.org/packages/04/3c/0e587060301ff24c67cd06d7bc3479b85dbb46d9e334aa020bef340753da/pylink_square-1.6.0-py2.py3-none-any.whl",
        ],
        sha256 = "4ec26cc02ac22cbe9acbc317ea221d1e586d1db40cbdc257e2b3ac30adaeaded",
        type = "zip",
        build_file_content = _build_file_content(
            pypi_name = "pylink_square",
            pypi_version = "1.6.0",
            deps = [
                "@coralnpu_pip_deps_psutil//:pkg",
            ],
        ),
    )

    http_archive(
        name = "coralnpu_pip_deps_pyocd",
        urls = [
            "https://files.pythonhosted.org/packages/94/9b/9ee42675ecc933f1ac6a2b518bdc8d3b77eb8eef49e5e342c88562ab8533/pyocd-0.36.0-py3-none-any.whl",
        ],
        sha256 = "422ec017f1c0be2fe8f7d43e7e73dfe8fdb413d53685a24d68d09c7d95ac11b3",
        type = "zip",
        build_file_content = _build_file_content(
            pypi_name = "pyocd",
            pypi_version = "0.36.0",
            deps = [
                "@coralnpu_pip_deps_colorama//:pkg",
                "@coralnpu_pip_deps_intervaltree//:pkg",
                "@coralnpu_pip_deps_importlib_metadata//:pkg",
                "@coralnpu_pip_deps_importlib_resources//:pkg",
                "@coralnpu_pip_deps_intelhex//:pkg",
                "@coralnpu_pip_deps_lark//:pkg",
                "@coralnpu_pip_deps_libusb_package//:pkg",
                "@coralnpu_pip_deps_natsort//:pkg",
                "@coralnpu_pip_deps_prettytable//:pkg",
                "@coralnpu_pip_deps_six//:pkg",
                "@coralnpu_pip_deps_typing_extensions//:pkg",
                "@coralnpu_pip_deps_pylink_square//:pkg",
                "@coralnpu_pip_deps_pyusb//:pkg",
                "@coralnpu_pip_deps_pyyaml//:pkg",
            ],
        ),
    )

    # FPGA
    http_archive(
        name = "coralnpu_pip_deps_mako",
        urls = [
            "https://files.pythonhosted.org/packages/87/fb/99f81ac72ae23375f22b7afdb7642aba97c00a713c217124420147681a2f/mako-1.3.10-py3-none-any.whl",
        ],
        sha256 = "baef24a52fc4fc514a0887ac600f9f1cff3d82c61d4d700a1fa84d597b88db59",
        type = "zip",
        build_file_content = _build_file_content(pypi_name = "mako", pypi_version = "1.3.10"),
    )

    http_archive(
        name = "coralnpu_pip_deps_hjson",
        urls = [
            "https://files.pythonhosted.org/packages/1f/7f/13cd798d180af4bf4c0ceddeefba2b864a63c71645abc0308b768d67bb81/hjson-3.1.0-py3-none-any.whl",
        ],
        sha256 = "65713cdcf13214fb554eb8b4ef803419733f4f5e551047c9b711098ab7186b89",
        type = "zip",
        build_file_content = _build_file_content(pypi_name = "hjson", pypi_version = "3.1.0"),
    )

    http_archive(
        name = "coralnpu_pip_deps_fusesoc",
        urls = [
            "https://files.pythonhosted.org/packages/cb/a8/10f62458dda2ca07c49477448e643b10f30825b7741fdb6ec3e6188b6999/fusesoc-2.4.3-py3-none-any.whl",
        ],
        sha256 = "9ab4a82a5b7d4decbeb8f76049673a1b0806732ab8f807fee285bbc0452b3dc3",
        type = "zip",
        build_file_content = _build_file_content(
            pypi_name = "fusesoc",
            pypi_version = "2.4.3",
            deps = [
                "@coralnpu_pip_deps_hjson//:pkg",
            ],
        ),
    )

    http_archive(
        name = "coralnpu_pip_deps_pyserial",
        urls = [
            "https://files.pythonhosted.org/packages/07/bc/587a445451b253b285629263eb51c2d8e9bcea4fc97826266d186f96f558/pyserial-3.5-py2.py3-none-any.whl",
        ],
        sha256 = "c4451db6ba391ca6ca299fb3ec7bae67a5c55dde170964c7a14ceefec02f2cf0",
        type = "zip",
        build_file_content = _build_file_content(pypi_name = "pyserial", pypi_version = "3.5"),
    )

    http_archive(
        name = "coralnpu_pip_deps_pyftdi",
        urls = [
            "https://files.pythonhosted.org/packages/16/cd/0731490946e037e954ef83719f07c7672cf32bc90dd9c75201c40b827664/pyftdi-0.57.1-py3-none-any.whl",
        ],
        sha256 = "efd3f5a7d43202dc883ff261a7b1cb4dcbbe65b19628f8603a8b1183a7bc2841",
        type = "zip",
        build_file_content = _build_file_content(
            pypi_name = "pyftdi",
            pypi_version = "0.55.0",
            deps = [
                "@coralnpu_pip_deps_pyserial//:pkg",
                "@coralnpu_pip_deps_pyusb//:pkg",
            ],
        ),
    )

    http_archive(
        name = "coralnpu_pip_deps_pillow",
        urls = [
            "https://files.pythonhosted.org/packages/5c/1f/8e66ab9be3aaf1435bc03edd1ebdf58ffcd17f7349c1d970cafe87af27d9/pillow-12.1.0-cp311-cp311-manylinux_2_27_x86_64.manylinux_2_28_x86_64.whl",
        ],
        sha256 = "1f345e7bc9d7f368887c712aa5054558bad44d2a301ddf9248599f4161abc7c0",
        type = "zip",
        build_file_content = _build_file_content(pypi_name = "Pillow", pypi_version = "12.1.0"),
    )
