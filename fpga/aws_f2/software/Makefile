CC ?= gcc
CFLAGS ?= -O2 -g
CFLAGS += -std=gnu11 -Wall -Wextra -Werror -I$(SDK_DIR)/userspace/include
LDLIBS += -lfpga_mgmt

.PHONY: all clean check-env
all: check-env coralnpu_runner

check-env:
	@test -n "$(SDK_DIR)" || (echo 'SDK_DIR is unset; source aws-fpga/sdk_setup.sh' >&2; exit 2)

coralnpu_runner: coralnpu_runner.c
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $< $(LDLIBS)

clean:
	rm -f coralnpu_runner
