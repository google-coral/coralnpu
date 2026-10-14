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

// Native FST waveform query tool built against Verilator's vendored fstcpp
// headers, zlib, and lz4. Queries signal hierarchies and value changes directly
// from .fst files without converting to VCD.

#include "utils/fst_query/fst_query.h"

#include <lz4.h>
#include <zlib.h>

#include <algorithm>
#include <cctype>
#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <limits>
#include <map>
#include <memory>
#include <ostream>
#include <set>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "absl/flags/usage.h"
#include "absl/status/status.h"
#include "absl/status/statusor.h"
#include "fstcpp/fstcpp.h"
#include "fstcpp/fstcpp_file.h"
#include "fstcpp/fstcpp_stream_write_helper.h"
#include "re2/re2.h"

namespace fst_query {
namespace {

constexpr uint64_t kMaxDecompressedBlockBytes = 512ULL << 20;  // 512 MiB sanity cap

struct BufferReader {
  const uint8_t *data;
  size_t size;
  size_t pos = 0;

  bool eof() const { return pos >= size; }
  size_t remaining() const { return pos < size ? size - pos : 0; }

  uint8_t readU8() {
    if (pos >= size)
      return 0;
    return data[pos++];
  }

  template <typename T>
  T readUIntBE() {
    T val = 0;
    if (pos + sizeof(T) > size) {
      pos = size;
      return val;
    }
    std::memcpy(&val, data + pos, sizeof(T));
    pos += sizeof(T);
    return fst::platform::to_big_endian(val);
  }

  std::string readString0() {
    std::string s;
    while (pos < size) {
      char c = static_cast<char>(data[pos++]);
      if (c == '\0')
        break;
      s.push_back(c);
    }
    return s;
  }

  uint64_t readLEB128() {
    uint64_t result = 0;
    unsigned shift  = 0;
    while (pos < size) {
      uint8_t byte = data[pos++];
      if (shift < 64) {
        result |= static_cast<uint64_t>(byte & 0x7f) << shift;
      }
      if ((byte & 0x80) == 0)
        break;
      shift += 7;
    }
    return result;
  }

  int64_t readLEB128Signed() {
    uint64_t result = 0;
    unsigned shift  = 0;
    uint8_t byte    = 0;
    while (pos < size) {
      byte = data[pos++];
      if (shift < 64) {
        result |= static_cast<uint64_t>(byte & 0x7f) << shift;
      }
      shift += 7;
      if ((byte & 0x80) == 0)
        break;
    }
    if ((shift < 64) && (byte & 0x40)) {
      result |= (~uint64_t{0}) << shift;
    }
    return static_cast<int64_t>(result);
  }
};

struct Event {
  uint64_t time;
  fst::Handle handle;
  std::string value;
};

struct TailEntry {
  uint64_t time;
  const SignalInfo *sig;
  std::string value;
};

struct BlockRef {
  fst::BlockType type;
  size_t payload_offset;
  size_t payload_size;
  uint64_t start_time = 0;
  uint64_t end_time   = 0;
};

std::string_view TimescaleUnit(int base_exp) {
  switch (base_exp) {
    case -15:
      return "fs";
    case -12:
      return "ps";
    case -9:
      return "ns";
    case -6:
      return "us";
    case -3:
      return "ms";
    case 0:
      return "s";
    default:
      return "";
  }
}

std::string FormatTimescale(int8_t exp) {
  int base_exp   = (exp >= 0) ? (exp / 3) * 3 : ((exp - 2) / 3) * 3;
  int multiplier = 1;
  int diff       = exp - base_exp;
  if (diff == 1)
    multiplier = 10;
  else if (diff == 2)
    multiplier = 100;

  std::string_view unit = TimescaleUnit(base_exp);
  if (unit.empty()) {
    return "1e" + std::to_string(exp) + " s";
  }
  return std::to_string(multiplier) + " " + std::string(unit) + " (1e" + std::to_string(exp) +
         " s)";
}

void FormatAndPrint(std::ostream &out, uint64_t time, bool is_sample, const std::string &name,
                    const std::string &val_str) {
  bool all_bin = !val_str.empty();
  for (char c : val_str) {
    if (c != '0' && c != '1') {
      all_bin = false;
      break;
    }
  }
  const char *tag = is_sample ? " (sample) " : " ";
  if (all_bin && val_str.size() > 1 && val_str.size() <= 64) {
    uint64_t v = std::strtoull(val_str.c_str(), nullptr, 2);
    out << "@" << time << tag << name << " = 0x" << std::hex << v << std::dec << "\n";
  } else {
    out << "@" << time << tag << name << " = " << val_str << "\n";
  }
}

bool DecompressZlib(const uint8_t *src, size_t src_len, std::vector<uint8_t> &dst,
                    size_t uncomp_len) {
  if (uncomp_len == 0) {
    dst.clear();
    return src_len == 0;
  }
  dst.resize(uncomp_len);
  if (src_len == uncomp_len) {
    std::memcpy(dst.data(), src, uncomp_len);
    return true;
  }
  uLongf dest_len = uncomp_len;
  int rc          = uncompress(dst.data(), &dest_len, src, src_len);
  if (rc == Z_OK) {
    dst.resize(dest_len);
    return true;
  }
  z_stream strm{};
  strm.next_in   = const_cast<Bytef *>(src);
  strm.avail_in  = src_len;
  strm.next_out  = dst.data();
  strm.avail_out = uncomp_len;
  if (inflateInit2(&strm, 15 + 32) != Z_OK)
    return false;
  rc = inflate(&strm, Z_FINISH);
  inflateEnd(&strm);
  return rc == Z_STREAM_END || rc == Z_OK;
}

std::vector<std::string> TokenizeQueryLine(std::string_view line) {
  std::vector<std::string> tokens;
  tokens.push_back("fst_query");
  std::string cur;
  bool in_single = false;
  bool in_double = false;
  bool has_token = false;
  for (size_t i = 0; i < line.size(); ++i) {
    char c = line[i];
    if (c == '\'' && !in_double) {
      in_single = !in_single;
      has_token = true;
    } else if (c == '"' && !in_single) {
      in_double = !in_double;
      has_token = true;
    } else if (std::isspace(static_cast<unsigned char>(c)) && !in_single && !in_double) {
      if (has_token) {
        tokens.push_back(std::move(cur));
        cur.clear();
        has_token = false;
      }
    } else {
      cur.push_back(c);
      has_token = true;
    }
  }
  if (has_token) {
    tokens.push_back(std::move(cur));
  }
  return tokens;
}

enum class ParseResult {
  kOk,
  kHelp,
  kError,
};

bool ParseBoolValue(std::string_view val, bool &out) {
  if (val == "true" || val == "1" || val == "t" || val == "yes" || val == "y") {
    out = true;
    return true;
  }
  if (val == "false" || val == "0" || val == "f" || val == "no" || val == "n") {
    out = false;
    return true;
  }
  return false;
}

bool ParseUInt64Value(std::string_view val, uint64_t &out) {
  if (val.empty())
    return false;
  std::string s(val);
  size_t first = s.find_first_not_of(" \t");
  if (first == std::string::npos || s[first] == '-')
    return false;
  char *endp           = nullptr;
  errno                = 0;
  unsigned long long v = std::strtoull(s.c_str() + first, &endp, 0);
  if (errno != 0 || endp == s.c_str() + first || *endp != '\0')
    return false;
  out = static_cast<uint64_t>(v);
  return true;
}

bool ParseNonNegIntValue(std::string_view val, int &out) {
  if (val.empty())
    return false;
  std::string s(val);
  size_t first = s.find_first_not_of(" \t");
  if (first == std::string::npos || s[first] == '-')
    return false;
  char *endp = nullptr;
  errno      = 0;
  long v     = std::strtol(s.c_str() + first, &endp, 0);
  if (errno != 0 || endp == s.c_str() + first || *endp != '\0' || v < 0 ||
      v > std::numeric_limits<int>::max()) {
    return false;
  }
  out = static_cast<int>(v);
  return true;
}

ParseResult ParseQueryArgs(int argc, const char *const *argv, QueryOptions &opts,
                           std::vector<std::string> &positional_out, std::ostream &out,
                           std::ostream &err, std::string *batch_out = nullptr) {
  opts = QueryOptions{};
  if (batch_out != nullptr) {
    batch_out->clear();
  }
  positional_out.clear();
  if (argc > 0) {
    positional_out.push_back(argv[0] ? argv[0] : "fst_query");
  }

  bool positional_only = false;
  for (int i = 1; i < argc; ++i) {
    std::string_view arg(argv[i] ? argv[i] : "");
    if (positional_only || arg.empty() || arg == "-" || arg[0] != '-') {
      positional_out.emplace_back(arg);
      continue;
    }
    if (arg == "--") {
      positional_only = true;
      continue;
    }

    std::string_view stripped = arg.substr(1);
    if (!stripped.empty() && stripped[0] == '-') {
      stripped.remove_prefix(1);
    }

    std::string_view name = stripped;
    std::string_view eq_val;
    bool has_eq   = false;
    size_t eq_pos = stripped.find('=');
    if (eq_pos != std::string_view::npos) {
      name   = stripped.substr(0, eq_pos);
      eq_val = stripped.substr(eq_pos + 1);
      has_eq = true;
    }

    if (name == "help" || name == "h") {
      out << absl::ProgramUsageMessage() << "\n";
      return ParseResult::kHelp;
    }

    auto HandleBoolFlag = [&](std::string_view flag_name, bool &target) -> bool {
      if (name == flag_name) {
        if (!has_eq) {
          target = true;
          return true;
        }
        if (!ParseBoolValue(eq_val, target)) {
          err << "Invalid boolean value '" << eq_val << "' for flag --" << flag_name << "\n";
          return false;
        }
        return true;
      }
      if (name.size() == flag_name.size() + 2 && name.substr(0, 2) == "no" &&
          name.substr(2) == flag_name && !has_eq) {
        target = false;
        return true;
      }
      return false;
    };

    if (name == "info" || name == "noinfo") {
      if (!HandleBoolFlag("info", opts.info_only))
        return ParseResult::kError;
      continue;
    }
    if (name == "list" || name == "nolist") {
      if (!HandleBoolFlag("list", opts.list_only))
        return ParseResult::kError;
      continue;
    }
    if (name == "count" || name == "nocount") {
      if (!HandleBoolFlag("count", opts.count_only))
        return ParseResult::kError;
      continue;
    }
    if (name == "scopes_only" || name == "noscopes_only") {
      if (!HandleBoolFlag("scopes_only", opts.scopes_only))
        return ParseResult::kError;
      continue;
    }
    if (name == "regex" || name == "noregex") {
      if (!HandleBoolFlag("regex", opts.use_regex))
        return ParseResult::kError;
      continue;
    }
    if (name == "exact" || name == "noexact") {
      if (!HandleBoolFlag("exact", opts.use_exact))
        return ParseResult::kError;
      continue;
    }

    auto ConsumeValue = [&](std::string_view &val_out) -> bool {
      if (has_eq) {
        val_out = eq_val;
        return true;
      }
      if (i + 1 >= argc || argv[i + 1] == nullptr) {
        err << "Flag '--" << name << "' requires a value\n";
        return false;
      }
      val_out = argv[++i];
      return true;
    };

    if (name == "start" || name == "end" || name == "limit" || name == "tail") {
      std::string_view val_str;
      if (!ConsumeValue(val_str))
        return ParseResult::kError;
      uint64_t parsed = 0;
      if (!ParseUInt64Value(val_str, parsed)) {
        err << "Invalid value '" << val_str << "' for flag --" << name << "\n";
        return ParseResult::kError;
      }
      if (name == "start")
        opts.start_time = parsed;
      else if (name == "end")
        opts.end_time = parsed;
      else if (name == "limit")
        opts.limit_count = parsed;
      else if (name == "tail")
        opts.tail_count = parsed;
      continue;
    }

    if (name == "depth") {
      std::string_view val_str;
      if (!ConsumeValue(val_str))
        return ParseResult::kError;
      int parsed = 0;
      if (!ParseNonNegIntValue(val_str, parsed)) {
        err << "Invalid value '" << val_str << "' for flag --depth\n";
        return ParseResult::kError;
      }
      opts.max_depth = parsed;
      continue;
    }

    if (name == "sample_at" || name == "scope" || name == "batch") {
      std::string_view val_str;
      if (!ConsumeValue(val_str))
        return ParseResult::kError;
      if (name == "sample_at") {
        opts.sample_at = std::string(val_str);
      } else if (name == "scope") {
        opts.scope_filter = std::string(val_str);
      } else if (name == "batch") {
        if (batch_out == nullptr) {
          err << "Flag '--batch' is not supported inside a session or batch query\n";
          return ParseResult::kError;
        }
        *batch_out = std::string(val_str);
      }
      continue;
    }

    err << "Unknown flag: '" << arg << "'\n";
    return ParseResult::kError;
  }

  return ParseResult::kOk;
}

}  // namespace

struct FstSession::Impl {
  std::ifstream ifs;
  size_t file_size = 0;
  std::vector<BlockRef> blocks;
  std::vector<uint32_t> handle_bitwidths;
  std::vector<bool> handle_is_real;
  std::vector<size_t> handle_bit_offsets;
  std::vector<uint8_t> initial_bits;
  uint64_t initial_bits_start_time = 0;
  bool has_initial_bits            = false;

  std::vector<Event> DecodeWaveBlock(
      const BlockRef &blk,
      const std::map<fst::Handle, std::vector<const SignalInfo *>> &matched_signals,
      uint64_t min_time, uint64_t max_time);
};

FstSession::~FstSession() = default;

std::vector<Event> FstSession::Impl::DecodeWaveBlock(
    const BlockRef &blk,
    const std::map<fst::Handle, std::vector<const SignalInfo *>> &matched_signals,
    uint64_t min_time, uint64_t max_time) {
  std::vector<Event> events;
  std::vector<uint8_t> raw(blk.payload_size);
  ifs.clear();
  ifs.seekg(blk.payload_offset, std::ios::beg);
  ifs.read(reinterpret_cast<char *>(raw.data()), blk.payload_size);
  if (!ifs) {
    return events;
  }

  BufferReader br{raw.data(), raw.size(), 0};
  (void)br.readUIntBE<uint64_t>();  // blk_start_time
  (void)br.readUIntBE<uint64_t>();  // blk_end_time
  (void)br.readUIntBE<uint64_t>();  // memory_req

  // Section 2: Initial Bits
  (void)br.readLEB128();  // bits_uncomp_len
  uint64_t bits_comp_len = br.readLEB128();
  (void)br.readLEB128();  // bits_count
  if (bits_comp_len > br.remaining())
    return events;
  br.pos += bits_comp_len;

  // Section 5: Time Table (at end of block)
  if (raw.size() < 24)
    return events;
  BufferReader tr_meta{raw.data(), raw.size(), raw.size() - 24};
  uint64_t time_uncomp_len = tr_meta.readUIntBE<uint64_t>();
  uint64_t time_comp_len   = tr_meta.readUIntBE<uint64_t>();
  uint64_t time_count      = tr_meta.readUIntBE<uint64_t>();

  if (time_comp_len > raw.size() - 24 || time_uncomp_len > kMaxDecompressedBlockBytes)
    return events;
  size_t time_sec_start = raw.size() - 24 - time_comp_len;
  if (time_sec_start < br.pos)
    return events;
  std::vector<uint8_t> time_data;
  if (!DecompressZlib(raw.data() + time_sec_start, time_comp_len, time_data, time_uncomp_len)) {
    return events;
  }

  std::vector<uint64_t> timestamps;
  timestamps.reserve(std::min<uint64_t>(time_count, time_data.size()));
  BufferReader tr{time_data.data(), time_data.size(), 0};
  uint64_t cur_time = 0;
  for (uint64_t i = 0; i < time_count && !tr.eof(); ++i) {
    cur_time += tr.readLEB128();
    timestamps.push_back(cur_time);
  }

  // Section 4: Position Table (immediately before Time Section)
  if (time_sec_start < 8)
    return events;
  BufferReader pr_len{raw.data(), raw.size(), time_sec_start - 8};
  uint64_t pos_len = pr_len.readUIntBE<uint64_t>();
  if (pos_len > time_sec_start - 8)
    return events;
  size_t pos_sec_start = time_sec_start - 8 - pos_len;
  if (pos_sec_start < br.pos)
    return events;

  // Section 3: Waves Header
  uint64_t waves_count    = br.readLEB128();
  uint8_t packtype        = br.readU8();
  size_t waves_data_start = br.pos;
  if ((!handle_bitwidths.empty() && waves_count > handle_bitwidths.size()) ||
      waves_count > kMaxDecompressedBlockBytes) {
    return events;
  }

  BufferReader pr{raw.data() + pos_sec_start, pos_len, 0};
  std::vector<int64_t> pos_raw(waves_count, 0);
  size_t idx       = 0;
  int64_t prev_neg = 0;
  while (idx < waves_count && !pr.eof()) {
    size_t save_pos = pr.pos;
    uint64_t uval   = pr.readLEB128();
    if ((uval & 1) == 0) {
      uint64_t run = uval >> 1;
      for (uint64_t k = 0; k < run && idx < waves_count; ++k) {
        pos_raw[idx++] = 0;
      }
    } else {
      pr.pos       = save_pos;
      int64_t sval = pr.readLEB128Signed();
      int64_t val  = sval >> 1;
      if (val == 0) {
        pos_raw[idx++] = prev_neg;
      } else if (val < 0) {
        pos_raw[idx++] = val;
        prev_neg       = val;
      } else {
        pos_raw[idx++] = val;
      }
    }
  }

  std::vector<std::pair<size_t, size_t>> wave_slices(waves_count, {0, 0});
  size_t cur_wave_offset  = waves_data_start;
  ssize_t prev_unique_idx = -1;
  for (size_t i = 0; i < waves_count; ++i) {
    if (pos_raw[i] > 0) {
      if (prev_unique_idx >= 0) {
        size_t len = static_cast<size_t>(pos_raw[i]);
        if (cur_wave_offset > pos_sec_start || len > pos_sec_start - cur_wave_offset) {
          return events;
        }
        wave_slices[prev_unique_idx].second = len;
        cur_wave_offset += len;
      }
      wave_slices[i].first = cur_wave_offset;
      prev_unique_idx      = static_cast<ssize_t>(i);
    }
  }
  if (prev_unique_idx >= 0 && pos_sec_start >= cur_wave_offset) {
    wave_slices[prev_unique_idx].second = pos_sec_start - cur_wave_offset;
  }
  for (size_t i = 0; i < waves_count; ++i) {
    if (pos_raw[i] < 0) {
      size_t orig_idx = static_cast<size_t>(-pos_raw[i] - 1);
      if (orig_idx < waves_count) {
        wave_slices[i] = wave_slices[orig_idx];
      }
    }
  }

  for (const auto &kv : matched_signals) {
    fst::Handle h = kv.first;
    if (kv.second.empty())
      continue;
    const SignalInfo &sig = *kv.second.front();
    if (h == 0 || h > waves_count || sig.is_real || sig.bitwidth == 0)
      continue;
    auto slice = wave_slices[h - 1];
    if (slice.second == 0 || slice.first > pos_sec_start ||
        slice.second > pos_sec_start - slice.first) {
      continue;
    }

    BufferReader wr{raw.data() + slice.first, slice.second, 0};
    uint64_t uncomp_len = wr.readLEB128();
    std::vector<uint8_t> wave_buf;
    const uint8_t *vdata = nullptr;
    size_t vsize         = 0;

    if (uncomp_len == 0) {
      vdata = raw.data() + slice.first + wr.pos;
      vsize = slice.second - wr.pos;
    } else {
      if (uncomp_len > kMaxDecompressedBlockBytes ||
          uncomp_len > static_cast<uint64_t>(std::numeric_limits<int>::max()) ||
          slice.second - wr.pos > static_cast<size_t>(std::numeric_limits<int>::max())) {
        continue;
      }
      wave_buf.resize(uncomp_len);
      if (packtype == '4') {
        int dec = LZ4_decompress_safe(
            reinterpret_cast<const char *>(raw.data() + slice.first + wr.pos),
            reinterpret_cast<char *>(wave_buf.data()), static_cast<int>(slice.second - wr.pos),
            static_cast<int>(uncomp_len));
        if (dec < 0)
          continue;
        vdata = wave_buf.data();
        vsize = static_cast<size_t>(dec);
      } else if (packtype == 'Z' || packtype == '!') {
        if (!DecompressZlib(raw.data() + slice.first + wr.pos, slice.second - wr.pos, wave_buf,
                            uncomp_len)) {
          continue;
        }
        vdata = wave_buf.data();
        vsize = wave_buf.size();
      } else {
        continue;
      }
    }

    BufferReader vr{vdata, vsize, 0};
    uint64_t time_idx = 0;
    while (!vr.eof()) {
      if (sig.bitwidth == 1) {
        uint64_t code = vr.readLEB128();
        char bit_char = '0';
        if ((code & 1) == 0) {
          time_idx += (code >> 2);
          bit_char = static_cast<char>('0' + ((code >> 1) & 1));
        } else {
          time_idx += (code >> 4);
          bit_char = fst::kEncodedBitToCharTable[2 + ((code >> 1) & 7)];
        }
        if (time_idx >= timestamps.size()) {
          break;
        }
        uint64_t t = timestamps[time_idx];
        if (t > max_time) {
          break;
        }
        if (t >= min_time) {
          events.push_back(Event{t, h, std::string(1, bit_char)});
        }
      } else {
        uint64_t code = vr.readLEB128();
        time_idx += (code >> 1);
        bool is_non_binary = (code & 1) != 0;
        std::string val_str(sig.bitwidth, '0');
        if (!is_non_binary) {
          size_t num_bytes = (sig.bitwidth + 7) / 8;
          if (vr.remaining() < num_bytes)
            break;
          const uint8_t *bptr = vr.data + vr.pos;
          vr.pos += num_bytes;
          for (uint32_t b = 0; b < sig.bitwidth; ++b) {
            uint8_t bit = (bptr[b / 8] >> (7 - (b % 8))) & 1;
            val_str[b]  = static_cast<char>('0' + bit);
          }
        } else {
          if (vr.remaining() < sig.bitwidth)
            break;
          std::memcpy(&val_str[0], vr.data + vr.pos, sig.bitwidth);
          vr.pos += sig.bitwidth;
        }
        if (time_idx >= timestamps.size()) {
          break;
        }
        uint64_t t = timestamps[time_idx];
        if (t > max_time) {
          break;
        }
        if (t >= min_time) {
          events.push_back(Event{t, h, std::move(val_str)});
        }
      }
    }
  }

  std::stable_sort(events.begin(), events.end(), [](const Event &a, const Event &b) {
    if (a.time != b.time)
      return a.time < b.time;
    return a.handle < b.handle;
  });

  return events;
}

absl::StatusOr<std::unique_ptr<FstSession>> FstSession::Open(const std::string &fst_path) {
  auto session   = std::unique_ptr<FstSession>(new FstSession());
  session->impl_ = std::make_unique<Impl>();

  session->impl_->ifs.open(fst_path, std::ios::binary | std::ios::ate);
  if (!session->impl_->ifs.is_open()) {
    return absl::NotFoundError("Failed to open FST file: " + fst_path);
  }
  const std::streamoff end_pos = session->impl_->ifs.tellg();
  if (end_pos < 0) {
    return absl::InternalError("Failed to determine FST file size: " + fst_path);
  }
  session->impl_->file_size = static_cast<size_t>(end_pos);
  session->impl_->ifs.seekg(0, std::ios::beg);

  session->header_.file_path = fst_path;

  // 1. Scan block headers
  size_t offset = 0;
  while (offset + fst::kSharedBlockHeaderSize <= session->impl_->file_size) {
    session->impl_->ifs.clear();
    session->impl_->ifs.seekg(offset, std::ios::beg);
    uint8_t header_buf[fst::kSharedBlockHeaderSize];
    session->impl_->ifs.read(reinterpret_cast<char *>(header_buf), fst::kSharedBlockHeaderSize);
    if (!session->impl_->ifs)
      break;

    BufferReader hr{header_buf, fst::kSharedBlockHeaderSize, 0};
    auto btype    = static_cast<fst::BlockType>(hr.readU8());
    uint64_t blen = hr.readUIntBE<uint64_t>();
    if (blen < 8 || blen - 8 > session->impl_->file_size - offset - fst::kSharedBlockHeaderSize)
      break;

    BlockRef ref{btype, offset + fst::kSharedBlockHeaderSize, static_cast<size_t>(blen - 8), 0, 0};

    if (btype == fst::BlockType::WAVE_DATA_VERSION3 ||
        btype == fst::BlockType::WAVE_DATA_VERSION2 ||
        btype == fst::BlockType::WAVE_DATA_VERSION1) {
      if (ref.payload_size >= 16) {
        session->impl_->ifs.seekg(ref.payload_offset, std::ios::beg);
        uint8_t time_buf[16];
        session->impl_->ifs.read(reinterpret_cast<char *>(time_buf), 16);
        BufferReader tr{time_buf, 16, 0};
        ref.start_time = tr.readUIntBE<uint64_t>();
        ref.end_time   = tr.readUIntBE<uint64_t>();
      }
    }

    session->impl_->blocks.push_back(ref);
    offset += 1 + blen;
  }

  // 2. Parse BlockType::HEADER
  for (const auto &blk : session->impl_->blocks) {
    if (blk.type == fst::BlockType::HEADER) {
      std::vector<uint8_t> hraw(blk.payload_size);
      session->impl_->ifs.clear();
      session->impl_->ifs.seekg(blk.payload_offset, std::ios::beg);
      session->impl_->ifs.read(reinterpret_cast<char *>(hraw.data()), blk.payload_size);

      BufferReader br{hraw.data(), hraw.size(), 0};
      session->header_.start_time = br.readUIntBE<uint64_t>();
      session->header_.end_time   = br.readUIntBE<uint64_t>();
      (void)br.readUIntBE<uint64_t>();  // double magic
      (void)br.readUIntBE<uint64_t>();  // memory use
      session->header_.num_scopes  = br.readUIntBE<uint64_t>();
      session->header_.num_vars    = br.readUIntBE<uint64_t>();
      session->header_.num_handles = br.readUIntBE<uint64_t>();
      (void)br.readUIntBE<uint64_t>();  // blocks
      session->header_.timescale = static_cast<int8_t>(br.readU8());

      for (int k = 0; k < 128 && !br.eof(); ++k) {
        char c = static_cast<char>(br.readU8());
        if (c != '\0')
          session->header_.writer.push_back(c);
        else
          break;
      }
      br.pos = 65 + 128;
      for (int k = 0; k < 26 && !br.eof(); ++k) {
        char c = static_cast<char>(br.readU8());
        if (c != '\0')
          session->header_.date.push_back(c);
        else
          break;
      }
      while (!session->header_.date.empty() &&
             (session->header_.date.back() == '\n' || session->header_.date.back() == '\r' ||
              session->header_.date.back() == ' ')) {
        session->header_.date.pop_back();
      }
      br.pos                    = 313;
      session->header_.timezero = br.readUIntBE<int64_t>();
      break;
    }
  }

  // 3. Parse Hierarchy
  std::set<std::string> seen_scopes;
  for (const auto &blk : session->impl_->blocks) {
    if (blk.type != fst::BlockType::HIERARCHY_LZ4_COMPRESSED &&
        blk.type != fst::BlockType::HIERARCHY_GZ_COMPRESSED) {
      continue;
    }
    if (blk.payload_size < 8) {
      return absl::InternalError("Truncated hierarchy block");
    }
    std::vector<uint8_t> raw(blk.payload_size);
    session->impl_->ifs.clear();
    session->impl_->ifs.seekg(blk.payload_offset, std::ios::beg);
    session->impl_->ifs.read(reinterpret_cast<char *>(raw.data()), blk.payload_size);

    BufferReader br{raw.data(), raw.size(), 0};
    uint64_t uncomp_len = br.readUIntBE<uint64_t>();
    if (uncomp_len > kMaxDecompressedBlockBytes ||
        uncomp_len > static_cast<uint64_t>(std::numeric_limits<int>::max()) ||
        raw.size() - br.pos > static_cast<size_t>(std::numeric_limits<int>::max())) {
      return absl::InternalError("Invalid hierarchy block size");
    }
    std::vector<uint8_t> hier_buf(uncomp_len);
    if (blk.type == fst::BlockType::HIERARCHY_LZ4_COMPRESSED) {
      int dec =
          LZ4_decompress_safe(reinterpret_cast<const char *>(raw.data() + br.pos),
                              reinterpret_cast<char *>(hier_buf.data()),
                              static_cast<int>(raw.size() - br.pos), static_cast<int>(uncomp_len));
      if (dec < 0) {
        return absl::InternalError("Failed to decompress LZ4 hierarchy block");
      }
      hier_buf.resize(static_cast<size_t>(dec));
    } else {
      if (!DecompressZlib(raw.data() + br.pos, raw.size() - br.pos, hier_buf, uncomp_len)) {
        return absl::InternalError("Failed to decompress GZ hierarchy block");
      }
    }

    BufferReader hr{hier_buf.data(), hier_buf.size(), 0};
    std::vector<std::string> scope_stack;
    fst::Handle next_handle = 1;

    while (!hr.eof()) {
      uint8_t tag = hr.readU8();
      if (tag == static_cast<uint8_t>(fst::Hierarchy::ScopeControlType::VCD_SCOPE)) {
        (void)hr.readU8();
        std::string scopename = hr.readString0();
        (void)hr.readString0();
        scope_stack.push_back(scopename);

        std::string full_scope;
        for (size_t s = 0; s < scope_stack.size(); ++s) {
          if (s > 0)
            full_scope.push_back('.');
          full_scope += scope_stack[s];
        }
        if (seen_scopes.insert(full_scope).second) {
          session->all_scopes_.push_back(full_scope);
        }
      } else if (tag == static_cast<uint8_t>(fst::Hierarchy::ScopeControlType::VCD_UPSCOPE)) {
        if (!scope_stack.empty())
          scope_stack.pop_back();
      } else if (tag == static_cast<uint8_t>(fst::Hierarchy::ScopeControlType::GEN_ATTR_BEGIN)) {
        (void)hr.readU8();
        (void)hr.readU8();
        (void)hr.readString0();
        (void)hr.readLEB128();
      } else if (tag == static_cast<uint8_t>(fst::Hierarchy::ScopeControlType::GEN_ATTR_END)) {
      } else {
        auto vartype = static_cast<fst::Hierarchy::VarType>(tag);
        (void)hr.readU8();
        std::string var_name = hr.readString0();
        uint32_t bitwidth    = static_cast<uint32_t>(hr.readLEB128());
        uint32_t alias       = static_cast<uint32_t>(hr.readLEB128());

        bool is_real = (vartype == fst::Hierarchy::VarType::VCD_REAL ||
                        vartype == fst::Hierarchy::VarType::VCD_REAL_PARAMETER ||
                        vartype == fst::Hierarchy::VarType::VCD_REALTIME ||
                        vartype == fst::Hierarchy::VarType::SV_SHORTREAL);

        fst::Handle handle = alias;
        if (alias == 0) {
          handle = next_handle++;
          session->impl_->handle_bitwidths.push_back(bitwidth);
          session->impl_->handle_is_real.push_back(is_real);
        }

        auto space_pos = var_name.find(' ');
        if (space_pos != std::string::npos) {
          var_name = var_name.substr(0, space_pos);
        }
        std::string full_name;
        for (const auto &s : scope_stack) {
          full_name += s;
          full_name.push_back('.');
        }
        full_name += var_name;

        session->all_signals_.push_back(SignalInfo{handle, full_name, bitwidth, is_real});
      }
    }
  }

  // Precompute initial bit offsets for each handle
  const size_t num_handles = session->impl_->handle_bitwidths.size();
  session->impl_->handle_bit_offsets.resize(num_handles, 0);
  size_t accum_offset = 0;
  for (size_t i = 0; i < num_handles; ++i) {
    session->impl_->handle_bit_offsets[i] = accum_offset;
    accum_offset += session->impl_->handle_is_real[i] ? 8 : session->impl_->handle_bitwidths[i];
  }

  // 4. Cache Initial Bits from Wave Block 0
  for (const auto &blk : session->impl_->blocks) {
    if (blk.type == fst::BlockType::WAVE_DATA_VERSION3 ||
        blk.type == fst::BlockType::WAVE_DATA_VERSION2 ||
        blk.type == fst::BlockType::WAVE_DATA_VERSION1) {
      std::vector<uint8_t> raw(blk.payload_size);
      session->impl_->ifs.clear();
      session->impl_->ifs.seekg(blk.payload_offset, std::ios::beg);
      session->impl_->ifs.read(reinterpret_cast<char *>(raw.data()), blk.payload_size);

      BufferReader br{raw.data(), raw.size(), 0};
      session->impl_->initial_bits_start_time = br.readUIntBE<uint64_t>();
      (void)br.readUIntBE<uint64_t>();  // end_time
      (void)br.readUIntBE<uint64_t>();  // mem_req

      uint64_t bits_uncomp_len = br.readLEB128();
      uint64_t bits_comp_len   = br.readLEB128();
      (void)br.readLEB128();  // bits_count

      if (bits_uncomp_len <= kMaxDecompressedBlockBytes && bits_comp_len <= br.remaining() &&
          DecompressZlib(raw.data() + br.pos, bits_comp_len, session->impl_->initial_bits,
                         bits_uncomp_len)) {
        session->impl_->has_initial_bits = true;
      }
      break;
    }
  }

  return session;
}

int FstSession::RunQuery(int argc, const char *const *argv, std::ostream &out, std::ostream &err) {
  QueryOptions opts;
  std::vector<std::string> positional;
  ParseResult pres = ParseQueryArgs(argc, argv, opts, positional, out, err);
  if (pres == ParseResult::kHelp) {
    return 0;
  }
  if (pres == ParseResult::kError) {
    return 1;
  }
  for (size_t i = 1; i < positional.size(); ++i) {
    opts.patterns.push_back(std::move(positional[i]));
  }
  return RunQuery(opts, out, err);
}

int FstSession::RunQuery(const QueryOptions &opts, std::ostream &out, std::ostream &err) {
  const bool info_only          = opts.info_only;
  const bool list_only          = opts.list_only;
  const uint64_t start_time     = opts.start_time;
  const uint64_t end_time       = opts.end_time;
  const uint64_t limit_count    = opts.limit_count;
  const uint64_t tail_count     = opts.tail_count;
  const bool count_only         = opts.count_only;
  const std::string &sample_arg = opts.sample_at;
  std::string scope_filter      = opts.scope_filter;
  while (!scope_filter.empty() && scope_filter.back() == '.') {
    scope_filter.pop_back();
  }
  const int max_depth                      = opts.max_depth;
  const bool scopes_only                   = opts.scopes_only;
  const bool use_regex                     = opts.use_regex;
  const bool use_exact                     = opts.use_exact;
  const std::vector<std::string> &patterns = opts.patterns;

  if (start_time > end_time) {
    err << "Invalid time range: --start (" << start_time << ") is greater than --end (" << end_time
        << ")\n";
    return 1;
  }

  // Handle --info mode
  if (info_only) {
    out << "File:         " << header_.file_path << "\n";
    if (!header_.writer.empty())
      out << "Writer:       " << header_.writer << "\n";
    if (!header_.date.empty())
      out << "Date:         " << header_.date << "\n";
    out << "Timescale:    " << FormatTimescale(header_.timescale) << "\n";
    if (header_.start_time == uint64_t(-1)) {
      out << "Time Range:   0 to 0\n";
    } else {
      out << "Time Range:   " << header_.start_time << " to " << header_.end_time;
      int base_exp          = (header_.timescale >= 0) ? (header_.timescale / 3) * 3
                                                       : ((header_.timescale - 2) / 3) * 3;
      int diff              = header_.timescale - base_exp;
      uint64_t mult         = (diff == 1) ? 10 : ((diff == 2) ? 100 : 1);
      std::string_view unit = TimescaleUnit(base_exp);
      if (!unit.empty()) {
        if (mult == 1) {
          out << " " << unit;
        } else {
          out << " ticks (" << (header_.start_time * mult) << " to " << (header_.end_time * mult)
              << " " << unit << ")";
        }
      }
      out << "\n";
    }
    if (header_.timezero != 0) {
      out << "Timezero:     " << header_.timezero << "\n";
    }
    out << "Scopes:       " << header_.num_scopes << "\n";
    out << "Signals:      " << header_.num_vars << " (unique handles: " << header_.num_handles
        << ")\n";
    return 0;
  }

  std::vector<std::unique_ptr<re2::RE2>> compiled_regexes;
  if (use_regex) {
    for (const auto &p : patterns) {
      auto re = std::make_unique<re2::RE2>(p);
      if (!re->ok()) {
        err << "Invalid regular expression '" << p << "': " << re->error() << "\n";
        return 1;
      }
      compiled_regexes.push_back(std::move(re));
    }
  }

  auto MatchesPattern = [&](const std::string &name) -> bool {
    if (patterns.empty()) {
      return true;
    }
    if (use_regex) {
      for (const auto &re : compiled_regexes) {
        if (use_exact ? re2::RE2::FullMatch(name, *re) : re2::RE2::PartialMatch(name, *re)) {
          return true;
        }
      }
      return false;
    }
    if (use_exact) {
      for (const auto &p : patterns) {
        if (name == p) {
          return true;
        }
      }
      return false;
    }
    for (const auto &p : patterns) {
      if (name.find(p) != std::string::npos) {
        return true;
      }
    }
    return false;
  };

  size_t scope_filter_level = 0;
  if (!scope_filter.empty()) {
    scope_filter_level = 1;
    for (char c : scope_filter) {
      if (c == '.')
        scope_filter_level++;
    }
  }

  auto ScopeMatches = [&](const std::string &full_path, size_t level, bool is_signal) -> bool {
    if (!scope_filter.empty()) {
      if (is_signal) {
        if (full_path.rfind(scope_filter + ".", 0) != 0) {
          return false;
        }
      } else {
        if (full_path != scope_filter && full_path.rfind(scope_filter + ".", 0) != 0) {
          return false;
        }
      }
    }
    if (max_depth > 0) {
      size_t depth = 0;
      if (scope_filter.empty()) {
        depth = level;
      } else if (is_signal) {
        depth = (level >= scope_filter_level) ? (level - scope_filter_level + 1) : 0;
      } else {
        depth = (level >= scope_filter_level) ? (level - scope_filter_level) : 0;
      }
      if (depth > static_cast<size_t>(max_depth)) {
        return false;
      }
    }
    return true;
  };

  // Handle --list mode
  if (list_only) {
    if (scopes_only) {
      for (const auto &scope_name : all_scopes_) {
        size_t level = 1;
        for (char c : scope_name) {
          if (c == '.')
            level++;
        }
        if (ScopeMatches(scope_name, level, /*is_signal=*/false) && MatchesPattern(scope_name)) {
          out << scope_name << "\n";
        }
      }
    } else {
      for (const auto &sig : all_signals_) {
        size_t level = 0;
        for (char c : sig.name) {
          if (c == '.')
            level++;
        }
        if (ScopeMatches(sig.name, level, /*is_signal=*/true) && MatchesPattern(sig.name)) {
          out << sig.name << " [" << sig.bitwidth << "] (handle=" << sig.handle << ")\n";
        }
      }
    }
    return 0;
  }

  // Resolve matched signals (preserving all matched aliases per handle)
  std::map<fst::Handle, std::vector<const SignalInfo *>> matched_signals;
  for (const auto &sig : all_signals_) {
    size_t level = 0;
    for (char c : sig.name) {
      if (c == '.')
        level++;
    }
    if (ScopeMatches(sig.name, level, /*is_signal=*/true) && MatchesPattern(sig.name)) {
      matched_signals[sig.handle].push_back(&sig);
    }
  }

  if (matched_signals.empty()) {
    if (count_only) {
      out << "0 transitions\n";
    }
    return 0;
  }

  // Handle --sample_at (multi-timestamp or single timestamp)
  if (!sample_arg.empty()) {
    std::vector<uint64_t> sample_times;
    std::string token;
    for (char c : sample_arg) {
      if (c == ',' || std::isspace(static_cast<unsigned char>(c))) {
        if (!token.empty()) {
          uint64_t val = 0;
          if (!ParseUInt64Value(token, val)) {
            err << "Invalid --sample_at timestamp: '" << token << "'\n";
            return 1;
          }
          sample_times.push_back(val);
          token.clear();
        }
      } else {
        token.push_back(c);
      }
    }
    if (!token.empty()) {
      uint64_t val = 0;
      if (!ParseUInt64Value(token, val)) {
        err << "Invalid --sample_at timestamp: '" << token << "'\n";
        return 1;
      }
      sample_times.push_back(val);
    }
    std::sort(sample_times.begin(), sample_times.end());
    sample_times.erase(std::unique(sample_times.begin(), sample_times.end()), sample_times.end());

    std::map<fst::Handle, std::string> current_values;
    const size_t num_handles = impl_->handle_bitwidths.size();

    std::map<uint64_t, std::map<fst::Handle, std::string>> snapshots;
    size_t next_idx = 0;

    if (impl_->has_initial_bits) {
      while (next_idx < sample_times.size() &&
             sample_times[next_idx] < impl_->initial_bits_start_time) {
        snapshots[sample_times[next_idx]] = current_values;
        next_idx++;
      }
      for (const auto &kv : matched_signals) {
        fst::Handle h         = kv.first;
        const SignalInfo &sig = *kv.second.front();
        if (h == 0 || h > num_handles || sig.is_real)
          continue;
        size_t boff = impl_->handle_bit_offsets[h - 1];
        if (boff + sig.bitwidth <= impl_->initial_bits.size()) {
          current_values[h] = std::string(
              reinterpret_cast<const char *>(impl_->initial_bits.data() + boff), sig.bitwidth);
        }
      }
    }

    for (const auto &blk : impl_->blocks) {
      if (blk.type != fst::BlockType::WAVE_DATA_VERSION3 &&
          blk.type != fst::BlockType::WAVE_DATA_VERSION2 &&
          blk.type != fst::BlockType::WAVE_DATA_VERSION1) {
        continue;
      }
      if (!sample_times.empty() && blk.start_time > sample_times.back()) {
        break;
      }

      std::vector<Event> block_events = impl_->DecodeWaveBlock(
          blk, matched_signals, 0, sample_times.empty() ? 0 : sample_times.back());

      for (const auto &ev : block_events) {
        while (next_idx < sample_times.size() && sample_times[next_idx] < ev.time) {
          snapshots[sample_times[next_idx]] = current_values;
          next_idx++;
        }
        current_values[ev.handle] = ev.value;
      }
    }

    while (next_idx < sample_times.size()) {
      snapshots[sample_times[next_idx]] = current_values;
      next_idx++;
    }

    for (uint64_t t : sample_times) {
      const auto &snap = snapshots[t];
      for (const auto &kv : matched_signals) {
        fst::Handle h   = kv.first;
        auto it         = snap.find(h);
        std::string val = (it != snap.end()) ? it->second : "x";
        for (const SignalInfo *sig : kv.second) {
          FormatAndPrint(out, t, /*is_sample=*/true, sig->name, val);
        }
      }
    }
    return 0;
  }

  // Handle standard transition stream / count / tail
  uint64_t total_matched_events = 0;
  uint64_t emitted_events       = 0;
  bool limit_exceeded           = false;
  std::deque<TailEntry> tail_buffer;
  bool is_first_block      = true;
  const size_t num_handles = impl_->handle_bitwidths.size();

  for (const auto &blk : impl_->blocks) {
    if (blk.type != fst::BlockType::WAVE_DATA_VERSION3 &&
        blk.type != fst::BlockType::WAVE_DATA_VERSION2 &&
        blk.type != fst::BlockType::WAVE_DATA_VERSION1) {
      continue;
    }
    if (blk.end_time < start_time || blk.start_time > end_time) {
      is_first_block = false;
      continue;
    }

    std::vector<Event> decoded = impl_->DecodeWaveBlock(blk, matched_signals, start_time, end_time);

    std::vector<Event> events;
    if (is_first_block && impl_->has_initial_bits && impl_->initial_bits_start_time >= start_time &&
        impl_->initial_bits_start_time <= end_time) {
      // Verilator's FST writer leaves Section 2 (initial_bits) as 'z' when
      // emitTimeChange(0) is called before dumping initial signal values, and
      // records the actual t=0 initial values in Section 3 (waves) at
      // initial_bits_start_time. Only synthesize an initial_bits transition
      // for handles that do not already have a wave event at that timestamp.
      std::set<fst::Handle> handles_at_init_time;
      for (const auto &ev : decoded) {
        if (ev.time == impl_->initial_bits_start_time) {
          handles_at_init_time.insert(ev.handle);
        }
      }
      for (const auto &kv : matched_signals) {
        fst::Handle h = kv.first;
        if (handles_at_init_time.count(h) > 0)
          continue;
        const SignalInfo &sig = *kv.second.front();
        if (h == 0 || h > num_handles || sig.is_real)
          continue;
        size_t boff = impl_->handle_bit_offsets[h - 1];
        if (boff + sig.bitwidth <= impl_->initial_bits.size()) {
          events.push_back(
              Event{impl_->initial_bits_start_time, h,
                    std::string(reinterpret_cast<const char *>(impl_->initial_bits.data() + boff),
                                sig.bitwidth)});
        }
      }
    }
    is_first_block = false;

    events.insert(events.end(), std::make_move_iterator(decoded.begin()),
                  std::make_move_iterator(decoded.end()));

    std::stable_sort(events.begin(), events.end(), [](const Event &a, const Event &b) {
      if (a.time != b.time)
        return a.time < b.time;
      return a.handle < b.handle;
    });

    if (count_only) {
      for (const auto &ev : events) {
        total_matched_events += matched_signals[ev.handle].size();
      }
    } else if (tail_count > 0) {
      for (const auto &ev : events) {
        for (const SignalInfo *sig : matched_signals[ev.handle]) {
          tail_buffer.push_back(TailEntry{ev.time, sig, ev.value});
          if (tail_buffer.size() > tail_count) {
            tail_buffer.pop_front();
          }
        }
      }
    } else {
      for (const auto &ev : events) {
        for (const SignalInfo *sig : matched_signals[ev.handle]) {
          if (limit_count > 0 && emitted_events >= limit_count) {
            limit_exceeded = true;
            break;
          }
          FormatAndPrint(out, ev.time, /*is_sample=*/false, sig->name, ev.value);
          emitted_events++;
        }
        if (limit_exceeded) {
          break;
        }
      }
      if (limit_exceeded) {
        break;
      }
    }
  }

  if (count_only) {
    out << total_matched_events << " transitions\n";
    return 0;
  }

  if (tail_count > 0) {
    for (const auto &entry : tail_buffer) {
      FormatAndPrint(out, entry.time, /*is_sample=*/false, entry.sig->name, entry.value);
    }
    return 0;
  }

  if (limit_exceeded) {
    err << "[fst_query: Output limited to " << limit_count
        << " transitions. Use --limit 0 for unlimited, or narrow with --start/--end.]\n";
  }

  return 0;
}

int FstSession::RunQuery(std::string_view query_line, std::ostream &out, std::ostream &err) {
  std::vector<std::string> tokens = TokenizeQueryLine(query_line);
  std::vector<const char *> argv;
  argv.reserve(tokens.size());
  for (const auto &tok : tokens) {
    argv.push_back(tok.c_str());
  }
  return RunQuery(static_cast<int>(argv.size()), argv.data(), out, err);
}

int FstSession::RunBatch(std::istream &in, std::ostream &out, std::ostream &err) {
  int status = 0;
  std::string line;
  while (std::getline(in, line)) {
    size_t first = line.find_first_not_of(" \t\r\n");
    if (first == std::string::npos)
      continue;
    size_t last              = line.find_last_not_of(" \t\r\n");
    std::string_view trimmed = std::string_view(line).substr(first, last - first + 1);
    if (trimmed.empty() || trimmed[0] == '#')
      continue;
    if (trimmed == "exit" || trimmed == "quit")
      break;

    int rc = RunQuery(trimmed, out, err);
    if (rc != 0) {
      status = rc;
    }
    out << "--- [query end] ---\n";
    out.flush();
    err.flush();
  }
  return status;
}

int RunFstQuery(int argc, const char *const *argv, std::ostream &out, std::ostream &err) {
  QueryOptions opts;
  std::vector<std::string> positional;
  std::string batch_arg;
  ParseResult pres = ParseQueryArgs(argc, argv, opts, positional, out, err, &batch_arg);
  if (pres == ParseResult::kHelp) {
    return 0;
  }
  if (pres == ParseResult::kError) {
    return 1;
  }

  if (positional.size() < 2) {
    err << "Usage: " << (positional.empty() ? "fst_query" : positional[0])
        << " <fst_file> [flags...] [pattern...]\n";
    return 1;
  }

  const std::string &fst_path = positional[1];
  auto session_status         = FstSession::Open(fst_path);
  if (!session_status.ok()) {
    err << session_status.status().message() << "\n";
    return 1;
  }
  auto &session = *session_status;

  if (!batch_arg.empty()) {
    if (batch_arg == "-") {
      return session->RunBatch(std::cin, out, err);
    }
    std::ifstream bfile(batch_arg);
    if (!bfile.is_open()) {
      err << "Failed to open batch query file: " << batch_arg << "\n";
      return 1;
    }
    return session->RunBatch(bfile, out, err);
  }

  for (size_t i = 2; i < positional.size(); ++i) {
    opts.patterns.push_back(std::move(positional[i]));
  }
  return session->RunQuery(opts, out, err);
}

}  // namespace fst_query
