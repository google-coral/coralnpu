#!/bin/bash
# Copyright 2023 Google LLC
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
#
# This script will be run by bazel when the build process wants to generate
# information about the status of the workspace.
#
# The output will be key-value pairs in the form:
# KEY1 VALUE1
#
# If this script exits with a non-zero exit code, it's considered as a failure
# and the output will be discarded.

if git_rev=$(git rev-parse HEAD 2>/dev/null); then
  echo "CORALNPU_BUILD_GIT_VERSION ${git_rev}"
fi
