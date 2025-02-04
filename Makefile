LLVM_VERSION=19.1.7
LLVM_DOWNLOAD_URL?="https://github.com/llvm/llvm-project/releases/download/llvmorg-$(LLVM_VERSION)/llvm-project-$(LLVM_VERSION).src.tar.xz"
LLVM_BUILD_ARGS?=""
LLVM_SOURCE_ARCHIVE=lib/llvm-$(LLVM_VERSION).src.tar.xz
LLVM_RELEASE_DIR=lib/llvm-$(LLVM_VERSION)
LLVM_INSTALL_DIR=lib/llvm
PWD?=$(shell pwd)

OUTPUT_LIB = libclang-full.a

TAR?=tar

PHONY:

# Download the LLVM project source code.
#
# This is a prerequisite for all of the targets that build LLVM.
# We keep the version as part of the name so that we can download a different
# version without clobbering the old version we previously downloaded.
$(LLVM_SOURCE_ARCHIVE):
	mkdir -p `dirname $@`
	curl -L --fail ${LLVM_DOWNLOAD_URL} --output $@

# Extract the LLVM project source code to a folder for a release build.
$(LLVM_RELEASE_DIR): $(LLVM_SOURCE_ARCHIVE)
	mkdir -p $@
	${TAR} -xf $(LLVM_SOURCE_ARCHIVE) --strip-components=1 -C $@ || true
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

$(OUTPUT_LIB): llvm
	@echo "Merging static libraries..."
	@rm -f $(OUTPUT_LIB)
	@tmpdir=$$(mktemp -d); \
	for lib in $$(find $(LLVM_INSTALL_DIR)/lib -name "*.a" ! -name "*.dll.a"); do \
	  echo "Extracting objects from $(LLVM_INSTALL_DIR)/lib/$$lib..."; \
	  (cd $$tmpdir && ar x "$(LLVM_INSTALL_DIR)/lib/$$lib"); \
	done; \
	ar -qcs $(OUTPUT_LIB) $$tmpdir/*.o; \
	ranlib $(OUTPUT_LIB); \
	rm -rf $$tmpdir; \
	@echo "Created $(OUTPUT_LIB)"

$(OUTPUT_LIB).gz : $(OUTPUT_LIB)
	@echo "Compressing $(OUTPUT_LIB)..."
	@gzip -c $(OUTPUT_LIB) > $(OUTPUT_LIB).gz
	@echo "Created $(OUTPUT_LIB).gz"
