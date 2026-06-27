# Crystal Ball — build the Immolate searcher and run the regression suite.
#
#   make build_linux     native Linux/Proton binary (Immolate/build/Immolate)
#   make build_windows   Windows .exe via MinGW cross-compile (see note below)
#   make build           both
#   make test            Lua + Python regression suite (tests/run.sh)
#   make clean           remove the Immolate build dirs (Linux + Windows)
#
# build_windows cross-compiles from Linux (needs a MinGW toolchain + OpenCL import
# lib; errors clearly if absent). The shipped .exe is normally cut by CI instead.

IMMOLATE_SRC := Immolate
LINUX_BUILD  := $(IMMOLATE_SRC)/build
WIN_BUILD    := $(IMMOLATE_SRC)/build-windows
MINGW        := x86_64-w64-mingw32

.PHONY: build build_linux build_windows test clean

build: build_linux build_windows

# Immolate loads its kernels relative to the binary's dir, so stage search.cl +
# filters/ + lib/ beside it (mirrors the bundle); else it only runs from Immolate/.
define stage_kernels
	cp $(IMMOLATE_SRC)/search.cl $(1)/
	mkdir -p $(1)/filters $(1)/lib
	cp $(IMMOLATE_SRC)/filters/*.cl $(1)/filters/
	cp -r $(IMMOLATE_SRC)/lib/. $(1)/lib/
endef

build_linux:
	cmake -S $(IMMOLATE_SRC) -B $(LINUX_BUILD) -DCMAKE_BUILD_TYPE=Release
	cmake --build $(LINUX_BUILD) --config Release
	$(call stage_kernels,$(LINUX_BUILD))

build_windows:
	@command -v $(MINGW)-gcc >/dev/null 2>&1 || { \
	  echo "error: $(MINGW)-gcc not found."; \
	  echo "  Install a MinGW toolchain (+ an OpenCL import lib), or build on"; \
	  echo "  Windows / via CI (.github/workflows/release.yml)."; \
	  exit 1; }
	cmake -S $(IMMOLATE_SRC) -B $(WIN_BUILD) -DCMAKE_BUILD_TYPE=Release \
	  -DCMAKE_SYSTEM_NAME=Windows \
	  -DCMAKE_C_COMPILER=$(MINGW)-gcc \
	  -DCMAKE_RC_COMPILER=$(MINGW)-windres \
	  -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER \
	  -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
	  -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY
	cmake --build $(WIN_BUILD) --config Release
	$(call stage_kernels,$(WIN_BUILD))

test:
	bash tests/run.sh

clean:
	rm -rf $(LINUX_BUILD) $(WIN_BUILD)
