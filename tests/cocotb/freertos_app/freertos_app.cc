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

#include <cstdint>

#include "FreeRTOS.h"
#include "task.h"

#define UART1_BASE   0x40010000u
#define UART1_PUT(c) (*(volatile uint32_t *)UART1_BASE = (c))

extern "C" {
void freertos_risc_v_trap_handler(void);

void vApplicationMallocFailedHook(void) {
  UART1_PUT('M');
  UART1_PUT('E');
  UART1_PUT('R');
  UART1_PUT('R');
  UART1_PUT('\n');
  while (1)
    ;
}

void vApplicationIdleHook(void) {}

void vApplicationStackOverflowHook(TaskHandle_t pxTask, char *pcTaskName) {
  UART1_PUT('S');
  UART1_PUT('O');
  UART1_PUT('V');
  UART1_PUT('F');
  UART1_PUT('\n');
  while (1)
    ;
}

// Required when configSUPPORT_STATIC_ALLOCATION is 0 (default) but some ports
// or configurations might still require them if enabled.
// For now, let's keep it simple.
}

void print_char(char c) { UART1_PUT(c); }

void Task1(void *pvParameters) {
  for (;;) {
    print_char('1');
    vTaskDelay(1);  // 1 tick = 1000 cycles
  }
}

void Task2(void *pvParameters) {
  for (;;) {
    print_char('2');
    vTaskDelay(2);  // 2 ticks = 2000 cycles
  }
}

int main() {
  // Setup trap handler for FreeRTOS
  asm volatile("csrw mtvec, %0" ::"r"(&freertos_risc_v_trap_handler));

  // Create tasks
  xTaskCreate(Task1, "Task1", configMINIMAL_STACK_SIZE, NULL, 1, NULL);
  xTaskCreate(Task2, "Task2", configMINIMAL_STACK_SIZE, NULL, 1, NULL);

  UART1_PUT('S');
  UART1_PUT('\n');

  // Start FreeRTOS scheduler
  vTaskStartScheduler();

  // Should never reach here
  for (;;) {
    UART1_PUT('F');
    UART1_PUT('\n');
  }

  return 0;
}
