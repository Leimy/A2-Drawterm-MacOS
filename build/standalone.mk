# Application inputs: PROGRAM, MODULES in initialization order, optional A2_PROFILE.
A2_ROOT ?= $(HOME)/srcs/oberon
A2_PROFILE ?= terminal
rules := $(abspath $(lastword $(MAKEFILE_LIST)))
repo := $(abspath $(dir $(rules))/..)
host := $(shell uname -s)
platform_rules := $(dir $(rules))standalone/$(host).mk
out := build/$(host)/$(A2_PROFILE)
runtime := Trace Glue Unix Machine Heaps Modules Objects Kernel RealConversions \
           KernelLog Streams Commands Pipes TrapWriters Reflection StdIO

.DEFAULT_GOAL := all
ifeq ($(wildcard $(platform_rules)),)
$(error No standalone A2 backend for $(host))
endif
include $(platform_rules)

ifeq ($(A2_PROFILE),activities)
runtime += Traps ActivityPlatform ActivityScheduler $(compat_module) ActivityTrees
runtime_sources := $(unix_source) Unix.Objects.Mod Unix.Kernel.Mod RealConversions.Mod \
    KernelLog.Mod Streams.Mod Commands.Mod Pipes.Mod TrapWriters.Mod Reflection.Mod Unix.StdIO.Mod \
    Unix.Traps.Mod $(host).ActivityPlatform.Mod Unix.ActivityScheduler.Mod $(compat_source) ActivityTrees.Mod
runtime_object := $(out)/ActivityTrees.$(ext)
else ifneq ($(A2_PROFILE),terminal)
$(error Unknown A2_PROFILE "$(A2_PROFILE)". Choose terminal or activities)
endif

app_modules := $(MODULES) $(epilogue)
app_sources := $(addsuffix .Mod,$(MODULES)) $(epilogue_source)
app_objects := $(addsuffix .$(ext),$(app_modules))
export AOSPATH := $(abspath $(out)):$(CURDIR):$(repo)/source:$(library)
export AOSCONFIG := Color 0 StackSize 8192

.PHONY: all module run clean
.DELETE_ON_ERROR:
all: $(PROGRAM)

# Fox may return success after a diagnostic. Require fresh objects before linking.
module: $(addsuffix .Mod,$(MODULES)) $(runtime_object)
	@mkdir -p "$(out)"
	@cd "$(out)" && rm -f $(app_objects) && \
	    "$(loader)" compile -p=$(platform) $(app_sources) && \
	    for obj in $(app_objects); do test -s "$$obj" || exit 1; done

ifneq ($(runtime_object),)
$(runtime_object): $(addprefix $(repo)/source/,$(runtime_sources)) $(rules) $(platform_rules) Makefile
	@mkdir -p "$(out)"
	@cd "$(out)" && rm -f ActivityTrees.$(ext) && \
	    "$(loader)" compile -p=$(platform) --traceModule=Trace --define=UNIX,$(arch),DESKTOP,LIGHTWEIGHT $(runtime_sources) && test -s ActivityTrees.$(ext)
endif

run: $(PROGRAM)
	@./$(PROGRAM) $(RUN_ARGS)

clean:
	@rm -f "$(PROGRAM)" $(sidecar) "$(out)/Program.elf" "$(out)/Program.core" "$(out)/Program.log" \
	    $(addprefix $(out)/,$(addsuffix .$(ext),$(app_modules) $(runtime))) \
	    $(addprefix $(out)/,$(addsuffix .$(sym),$(app_modules) $(runtime)))
