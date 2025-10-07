#!/bin/bash

# =============================================================================
# Build Script for Pixel 3 (blueline) - KSUN + SUSFS Kernel
# Repository: kernel-build-from-rainyland/kernel_google_b1c1
# Target: Google b1c1 platform (Pixel 3 blueline + Pixel 3 XL crosshatch)
# =============================================================================

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
KERNEL_NAME="b1c1-ksun-susfs"
DEFCONFIG="b1c1_defconfig"
ARCH="arm64"
SUBARCH="arm64"

# Directories
KERNEL_DIR=$(pwd)
BUILD_DIR="${KERNEL_DIR}/out"
CCACHE_DIR="${HOME}/.ccache"

# Toolchain Configuration (modify as needed)
# Auto-detect toolchain or use these paths

# User's toolchain directory
TOOLCHAIN_BASE="${HOME}/toolchains"

# Option 1: Clang prebuilts (user's existing toolchains)
CLANG_PREBUILT="${TOOLCHAIN_BASE}/clang-prebuilts"
CLANG_R416183B="${TOOLCHAIN_BASE}/clang-r416183b"

# Option 2: Android NDK (if available)
NDK_DIR="${HOME}/android-ndk-r25c"

# Option 3: Standalone GCC toolchain
GCC_STANDALONE="${HOME}/toolchain/aarch64-linux-android-4.9"

# Will be auto-detected in order of preference

# Build configuration
VERBOSE=0  # Set to 0 for quiet build
if [[ "${JOBS}" == "all" ]]; then
    JOBS=$(nproc)
else
    JOBS=${JOBS:-8}
fi
# =============================================================================
# Functions
# =============================================================================

print_banner() {
    echo -e "${BLUE}"
    echo "============================================================"
    echo "  PIXEL 3 KERNEL BUILD SCRIPT - KSUN + SUSFS"
    echo "============================================================"
    echo "  Target Device: Pixel 3 (blueline) / Pixel 3 XL (crosshatch)"
    echo "  Kernel: ${KERNEL_NAME}"
    echo "  Defconfig: ${DEFCONFIG}"
    echo "  Jobs: ${JOBS}"
    echo "============================================================"
    echo -e "${NC}"
}

check_dependencies() {
    echo -e "${YELLOW}[INFO]${NC} Checking build dependencies..."
    
    # Check required tools
    local tools=("make" "bc" "bison" "flex" "openssl")
    for tool in "${tools[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            echo -e "${RED}[ERROR]${NC} Required tool '$tool' not found"
            echo "Please install build dependencies:"
            echo "Ubuntu/Debian: sudo apt install build-essential bc bison flex libssl-dev"
            echo "Arch Linux: sudo pacman -S base-devel bc bison flex openssl"
            exit 1
        fi
    done
    
    # Check ccache
    if ! command -v ccache &> /dev/null; then
        echo -e "${YELLOW}[WARNING]${NC} ccache not found, installing..."
        if command -v apt &> /dev/null; then
            sudo apt install ccache
        elif command -v pacman &> /dev/null; then
            sudo pacman -S ccache
        else
            echo -e "${RED}[ERROR]${NC} Please install ccache manually"
            exit 1
        fi
    fi
    
    echo -e "${GREEN}[OK]${NC} Dependencies check passed"
}

setup_ccache() {
    echo -e "${YELLOW}[INFO]${NC} Setting up ccache..."

    mkdir -p "${CCACHE_DIR}"
    ccache -M 50G >/dev/null

    export USE_CCACHE=1
    export CCACHE_DIR="${CCACHE_DIR}"
    export CCACHE_CPP2=yes
    export CCACHE_COMPILERCHECK=content
    export CCACHE_BASEDIR="${KERNEL_DIR}"
    export CC="ccache clang"

    # Improve kernel build compatibility
    export CCACHE_SLOPPINESS=file_macro,time_macros,include_file_mtime,include_file_ctime
    export CCACHE_LOGFILE="${BUILD_DIR}/ccache.log"

    echo -e "${GREEN}[OK]${NC} ccache configured (max size: 50GB)"
}

check_toolchain() {
    echo -e "${YELLOW}[INFO]${NC} Checking toolchain..."
    
    # Helper function to find clang in a directory
    find_clang() {
        local base_dir="$1"
        # Common Clang locations in prebuilt toolchains
        local clang_paths=(
            "${base_dir}/bin/clang"
            "${base_dir}/host/linux-x86/clang-r416183b/bin/clang"
            "${base_dir}/clang-r416183b/bin/clang"
            "${base_dir}/linux-x86/clang-r416183b/bin/clang"
        )
        
        for clang_bin in "${clang_paths[@]}"; do
            if [[ -f "$clang_bin" ]]; then
                echo "$(dirname "$clang_bin")"
                return 0
            fi
        done
        return 1
    }
    
    # Helper function to find GCC/binutils
    find_gcc_binutils() {
        local base_dir="$1"
        local gcc_paths=(
            "${base_dir}/aarch64-linux-android/bin"
            "${base_dir}/bin"
            "${base_dir}/../gcc/linux-x86/aarch64/aarch64-linux-android-4.9/bin"
            "${base_dir}/../../gcc/linux-x86/aarch64/aarch64-linux-android-4.9/bin"
        )
        
        for gcc_dir in "${gcc_paths[@]}"; do
            if [[ -f "${gcc_dir}/aarch64-linux-android-as" ]] || [[ -f "${gcc_dir}/aarch64-linux-android-ld" ]]; then
                echo "$gcc_dir"
                return 0
            fi
        done
        return 1
    }
    
    # Helper function to find 32-bit ARM compiler
    find_arm32_compiler() {
        local base_dir="$1"
        local arm32_paths=(
            "${base_dir}/arm-linux-androideabi/bin"
            "${base_dir}/bin"
            "${base_dir}/../gcc/linux-x86/arm/arm-linux-androideabi-4.9/bin"
            "${base_dir}/../../gcc/linux-x86/arm/arm-linux-androideabi-4.9/bin"
        )
        
        for arm32_dir in "${arm32_paths[@]}"; do
            if [[ -f "${arm32_dir}/arm-linux-androideabi-gcc" ]]; then
                echo "${arm32_dir}/arm-linux-androideabi-"
                return 0
            fi
        done
        
        # Check system-wide
        if command -v arm-linux-gnueabi-gcc &> /dev/null; then
            echo "arm-linux-gnueabi-"
            return 0
        fi
        
        if command -v arm-linux-gnueabihf-gcc &> /dev/null; then
            echo "arm-linux-gnueabihf-"
            return 0
        fi
        
        return 1
    }
    
    # 1. Check user's clang-r416183b toolchain
    if [[ -d "${CLANG_R416183B}" ]]; then
        local clang_bin_dir=$(find_clang "${CLANG_R416183B}")
        if [[ -n "$clang_bin_dir" ]]; then
            echo -e "${BLUE}[INFO]${NC} Using clang-r416183b toolchain"
            export PATH="${clang_bin_dir}:${PATH}"
            
            # Look for binutils/GCC for assembler and linker
            local gcc_bin_dir=$(find_gcc_binutils "${CLANG_R416183B}")
            if [[ -n "$gcc_bin_dir" ]]; then
                export PATH="${gcc_bin_dir}:${PATH}"
                echo -e "${GREEN}[OK]${NC} Found binutils at: ${gcc_bin_dir}"
            fi
            
            # Look for 32-bit ARM compiler
            local arm32_prefix=$(find_arm32_compiler "${CLANG_R416183B}")
            if [[ -n "$arm32_prefix" ]]; then
                export CROSS_COMPILE_ARM32="$arm32_prefix"
                echo -e "${GREEN}[OK]${NC} Found ARM32 compiler: ${arm32_prefix}"
            else
                echo -e "${YELLOW}[WARNING]${NC} ARM32 compiler not found, disabling compat vDSO"
                export CROSS_COMPILE_ARM32="arm-linux-gnueabi-"
            fi
            
            # Set Clang-specific variables
            export CC="ccache clang"
            export CLANG_TRIPLE="aarch64-linux-gnu-"
            export CROSS_COMPILE="aarch64-linux-android-"
            
            # Tell kernel build system to use LLVM tools
            export LLVM=1
            export LLVM_IAS=1
            
            if clang --version &> /dev/null; then
                echo -e "${GREEN}[OK]${NC} Clang found: $(clang --version | head -n1)"
                export ARCH="${ARCH}"
                export SUBARCH="${SUBARCH}"
                return 0
            fi
        fi
    fi
    
    # 2. Check user's clang-prebuilts toolchain
    if [[ -d "${CLANG_PREBUILT}" ]]; then
        local clang_bin_dir=$(find_clang "${CLANG_PREBUILT}")
        if [[ -n "$clang_bin_dir" ]]; then
            echo -e "${BLUE}[INFO]${NC} Using clang-prebuilts toolchain"
            export PATH="${clang_bin_dir}:${PATH}"
            
            # Look for binutils/GCC for assembler and linker
            local gcc_bin_dir=$(find_gcc_binutils "${CLANG_PREBUILT}")
            if [[ -n "$gcc_bin_dir" ]]; then
                export PATH="${gcc_bin_dir}:${PATH}"
                echo -e "${GREEN}[OK]${NC} Found binutils at: ${gcc_bin_dir}"
            fi
            
            # Look for 32-bit ARM compiler
            local arm32_prefix=$(find_arm32_compiler "${CLANG_PREBUILT}")
            if [[ -n "$arm32_prefix" ]]; then
                export CROSS_COMPILE_ARM32="$arm32_prefix"
                echo -e "${GREEN}[OK]${NC} Found ARM32 compiler: ${arm32_prefix}"
            else
                echo -e "${YELLOW}[WARNING]${NC} ARM32 compiler not found, disabling compat vDSO"
                export CROSS_COMPILE_ARM32="arm-linux-gnueabi-"
            fi
            
            # Set Clang-specific variables
            export CC="ccache clang"
            export CLANG_TRIPLE="aarch64-linux-gnu-"
            export CROSS_COMPILE="aarch64-linux-android-"
            
            # Tell kernel build system to use LLVM tools
            export LLVM=1
            export LLVM_IAS=1
            
            if clang --version &> /dev/null; then
                echo -e "${GREEN}[OK]${NC} Clang found: $(clang --version | head -n1)"
                export ARCH="${ARCH}"
                export SUBARCH="${SUBARCH}"
                return 0
            fi
        fi
    fi
    
    # 3. Check for Android NDK
    if [[ -d "${NDK_DIR}/toolchains/llvm/prebuilt/linux-x86_64/bin" ]]; then
        local clang_dir="${NDK_DIR}/toolchains/llvm/prebuilt/linux-x86_64"
        if [[ -f "${clang_dir}/bin/clang" ]]; then
            echo -e "${BLUE}[INFO]${NC} Using Android NDK Clang toolchain"
            export PATH="${clang_dir}/bin:${PATH}"
            export CC="ccache clang"
            export CLANG_TRIPLE="aarch64-linux-android-"
            export CROSS_COMPILE="aarch64-linux-android-"
            
            # NDK usually has ARM32 compiler
            local arm32_prefix=$(find_arm32_compiler "${clang_dir}")
            if [[ -n "$arm32_prefix" ]]; then
                export CROSS_COMPILE_ARM32="$arm32_prefix"
                echo -e "${GREEN}[OK]${NC} Found ARM32 compiler: ${arm32_prefix}"
            else
                export CROSS_COMPILE_ARM32="arm-linux-gnueabi-"
            fi
            
            # Tell kernel build system to use LLVM tools
            export LLVM=1
            export LLVM_IAS=1
            
            if clang --version &> /dev/null; then
                echo -e "${GREEN}[OK]${NC} Clang found: $(clang --version | head -n1)"
                export ARCH="${ARCH}"
                export SUBARCH="${SUBARCH}"
                return 0
            fi
        fi
    fi
    
    # 4. Check for standalone GCC
    if [[ -d "${GCC_STANDALONE}/bin" ]]; then
        local gcc_path="${GCC_STANDALONE}/bin/aarch64-linux-android-"
        if [[ -f "${gcc_path}gcc" ]]; then
            echo -e "${BLUE}[INFO]${NC} Using standalone GCC toolchain"
            export PATH="${GCC_STANDALONE}/bin:${PATH}"
            export CROSS_COMPILE="${gcc_path}"
            export CC="ccache ${CROSS_COMPILE}gcc"
            
            # Look for ARM32 compiler
            local arm32_prefix=$(find_arm32_compiler "${GCC_STANDALONE}")
            if [[ -n "$arm32_prefix" ]]; then
                export CROSS_COMPILE_ARM32="$arm32_prefix"
                echo -e "${GREEN}[OK]${NC} Found ARM32 compiler: ${arm32_prefix}"
            else
                export CROSS_COMPILE_ARM32="arm-linux-gnueabi-"
            fi
            
            if "${CROSS_COMPILE}gcc" --version &> /dev/null; then
                echo -e "${GREEN}[OK]${NC} GCC found: $(${CROSS_COMPILE}gcc --version | head -n1)"
                export ARCH="${ARCH}"
                export SUBARCH="${SUBARCH}"
                return 0
            fi
        fi
    fi
    
    # 5. Check for system-wide aarch64 toolchain
    if command -v aarch64-linux-gnu-gcc &> /dev/null; then
        echo -e "${BLUE}[INFO]${NC} Using system aarch64-linux-gnu toolchain"
        export CROSS_COMPILE="aarch64-linux-gnu-"
        export CC="ccache ${CROSS_COMPILE}gcc"
        
        # Check for system ARM32 compiler
        if command -v arm-linux-gnueabi-gcc &> /dev/null; then
            export CROSS_COMPILE_ARM32="arm-linux-gnueabi-"
            echo -e "${GREEN}[OK]${NC} Found ARM32 compiler: arm-linux-gnueabi-"
        elif command -v arm-linux-gnueabihf-gcc &> /dev/null; then
            export CROSS_COMPILE_ARM32="arm-linux-gnueabihf-"
            echo -e "${GREEN}[OK]${NC} Found ARM32 compiler: arm-linux-gnueabihf-"
        else
            export CROSS_COMPILE_ARM32="arm-linux-gnueabi-"
        fi
        
        if "${CROSS_COMPILE}gcc" --version &> /dev/null; then
            echo -e "${GREEN}[OK]${NC} GCC found: $(${CROSS_COMPILE}gcc --version | head -n1)"
            export ARCH="${ARCH}"
            export SUBARCH="${SUBARCH}"
            return 0
        fi
    fi
    
    # No toolchain found
    echo -e "${RED}[ERROR]${NC} No suitable ARM64 cross-compiler found!"
    echo ""
    echo "Checked locations:"
    echo "  - ${CLANG_R416183B}"
    echo "  - ${CLANG_PREBUILT}"
    echo "  - ${NDK_DIR}"
    echo "  - ${GCC_STANDALONE}"
    echo "  - System PATH"
    echo ""
    echo "Please verify your toolchain installation or update paths in the script."
    echo ""
    exit 1
}

check_kernel_source() {
    echo -e "${YELLOW}[INFO]${NC} Verifying kernel source..."
    
    # Check if we're in kernel directory
    if [[ ! -f "Makefile" ]]; then
        echo -e "${RED}[ERROR]${NC} Makefile not found in current directory"
        echo "Please run this script from the kernel source root"
        exit 1
    fi
    
    # Check if it's a Linux kernel Makefile
    if ! grep -q "SPDX-License-Identifier\|Linux kernel\|Linus Torvalds\|VERSION\|PATCHLEVEL" Makefile 2>/dev/null; then
        echo -e "${RED}[ERROR]${NC} This doesn't appear to be a Linux kernel source directory"
        echo "Please run this script from the kernel source root"
        exit 1
    fi
    
    echo -e "${GREEN}[OK]${NC} Kernel source directory verified"
    
    # Check KSUN integration
    if [[ -d "KernelSU-Next" ]]; then
        echo -e "${GREEN}[OK]${NC} KernelSU-Next found"
    else
        echo -e "${RED}[ERROR]${NC} KernelSU-Next directory not found"
        echo "Please ensure the repository has KSUN integration"
        exit 1
    fi
    
    # Check SUSFS integration
    if [[ -f "fs/susfs.c" ]]; then
        echo -e "${GREEN}[OK]${NC} SUSFS integration found (fs/susfs.c)"
    else
        echo -e "${YELLOW}[WARNING]${NC} fs/susfs.c not found"
        echo "Checking for alternative SUSFS integration..."
        
        if find fs/ -name "*susfs*" -type f | grep -q .; then
            echo -e "${GREEN}[OK]${NC} SUSFS files found in fs/ directory"
        else
            echo -e "${RED}[ERROR]${NC} SUSFS integration not found"
            exit 1
        fi
    fi
    
    # Initialize submodules
    echo -e "${YELLOW}[INFO]${NC} Initializing submodules..."
    git submodule update --init --recursive
    
    echo -e "${GREEN}[OK]${NC} Kernel source verification passed"
}

clean_build() {
    echo -e "${YELLOW}[INFO]${NC} Performing deep clean (mrproper only)..."

    make O="${BUILD_DIR}" mrproper

    if [[ -d "${BUILD_DIR}" ]]; then
        rm -rf "${BUILD_DIR}"
    fi
    mkdir -p "${BUILD_DIR}"

    echo -e "${GREEN}[OK]${NC} Clean completed (mrproper done)"
}

configure_kernel() {
    local config_file="${BUILD_DIR}/.config"

    if [[ ! -f "${config_file}" ]]; then
        echo -e "${YELLOW}[INFO]${NC} No existing config found — creating fresh .config"
        make O="${BUILD_DIR}" "${DEFCONFIG}"
    else
        echo -e "${YELLOW}[INFO]${NC} Reusing existing .config for incremental build"
    fi

    echo -e "${YELLOW}[INFO]${NC} Disabling CONFIG_VDSO32 (if present)"
    sed -i 's/^CONFIG_VDSO32=y/# CONFIG_VDSO32 is not set/' "${config_file}" 2>/dev/null
    sed -i 's/^CONFIG_COMPAT_VDSO=y/# CONFIG_COMPAT_VDSO is not set/' "${config_file}" 2>/dev/null
    echo "# CONFIG_VDSO32 is not set" >> "${config_file}"
    echo "# CONFIG_COMPAT_VDSO is not set" >> "${config_file}"

    echo -e "${YELLOW}[INFO]${NC} Finalizing configuration..."
    make O="${BUILD_DIR}" olddefconfig

    if grep -q "CONFIG_KSU=y\|CONFIG_KERNELSU=y" "${config_file}"; then
        echo -e "${GREEN}[OK]${NC} KernelSU enabled"
    else
        echo -e "${RED}[ERROR]${NC} KernelSU missing!"
    fi

    if grep -q "CONFIG_KSU_SUSFS=y" "${config_file}"; then
        echo -e "${GREEN}[OK]${NC} SUSFS enabled"
    else
        echo -e "${RED}[ERROR]${NC} SUSFS missing!"
    fi

    echo -e "${GREEN}[OK]${NC} Kernel configuration completed"
}

build_kernel() {
    echo -e "${YELLOW}[INFO]${NC} Starting kernel build..."
    echo -e "${BLUE}[INFO]${NC} Using ${JOBS} parallel jobs"
    
    # Build command arguments
    local make_args=(
        "O=${BUILD_DIR}"
        "-j${JOBS}"
	"CC=ccache clang"
    )
    
    # Add LLVM flags if using Clang
    if [[ -n "${LLVM}" ]]; then
        make_args+=("LLVM=1")
        make_args+=("LLVM_IAS=1")
        echo -e "${BLUE}[INFO]${NC} Building with LLVM/Clang toolchain"
    fi
    
    # Add verbose output if enabled
    if [[ "${VERBOSE}" == "1" ]]; then
        make_args+=("V=1")
    fi
    
    # Start build with progress
    echo -e "${BLUE}[INFO]${NC} Build command: make ${make_args[@]}"
    
    if make "${make_args[@]}" 2>&1 | tee "${BUILD_DIR}/build.log"; then
        # Check if kernel image was actually created
        local image_created=false
        local kernel_images=(
            "${BUILD_DIR}/arch/${ARCH}/boot/Image.lz4-dtb"
            "${BUILD_DIR}/arch/${ARCH}/boot/Image.gz-dtb"
            "${BUILD_DIR}/arch/${ARCH}/boot/Image-dtb"
            "${BUILD_DIR}/arch/${ARCH}/boot/Image.lz4"
            "${BUILD_DIR}/arch/${ARCH}/boot/Image.gz"
            "${BUILD_DIR}/arch/${ARCH}/boot/Image"
        )
        
        for img in "${kernel_images[@]}"; do
            if [[ -f "$img" ]]; then
                image_created=true
                break
            fi
        done
        
        if [[ "$image_created" == false ]]; then
            echo -e "${RED}[ERROR]${NC} Build completed but no kernel image was created"
            echo -e "${YELLOW}[INFO]${NC} Checking build log for errors..."
            echo ""
            echo "Last 50 lines of build log:"
            tail -n 50 "${BUILD_DIR}/build.log"
            echo ""
            echo "Errors in build log:"
            grep -i "error\|failed\|Stop" "${BUILD_DIR}/build.log" | tail -n 20
            exit 1
        fi
        
        local end_time=$(date +%s)
        local build_time=$((end_time - start_time))
        local minutes=$((build_time / 60))
        local seconds=$((build_time % 60))
        
        echo -e "${GREEN}[SUCCESS]${NC} Kernel build completed in ${minutes}m ${seconds}s"
    else
        echo -e "${RED}[ERROR]${NC} Kernel build failed"
        echo "Check build log: ${BUILD_DIR}/build.log"
        echo ""
        echo "Last 30 lines of build log:"
        tail -n 30 "${BUILD_DIR}/build.log"
        exit 1
    fi
}

verify_build() {
    echo -e "${YELLOW}[INFO]${NC} Verifying build output..."
    
    # Look for kernel images in various formats and locations
    local kernel_images=(
        "${BUILD_DIR}/arch/${ARCH}/boot/Image.lz4-dtb"
        "${BUILD_DIR}/arch/${ARCH}/boot/Image.gz-dtb"
        "${BUILD_DIR}/arch/${ARCH}/boot/Image-dtb"
        "${BUILD_DIR}/arch/${ARCH}/boot/Image.lz4"
        "${BUILD_DIR}/arch/${ARCH}/boot/Image.gz"
        "${BUILD_DIR}/arch/${ARCH}/boot/Image"
    )
    
    local kernel_found=false
    local kernel_path=""
    
    # Check for kernel image
    for img in "${kernel_images[@]}"; do
        if [[ -f "$img" ]]; then
            local size=$(du -h "$img" | cut -f1)
            echo -e "${GREEN}[OK]${NC} Kernel image found: $img (${size})"
            kernel_found=true
            kernel_path="$img"
            break
        fi
    done
    
    if [[ "$kernel_found" == false ]]; then
        echo -e "${YELLOW}[WARNING]${NC} Standard kernel images not found, checking build directory..."
        
        # Search for any Image* files
        local found_images=$(find "${BUILD_DIR}/arch/${ARCH}/boot" -name "Image*" -type f 2>/dev/null)
        
        if [[ -n "$found_images" ]]; then
            echo -e "${GREEN}[OK]${NC} Found kernel image(s):"
            echo "$found_images" | while read img; do
                local size=$(du -h "$img" | cut -f1)
                echo -e "     $img (${size})"
            done
            kernel_path=$(echo "$found_images" | head -n1)
        else
            echo -e "${RED}[ERROR]${NC} No kernel image found in ${BUILD_DIR}/arch/${ARCH}/boot/"
            echo "Available files:"
            ls -la "${BUILD_DIR}/arch/${ARCH}/boot/" 2>/dev/null || echo "Boot directory not found"
            exit 1
        fi
    fi
    
    # Check for KSUN integration in kernel
    if [[ -n "$kernel_path" ]]; then
        if strings "$kernel_path" | grep -qi "kernelsu\|ksu"; then
            echo -e "${GREEN}[OK]${NC} KernelSU integration verified in kernel image"
        else
            echo -e "${YELLOW}[WARNING]${NC} KernelSU strings not found in kernel image"
        fi
    fi
    
    # Check for modules
    local module_count=$(find "${BUILD_DIR}" -name "*.ko" 2>/dev/null | wc -l)
    if [[ ${module_count} -gt 0 ]]; then
        echo -e "${GREEN}[OK]${NC} Built ${module_count} kernel modules"
    fi
    
    # Check for dtb/dtbo files
    if [[ -d "${BUILD_DIR}/arch/${ARCH}/boot/dts" ]]; then
        local dtb_count=$(find "${BUILD_DIR}/arch/${ARCH}/boot/dts" -name "*.dtb" -o -name "*.dtbo" 2>/dev/null | wc -l)
        if [[ ${dtb_count} -gt 0 ]]; then
            echo -e "${GREEN}[OK]${NC} Built ${dtb_count} device tree files"
        fi
    fi
}

show_ccache_stats() {
    echo -e "${BLUE}[INFO]${NC} ccache statistics:"
    ccache -s
}

create_flashable_zip() {
    echo -e "${YELLOW}[INFO]${NC} Creating flashable package..."
    
    local output_dir="${KERNEL_DIR}/output"
    local ak3_dir="${HOME}/works/AnyKernel3"
    
    # Find the built kernel image
    local kernel_images=(
        "${BUILD_DIR}/arch/${ARCH}/boot/Image.lz4-dtb"
        "${BUILD_DIR}/arch/${ARCH}/boot/Image.gz-dtb"
        "${BUILD_DIR}/arch/${ARCH}/boot/Image-dtb"
        "${BUILD_DIR}/arch/${ARCH}/boot/Image.lz4"
        "${BUILD_DIR}/arch/${ARCH}/boot/Image.gz"
        "${BUILD_DIR}/arch/${ARCH}/boot/Image"
    )
    
    local kernel_path=""
    for img in "${kernel_images[@]}"; do
        if [[ -f "$img" ]]; then
            kernel_path="$img"
            break
        fi
    done
    
    # If still not found, search
    if [[ -z "$kernel_path" ]]; then
        kernel_path=$(find "${BUILD_DIR}/arch/${ARCH}/boot" -name "Image*" -type f 2>/dev/null | head -n1)
    fi
    
    if [[ -z "$kernel_path" ]] || [[ ! -f "$kernel_path" ]]; then
        echo -e "${RED}[ERROR]${NC} Could not find kernel image"
        return 1
    fi
    
    # Create output directory
    mkdir -p "${output_dir}"
    
    # Copy kernel image
    local img_name=$(basename "$kernel_path")
    if [[ "$kernel_path" != "${output_dir}/${img_name}" ]]; then
        cp "$kernel_path" "${output_dir}/"
        echo -e "${GREEN}[OK]${NC} Kernel image copied to: ${output_dir}/${img_name}"
    else
        echo -e "${YELLOW}[INFO]${NC} Skipping copy (source and destination are the same)"
    fi
    
    # Copy dtb/dtbo files if they exist
    if [[ -d "${BUILD_DIR}/arch/${ARCH}/boot/dts" ]]; then
        find "${BUILD_DIR}/arch/${ARCH}/boot/dts" -name "*.dtb" -o -name "*.dtbo" 2>/dev/null | while read dtb; do
            cp "$dtb" "${output_dir}/" 2>/dev/null
        done
    fi
    
    # Copy build info
    cat > "${output_dir}/build_info.txt" << EOF
Kernel: ${KERNEL_NAME}
Device: Pixel 3 (blueline) / Pixel 3 XL (crosshatch)
Build Date: $(date)
Features: KernelSU-Next + SUSFS
Defconfig: ${DEFCONFIG}
Kernel Image: $(basename "$kernel_path")
Build Directory: ${BUILD_DIR}
EOF
    
    echo -e "${GREEN}[OK]${NC} Build package ready in: ${output_dir}/"
    
    # Create AnyKernel3 flashable ZIP if AK3 directory exists
    if [[ -d "${ak3_dir}" ]]; then
        echo -e "${YELLOW}[INFO]${NC} Creating AnyKernel3 flashable ZIP..."
        
        # Copy kernel to AK3 directory
        cp "$kernel_path" "${ak3_dir}/Image.lz4-dtb"
        
        # Create ZIP filename with date
        local zip_name="KSUN-SUSFS-b1c1-$(date +%Y%m%d-%H%M).zip"
        
        # Create the flashable ZIP
        cd "${ak3_dir}"
	zip -r9 "${output_dir}/${zip_name}" * \
	    -x .git .gitignore README.md *placeholder .gitattributes "${output_dir}/*" "*.zip" \
	    >/dev/null
	cd - >/dev/null
        
        if [[ -f "${output_dir}/${zip_name}" ]]; then
            local zip_size=$(du -h "${output_dir}/${zip_name}" | cut -f1)
            echo -e "${GREEN}[OK]${NC} Flashable ZIP created: ${zip_name} (${zip_size})"
            echo -e "${BLUE}[INFO]${NC} Flash via TWRP: adb push output/${zip_name} /sdcard/"
        else
            echo -e "${YELLOW}[WARNING]${NC} Failed to create AnyKernel3 ZIP"
        fi
    else
        echo -e "${YELLOW}[WARNING]${NC} AnyKernel3 not found at ${ak3_dir}"
        echo -e "${BLUE}[INFO]${NC} Clone it with: git clone https://github.com/kernel-build-from-rainyland/AnyKernel3.git ${ak3_dir}"
    fi
    
    echo -e "${BLUE}[INFO]${NC} Output directory contents:"
    ls -lh "${output_dir}/"
}

# =============================================================================
# Main execution
# =============================================================================

main() {
    local doclean=0
    for arg in "$@"; do
        [[ "$arg" == "--clean" ]] && doclean=1
    done

    print_banner
    
    # Pre-build checks
    check_dependencies
    setup_ccache
    check_toolchain
    check_kernel_source
    
    # Build process
    if [[ $doclean -eq 1 ]]; then
        clean_build
    else
        echo -e "${YELLOW}[INFO]${NC} Skipping clean build (incremental mode)"
    fi
    configure_kernel
    build_kernel
    
    # Post-build
    verify_build
    show_ccache_stats
    create_flashable_zip
    
    echo -e "${GREEN}"
    echo "============================================================"
    echo "  BUILD COMPLETED SUCCESSFULLY!"
    echo "============================================================"
    echo -e "${NC}"
    echo -e "Kernel image: ${BUILD_DIR}/arch/${ARCH}/boot/Image.lz4-dtb"
    echo -e "Build log: ${BUILD_DIR}/build.log"
    echo -e "Output package: ${KERNEL_DIR}/output/"
    echo ""
    echo -e "${YELLOW}Next steps:${NC}"
    echo "1. Boot into recovery (TWRP or similar) and flash the ZIP:"
    echo "   adb push output/KSUN-SUSFS-b1c1-*.zip /sdcard/"
    echo "   Then install from recovery."
    echo "2. Or repack into a boot.img using AnyKernel3 if you need fastboot flashing."
}

# Run main function
main "$@"
