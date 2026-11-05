#!/usr/bin/env python3
"""Packages the build outputs a Verilator regression ran on.

Collects, from Bazel's output tree after run_regression.sh:
  - uvm_model.tar.gz: the UVM testbench model (tests/uvm/uvm_sim_verilator_*),
    plus uvm_batch_list.txt, which lists every UVM program with its ELF path
    inside elfs.tar.gz;
  - cocotb_models.tar.gz: every Verilator cocotb model (<Top>_build/<Top>);
  - elfs.tar.gz: every RISC-V test program (*.elf), plus the programs the UVM
    batch lists name that have no .elf suffix;
  - rtl.tar.gz: the generated SystemVerilog the models were built from;
  - MANIFEST.sha256: the sha256 of every file inside the archives.

usage: package_artifacts.py OUT_DIR [UVM_TARGETS_FILE]
"""
import hashlib
import io
import os
import re
import subprocess
import sys
import tarfile

RTL = [
    "hdl/chisel/src/coralnpu/CoreMiniAxi.sv",
    "hdl/chisel/src/coralnpu/RvvCoreMiniAxi.sv",
    "hdl/chisel/src/coralnpu/RvvCoreMiniHighmemAxi.sv",
    "hdl/chisel/src/coralnpu/RvvCoreMini_ITCM512KB_DTCM512KBAxi.sv",
    "hdl/chisel/src/coralnpu/VmeCoreMiniAxi.sv",
    "hdl/chisel/src/coralnpu/VmeCoreMiniVerificationAxi.sv",
    "hdl/chisel/src/soc/CoralNPUChiselSubsystemTestHarness.sv",
    "hdl/chisel/src/soc/CoralNPUChiselSubsystemHighmemTestHarness.sv",
    "hdl/chisel/src/soc/CoralNPUXbarTestHarness.sv",
]


def bazel_out():
    out = subprocess.run(["bazel", "info", "output_path"],
                         capture_output=True,
                         text=True,
                         check=True).stdout.strip()
    return [
        os.path.join(out, d, "bin")
        for d in sorted(os.listdir(out))
        if os.path.isdir(os.path.join(out, d, "bin"))
    ]


def find_output(bins, rel):
    """Finds workspace-relative `rel` in any configuration's bin directory."""
    for b in bins:
        p = os.path.join(b, rel)
        if os.path.isfile(p):
            return p
    return None


def add(tar, manifest, arcname, path):
    data = open(path, "rb").read()
    info = tarfile.TarInfo(arcname)
    info.size = len(data)
    info.mode = 0o755 if os.access(path, os.X_OK) else 0o644
    info.mtime = 0
    tar.addfile(info, io.BytesIO(data))
    manifest.append(f"{hashlib.sha256(data).hexdigest()}  {arcname}")


def main():
    out_dir = sys.argv[1]
    uvm_targets = sys.argv[2] if len(sys.argv) > 2 else None
    os.makedirs(out_dir, exist_ok=True)
    bins = bazel_out()
    testlogs = os.path.realpath("bazel-testlogs")
    manifest = []

    # Programs: every .elf, plus whatever the UVM batch lists name.
    elfs = {}
    for b in bins:
        for root, dirs, files in os.walk(b):
            dirs[:] = [d for d in dirs if not d.endswith(".runfiles")]
            for f in files:
                if f.endswith(".elf"):
                    p = os.path.join(root, f)
                    elfs.setdefault(os.path.relpath(p, b), p)
    batch_lines = []
    if uvm_targets:
        for t in open(uvm_targets):
            pkg, name = t.strip()[2:].split(":")
            listing = os.path.join(
                testlogs, pkg, name, "test.outputs", "uvm_regression_batch",
                "uvm_batch_list.txt"
            )
            for line in open(listing):
                elf, rest = line.split(" ", 1)
                rel = re.sub(r"^.*?\.runfiles/", "", elf)
                rel = re.sub(r"^_main/", "", rel)
                if rel not in elfs:
                    p = find_output(bins, rel)
                    if not p:
                        sys.exit(f"cannot find {rel} for {t.strip()}")
                    elfs[rel] = p
                batch_lines.append(f"elfs/{rel} {rest}")

    with tarfile.open(os.path.join(out_dir, "elfs.tar.gz"), "w:gz") as tar:
        for rel in sorted(elfs):
            add(tar, manifest, "elfs/" + rel, elfs[rel])

    with tarfile.open(os.path.join(out_dir, "uvm_model.tar.gz"),
                      "w:gz") as tar:
        for b in bins:
            uvm = os.path.join(b, "tests", "uvm")
            if not os.path.isdir(uvm):
                continue
            for f in sorted(os.listdir(uvm)):
                p = os.path.join(uvm, f)
                if re.fullmatch(r"uvm_sim_verilator_\w+", f) and \
                        os.path.isfile(p) and os.access(p, os.X_OK):
                    add(tar, manifest, "uvm/" + f, p)
        if batch_lines:
            data = "".join(batch_lines).encode()
            info = tarfile.TarInfo("uvm/uvm_batch_list.txt")
            info.size = len(data)
            tar.addfile(info, io.BytesIO(data))
            manifest.append(
                f"{hashlib.sha256(data).hexdigest()}  uvm/uvm_batch_list.txt"
            )

    with tarfile.open(os.path.join(out_dir, "cocotb_models.tar.gz"),
                      "w:gz") as tar:
        seen = set()
        for b in bins:
            for root, dirs, files in os.walk(b):
                dirs[:] = [d for d in dirs if not d.endswith(".runfiles")]
                if not root.endswith("_build"):
                    continue
                top = os.path.basename(root)[:-len("_build")]
                p = os.path.join(root, top)
                rel = os.path.relpath(p, b)
                if top in files and rel not in seen:
                    seen.add(rel)
                    add(tar, manifest, "cocotb/" + rel, p)

    with tarfile.open(os.path.join(out_dir, "rtl.tar.gz"), "w:gz") as tar:
        for rel in RTL:
            p = find_output(bins, rel)
            if p:
                add(tar, manifest, "rtl/" + rel, p)

    with open(os.path.join(out_dir, "MANIFEST.sha256"), "w") as f:
        f.write("\n".join(sorted(manifest, key=lambda l: l.split("  ")[1])))
        f.write("\n")
    for f in sorted(os.listdir(out_dir)):
        print(f"{os.path.getsize(os.path.join(out_dir, f)):>12d}  {f}")


if __name__ == "__main__":
    main()
