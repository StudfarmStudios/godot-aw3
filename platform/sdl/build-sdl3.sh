#!/bin/bash
# Build a static SDL3 with KMS/DRM support, for linking into the SDL platform
# templates (see build-template.sh).
#
# Run natively on the target architecture (device, arm64 VM, or docker
# via e.g. `docker run --platform linux/arm64`). Cross-compiling works too:
# set CMAKE_TOOLCHAIN_FILE or CC to a cross toolchain and make the target's
# dev libraries visible (Debian/Ubuntu multiarch: libdrm-dev:arm64 etc.).
#
# Knobs (env vars):
#   SDL3_VERSION  - release to build (default: latest on libsdl.org)
#   PREFIX        - install prefix (default: <repo>/tmp/sdl3-prefix-<arch>)
#   WORKDIR       - build dir (default: <repo>/tmp/sdl3-build)
#
# Build-time dependencies (Debian/Ubuntu package names):
#   cmake ninja-build pkg-config build-essential
#   libdrm-dev libgbm-dev libegl1-mesa-dev libgles-dev   (KMS/DRM video)
#   libasound2-dev [libpulse-dev] [libpipewire-0.3-dev]  (audio)
#   [libudev-dev]                                        (joypad hotplug)
#   [libx11-dev ... / libwayland-dev ...]  (optional; makes the same binary
#                                           also run on desktop sessions)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ARCH_TAG="$(uname -m)"
WORKDIR="${WORKDIR:-$REPO_ROOT/tmp/sdl3-build}"
PREFIX="${PREFIX:-$REPO_ROOT/tmp/sdl3-prefix-$ARCH_TAG}"

mkdir -p "$WORKDIR"
cd "$WORKDIR"

if [ -z "${SDL3_VERSION:-}" ]; then
    TARBALL=$(curl -sSL https://www.libsdl.org/release/ | grep -o 'SDL3-3\.[0-9]*\.[0-9]*\.tar\.gz' | sort -uV | tail -1)
    [ -n "$TARBALL" ] || { echo "Could not determine latest SDL3 release." >&2; exit 1; }
else
    TARBALL="SDL3-$SDL3_VERSION.tar.gz"
fi

echo "Building $TARBALL -> $PREFIX"
[ -f "$TARBALL" ] || curl -fsSL -o "$TARBALL" "https://www.libsdl.org/release/$TARBALL"
SRC_DIR="${TARBALL%.tar.gz}"
[ -d "$SRC_DIR" ] || tar xzf "$TARBALL"

cmake -S "$SRC_DIR" -B build -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DSDL_SHARED=OFF -DSDL_STATIC=ON \
    -DSDL_KMSDRM=ON \
    -DSDL_UNIX_CONSOLE_BUILD=ON \
    -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF -DSDL_TEST_LIBRARY=OFF
cmake --build build -j"$(nproc)"
cmake --install build >/dev/null

echo
echo "SDL3 installed to $PREFIX"
echo "Enabled video drivers are listed in the summary above - make sure 'kmsdrm' is among them."
echo "Next: SDL3_PREFIX=$PREFIX platform/sdl/build-template.sh"
