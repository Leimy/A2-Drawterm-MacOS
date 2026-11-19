A2_TOOLCHAIN ?= $(A2_ROOT)/build/native-toolchain
library := $(A2_TOOLCHAIN)
loader := $(A2_TOOLCHAIN)/OberonLoader
export OBERON_CORE := $(A2_TOOLCHAIN)/DarwinAosCompilerAa
platform := DarwinA2
arch := AARCH64
ext := GofAa
sym := SymAa
ifeq ($(A2_PROFILE),activities)
compat_module := DarwinActivities
unix_source := Darwin.Unix.Mod
compat_source := DarwinActivities.Mod
fiber_source := $(repo)/UnixAos/boot/DarwinActivities.c
fiber_flags := -DA2_EMBEDDED_ACTIVITIES -Wno-deprecated-declarations -Wl,-exported_symbol,_activity_*
endif

$(PROGRAM): module
	@cd "$(out)" && rm -f "Program.core" && \
	    "$(loader)" link --splitCodeData --fileFormat=UnixRaw --fileName="Program.core" \
	        --extension=.$(ext) $(runtime) $(app_modules) && test -s "Program.core"
	@$(CC) -arch arm64 -O2 -DA2_EMBEDDED_CORE $(fiber_flags) "$(A2_ROOT)/UnixAos/boot/OberonLoader.c" $(fiber_source) \
	    "-Wl,-sectcreate,__TEXT,__a2core,$(out)/Program.core" -o "$@"
