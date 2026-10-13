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

import argparse
import re


def find_cocotb_tests(filename):
    with open(filename, "r") as f:
        source = f.read()
    return re.findall(
        r"@(?:cocotb\.test|coralflow_test)(?:\([^)]*\))?\s+async def\s+(\w+)",
        source,
    )


def update_build_file(build_file, test_file, variable_name, name):
    test_names = find_cocotb_tests(test_file)
    with open(build_file, "r") as f:
        lines = f.readlines()

    start_marker = f"# BEGIN_TESTCASES_FOR_{name}\n"
    end_marker = f"# END_TESTCASES_FOR_{name}\n"

    try:
        start_index = lines.index(start_marker)
        end_index = lines.index(end_marker)
    except ValueError:
        print(f"Error: Markers not found for {name} in {build_file}")
        return

    new_lines = lines[:start_index + 1]
    new_lines.append(f'{variable_name} = [\n')
    for name in test_names:
        new_lines.append(f'    "{name}",\n')
    new_lines.append(']\n')
    new_lines.extend(lines[end_index:])

    with open(build_file, "w") as f:
        f.writelines(new_lines)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--build_file", required=True)
    parser.add_argument("--test_file", required=True)
    parser.add_argument("--variable_name", required=True)
    parser.add_argument("--name", required=True)
    args = parser.parse_args()
    update_build_file(
        args.build_file, args.test_file, args.variable_name, args.name
    )
