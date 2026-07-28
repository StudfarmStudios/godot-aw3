#!/usr/bin/env bash
# Two-pass AOT web export of the AW3 client, run inside the aw3-wasm-builder
# image (see builder.Dockerfile for why the passes exist).
#
#   aw3-build-web /path/to/aw3-checkout
#
# Produces <aw3>/gameclient/builds/web/ ready for tools/webhost/deploy.sh.
set -euo pipefail

AW3_DIR="${1:?usage: aw3-build-web <aw3 repo dir>}"
GAME="$AW3_DIR/gameclient"
ENGINE=/engine
EDITOR="$ENGINE/bin/godot.linuxbsd.editor.x86_64.mono"
TEMPLATE="$ENGINE/bin/godot.web.template_release.wasm32.mono.zip"

[[ -x "$EDITOR" ]] || { echo "editor missing at $EDITOR" >&2; exit 1; }
[[ -f "$TEMPLATE" ]] || { echo "web template missing at $TEMPLATE" >&2; exit 1; }

# NuGet must resolve the fork's Godot.* packages. The file is gitignored in
# the aw3 repo (developer machines point it at their own fork checkout), so CI
# always writes its own.
cat > "$GAME/nuget.config" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <add key="GodotForkLocal" value="/opt/godot-nuget" />
  </packageSources>
</configuration>
EOF

# The committed Web preset carries a developer-machine template path — point
# both slots at this image's template instead.
sed -i "s#^custom_template/debug=.*#custom_template/debug=\"$TEMPLATE\"#; s#^custom_template/release=.*#custom_template/release=\"$TEMPLATE\"#" \
    "$GAME/export_presets.cfg"

echo "== import (fresh checkout has no .godot cache) =="
# Without this the export packs unresolved UIDs / missing ctex and the game
# boots into placeholder content — the classic stale-import trap.
(cd "$GAME" && "$EDITOR" --headless --path . --import)

echo "== pass 1: export (publishes C#, emits AOT objects) =="
mkdir -p "$GAME/builds/web"
(cd "$GAME" && "$EDITOR" --headless --path . --export-release "Web" builds/web/index.html)

AOT_DIR="$GAME/.godot/mono/temp/obj/ExportRelease/browser-wasm/wasm/for-publish"
if [[ ! -f "$AOT_DIR/AssaultWing.dll.o" ]]; then
    echo "AOT objects missing under $AOT_DIR — the publish failed silently;" >&2
    echo "check the msbuild logs under ~/.local/share/godot/mono/build_logs" >&2
    exit 1
fi

echo "== pass 2: relink engine template against the AOT objects =="
source /opt/emsdk/emsdk_env.sh
(cd "$ENGINE" && scons platform=web target=template_release module_mono_enabled=yes webgpu=yes \
    stack_size=32768 default_pthread_stack_size=32768 initial_memory=256 \
    mono_aot_dir="$AOT_DIR" -j"$(nproc)")

echo "== swap relinked engine into the export =="
SWAP_TMP="$(mktemp -d)"
unzip -oq "$TEMPLATE" -d "$SWAP_TMP"
cp "$SWAP_TMP/godot.wasm" "$GAME/builds/web/index.wasm"
cp "$SWAP_TMP/godot.js"   "$GAME/builds/web/index.js"
rm -rf "$SWAP_TMP"

echo "== done =="
ls -la "$GAME/builds/web/"
