# Native WebGPU on macOS

Native WebGPU links an external static Dawn SDK. The SDK's presentation fix is
separate from Godot's Metal driver: rebuilding Godot against an old Dawn archive
does not fix WebGPU presentation.

Use Dawn `a082d8e7cb9118e9df5965e63c4ff64e62e5fd14` with
[`patches/0001-metal-schedule-drawable-presentation.patch`](patches/0001-metal-schedule-drawable-presentation.patch).
This backports upstream Dawn
[`6c89318c`](https://github.com/google/dawn/commit/6c89318c3ca666e54bda3c012e9e2c4967ec4fff),
which schedules drawable presentation on a command buffer. The old implementation
called `MTLDrawable.present()` immediately after submission, when GPU writes might
not yet have been scheduled. This can cause corruption or GPU hangs even with
display synchronization enabled. No per-frame CPU wait is needed with the patch.

The older SDK revision is retained for compatibility with this fork's WebGPU C API
and its 48-sampled-textures binding tier. Do not replace the SDK with current Dawn
without checking API and Tint compatibility.

## Build the SDK

From this engine checkout, set `DAWN_SOURCE` to a local Dawn checkout. Apply the
patch before compiling and installing; changing source alone does not replace the
archive linked into Godot. Reuse an existing checkout and its dependencies when
available.

```sh
export DAWN_SOURCE=/absolute/path/to/dawn-native
git -C "$DAWN_SOURCE" checkout a082d8e7cb9118e9df5965e63c4ff64e62e5fd14
git -C "$DAWN_SOURCE" apply --check "$PWD/misc/native-webgpu/patches/0001-metal-schedule-drawable-presentation.patch"
git -C "$DAWN_SOURCE" apply "$PWD/misc/native-webgpu/patches/0001-metal-schedule-drawable-presentation.patch"

cmake -S "$DAWN_SOURCE" -B "$DAWN_SOURCE/out/Release" \
  -G "Unix Makefiles" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0 \
  -DDAWN_FETCH_DEPENDENCIES=ON \
  -DDAWN_ENABLE_INSTALL=ON \
  -DDAWN_BUILD_MONOLITHIC_LIBRARY=STATIC \
  -DBUILD_SHARED_LIBS=OFF \
  -DDAWN_ENABLE_METAL=ON \
  -DDAWN_ENABLE_VULKAN=OFF \
  -DDAWN_ENABLE_DESKTOP_GL=OFF \
  -DDAWN_ENABLE_OPENGLES=OFF \
  -DDAWN_ENABLE_NULL=OFF \
  -DDAWN_USE_GLFW=OFF \
  -DDAWN_BUILD_SAMPLES=OFF \
  -DDAWN_BUILD_TESTS=OFF \
  -DDAWN_BUILD_NODE_BINDINGS=OFF \
  -DDAWN_BUILD_PROTOBUF=OFF \
  -DTINT_BUILD_CMD_TOOLS=OFF \
  -DTINT_BUILD_TESTS=OFF
cmake --build "$DAWN_SOURCE/out/Release" --target webgpu_dawn -j10
cmake --install "$DAWN_SOURCE/out/Release" --prefix "$DAWN_SOURCE/install/Release"
```

For an already-patched checkout, `git apply --reverse --check` with the same patch
verifies its presence; skip the two apply commands above. When dependencies are
already present, configure with `DAWN_FETCH_DEPENDENCIES=OFF` to avoid fetching
them again.

## Build and run Godot

```sh
scons platform=macos target=editor arch=arm64 module_mono_enabled=yes \
  accesskit=no angle=no webgpu=yes \
  dawn_sdk_path="$DAWN_SOURCE/install/Release" -j10

bin/godot.macos.editor.arm64.mono --path /absolute/path/to/game \
  --rendering-driver webgpu --rendering-method forward_plus --windowed
```

The same SDK supports `target=template_release`. Both the SDK and the linked
editor/export templates must be rebuilt or replaced when applying the patch.
The SDK is per-architecture; an x86_64 template needs an x86_64 Dawn build.
This pinned SDK requires macOS 12 or newer.

For presentation checks, maximize the ordinary window and verify its actual
viewport size. A launch resolution can describe backing pixels rather than the
physical window size on mixed-density macOS desktops. Keep runtime diagnostics
such as `DYLD_INSERT_LIBRARIES` presentation observers out of final builds.
