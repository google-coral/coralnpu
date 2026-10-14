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

#include <fstream>
#include <iostream>
#include <limits>
#include <string>
#include <vector>

#include "absl/flags/flag.h"
#include "absl/flags/parse.h"
#include "absl/flags/usage.h"
#include "absl/flags/usage_config.h"
#include "absl/strings/string_view.h"
#include "utils/fst_query/fst_query.h"

ABSL_FLAG(bool, info, false, "Inspect simulation metadata and total time range");
ABSL_FLAG(bool, list, false, "List hierarchy signals");
ABSL_FLAG(uint64_t, start, 0, "Query time window start timestamp");
ABSL_FLAG(uint64_t, end, std::numeric_limits<uint64_t>::max(), "Query time window end timestamp");
ABSL_FLAG(uint64_t, limit, 1000, "Maximum number of transitions to output (0 for unlimited)");
ABSL_FLAG(uint64_t, tail, 0, "Output only the last N transitions in time window");
ABSL_FLAG(bool, count, false, "Count total matching transitions without printing details");
ABSL_FLAG(std::string, sample_at, "", "Comma-separated timestamps to sample signal values");
ABSL_FLAG(std::string, scope, "", "Filter signals to a specific scope");
ABSL_FLAG(int, depth, 0, "Limit scope depth for listing or querying");
ABSL_FLAG(bool, scopes_only, false, "List module scopes only");
ABSL_FLAG(bool, regex, false, "Treat patterns as regular expressions");
ABSL_FLAG(bool, exact, false, "Match signal names exactly");
ABSL_FLAG(std::string, batch, "", "Execute queries from batch file (or '-' for stdin)");

int main(int argc, char **argv) {
  absl::FlagsUsageConfig config;
  config.contains_help_flags = [](absl::string_view filename) {
    return filename.find("fst_query") != absl::string_view::npos;
  };
  config.contains_helpshort_flags = [](absl::string_view filename) {
    return filename.find("fst_query") != absl::string_view::npos;
  };
  absl::SetFlagsUsageConfig(config);

  absl::SetProgramUsageMessage(
      "High-performance native FST waveform query tool for RTL debugging.\n\n"
      "Usage:\n"
      "  fst_query <fst_file> [flags...] [pattern...]\n\n"
      "Common Workflows:\n"
      "  1. Inspect simulation metadata & total time range:\n"
      "     $ fst_query sim.fst --info\n\n"
      "  2. Explore signal hierarchy:\n"
      "     $ fst_query sim.fst --list                     # List all signals\n"
      "     $ fst_query sim.fst --list --scopes_only       # List module scopes only\n"
      "     $ fst_query sim.fst --list --scope TOP.core    # List signals under scope\n\n"
      "  3. Inspect transitions within a time window:\n"
      "     $ fst_query sim.fst --start 1000 --end 2000 TOP.clk TOP.core.pc\n\n"
      "  4. Inspect the last transitions before test end (e.g. failure window):\n"
      "     $ fst_query sim.fst --tail 50 TOP.core.state TOP.err_code\n\n"
      "  5. Inspect signal state at specific timestamp(s):\n"
      "     $ fst_query sim.fst --sample_at 45200 TOP.core.pc TOP.core.state\n"
      "     $ fst_query sim.fst --sample_at 1000,2000,3000 TOP.core.pc\n\n"
      "  6. Match signals using regular expressions:\n"
      "     $ fst_query sim.fst --regex 'TOP\\.core\\.(pc|instruction)'\n\n"
      "  7. Execute multiple queries reusing open session & cached hierarchy:\n"
      "     $ fst_query sim.fst --batch queries.txt\n"
      "     $ cat queries.txt | fst_query sim.fst --batch -");

  std::vector<char *> positional = absl::ParseCommandLine(argc, argv);
  if (positional.size() < 2) {
    std::cerr << "Usage: " << (positional.empty() ? "fst_query" : positional[0])
              << " <fst_file> [flags...] [pattern...]\n";
    return 1;
  }

  const std::string fst_path = positional[1];
  auto session_status        = fst_query::FstSession::Open(fst_path);
  if (!session_status.ok()) {
    std::cerr << session_status.status().message() << "\n";
    return 1;
  }
  auto &session = *session_status;

  const std::string batch_arg = absl::GetFlag(FLAGS_batch);
  if (!batch_arg.empty()) {
    if (batch_arg == "-") {
      return session->RunBatch(std::cin, std::cout, std::cerr);
    }
    std::ifstream bfile(batch_arg);
    if (!bfile.is_open()) {
      std::cerr << "Failed to open batch query file: " << batch_arg << "\n";
      return 1;
    }
    return session->RunBatch(bfile, std::cout, std::cerr);
  }

  fst_query::QueryOptions opts;
  opts.info_only    = absl::GetFlag(FLAGS_info);
  opts.list_only    = absl::GetFlag(FLAGS_list);
  opts.start_time   = absl::GetFlag(FLAGS_start);
  opts.end_time     = absl::GetFlag(FLAGS_end);
  opts.limit_count  = absl::GetFlag(FLAGS_limit);
  opts.tail_count   = absl::GetFlag(FLAGS_tail);
  opts.count_only   = absl::GetFlag(FLAGS_count);
  opts.sample_at    = absl::GetFlag(FLAGS_sample_at);
  opts.scope_filter = absl::GetFlag(FLAGS_scope);
  opts.max_depth    = absl::GetFlag(FLAGS_depth);
  opts.scopes_only  = absl::GetFlag(FLAGS_scopes_only);
  opts.use_regex    = absl::GetFlag(FLAGS_regex);
  opts.use_exact    = absl::GetFlag(FLAGS_exact);

  for (size_t i = 2; i < positional.size(); ++i) {
    opts.patterns.push_back(positional[i]);
  }

  return session->RunQuery(opts, std::cout, std::cerr);
}
