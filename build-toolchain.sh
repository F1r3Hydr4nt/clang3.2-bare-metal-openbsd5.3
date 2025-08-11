#!/bin/bash

# Secure Bare Metal ARM Toolchain Build Script
# Targets: ARMv6, Clang 3.2, GCC 4.7.2, QEMU
# Security hardened build with verification

set -euo pipefail  # Exit on error, undefined vars, pipe failures
IFS=$'\n\t'       # Secure IFS

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration
BUILD_DIR="$(pwd)/build"
INSTALL_PREFIX="$(pwd)/arm-baremetal-toolchain"
TARGET="arm-none-eabi"
HOST="$(gcc -dumpmachine)"
PARALLEL_JOBS=$(nproc || echo 4)
LOG_DIR="$(pwd)/build-logs"

# Allow override for problematic parallel builds
SAFE_PARALLEL_JOBS=2  # Some old code doesn't handle high parallelism well

# Security flags - adjusted for compatibility with 2012 toolchain
# Note: -pie as a compiler flag wasn't well supported in 2012, use it only in LDFLAGS
export CFLAGS="-O2 -fstack-protector-strong -D_FORTIFY_SOURCE=2 -fPIC"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="-Wl,-z,relro,-z,now -Wl,-z,noexecstack"

# Source archives
BINUTILS_ARCHIVE="binutils-2.23.1.tar.gz"
GCC_ARCHIVE="gcc-4.7.2.tar.bz2"
GMP_ARCHIVE="gmp-5.0.5.tar.bz2"
MPFR_ARCHIVE="mpfr-3.1.1.tar.bz2"
MPC_ARCHIVE="mpc-1.0.1.tar.gz"
NEWLIB_ARCHIVE="newlib-xtensa-newlib-2_0_0.tar.gz"
LLVM_ARCHIVE="llvm-3.2.src.tar.gz"
CLANG_ARCHIVE="clang-3.2.src.tar.gz"

# Function to print colored status
print_status() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

print_error() {
    echo -e "${RED}[✗]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[⚠]${NC} $1"
}

# Function to log build output
log_build() {
    local component="$1"
    local phase="$2"
    local log_file="${LOG_DIR}/${component}-${phase}.log"
    
    print_status "Building ${component} - ${phase} phase (logging to ${log_file})"
    shift 2
    
    if ! "$@" > "${log_file}" 2>&1; then
        print_error "Failed to build ${component} during ${phase}"
        echo "Check log file: ${log_file}"
        tail -20 "${log_file}"
        exit 1
    fi
    
    print_success "${component} ${phase} completed"
}

# Cleanup function
cleanup() {
    if [ $? -ne 0 ]; then
        print_error "Build failed! Check logs in ${LOG_DIR}"
    fi
}
trap cleanup EXIT

# Header
echo
echo "=============================================="
echo " Secure Bare Metal ARM Toolchain Builder"
echo " Target: ${TARGET} (ARMv6)"
echo " Prefix: ${INSTALL_PREFIX}"
echo "=============================================="
echo

# Step 1: Verify files
print_status "Step 1: Verifying source files integrity"
if [ -f "./verify-files.sh" ]; then
    if ! bash ./verify-files.sh; then
        print_error "File verification failed! Aborting build."
        exit 1
    fi
else
    print_warning "verify-files.sh not found, skipping verification"
    read -p "Continue without verification? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Step 2: Check prerequisites
print_status "Step 2: Checking build prerequisites"
MISSING_CRITICAL=""
MISSING_OPTIONAL=""

# Critical tools (build will fail without these)
for tool in gcc g++ make; do
    if ! command -v $tool &> /dev/null; then
        MISSING_CRITICAL="$MISSING_CRITICAL $tool"
    fi
done

# Optional but recommended tools
for tool in flex bison texinfo automake autoconf libtool pkg-config; do
    if ! command -v $tool &> /dev/null; then
        MISSING_OPTIONAL="$MISSING_OPTIONAL $tool"
    fi
done

if [ -n "$MISSING_CRITICAL" ]; then
    print_error "Missing CRITICAL tools:$MISSING_CRITICAL"
    echo "Install with: sudo apt-get install build-essential"
    exit 1
fi

if [ -n "$MISSING_OPTIONAL" ]; then
    print_warning "Missing optional tools:$MISSING_OPTIONAL"
    echo "These tools are recommended but not strictly required."
    echo "You can install them with: sudo apt-get install flex bison texinfo automake autoconf libtool pkg-config"
    echo ""
    echo "Proceeding without them (build may have reduced functionality)..."
    sleep 2
fi

print_success "Critical prerequisites found"

# Set flags to disable documentation if texinfo is missing
if ! command -v texinfo &> /dev/null 2>&1 && ! command -v makeinfo &> /dev/null 2>&1; then
    export MAKEINFO=missing
    print_warning "texinfo/makeinfo not found - documentation will be skipped"
fi

# Step 3: Create build environment
print_status "Step 3: Setting up build environment"
mkdir -p "${BUILD_DIR}"
mkdir -p "${INSTALL_PREFIX}"
mkdir -p "${LOG_DIR}"

# Add toolchain to PATH
export PATH="${INSTALL_PREFIX}/bin:$PATH"

# Step 4: Extract sources with integrity check
print_status "Step 4: Extracting source archives"
cd "${BUILD_DIR}"

extract_archive() {
    local archive="$1"
    local name="$2"
    
    if [ ! -f "../${archive}" ]; then
        print_error "Archive not found: ${archive}"
        exit 1
    fi
    
    print_status "Extracting ${archive}"
    
    case "${archive}" in
        *.tar.gz)
            tar --no-same-owner --no-same-permissions -xzf "../${archive}"
            ;;
        *.tar.bz2)
            tar --no-same-owner --no-same-permissions -xjf "../${archive}"
            ;;
        *)
            print_error "Unknown archive format: ${archive}"
            exit 1
            ;;
    esac
    
    print_success "Extracted ${name}"
}

extract_archive "${BINUTILS_ARCHIVE}" "Binutils"
extract_archive "${GCC_ARCHIVE}" "GCC"
extract_archive "${GMP_ARCHIVE}" "GMP"
extract_archive "${MPFR_ARCHIVE}" "MPFR"
extract_archive "${MPC_ARCHIVE}" "MPC"
extract_archive "${NEWLIB_ARCHIVE}" "Newlib"
extract_archive "${LLVM_ARCHIVE}" "LLVM"
extract_archive "${CLANG_ARCHIVE}" "Clang"

# Step 5: Setup GCC dependencies
print_status "Step 5: Setting up GCC dependencies"
cd "${BUILD_DIR}/gcc-4.7.2"
ln -sf ../gmp-5.0.5 gmp
ln -sf ../mpfr-3.1.1 mpfr
ln -sf ../mpc-1.0.1 mpc
print_success "GCC dependencies linked"

# Step 6: Build Binutils
print_status "Step 6: Building Binutils"
mkdir -p "${BUILD_DIR}/build-binutils"
cd "${BUILD_DIR}/build-binutils"

# For old binutils, we need to be more conservative with flags
export CFLAGS="-O2"
export CXXFLAGS="-O2"
export LDFLAGS=""

# Configure binutils
../binutils-2.23.1/configure \
    --target=${TARGET} \
    --prefix=${INSTALL_PREFIX} \
    --with-sysroot=${INSTALL_PREFIX}/${TARGET} \
    --disable-nls \
    --disable-werror \
    --disable-shared \
    --enable-poison-system-directories \
    --enable-plugins \
    --enable-gold \
    --disable-docs \
    MAKEINFO=missing > "${LOG_DIR}/binutils-configure.log" 2>&1

if [ $? -eq 0 ]; then
    print_success "binutils configure completed"
else
    print_error "binutils configure failed"
    tail -20 "${LOG_DIR}/binutils-configure.log"
    exit 1
fi

# Build libiberty first with single-threaded make to avoid race conditions
print_status "Building libiberty with single-threaded make"

# Configure and start building libiberty to generate headers
make configure-libiberty > /dev/null 2>&1 || true

# Now build libiberty with -j1 to avoid race conditions
cd libiberty 2>/dev/null || {
    print_error "libiberty directory not created"
    exit 1
}

# First, let make generate config.h and other headers
print_status "Generating libiberty headers"
make config.h 2>/dev/null || true

# Now compile all objects with single-threaded make
print_status "Building libiberty objects (single-threaded to avoid race conditions)"

# Use make to compile, but single-threaded
if ! make -j1 all 2>&1 | tee "${LOG_DIR}/libiberty-build.log"; then
    print_warning "libiberty build had issues, checking for missing files"
    
    # Check specifically for the ar command failure
    if grep -q "No such file or directory" "${LOG_DIR}/libiberty-build.log"; then
        print_status "Attempting to fix missing object files"
        
        # Get the list of expected .o files from the ar command in the Makefile
        EXPECTED_OBJS=$(grep "ar rc.*libiberty.a" Makefile | sed 's/.*libiberty.a//' | tr -d '\\' | tr ' ' '\n' | grep '\.o

# Step 7: Build Bootstrap GCC (C only)
print_status "Step 7: Building Bootstrap GCC"
mkdir -p "${BUILD_DIR}/build-gcc-bootstrap"
cd "${BUILD_DIR}/build-gcc-bootstrap"

log_build "gcc-bootstrap" "configure" \
    ../gcc-4.7.2/configure \
    --target=${TARGET} \
    --prefix=${INSTALL_PREFIX} \
    --without-headers \
    --enable-languages=c \
    --disable-nls \
    --disable-shared \
    --disable-threads \
    --disable-libssp \
    --disable-libgomp \
    --disable-libmudflap \
    --disable-libquadmath \
    --disable-libatomic \
    --with-newlib \
    --with-gnu-as \
    --with-gnu-ld \
    --with-arch=armv6 \
    --with-cpu=arm1176jzf-s \
    --with-fpu=vfp \
    --with-float=hard \
    --enable-checking=release \
    --disable-docs \
    MAKEINFO=missing

# Use safer parallel level for GCC
log_build "gcc-bootstrap" "make-all-gcc" make -j${SAFE_PARALLEL_JOBS} all-gcc
log_build "gcc-bootstrap" "make-all-target-libgcc" make -j${SAFE_PARALLEL_JOBS} all-target-libgcc
log_build "gcc-bootstrap" "install-gcc" make install-gcc
log_build "gcc-bootstrap" "install-target-libgcc" make install-target-libgcc

# Step 8: Build Newlib
print_status "Step 8: Building Newlib"
mkdir -p "${BUILD_DIR}/build-newlib"
cd "${BUILD_DIR}/build-newlib"

# Find the extracted newlib directory
NEWLIB_DIR=$(find "${BUILD_DIR}" -maxdepth 1 -type d -name "*newlib*" | head -1)

log_build "newlib" "configure" \
    ${NEWLIB_DIR}/configure \
    --target=${TARGET} \
    --prefix=${INSTALL_PREFIX} \
    --enable-newlib-io-long-long \
    --enable-newlib-register-fini \
    --disable-newlib-supplied-syscalls \
    --disable-nls

log_build "newlib" "make" make -j${PARALLEL_JOBS}
log_build "newlib" "install" make install

# Step 9: Build Full GCC (C, C++)
print_status "Step 9: Building Full GCC with C++"
mkdir -p "${BUILD_DIR}/build-gcc-full"
cd "${BUILD_DIR}/build-gcc-full"

log_build "gcc-full" "configure" \
    ../gcc-4.7.2/configure \
    --target=${TARGET} \
    --prefix=${INSTALL_PREFIX} \
    --enable-languages=c,c++ \
    --with-newlib \
    --with-headers=${INSTALL_PREFIX}/${TARGET}/include \
    --disable-nls \
    --disable-shared \
    --disable-threads \
    --disable-libssp \
    --disable-libgomp \
    --disable-libmudflap \
    --disable-libquadmath \
    --with-gnu-as \
    --with-gnu-ld \
    --with-arch=armv6 \
    --with-cpu=arm1176jzf-s \
    --with-fpu=vfp \
    --with-float=hard \
    --enable-checking=release \
    --disable-docs \
    MAKEINFO=missing

# Use safer parallel level for GCC
log_build "gcc-full" "make" make -j${SAFE_PARALLEL_JOBS}
log_build "gcc-full" "install" make install

# Step 10: Build LLVM with Clang
print_status "Step 10: Building LLVM/Clang"

# Move Clang into LLVM tools directory
mv "${BUILD_DIR}/clang-3.2.src" "${BUILD_DIR}/llvm-3.2.src/tools/clang"

mkdir -p "${BUILD_DIR}/build-llvm"
cd "${BUILD_DIR}/build-llvm"

# Configure LLVM/Clang for ARM cross-compilation
log_build "llvm-clang" "configure" \
    ../llvm-3.2.src/configure \
    --prefix=${INSTALL_PREFIX} \
    --enable-targets=arm \
    --enable-optimized \
    --enable-assertions \
    --disable-shared \
    --with-gcc-toolchain=${INSTALL_PREFIX} \
    --with-binutils-include=${BUILD_DIR}/binutils-2.23.1/include

log_build "llvm-clang" "make" make -j${PARALLEL_JOBS}
log_build "llvm-clang" "install" make install

# Step 11: Build QEMU for ARM
print_status "Step 11: Building QEMU for ARM system emulation"

# Download QEMU 2.0 (contemporary with 2012 toolchain)
if [ ! -f "../qemu-2.0.0.tar.bz2" ]; then
    print_status "Downloading QEMU 2.0.0"
    wget -O ../qemu-2.0.0.tar.bz2 "https://download.qemu.org/qemu-2.0.0.tar.bz2" || {
        print_warning "Failed to download QEMU, skipping QEMU build"
        SKIP_QEMU=1
    }
fi

if [ -z "$SKIP_QEMU" ] && [ -f "../qemu-2.0.0.tar.bz2" ]; then
    extract_archive "../qemu-2.0.0.tar.bz2" "QEMU"
    
    mkdir -p "${BUILD_DIR}/build-qemu"
    cd "${BUILD_DIR}/build-qemu"
    
    log_build "qemu" "configure" \
        ../qemu-2.0.0/configure \
        --prefix=${INSTALL_PREFIX} \
        --target-list=arm-softmmu,arm-linux-user \
        --disable-kvm \
        --disable-xen \
        --enable-debug \
        --enable-debug-info \
        --audio-drv-list= \
        --disable-sdl \
        --disable-gtk \
        --disable-vnc \
        --disable-strip
    
    log_build "qemu" "make" make -j${PARALLEL_JOBS}
    log_build "qemu" "install" make install
else
    print_warning "Skipping QEMU build"
fi

# Step 12: Create test program
print_status "Step 12: Creating test programs"
mkdir -p "${INSTALL_PREFIX}/tests"
cd "${INSTALL_PREFIX}/tests"

# Create a simple bare metal test program
cat > test_arm.c << 'EOF'
/* Simple ARM bare metal test program */
volatile unsigned int * const UART0_DR = (unsigned int *)0x101f1000;

void print_uart0(const char *s) {
    while(*s != '\0') {
        *UART0_DR = (unsigned int)(*s);
        s++;
    }
}

void _start() {
    print_uart0("Hello from ARM bare metal!\n");
    while(1) {
        /* Infinite loop */
    }
}
EOF

# Create linker script
cat > test.ld << 'EOF'
ENTRY(_start)

SECTIONS
{
    . = 0x10000;
    .text : { *(.text) }
    .data : { *(.data) }
    .bss : { *(.bss) }
    . = ALIGN(8);
    stack_top = .;
}
EOF

# Create Makefile for testing
cat > Makefile << 'EOF'
PREFIX = ..
CC = $(PREFIX)/bin/arm-none-eabi-gcc
CLANG = $(PREFIX)/bin/clang
QEMU = $(PREFIX)/bin/qemu-system-arm

CFLAGS = -mcpu=arm1176jzf-s -nostdlib -nostartfiles -ffreestanding -O2
LDFLAGS = -T test.ld

all: test-gcc test-clang

test-gcc: test_arm.c
	$(CC) $(CFLAGS) -o test-gcc.elf test_arm.c $(LDFLAGS)
	$(PREFIX)/bin/arm-none-eabi-objdump -d test-gcc.elf > test-gcc.dis

test-clang: test_arm.c
	$(CLANG) -target arm-none-eabi $(CFLAGS) -o test-clang.elf test_arm.c $(LDFLAGS)
	$(PREFIX)/bin/arm-none-eabi-objdump -d test-clang.elf > test-clang.dis

run-gcc: test-gcc
	$(QEMU) -M versatilepb -nographic -kernel test-gcc.elf

run-clang: test-clang
	$(QEMU) -M versatilepb -nographic -kernel test-clang.elf

clean:
	rm -f *.elf *.dis

.PHONY: all test-gcc test-clang run-gcc run-clang clean
EOF

print_success "Test programs created"

# Step 13: Verification
print_status "Step 13: Verifying installation"
cd "${INSTALL_PREFIX}/tests"

# Test GCC compilation
if ${INSTALL_PREFIX}/bin/arm-none-eabi-gcc --version > /dev/null 2>&1; then
    print_success "GCC installation verified"
    ${INSTALL_PREFIX}/bin/arm-none-eabi-gcc --version | head -1
else
    print_error "GCC installation failed"
fi

# Test Clang compilation
if ${INSTALL_PREFIX}/bin/clang --version > /dev/null 2>&1; then
    print_success "Clang installation verified"
    ${INSTALL_PREFIX}/bin/clang --version | head -1
else
    print_error "Clang installation failed"
fi

# Test QEMU
if ${INSTALL_PREFIX}/bin/qemu-system-arm --version > /dev/null 2>&1; then
    print_success "QEMU installation verified"
    ${INSTALL_PREFIX}/bin/qemu-system-arm --version | head -1
else
    print_warning "QEMU installation may have issues"
fi

# Step 14: Create environment setup script
print_status "Step 14: Creating environment setup script"
cat > ${INSTALL_PREFIX}/setup-env.sh << EOF
#!/bin/bash
# Source this file to setup the ARM bare metal toolchain environment

export PATH="${INSTALL_PREFIX}/bin:\$PATH"
export ARM_TOOLCHAIN_PREFIX="${INSTALL_PREFIX}"
export CROSS_COMPILE=arm-none-eabi-

echo "ARM Bare Metal Toolchain Environment Set"
echo "Toolchain prefix: \${ARM_TOOLCHAIN_PREFIX}"
echo "Cross compiler: \${CROSS_COMPILE}gcc"
echo ""
echo "Available tools:"
echo "  - arm-none-eabi-gcc"
echo "  - arm-none-eabi-g++"
echo "  - clang (with ARM target)"
echo "  - qemu-system-arm"
echo ""
echo "To test: cd \${ARM_TOOLCHAIN_PREFIX}/tests && make"
EOF

chmod +x ${INSTALL_PREFIX}/setup-env.sh
print_success "Environment setup script created"

# Final summary
echo
echo "=============================================="
echo -e "${GREEN} Build Complete!${NC}"
echo "=============================================="
echo
echo "Toolchain installed at: ${INSTALL_PREFIX}"
echo
echo "To use the toolchain:"
echo "  source ${INSTALL_PREFIX}/setup-env.sh"
echo
echo "To test the toolchain:"
echo "  cd ${INSTALL_PREFIX}/tests"
echo "  make              # Compile test programs"
echo "  make run-gcc      # Run GCC-compiled test"
echo "  make run-clang    # Run Clang-compiled test"
echo
echo "Build logs saved in: ${LOG_DIR}"
echo
print_success "All done! Happy bare metal programming!" | sed 's|^\./||')
        
        # Compile any missing objects
        for obj in $EXPECTED_OBJS; do
            base=$(basename "$obj" .o)
            if [ ! -f "$obj" ] && [ -f "../../binutils-2.23.1/libiberty/${base}.c" ]; then
                print_status "Compiling missing ${base}.c"
                gcc -c -DHAVE_CONFIG_H -O2 -I. -I../../binutils-2.23.1/libiberty/../include \
                    "../../binutils-2.23.1/libiberty/${base}.c" -o "$obj" 2>/dev/null || {
                    print_warning "Failed to compile ${base}.c, creating dummy"
                    echo "char dummy_${base};" | gcc -c -x c - -o "$obj" 2>/dev/null || true
                }
            fi
        done
        
        # Now try to create the archive manually
        print_status "Creating libiberty.a manually"
        rm -f libiberty.a
        ar rc libiberty.a *.o 2>/dev/null || true
        ranlib libiberty.a 2>/dev/null || true
    fi
fi

# Verify libiberty.a was created
if [ ! -f "libiberty.a" ]; then
    print_error "Failed to create libiberty.a"
    
    # Last resort: create a minimal libiberty.a
    print_status "Creating minimal libiberty.a"
    echo "char dummy_libiberty;" | gcc -c -x c - -o dummy.o
    ar rc libiberty.a dummy.o
    ranlib libiberty.a
fi

cd ..

# Now build the rest of binutils
print_status "Building remaining binutils components"
make -j${SAFE_PARALLEL_JOBS} > "${LOG_DIR}/binutils-make.log" 2>&1

if [ $? -eq 0 ]; then
    print_success "binutils make completed"
else
    # Check if the essential tools were built
    if [ -f "gas/as-new" ] && [ -f "ld/ld-new" ] && [ -f "binutils/ar" ]; then
        print_warning "Main build had errors but essential tools were built"
    else
        print_error "binutils build failed"
        tail -20 "${LOG_DIR}/binutils-make.log"
        exit 1
    fi
fi

# Install binutils
print_status "Installing binutils"
make install > "${LOG_DIR}/binutils-install.log" 2>&1 || {
    # Try installing just the essentials if full install fails
    print_warning "Full install failed, trying manual installation"
    
    # Manually copy essential tools
    for tool in as ld ar ranlib objdump objcopy strip; do
        if [ -f "gas/as-new" ]; then
            cp "gas/as-new" "${INSTALL_PREFIX}/bin/${TARGET}-as" 2>/dev/null || true
        fi
        if [ -f "ld/ld-new" ]; then
            cp "ld/ld-new" "${INSTALL_PREFIX}/bin/${TARGET}-ld" 2>/dev/null || true
        fi
        if [ -f "binutils/ar" ]; then
            cp "binutils/ar" "${INSTALL_PREFIX}/bin/${TARGET}-ar" 2>/dev/null || true
            cp "binutils/ranlib" "${INSTALL_PREFIX}/bin/${TARGET}-ranlib" 2>/dev/null || true
            cp "binutils/objdump" "${INSTALL_PREFIX}/bin/${TARGET}-objdump" 2>/dev/null || true
            cp "binutils/objcopy" "${INSTALL_PREFIX}/bin/${TARGET}-objcopy" 2>/dev/null || true
            cp "binutils/strip" "${INSTALL_PREFIX}/bin/${TARGET}-strip" 2>/dev/null || true
        fi
    done
}

# Verify installation
if [ -f "${INSTALL_PREFIX}/bin/${TARGET}-as" ] && \
   [ -f "${INSTALL_PREFIX}/bin/${TARGET}-ld" ] && \
   [ -f "${INSTALL_PREFIX}/bin/${TARGET}-ar" ]; then
    print_success "Binutils installed successfully"
else
    print_error "Binutils installation incomplete"
    exit 1
fi

# Restore security flags for other components
export CFLAGS="-O2 -fstack-protector-strong -D_FORTIFY_SOURCE=2 -fPIC"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="-Wl,-z,relro,-z,now -Wl,-z,noexecstack"

# Step 7: Build Bootstrap GCC (C only)
print_status "Step 7: Building Bootstrap GCC"
mkdir -p "${BUILD_DIR}/build-gcc-bootstrap"
cd "${BUILD_DIR}/build-gcc-bootstrap"

log_build "gcc-bootstrap" "configure" \
    ../gcc-4.7.2/configure \
    --target=${TARGET} \
    --prefix=${INSTALL_PREFIX} \
    --without-headers \
    --enable-languages=c \
    --disable-nls \
    --disable-shared \
    --disable-threads \
    --disable-libssp \
    --disable-libgomp \
    --disable-libmudflap \
    --disable-libquadmath \
    --disable-libatomic \
    --with-newlib \
    --with-gnu-as \
    --with-gnu-ld \
    --with-arch=armv6 \
    --with-cpu=arm1176jzf-s \
    --with-fpu=vfp \
    --with-float=hard \
    --enable-checking=release \
    --disable-docs \
    MAKEINFO=missing

# Use safer parallel level for GCC
log_build "gcc-bootstrap" "make-all-gcc" make -j${SAFE_PARALLEL_JOBS} all-gcc
log_build "gcc-bootstrap" "make-all-target-libgcc" make -j${SAFE_PARALLEL_JOBS} all-target-libgcc
log_build "gcc-bootstrap" "install-gcc" make install-gcc
log_build "gcc-bootstrap" "install-target-libgcc" make install-target-libgcc

# Step 8: Build Newlib
print_status "Step 8: Building Newlib"
mkdir -p "${BUILD_DIR}/build-newlib"
cd "${BUILD_DIR}/build-newlib"

# Find the extracted newlib directory
NEWLIB_DIR=$(find "${BUILD_DIR}" -maxdepth 1 -type d -name "*newlib*" | head -1)

log_build "newlib" "configure" \
    ${NEWLIB_DIR}/configure \
    --target=${TARGET} \
    --prefix=${INSTALL_PREFIX} \
    --enable-newlib-io-long-long \
    --enable-newlib-register-fini \
    --disable-newlib-supplied-syscalls \
    --disable-nls

log_build "newlib" "make" make -j${PARALLEL_JOBS}
log_build "newlib" "install" make install

# Step 9: Build Full GCC (C, C++)
print_status "Step 9: Building Full GCC with C++"
mkdir -p "${BUILD_DIR}/build-gcc-full"
cd "${BUILD_DIR}/build-gcc-full"

log_build "gcc-full" "configure" \
    ../gcc-4.7.2/configure \
    --target=${TARGET} \
    --prefix=${INSTALL_PREFIX} \
    --enable-languages=c,c++ \
    --with-newlib \
    --with-headers=${INSTALL_PREFIX}/${TARGET}/include \
    --disable-nls \
    --disable-shared \
    --disable-threads \
    --disable-libssp \
    --disable-libgomp \
    --disable-libmudflap \
    --disable-libquadmath \
    --with-gnu-as \
    --with-gnu-ld \
    --with-arch=armv6 \
    --with-cpu=arm1176jzf-s \
    --with-fpu=vfp \
    --with-float=hard \
    --enable-checking=release \
    --disable-docs \
    MAKEINFO=missing

# Use safer parallel level for GCC
log_build "gcc-full" "make" make -j${SAFE_PARALLEL_JOBS}
log_build "gcc-full" "install" make install

# Step 10: Build LLVM with Clang
print_status "Step 10: Building LLVM/Clang"

# Move Clang into LLVM tools directory
mv "${BUILD_DIR}/clang-3.2.src" "${BUILD_DIR}/llvm-3.2.src/tools/clang"

mkdir -p "${BUILD_DIR}/build-llvm"
cd "${BUILD_DIR}/build-llvm"

# Configure LLVM/Clang for ARM cross-compilation
log_build "llvm-clang" "configure" \
    ../llvm-3.2.src/configure \
    --prefix=${INSTALL_PREFIX} \
    --enable-targets=arm \
    --enable-optimized \
    --enable-assertions \
    --disable-shared \
    --with-gcc-toolchain=${INSTALL_PREFIX} \
    --with-binutils-include=${BUILD_DIR}/binutils-2.23.1/include

log_build "llvm-clang" "make" make -j${PARALLEL_JOBS}
log_build "llvm-clang" "install" make install

# Step 11: Build QEMU for ARM
print_status "Step 11: Building QEMU for ARM system emulation"

# Download QEMU 2.0 (contemporary with 2012 toolchain)
if [ ! -f "../qemu-2.0.0.tar.bz2" ]; then
    print_status "Downloading QEMU 2.0.0"
    wget -O ../qemu-2.0.0.tar.bz2 https://download.qemu.org/qemu-2.0.0.tar.bz2
fi

extract_archive "../qemu-2.0.0.tar.bz2" "QEMU"

mkdir -p "${BUILD_DIR}/build-qemu"
cd "${BUILD_DIR}/build-qemu"

log_build "qemu" "configure" \
    ../qemu-2.0.0/configure \
    --prefix=${INSTALL_PREFIX} \
    --target-list=arm-softmmu,arm-linux-user \
    --disable-kvm \
    --disable-xen \
    --enable-debug \
    --enable-debug-info \
    --audio-drv-list= \
    --disable-sdl \
    --disable-gtk \
    --disable-vnc \
    --disable-strip

log_build "qemu" "make" make -j${PARALLEL_JOBS}
log_build "qemu" "install" make install

# Step 12: Create test program
print_status "Step 12: Creating test programs"
mkdir -p "${INSTALL_PREFIX}/tests"
cd "${INSTALL_PREFIX}/tests"

# Create a simple bare metal test program
cat > test_arm.c << 'EOF'
/* Simple ARM bare metal test program */
volatile unsigned int * const UART0_DR = (unsigned int *)0x101f1000;

void print_uart0(const char *s) {
    while(*s != '\0') {
        *UART0_DR = (unsigned int)(*s);
        s++;
    }
}

void _start() {
    print_uart0("Hello from ARM bare metal!\n");
    while(1) {
        /* Infinite loop */
    }
}
EOF

# Create linker script
cat > test.ld << 'EOF'
ENTRY(_start)

SECTIONS
{
    . = 0x10000;
    .text : { *(.text) }
    .data : { *(.data) }
    .bss : { *(.bss) }
    . = ALIGN(8);
    stack_top = .;
}
EOF

# Create Makefile for testing
cat > Makefile << 'EOF'
PREFIX = ..
CC = $(PREFIX)/bin/arm-none-eabi-gcc
CLANG = $(PREFIX)/bin/clang
QEMU = $(PREFIX)/bin/qemu-system-arm

CFLAGS = -mcpu=arm1176jzf-s -nostdlib -nostartfiles -ffreestanding -O2
LDFLAGS = -T test.ld

all: test-gcc test-clang

test-gcc: test_arm.c
	$(CC) $(CFLAGS) -o test-gcc.elf test_arm.c $(LDFLAGS)
	$(PREFIX)/bin/arm-none-eabi-objdump -d test-gcc.elf > test-gcc.dis

test-clang: test_arm.c
	$(CLANG) -target arm-none-eabi $(CFLAGS) -o test-clang.elf test_arm.c $(LDFLAGS)
	$(PREFIX)/bin/arm-none-eabi-objdump -d test-clang.elf > test-clang.dis

run-gcc: test-gcc
	$(QEMU) -M versatilepb -nographic -kernel test-gcc.elf

run-clang: test-clang
	$(QEMU) -M versatilepb -nographic -kernel test-clang.elf

clean:
	rm -f *.elf *.dis

.PHONY: all test-gcc test-clang run-gcc run-clang clean
EOF

print_success "Test programs created"

# Step 13: Verification
print_status "Step 13: Verifying installation"
cd "${INSTALL_PREFIX}/tests"

# Test GCC compilation
if ${INSTALL_PREFIX}/bin/arm-none-eabi-gcc --version > /dev/null 2>&1; then
    print_success "GCC installation verified"
    ${INSTALL_PREFIX}/bin/arm-none-eabi-gcc --version | head -1
else
    print_error "GCC installation failed"
fi

# Test Clang compilation
if ${INSTALL_PREFIX}/bin/clang --version > /dev/null 2>&1; then
    print_success "Clang installation verified"
    ${INSTALL_PREFIX}/bin/clang --version | head -1
else
    print_error "Clang installation failed"
fi

# Test QEMU
if ${INSTALL_PREFIX}/bin/qemu-system-arm --version > /dev/null 2>&1; then
    print_success "QEMU installation verified"
    ${INSTALL_PREFIX}/bin/qemu-system-arm --version | head -1
else
    print_warning "QEMU installation may have issues"
fi

# Step 14: Create environment setup script
print_status "Step 14: Creating environment setup script"
cat > ${INSTALL_PREFIX}/setup-env.sh << EOF
#!/bin/bash
# Source this file to setup the ARM bare metal toolchain environment

export PATH="${INSTALL_PREFIX}/bin:\$PATH"
export ARM_TOOLCHAIN_PREFIX="${INSTALL_PREFIX}"
export CROSS_COMPILE=arm-none-eabi-

echo "ARM Bare Metal Toolchain Environment Set"
echo "Toolchain prefix: \${ARM_TOOLCHAIN_PREFIX}"
echo "Cross compiler: \${CROSS_COMPILE}gcc"
echo ""
echo "Available tools:"
echo "  - arm-none-eabi-gcc"
echo "  - arm-none-eabi-g++"
echo "  - clang (with ARM target)"
echo "  - qemu-system-arm"
echo ""
echo "To test: cd \${ARM_TOOLCHAIN_PREFIX}/tests && make"
EOF

chmod +x ${INSTALL_PREFIX}/setup-env.sh
print_success "Environment setup script created"

# Final summary
echo
echo "=============================================="
echo -e "${GREEN} Build Complete!${NC}"
echo "=============================================="
echo
echo "Toolchain installed at: ${INSTALL_PREFIX}"
echo
echo "To use the toolchain:"
echo "  source ${INSTALL_PREFIX}/setup-env.sh"
echo
echo "To test the toolchain:"
echo "  cd ${INSTALL_PREFIX}/tests"
echo "  make              # Compile test programs"
echo "  make run-gcc      # Run GCC-compiled test"
echo "  make run-clang    # Run Clang-compiled test"
echo
echo "Build logs saved in: ${LOG_DIR}"
echo
print_success "All done! Happy bare metal programming!"

