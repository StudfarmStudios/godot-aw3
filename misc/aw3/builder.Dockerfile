# AW3 wasm builder image — everything needed to run the two-pass AOT web
# export of the AW3 game client in CI (see aw3 repo,
# docs/gameclient/web-csharp-export.md for the full story):
#
#   pass 1: headless editor export  — publishes game C# for browser-wasm,
#           leaving AOT objects in .godot/mono/temp/.../for-publish
#   pass 2: scons relink of the web template against those objects
#           (mono_aot_dir feeds them in as sources, not LINKFLAGS)
#   swap:   the relinked godot.wasm/godot.js replace index.wasm/index.js in
#           the export — a third export pass would regenerate the AOT objects
#           and desync them from the pck's assemblies
#
# The image carries the engine SOURCE with a warm web object tree, so pass 2
# is an incremental compile+link (minutes), not a from-scratch engine build
# (hours). That warmth is the whole point of baking the engine in; the cost is
# an image of several GB.
#
# Build from the repo root:
#   docker build -f misc/aw3/builder.Dockerfile -t aw3-wasm-builder .
# The aw3 repo's web-build workflow runs `aw3-build-web <aw3 checkout>`.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential scons pkg-config python3 git ca-certificates \
    curl unzip zip xz-utils glslang-tools \
    libx11-dev libxcursor-dev libxrandr-dev libxinerama-dev libxi-dev \
    libgl1-mesa-dev libglu1-mesa-dev libasound2-dev libpulse-dev \
    libudev-dev libdbus-1-dev libfontconfig-dev libspeechd-dev \
    && rm -rf /var/lib/apt/lists/*

# emsdk, pinned: the emdawnwebgpu port and wasm threading behavior are
# version-sensitive (built and shipped against 4.0.20).
ARG EMSDK_VERSION=4.0.20
RUN git clone --depth 1 https://github.com/emscripten-core/emsdk /opt/emsdk \
    && /opt/emsdk/emsdk install ${EMSDK_VERSION} \
    && /opt/emsdk/emsdk activate ${EMSDK_VERSION}

# .NET 9 SDK + wasm-tools workload — the AOT publish runs through it. The
# GODOT_DOTNET_EXE override is how GodotTools finds it (PATH alone is not
# honored by the editor's DotNetFinder).
RUN curl -sSL https://dot.net/v1/dotnet-install.sh | bash -s -- \
      --channel 9.0 --install-dir /opt/dotnet \
    && DOTNET_ROOT=/opt/dotnet /opt/dotnet/dotnet workload install wasm-tools
ENV DOTNET_ROOT=/opt/dotnet \
    GODOT_DOTNET_EXE=/opt/dotnet/dotnet \
    PATH="/opt/dotnet:${PATH}"

# Engine source. .dockerignore keeps .git and local build artifacts out.
COPY . /engine
WORKDIR /engine

# Linux editor (headless use only — it runs the export), mono glue, and the
# fork's Godot.* NuGet packages for the game's restore. The editor's object
# files are pruned afterwards: only the web tree's warmth is worth the bytes.
RUN scons platform=linuxbsd target=editor module_mono_enabled=yes debug_symbols=no -j"$(nproc)" \
    && ./bin/godot.linuxbsd.editor.x86_64.mono --headless --generate-mono-glue modules/mono/glue \
    && python3 modules/mono/build_scripts/build_assemblies.py \
         --godot-output-dir=./bin --push-nupkgs-local /opt/godot-nuget \
    && find . -name "*.linuxbsd.editor*.o" -delete

# Bootstrap web template: no AOT images in it (a configuration the game cannot
# actually run), built to warm the web object tree so the per-build relink is
# incremental. The stack sizes are load-bearing — see web-csharp-export.md.
RUN bash -c 'source /opt/emsdk/emsdk_env.sh && \
    scons platform=web target=template_release module_mono_enabled=yes webgpu=yes \
      stack_size=32768 default_pthread_stack_size=32768 initial_memory=256 -j"$(nproc)"'

RUN ln -s /engine/misc/aw3/build-web.sh /usr/local/bin/aw3-build-web \
    && chmod +x /engine/misc/aw3/build-web.sh
