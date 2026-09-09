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

"""Provides a utility macro that copies a file."""

def copy(name, src, out):
    native.genrule(
        name = name,
        srcs = [src],
        outs = [out],
        cmd = "cp $(SRCS) $@",
        message = "Copying $(SRCS)",
    )

def touch(name, out, contents = None):
    """Produces a genrule to creates a file, with optional #define contents.

    Args:
      name: Name to use for the genrule.
      out: Path for the output file.
      contents: Optional mapping that will be materialized as
        `#define $KEY $VALUE` in the output file.
    """
    lines = []
    if contents:
        for k, v in contents.items():
            lines.append("#define %s %s" % (k, v))
    contents = "\n".join(lines)
    if contents:
        contents += "\n"
    native.genrule(
        name = name,
        outs = [out],
        cmd = "cat << 'EOF' > $@\n" + contents + "EOF\n",
        message = "Touch $@",
    )
