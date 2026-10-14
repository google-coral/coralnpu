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

#ifndef UTILS_FST_QUERY_FST_QUERY_H_
#define UTILS_FST_QUERY_FST_QUERY_H_

#include <cstdint>
#include <istream>
#include <limits>
#include <memory>
#include <ostream>
#include <string>
#include <string_view>
#include <vector>

#include "absl/status/statusor.h"

namespace fst_query {

struct SignalInfo {
  uint32_t handle;
  std::string name;
  uint32_t bitwidth;
  bool is_real;
};

struct HeaderMetadata {
  std::string file_path;
  std::string writer;
  std::string date;
  int8_t timescale     = -9;
  uint64_t start_time  = 0;
  uint64_t end_time    = 0;
  int64_t timezero     = 0;
  uint64_t num_scopes  = 0;
  uint64_t num_vars    = 0;
  uint64_t num_handles = 0;
};

struct QueryOptions {
  bool info_only       = false;
  bool list_only       = false;
  uint64_t start_time  = 0;
  uint64_t end_time    = std::numeric_limits<uint64_t>::max();
  uint64_t limit_count = 1000;
  uint64_t tail_count  = 0;
  bool count_only      = false;
  std::string sample_at;
  std::string scope_filter;
  int max_depth    = 0;
  bool scopes_only = false;
  bool use_regex   = false;
  bool use_exact   = false;
  std::vector<std::string> patterns;
};

/**
 * @brief Persistent session managing an opened and indexed FST waveform.
 *
 * Keeps file handles, container block indices, decompressed hierarchy, and
 * signal handle maps cached in memory. Allows executing multiple queries
 * without repeatedly paying file opening and decompression overhead.
 *
 * Note: FstSession is not thread-safe. Run concurrent queries using separate
 * FstSession instances or external synchronization.
 */
class FstSession {
 public:
  static absl::StatusOr<std::unique_ptr<FstSession>> Open(const std::string &fst_path);

  ~FstSession();

  const HeaderMetadata &GetHeaderMetadata() const { return header_; }
  const std::vector<SignalInfo> &GetAllSignals() const { return all_signals_; }
  const std::vector<std::string> &GetAllScopes() const { return all_scopes_; }

  /**
   * @brief Executes a single structured query against this opened session.
   */
  int RunQuery(const QueryOptions &opts, std::ostream &out, std::ostream &err);

  /**
   * @brief Executes a single query against this opened session.
   *
   * @param argc Argument count.
   * @param argv Argument vector (starting with program name at index 0, omitting <fst_file>).
   * @param out Output stream.
   * @param err Diagnostic/error stream.
   * @return 0 on success, non-zero on error.
   */
  int RunQuery(int argc, const char *const *argv, std::ostream &out, std::ostream &err);

  /**
   * @brief Executes a single query line (split into tokens) against this session.
   */
  int RunQuery(std::string_view query_line, std::ostream &out, std::ostream &err);

  /**
   * @brief Processes a batch of queries from an input stream (e.g. file or std::cin).
   * Emits delimiter "--- [query end] ---\n" after each query.
   */
  int RunBatch(std::istream &in, std::ostream &out, std::ostream &err);

 private:
  FstSession() = default;
  struct Impl;
  std::unique_ptr<Impl> impl_;
  HeaderMetadata header_;
  std::vector<SignalInfo> all_signals_;
  std::vector<std::string> all_scopes_;
};

/**
 * @brief Main CLI entry point.
 */
int RunFstQuery(int argc, const char *const *argv, std::ostream &out, std::ostream &err);

}  // namespace fst_query

#endif  // UTILS_FST_QUERY_FST_QUERY_H_
