# Copyright 2020 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Fake configuration step for hacky substitutions in ".in" files."""

def pseudo_configure(name, out, src = None, defs = [], mappings = {}, additional = None):
    """Creates a genrule that performs a fake 'configure' step on a file.

    Args:
      name: Name to use for the created genrule.
      src: ".in" file to transform.
      out: Path to place the output file contents.
      defs: List of definitions to #define as `1`.
      mappings: Mapping of definitions with non-trivial values.
      additional: Optional mapping of definitions to prepend to the file.
    """
    additional = additional or {}

    cmd = ""

    if src == None:
        cmd += "echo '#pragma once' >> $@ &&"

    for k, v in additional.items():
        cmd += "echo '#define %s %s' >> $@ &&" % (k, v)

    if src != None:
        cmd += "cat $<"
    else:
        cmd += "echo"
    all_defs = ""
    for def_ in defs:
        cmd += r"| perl -p -e 's/#\s*undef \b(" + def_ + r")\b/#define $$1 1/'"
        all_defs += "#define " + def_ + " 1\\n"
    for key, value in mappings.items():
        cmd += r"| perl -p -e 's/#\s*undef \b" + key + r"\b/#define " + str(key) + " " + str(value) + "/'"
        cmd += r"| perl -p -e 's/#\s*define \b(" + key + r")\b 0/#define $$1 " + str(value) + "/'"
        all_defs += "#define " + key + " " + value + "\\n"
    cmd += r"| perl -p -e 's/\@DEFS\@/" + all_defs + "/'"
    cmd += " >> $@"
    native.genrule(
        name = name,
        srcs = [src] if src != None else [],
        outs = [out],
        cmd = cmd,
        message = "Configuring " + (src if src else out),
    )
