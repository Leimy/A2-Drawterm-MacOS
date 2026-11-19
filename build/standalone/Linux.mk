# The stock Linux64 release contains the compiler and ELF linker.
ifneq ($(shell uname -m),x86_64)
$(error The Linux standalone backend currently supports x86_64)
endif
A2_TOOLCHAIN ?= $(HOME)/Linux64
library := $(A2_TOOLCHAIN)/bin
loader := $(A2_TOOLCHAIN)/oberon
platform := Unix64
arch := AMD64
ext := GofUu
sym := SymUu
epilogue := TerminalExit
epilogue_source := Linux.TerminalExit.Mod

ifeq ($(A2_PROFILE),activities)
unix_source := Linux.Unix.Mod
sidecar := libA2Activities.so

$(sidecar): $(repo)/UnixAos/boot/LinuxActivities.c $(repo)/UnixAos/boot/UnixActivityFibers.inc
	@$(CC) -O2 -fPIC -shared -pthread "$<" -o "$@"
endif

$(PROGRAM): module $(sidecar)
	@cd "$(out)" && rm -f Program.elf && \
	    "$(loader)" link -p=Linux64 --fileName=Program.elf Builtins $(runtime) $(app_modules) && test -s Program.elf
	@chmod +x "$(out)/Program.elf" && mv "$(out)/Program.elf" "$@"
