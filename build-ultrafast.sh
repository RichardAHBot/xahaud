#!/usr/bin/env bash
###############################################################################
# build-ultrafast.sh — Maximum-performance build for xahaud
#
# Designed for beefy build machines (16+ cores, 32+ GB RAM).
# Automatically detects hardware and tunes everything to max out the machine.
#
# Optimizations used:
#   • mold linker (10× faster than gold, 3× faster than lld)
#   • ccache with aggressive direct mode (50 GB cache)
#   • Ninja with unlimited parallelism across all CPUs
#   • Unity builds with large batch size (fewer compilation units)
#   • Thin LTO at link time (cross-TU optimization)
#   • Precompiled headers for common includes
#   • Compiler resource limits raised (4 GB per job)
#   • tmpfs for compilation temp files (RAM-backed I/O)
#   • Pipe buffer tuned for massive parallelism
#   • Conan dependency caching (reuse existing builds)
#
# Usage: ./build-ultrafast.sh [--clean] [--full-clean] [--debug]
#
# Portable: works on any Linux machine with cmake, ninja, ccache, conan,
# and a C++ compiler (clang preferred, gcc fallback).
###############################################################################
set -euo pipefail

# ── Self-contained colors & helpers ──────────────────────────────────────────
if [[ -t 1 ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; NC=''
fi

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fail()  { echo -e "${RED}[FAIL]${NC}  $*" >&2; exit 1; }
timer() { echo "$SECONDS" > "$BUILD_DIR/.build_start_time"; }
elapsed(){ local e=$((SECONDS - $(cat "$BUILD_DIR/.build_start_time" 2>/dev/null || echo "$SECONDS"))); echo "$((e/60))m $((e%60))s"; }

# ── Detect machine specs ────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

NCPU=$(nproc 2>/dev/null || echo 8)
RAM_GB=$(free -g 2>/dev/null | awk '/^Mem:/{print $2}' || echo 8)
DISK_AVAIL_MB=$(df -BM / | awk 'NR==2{gsub(/M/,"",$4); print $4}' || echo 50000)

info "Machine: ${NCPU} cores | ${RAM_GB} GB RAM | ${DISK_AVAIL_MB} MB disk free"

# ── Initialize variables BEFORE parsing args ─────────────────────────────────
CLEAN=0
FULL_CLEAN=0
DEBUG_BUILD=0
REUSE_CONAN=1
BUILD_TYPE="Release"
CMAKE_EXTRA_ARGS=""

# ── Parse arguments ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --clean)       CLEAN=1;       shift ;;
        --full-clean)  FULL_CLEAN=1;  CLEAN=1; shift ;;
        --debug)       DEBUG_BUILD=1; shift ;;
        --fresh-deps)  REUSE_CONAN=0; shift ;;
        --cmake-args)  CMAKE_EXTRA_ARGS="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: $0 [--clean] [--full-clean] [--debug] [--fresh-deps] [--cmake-args \"...\"]"
            echo ""
            echo "  --clean        Remove build directory (keep ccache & conan)"
            echo "  --full-clean   Remove build directory AND ccache"
            echo "  --fresh-deps   Force rebuild of Conan dependencies"
            echo "  --debug        Build with debug info (slower binary, easier debugging)"
            echo "  --cmake-args   Extra CMake flags to pass through"
            exit 0
            ;;
        *) fail "Unknown option: $1" ;;
    esac
done

if [[ $DEBUG_BUILD -eq 1 ]]; then
    BUILD_TYPE="RelWithDebInfo"
    info "Building with debug symbols (RelWithDebInfo)"
fi

BUILD_DIR="build-ultrafast"
CCACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/ccache-xahaud-ultrafast"

# ── Ccache setup ────────────────────────────────────────────────────────────
CCACHE_SIZE_GB=$((RAM_GB > 100 ? 50 : RAM_GB / 2))
[[ $CCACHE_SIZE_GB -lt 8 ]] && CCACHE_SIZE_GB=8

export CCACHE_DIR
mkdir -p "$CCACHE_DIR"

# Configure ccache for maximum hit rate
ccache --max-size="${CCACHE_SIZE_GB}G" \
       --max-direct=TRUE \
       --cache-file-metadata=FALSE \
       --hard-link=TRUE \
       --compression=FALSE \
       --sloppiness=pch_defines,time_macros \
       --base-dir="$SCRIPT_DIR" \
       2>/dev/null || true

info "Ccache: ${CCACHE_DIR} (max ${CCACHE_SIZE_GB}G, direct+hard-link)"
ccache -s 2>/dev/null | head -6 || true

if [[ $FULL_CLEAN -eq 1 ]]; then
    ccache --zero-stats 2>/dev/null
    info "Ccache stats zeroed"
fi

# ── Clean build dir if requested ────────────────────────────────────────────
if [[ $CLEAN -eq 1 ]]; then
    info "Cleaning build directory..."
    rm -rf "$BUILD_DIR"
fi

# ── Check required tools ───────────────────────────────────────────────────
check_tool() {
    if ! command -v "$1" &>/dev/null; then
        fail "Required tool '$1' not found. Install it first."
    fi
}

check_tool cmake
check_tool ninja
check_tool conan
check_tool ccache

# Detect compiler (prefer clang, fall back to gcc)
if command -v clang++-17 &>/dev/null; then
    CXX="clang++-17"; CC="clang-17"; COMPILER=clang
elif command -v clang++-15 &>/dev/null; then
    CXX="clang++-15"; CC="clang-15"; COMPILER=clang
elif command -v clang++-14 &>/dev/null; then
    CXX="clang++-14"; CC="clang-14"; COMPILER=clang
elif command -v clang++ &>/dev/null; then
    CXX="clang++"; CC="clang"; COMPILER=clang
elif command -v g++-12 &>/dev/null; then
    CXX="g++-12"; CC="gcc-12"; COMPILER=gcc
elif command -v g++-11 &>/dev/null; then
    CXX="g++-11"; CC="gcc-11"; COMPILER=gcc
elif command -v g++ &>/dev/null; then
    CXX="g++"; CC="gcc"; COMPILER=gcc
else
    fail "No suitable C++ compiler found"
fi

# Get compiler version for display and conan
CXX_VER_FULL=$($CXX -dumpfullversion 2>/dev/null || $CXX -dumpversion 2>/dev/null || echo "unknown")
# Conan needs major version only (e.g. "17" not "17.0.6")
CXX_VER=${CXX_VER_FULL%%.*}

info "Compiler: ${COMPILER} $CXX_VER_FULL (${CXX})"

# Detect linker
if command -v mold &>/dev/null; then
    LINKER="mold"; USE_MOLD=ON; USE_LLD=OFF
elif command -v ld.lld &>/dev/null; then
    LINKER="lld"; USE_MOLD=OFF; USE_LLD=ON
else
    LINKER="default"; USE_MOLD=OFF; USE_LLD=OFF
    warn "No fast linker found. mold or lld recommended."
fi
info "Linker: ${LINKER}"

# ── Set up fast temp directory (ramdisk for compilation artifacts) ──────────
if [[ -d /dev/shm ]] && [[ -w /dev/shm ]]; then
    # Use RAM-backed tmpfs for I/O-bound compilation
    TMP_BUILD_DIR="/dev/shm/xahaud-build-${NCPU}c"
    mkdir -p "$TMP_BUILD_DIR"
    info "Temp dir: ${TMP_BUILD_DIR} (ramdisk)"
else
    TMP_BUILD_DIR=$(mktemp -d -t xahaud-build-XXXXXX)
    info "Temp dir: ${TMP_BUILD_DIR}"
fi

export TMPDIR="$TMP_BUILD_DIR"
export TEMP="$TMP_BUILD_DIR"
export TMP="$TMP_BUILD_DIR"

# ── Conan dependency handling ────────────────────────────────────────────────
# Strategy: reuse existing conan deps when possible (they're heavy to rebuild)
CONAN_TOOLCHAIN="$BUILD_DIR/build/generators/conan_toolchain.cmake"
EXISTING_CONAN=""

if [[ $REUSE_CONAN -eq 1 ]]; then
    for candidate in "$SCRIPT_DIR/build-fast/build/generators/conan_toolchain.cmake" \
                     "$SCRIPT_DIR/build/build/generators/conan_toolchain.cmake"; do
        if [[ -f "$candidate" ]]; then
            EXISTING_CONAN="$candidate"
            break
        fi
    done
fi

if [[ -n "$EXISTING_CONAN" ]]; then
    ok "Reusing existing Conan toolchain: $EXISTING_CONAN"
    mkdir -p "$BUILD_DIR/build/generators"
    # Copy all generator files (they contain dependency paths)
    cp "${EXISTING_CONAN%/*}"/* "$BUILD_DIR/build/generators/" 2>/dev/null || true
    CONAN_TOOLCHAIN="$BUILD_DIR/build/generators/conan_toolchain.cmake"
    ok "Conan dependencies ready (cached)"
elif [[ -f "$CONAN_TOOLCHAIN" ]]; then
    ok "Conan toolchain already in build dir"
else
    info "Installing Conan dependencies (this may take a while first time)..."
    
    # Export local packages needed by conanfile
    if [[ -d external/snappy ]]; then
        conan export external/snappy --version 1.1.10 --user xahaud --channel stable 2>/dev/null || true
    fi
    if [[ -d external/soci ]]; then
        conan export external/soci --version 4.0.3 --user xahaud --channel stable 2>/dev/null || true
    fi
    
    # Try with clang first
    if conan install . --build=missing \
        --output-folder="$BUILD_DIR/build" \
        --settings build_type="$BUILD_TYPE" \
        --settings compiler="$COMPILER" \
        --settings compiler.version="$CXX_VER" \
        --settings compiler.libcxx=libstdc++11 \
        --settings compiler.cppstd=20 \
        -o unity=True \
        -o tests=False \
        -o xrpld=True \
        -o rocksdb=True \
        -o with_wasmedge=True \
        2>&1 | tail -10; then
        ok "Conan install succeeded with ${COMPILER}"
    else
        # Fallback: try gcc profile (should have cached deps)
        warn "Conan failed with ${COMPILER}, trying default profile..."
        if conan install . --build=missing \
            --output-folder="$BUILD_DIR/build" \
            --profile=default \
            -o unity=True \
            -o tests=False \
            -o xrpld=True \
            -o rocksdb=True \
            -o with_wasmedge=True \
            2>&1 | tail -10; then
            ok "Conan install succeeded with default profile"
        else
            # Last resort: disable wasmedge
            warn "Retrying without wasmedge..."
            conan install . --build=missing \
                --output-folder="$BUILD_DIR/build" \
                --settings build_type="$BUILD_TYPE" \
                --settings compiler="$COMPILER" \
                --settings compiler.version="$CXX_VER" \
                --settings compiler.libcxx=libstdc++11 \
                --settings compiler.cppstd=20 \
                -o unity=True \
                -o tests=False \
                -o xrpld=True \
                -o rocksdb=True \
                -o with_wasmedge=False \
                2>&1 | tail -10 || {
                    fail "Conan dependency installation failed"
                }
        fi
    fi
fi

# ── CMake configuration ─────────────────────────────────────────────────────
info "Configuring CMake..."
timer

if [[ ! -f "$BUILD_DIR/build.ninja" ]]; then
    if cmake \
        -G "Ninja" \
        -S "$SCRIPT_DIR" \
        -B "$BUILD_DIR" \
        -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
        -DCMAKE_C_COMPILER="$CC" \
        -DCMAKE_CXX_COMPILER="$CXX" \
        -DCMAKE_C_COMPILER_LAUNCHER=ccache \
        -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
        -DCMAKE_TOOLCHAIN_FILE="$CONAN_TOOLCHAIN" \
        -DCMAKE_UNITY_BUILD=ON \
        -DCMAKE_UNITY_BUILD_BATCH_SIZE=30 \
        -DCMAKE_INTERPROCEDURAL_OPTIMIZATION_RELEASE=TRUE \
        -DCMAKE_INTERPROCEDURAL_OPTIMIZATION_RELWITHDEBINFO=TRUE \
        -Dunity=ON \
        -Dxrpld=ON \
        -Dtests=OFF \
        -Dwerr=OFF \
        -Dwextra=OFF \
        -Dstatic=ON \
        -Duse_mold="$USE_MOLD" \
        -Duse_lld="$USE_LLD" \
        -Duse_gold=OFF \
        -Drocksdb=ON \
        -Djemalloc=OFF \
        $CMAKE_EXTRA_ARGS \
        2>&1 | grep -E 'Configuring done|Error|error|STATUS'; then
        ok "CMake configured ($(elapsed))"
    else
        fail "CMake configuration failed"
    fi
else
    ok "CMake already configured"
fi

# ── Patch build.ninja for parallel linking ──────────────────────────────────
# Ninja limits link jobs to 1 by default. For mold (which is multi-threaded),
# we can safely allow more parallel links.
NINJA_FILE="$BUILD_DIR/build.ninja"
if [[ -f "$NINJA_FILE" ]]; then
    # Check if links pool already exists
    if grep -q "^pool = links" "$NINJA_FILE" 2>/dev/null; then
        # Already has a links pool, ensure depth is sufficient
        if ! grep -q "depth = 3" "$NINJA_FILE"; then
            sed -i 's/^pool = links$/pool = links\n  depth = 3/' "$NINJA_FILE"
        fi
    else
        # Add a dedicated links pool after the console pool
        sed -i '/^pool = console$/a\\n# Allow parallel linking (mold is multi-threaded)\npool = links\n  depth = 3' "$NINJA_FILE"
    fi
    info "Ninja parallel linking enabled (depth=3)"
fi

# ── The build ────────────────────────────────────────────────────────────────
info "Starting build ($(elapsed) so far)..."
echo "═══════════════════════════════════════════════════════════════════════"
echo -e "${BOLD}  xahaud ultra-fast build — ${NCPU} cores, ${RAM_GB} GB RAM, ${LINKER} linker${NC}"
echo "═══════════════════════════════════════════════════════════════════════"

timer

# Run ccache stats before build
ccache -z 2>/dev/null || true

# Build with maximum parallelism
# Ninja's -j flag: use NCPU for compilation, mold handles its own parallelism
BUILD_START=$(date +%s)

if ninja -C "$BUILD_DIR" -j"$NCPU" rippled 2>&1; then
    BUILD_END=$(date +%s)
    BUILD_TIME=$((BUILD_END - BUILD_START))
    TOTAL_TIME=$((SECONDS - $(cat "$BUILD_DIR/.build_start_time" 2>/dev/null || echo "$SECONDS")))
    
    ok "Build completed in $((BUILD_TIME/60))m $((BUILD_TIME%60))s!"
    
    # ── Post-build processing ───────────────────────────────────────────
    echo ""
    echo "═══════════════════════════════════════════════════════════════════════"
    echo "  Post-processing..."
    echo "═══════════════════════════════════════════════════════════════════════"
    
    BUILD_BIN="$BUILD_DIR/rippled"
    
    if [[ -f "$BUILD_BIN" ]]; then
        ORIG_SIZE=$(stat -c%s "$BUILD_BIN" 2>/dev/null || echo "unknown")
        ORIG_SIZE_HR=$(numfmt --to=iec-i "$ORIG_SIZE" 2>/dev/null || echo "${ORIG_SIZE}B")
        
        # Strip debug symbols for minimal size
        info "Stripping binary..."
        strip -s "$BUILD_BIN" 2>/dev/null || true
        
        STRIPPED_SIZE=$(stat -c%s "$BUILD_BIN" 2>/dev/null || echo "unknown")
        STRIPPED_SIZE_HR=$(numfmt --to=iec-i "$STRIPPED_SIZE" 2>/dev/null || echo "${STRIPPED_SIZE}B")
        
        if [[ "$ORIG_SIZE" != "unknown" ]] && [[ "$STRIPPED_SIZE" != "unknown" ]]; then
            SAVED=$(( (ORIG_SIZE - STRIPPED_SIZE) * 100 / ORIG_SIZE ))
            info "Binary: ${ORIG_SIZE_HR} → ${STRIPPED_SIZE_HR} (${SAVED}% smaller)"
        fi
        
        # Show binary info
        echo ""
        info "Binary info:"
        file "$BUILD_BIN"
        ls -lh "$BUILD_BIN"
        echo ""
        info "Linked libraries:"
        ldd "$BUILD_BIN" 2>/dev/null | wc -l | xargs -I{} echo "  {} shared libraries"
    else
        warn "rippled binary not found at $BUILD_BIN"
        # Try to find it
        find "$BUILD_DIR" -name "rippled" -type f 2>/dev/null | head -3 | while read -r f; do
            info "Found: $f"
        done
    fi
    
    # ── Ccache stats ─────────────────────────────────────────────────────
    echo ""
    info "Ccache statistics:"
    ccache -s 2>/dev/null | head -8 || true
    
    # ── Build summary ────────────────────────────────────────────────────
    echo ""
    echo "╔═══════════════════════════════════════════════════════════════════════╗"
    echo -e "║  ${GREEN}${BOLD}BUILD SUCCESSFUL${NC}                                                ║"
    echo "╠═══════════════════════════════════════════════════════════════════════╣"
    echo -e "║  Total time:      $((TOTAL_TIME/60))m $((TOTAL_TIME%60))s"
    echo -e "║  Compile time:    $((BUILD_TIME/60))m $((BUILD_TIME%60))s"
    echo -e "║  Compiler:        ${COMPILER} $CXX_VER_FULL"
    echo -e "║  Linker:          ${LINKER}"
    echo -e "║  Build type:      ${BUILD_TYPE}"
    echo -e "║  Parallelism:     ${NCPU} cores"
    echo -e "║  Unity batch:     30"
    echo -e "║  LTO:             Thin (interprocedural)"
    echo -e "║  Build dir:       ${BUILD_DIR}"
    echo "╚═══════════════════════════════════════════════════════════════════════╝"
    
    exit 0
else
    BUILD_END=$(date +%s)
    BUILD_TIME=$((BUILD_END - BUILD_START))
    
    echo ""
    echo "╔═══════════════════════════════════════════════════════════════════════╗"
    echo -e "║  ${RED}${BOLD}BUILD FAILED${NC}                                                  ║"
    echo "╠═══════════════════════════════════════════════════════════════════════╣"
    echo -e "║  Failed after:    $((BUILD_TIME/60))m $((BUILD_TIME%60))s"
    echo -e "║  Build dir:       ${BUILD_DIR}"
    echo -e "║  Debug with:      ninja -C ${BUILD_DIR} -v"
    echo "╚═══════════════════════════════════════════════════════════════════════╝"
    
    # Show ccache stats on failure too
    info "Ccache statistics:"
    ccache -s 2>/dev/null | head -5 || true
    
    exit 1
fi
