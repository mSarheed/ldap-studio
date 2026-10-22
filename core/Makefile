# Builds build/libldapstudio.a — the native core the SwiftUI app links —
# and first the libraries it and the app need: OpenSSL, libxcrypt, OpenLDAP
# and libssh2, built from source into build/deps by deps/build.sh for the
# architectures in ARCHS and the macOS in MACOSX_DEPLOYMENT_TARGET.
#
# Standalone:  make            (the host arch, the app's minimum macOS)
# From Xcode:  the "Build C Core" script phase runs `make`, passing ARCHS,
#              MACOSX_DEPLOYMENT_TARGET and SDKROOT through the environment.

SRC := $(wildcard src/*.c)
HDR := $(wildcard src/*.h include/*.h)
OBJ := $(SRC:%.c=build/%.o)
LIB := build/libldapstudio.a
DEPS := build/deps

CC ?= clang

# clang-format ships with the Command Line Tools; clang-tidy comes from a
# Homebrew llvm keg. Fall back to those if they're not on PATH; override
# with `make format CLANG_FORMAT=/path/to/clang-format`.
CLANG_FORMAT ?= $(firstword $(shell command -v clang-format 2>/dev/null) \
                            $(shell xcrun -f clang-format 2>/dev/null) clang-format)
CLANG_TIDY   ?= $(firstword $(shell command -v clang-tidy 2>/dev/null) \
                            $(wildcard /opt/homebrew/opt/llvm*/bin/clang-tidy) \
                            $(wildcard /usr/local/opt/llvm*/bin/clang-tidy) clang-tidy)

ARCHS ?= $(shell uname -m)
ARCHFLAGS := $(foreach a,$(ARCHS),-arch $(a))

# The Xcode project's, unless Xcode (or a caller) says otherwise: the core
# and the libraries must run wherever the app does.
MACOSX_DEPLOYMENT_TARGET ?= $(shell ../scripts/deployment-target.sh)
ifeq ($(MACOSX_DEPLOYMENT_TARGET),)
$(error could not read MACOSX_DEPLOYMENT_TARGET from the Xcode project)
endif
MINFLAG := -mmacosx-version-min=$(MACOSX_DEPLOYMENT_TARGET)

# Xcode sets SDKROOT; standalone, resolve it so compile_commands.json is
# self-contained for tools (clang-tidy) that lack Apple clang's baked-in SDK.
SDKROOT ?= $(shell xcrun --show-sdk-path 2>/dev/null)
ifneq ($(SDKROOT),)
SYSROOT := -isysroot $(SDKROOT)
endif

CFLAGS ?= -std=c11 -O2 -Wall -Wextra -fno-common
CPPFLAGS += -Iinclude -Isrc -I$(DEPS)/include

all: $(LIB)

# The bundled libraries. Each architecture is built once (several minutes)
# and kept until deps/build.sh, a patch or the deployment target changes;
# after that this is a quick check.
deps:
	@ARCHS="$(ARCHS)" MACOSX_DEPLOYMENT_TARGET="$(MACOSX_DEPLOYMENT_TARGET)" SDKROOT="$(SDKROOT)" deps/build.sh

$(LIB): $(OBJ)
	@mkdir -p $(dir $@)
	libtool -static -o $@ $(OBJ)

# Everything an object is compiled with, recorded so that a change to it —
# another SDK or architecture, say — rebuilds the objects rather than
# linking ones built against the old headers. Compared while the Makefile
# is read, before make looks at any object, so their timestamps don't come
# into it — and only for a real build: not `make -n`/`-q`/`-t`,
# `format-check` or the like, which would otherwise delete the library an
# Xcode build just made. (A rebuilt deps/ shows as newer headers, which
# the .d files below pick up.)
BUILD_CONFIG := $(CC) $(ARCHFLAGS) $(MINFLAG) $(SYSROOT) $(CFLAGS) $(CPPFLAGS)
CONFIG_STAMP := build/config.stamp
# MAKEFLAGS starts with the single-letter flags (n dry run, q question,
# t touch — none of them builds), or with a variable assignment when there
# are none.
MAKEFLAGS_FIRST := $(firstword -$(MAKEFLAGS))
DRY_RUN := $(if $(findstring =,$(MAKEFLAGS_FIRST)),,$(strip \
             $(findstring n,$(MAKEFLAGS_FIRST))$(findstring q,$(MAKEFLAGS_FIRST))$(findstring t,$(MAKEFLAGS_FIRST))))
BUILDING := $(if $(MAKECMDGOALS),$(filter all $(LIB) $(OBJ),$(MAKECMDGOALS)),all)
ifeq ($(DRY_RUN),)
ifneq ($(BUILDING),)
ifneq ($(BUILD_CONFIG),$(shell cat $(CONFIG_STAMP) 2>/dev/null))
$(shell mkdir -p build && rm -f $(OBJ) $(LIB) && echo '$(BUILD_CONFIG)' > $(CONFIG_STAMP))
endif
endif
endif

# -MMD -MP emits a build/src/foo.d listing every header foo.c pulls in, so
# editing e.g. ldapstudio.h forces the affected .o files to rebuild. The
# libraries' headers must be there before anything is compiled.
build/%.o: %.c | deps
	@mkdir -p $(dir $@)
	$(CC) $(ARCHFLAGS) $(MINFLAG) $(SYSROOT) $(CFLAGS) $(CPPFLAGS) -MMD -MP -c $< -o $@

-include $(OBJ:.o=.d)

# The core's own objects; the libraries take minutes, so they stay.
clean:
	rm -rf build/src $(LIB) $(CONFIG_STAMP)

# Everything, libraries and their downloads included.
distclean:
	rm -rf build

# Regenerate core/compile_commands.json for editors / clangd (needs `bear`).
compdb:
	$(MAKE) clean
	bear --output compile_commands.json -- $(MAKE) all

# Reformat all C sources/headers in place, per ../.clang-format.
format:
	$(CLANG_FORMAT) -i $(SRC) $(HDR)

# Fail if anything isn't formatted (for CI / pre-commit).
format-check:
	$(CLANG_FORMAT) --dry-run --Werror $(SRC) $(HDR)

# Static analysis per ../.clang-tidy. Needs compile_commands.json.
tidy:
	@test -f compile_commands.json || { echo "run 'make compdb' first" >&2; exit 1; }
	$(CLANG_TIDY) -p . $(SRC)

.PHONY: all deps clean distclean compdb format format-check tidy
