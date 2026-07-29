#!/bin/bash
# Build a Godot export template from this tree using the SDL platform port
# (KMS/DRM capable, arm64 or x86_64, .NET enabled by default).
#
# Run build-sdl3.sh first (its install prefix is picked up automatically),
# or point SDL3_PREFIX at an existing static SDL3 install / use the distro's
# libsdl3-dev.
#
# This is a thin wrapper around the scons invocation - see the "Building"
# section of platform/sdl/README.md if you want to drive scons directly.
#
# Knobs (env vars):
#   ARCH        - target arch: arm64 | x86_64 (default: host arch)
#   TARGET      - template_release | template_debug (default: release)
#   WITH_MONO   - yes|no, .NET support for the C# game (default: yes)
#   PRODUCTION  - yes|no, full optimizations + LTO (default: yes)
#   SDL3_PREFIX - static SDL3 install prefix (default: from build-sdl3.sh)
#   EXTRA_SCONS - extra scons arguments
#
# Cross-compiling x86_64 -> arm64 needs g++-aarch64-linux-gnu and an arm64
# SDL3 (build it with build-sdl3.sh under an arm64 toolchain/sysroot, or
# just run everything natively on the device / in an arm64 container).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

ARCH="${ARCH:-$( [ "$(uname -m)" = "aarch64" ] && echo arm64 || echo x86_64 )}"
TARGET="${TARGET:-template_release}"
WITH_MONO="${WITH_MONO:-yes}"
PRODUCTION="${PRODUCTION:-yes}"

if [ -z "${SDL3_PREFIX:-}" ]; then
    for candidate in "$REPO_ROOT/tmp/sdl3-prefix-$(uname -m)" "$REPO_ROOT"/tmp/sdl3-prefix-*; do
        if [ -d "$candidate/lib/pkgconfig" ]; then
            SDL3_PREFIX="$candidate"
            break
        fi
    done
fi

SCONS_ARGS=(
    platform=sdl
    target="$TARGET"
    arch="$ARCH"
    static_sdl=yes
    module_mono_enabled="$WITH_MONO"
    production="$PRODUCTION"
    progress=no
)

if [ "$ARCH" = "arm64" ] && [ "$(uname -m)" != "aarch64" ]; then
    SCONS_ARGS+=(CC=aarch64-linux-gnu-gcc CXX=aarch64-linux-gnu-g++)
fi

cd "$REPO_ROOT"
if [ -n "${SDL3_PREFIX:-}" ]; then
    export PKG_CONFIG_PATH="$SDL3_PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
fi
# shellcheck disable=SC2086
scons "${SCONS_ARGS[@]}" ${EXTRA_SCONS:-} -j"$(nproc)"

BIN=$(ls -t "$REPO_ROOT"/bin/godot.sdl.* | head -1)
echo
echo "Export template built: $BIN"
echo
echo "Use it from the Godot editor's Linux export preset:"
echo "  - Architecture: $ARCH"
echo "  - Custom Template -> Release: $BIN"
echo "See platform/sdl/README.md for device setup and runtime flags."
