LLVM_VERSION=19.1.7
LLVM_DOWNLOAD_URL?="https://github.com/llvm/llvm-project/releases/download/llvmorg-$(LLVM_VERSION)/llvm-project-$(LLVM_VERSION).src.tar.xz"
LLVM_BUILD_ARGS?=""
LLVM_SOURCE_ARCHIVE=lib/llvm-$(LLVM_VERSION).src.tar.xz
LLVM_RELEASE_DIR=lib/llvm-$(LLVM_VERSION)
LLVM_INSTALL_DIR=lib/llvm
PWD?=$(shell pwd)

OUTPUT_LIB = libclang-full.a

TAR?=tar

.PHONY: all clean llvm

# Download the LLVM project source code.
$(LLVM_SOURCE_ARCHIVE):
	mkdir -p `dirname $@`
	curl -L --fail ${LLVM_DOWNLOAD_URL} --output $@

# Extract the LLVM project source code.
$(LLVM_RELEASE_DIR): $(LLVM_SOURCE_ARCHIVE)
	mkdir -p $@
	$(TAR) -xf $(LLVM_SOURCE_ARCHIVE) --strip-components=1 -C $@ || true
	touch $@

# Configure CMake for the LLVM release build.
$(LLVM_RELEASE_DIR)/build/CMakeCache.txt: $(LLVM_RELEASE_DIR)
	mkdir -p $(LLVM_RELEASE_DIR)/build
	cd $(LLVM_RELEASE_DIR)/build && env CC=clang CXX=clang++ cmake \
		-G Ninja \
		-DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_INSTALL_PREFIX=$(PWD)/$(LLVM_INSTALL_DIR) \
		-DCMAKE_OSX_ARCHITECTURES='arm64' \
		-DLIBCLANG_BUILD_STATIC=ON \
		-DLLVM_ENABLE_PIC=ON \
		-DLLVM_ENABLE_BINDINGS=OFF \
		-DLLVM_ENABLE_LIBXML2=OFF \
		-DLLVM_ENABLE_LTO=OFF \
		-DLLVM_ENABLE_OCAMLDOC=OFF \
		-DLLVM_ENABLE_PROJECTS='clang' \
		-DLLVM_STATIC_LINK_CXX_STDLIB=ON \
		-DLLVM_ENABLE_WARNINGS=OFF \
		-DLLVM_ENABLE_Z3_SOLVER=OFF \
		-DLLVM_ENABLE_ZLIB=OFF \
		-DLLVM_ENABLE_ZSTD=OFF \
		-DLLVM_INCLUDE_BENCHMARKS=OFF \
		-DLLVM_INCLUDE_TESTS=OFF \
		-DLLVM_INCLUDE_EXAMPLES=OFF \
		-DLLVM_TOOL_REMARKS_SHLIB_BUILD=OFF \
		-DLLVM_TARGETS_TO_BUILD="AArch64;X86" \
		$(LLVM_BUILD_ARGS) \
		../llvm

llvm: $(LLVM_RELEASE_DIR)/build/CMakeCache.txt
	mkdir -p $(LLVM_INSTALL_DIR)/lib
	mkdir -p $(LLVM_INSTALL_DIR)/bin
	cd $(LLVM_RELEASE_DIR)/build && ninja install-clang-libraries install-llvm-libraries install-clang-headers install-llvm-headers

# Merge all static libraries into one archive.
$(OUTPUT_LIB): llvm
	@tmpdir=$$(mktemp -d); \
	echo "Temporary directory created: $$tmpdir"; \
	$(MAKE) extract-llvm-objects TMPDIR=$$tmpdir; \
	$(MAKE) extract-std-objects TMPDIR=$$tmpdir; \
	$(MAKE) merge-objects TMPDIR=$$tmpdir; \
	echo "Removing temporary directory $$tmpdir"; \
	rm -rf $$tmpdir

.PHONY: extract-llvm-objects
extract-llvm-objects:
	@for lib in $$(find $(LLVM_INSTALL_DIR)/lib -name "*.a" ! -name "*.dll.a"); do \
	  abs_lib=$$(cd $$(dirname $$lib) && pwd)/$$(basename $$lib); \
	  libname=$$(basename $$lib .a); \
	  echo "Extracting objects from $$abs_lib into $(TMPDIR)/$$libname"; \
	  mkdir -p $(TMPDIR)/$$libname; \
	  if (cd $(TMPDIR)/$$libname && ar x "$$abs_lib"); then \
		echo "Successfully extracted from $$abs_lib"; \
	  else \
		echo "[ERROR] Failed to extract from $$abs_lib"; \
	  fi; \
	done

.PHONY: extract-std-objects
extract-std-objects:
	@uname_str=$$(uname -s); \
	case "$$uname_str" in \
		Linux*)    handle_linux ;; \
		Darwin*)   handle_macos ;; \
		MINGW*|MSYS*) handle_mingw ;; \
		*)         echo "Unsupported system: $$uname_str"; exit 1 ;; \
	esac

define handle_linux
	echo "Searching for libstdc++.a in Linux..."; \
	found_lib=$$(find /usr/lib/gcc -name 'libstdc++.a' -print -quit 2>/dev/null); \
	if [ -n "$$found_lib" ]; then \
		process_lib "$$found_lib"; \
	else \
		echo "libstdc++.a not found in /usr/lib/gcc"; \
	fi
endef

define handle_macos
	echo "Searching for libc++.a in macOS..."; \
	sdk_path=$$(xcrun --show-sdk-path 2>/dev/null); \
	if [ -z "$$sdk_path" ]; then \
		echo "[ERROR] Xcode SDK path not found"; \
		exit 1; \
	fi; \
	found_lib=$$(find "$$sdk_path/usr/lib" -name 'libc++.a' -print -quit 2>/dev/null); \
	if [ -n "$$found_lib" ]; then \
		process_lib "$$found_lib"; \
	else \
		echo "libc++.a not found in $$sdk_path/usr/lib"; \
	fi
endef

define handle_mingw
	echo "Searching for libstdc++.a in MSYS2..."; \
	found_lib=$$(find /mingw64/lib -maxdepth 1 -name 'libstdc++.a' -print -quit 2>/dev/null); \
	if [ -n "$$found_lib" ]; then \
		process_lib "$$found_lib"; \
	else \
		echo "libstdc++.a not found in /mingw64/lib"; \
	fi
endef

define process_lib
	echo "Found library at $1"; \
	libname=$$(basename "$1" .a); \
	mkdir -p "$(TMPDIR)/$$libname"; \
	if (cd "$(TMPDIR)/$$libname" && ar x "$1"); then \
		echo "Successfully extracted from $1"; \
	else \
		echo "[ERROR] Failed to extract from $1"; \
	fi
endef

.PHONY: merge-objects
merge-objects:
	@tmpfile=$(TMPDIR)/obj_list.txt; \
	echo "Generating object file list in $$tmpfile"; \
	find $(TMPDIR) -type f -name '*.o' > $$tmpfile; \
	if [ -s $$tmpfile ]; then \
	  if ar -qcs $(OUTPUT_LIB) @$$tmpfile; then \
		ranlib $(OUTPUT_LIB); \
		echo "Created $(OUTPUT_LIB) successfully"; \
	  else \
		echo "[ERROR] Failed to create $(OUTPUT_LIB)"; \
	  fi; \
	else \
	  echo "No object files extracted, skipping archive creation."; \
	fi

# Compress the output archive.
$(OUTPUT_LIB).gz : $(OUTPUT_LIB)
	@echo "Compressing $(OUTPUT_LIB)..."
	@gzip -c $(OUTPUT_LIB) > $(OUTPUT_LIB).gz
	@echo "Created $(OUTPUT_LIB).gz"

clean:
	rm -rf $(LLVM_RELEASE_DIR) $(LLVM_SOURCE_ARCHIVE) $(LLVM_INSTALL_DIR) $(OUTPUT_LIB) $(OUTPUT_LIB).gz
