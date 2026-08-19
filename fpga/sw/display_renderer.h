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

#ifndef FPGA_SW_DISPLAY_RENDERER_H_
#define FPGA_SW_DISPLAY_RENDERER_H_

#include <cstddef>
#include <cstdint>

#include "fpga/sw/dma.h"
#include "third_party/waveshare_display/LCD_Driver.h"

namespace coralnpu {

struct DisplayCmd {
  uint8_t cmd_2a = 0x2a;
  uint8_t x_data[4];
  uint8_t cmd_2b = 0x2b;
  uint8_t y_data[4];
  uint8_t cmd_2c = 0x2c;
};

class DisplayRenderer {
 public:
  DisplayRenderer() = default;

  // Initializes the display and DMA chain.
  // Returns true on success, false on failure.
  bool Init();

  // Synchronous render using a single full-frame DMA.
  // buffer must be 32-byte aligned and 320x240 RGB565.
  void Render(const uint16_t* frame_buffer);

  // Waits for the current DMA operation to complete.
  void WaitDma();

  static constexpr int kLcdWidth = 320;
  static constexpr int kLcdHeight = 240;

 private:
  void SetupFrameDma(const uint16_t* frame_buffer);

  [[maybe_unused]] PAINT paint_;
  uint32_t dc_0_val_ = 2;  // RST=1, DC=0
  uint32_t dc_1_val_ = 3;  // RST=1, DC=1
};

}  // namespace coralnpu

#endif  // FPGA_SW_DISPLAY_RENDERER_H_
