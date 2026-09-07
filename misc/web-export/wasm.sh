#!/usr/bin/env bash
# godot-aw3 web export: add AOT-compiled C# + WebGPU web support to a Godot 4.7
# C# game, using this engine fork. Idempotent, non-interactive, meant to be run
# by a person or an agent from a checkout of the fork.
#
#   misc/web-export/wasm.sh toolchain            emsdk + .NET 9 (wasm-tools) under $WASM_HOME
#   misc/web-export/wasm.sh engine               editor, C# glue + GodotSharp nupkgs, bootstrap web template
#   misc/web-export/wasm.sh prepare <game-dir>   nuget.config, csproj import, entry stub, .sln, project.godot, Web preset
#   misc/web-export/wasm.sh export  <game-dir>   two-pass export (publish -> relink template -> swap) into <game>/builds/web
#   misc/web-export/wasm.sh serve   <game-dir> [port]   local COOP/COEP server for the export
#   misc/web-export/wasm.sh doctor  [game-dir]   report toolchain / engine / project state and stale artifacts
#   misc/web-export/wasm.sh all     <game-dir>   toolchain + engine + prepare + export
#
# Environment (all optional):
#   WASM_HOME         where toolchains go            (default ~/.godot-aw3)
#   EMSDK_DIR         emsdk checkout                 (default $WASM_HOME/emsdk)
#   DOTNET_DIR        .NET 9 SDK with wasm-tools     (default $WASM_HOME/dotnet9)
#   ENGINE_DIR        the godot-aw3 checkout         (default: the repo this script lives in)
#   AOT_MODE          LLVMOnlyInterp | LLVMOnly      (default LLVMOnlyInterp; see prepare)
#   RENDERING_METHOD  forward_plus | mobile          (default forward_plus; either selects WebGPU)
#   CSPROJ            the game's .csproj, when the game dir holds more than one
#   PRESET            export preset name             (default Web)
#   JOBS              parallel jobs for scons
#   FORCE=1           rebuild engine artifacts even if present
#
# Why the export is two passes: the AOT images are linked into the ENGINE
# template, not into the game's pck, so the template is game-specific. Pass 1
# publishes the C# and leaves .o files behind; pass 2 relinks the template with
# them; the relinked engine is then copied over the export. Repeat all of it
# whenever game C# changes. Details: AW3's docs/gameclient/web-csharp-export.md.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_DIR="${ENGINE_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
WASM_HOME="${WASM_HOME:-$HOME/.godot-aw3}"
EMSDK_DIR="${EMSDK_DIR:-$WASM_HOME/emsdk}"
DOTNET_DIR="${DOTNET_DIR:-$WASM_HOME/dotnet9}"
EMSDK_VERSION="${EMSDK_VERSION:-4.0.20}"
AOT_MODE="${AOT_MODE:-LLVMOnlyInterp}"
RENDERING_METHOD="${RENDERING_METHOD:-forward_plus}"
PRESET="${PRESET:-Web}"
FORCE="${FORCE:-0}"

# The template flags. The bootstrap and the per-game relink MUST use the same
# set, or scons rebuilds the engine from scratch instead of relinking. The
# stack sizes are not optional (Mono frames blow the default 2 MB pthread
# stack with no message at all), and webgpu=yes is what makes the renderer.
TEMPLATE_FLAGS="platform=web target=template_release module_mono_enabled=yes webgpu=yes stack_size=32768 default_pthread_stack_size=32768 initial_memory=256 optimize=speed lto=thin"

case "$(uname -s)" in
    Darwin) HOST_PLATFORM=macos ;;
    Linux)  HOST_PLATFORM=linuxbsd ;;
    *) echo "unsupported host $(uname -s)" >&2; exit 1 ;;
esac
# uname -m lies under Rosetta (an x86_64 bash on Apple Silicon says x86_64);
# ask the hardware instead so we build and look for the native arm64 binaries.
MACHINE="$(uname -m)"
if [[ "$HOST_PLATFORM" == macos && "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" == 1 ]]; then
    MACHINE=arm64
fi
case "$MACHINE" in
    arm64|aarch64) HOST_ARCH=arm64; DOTNET_ARCH=arm64 ;;
    x86_64|amd64)  HOST_ARCH=x86_64; DOTNET_ARCH=x64 ;;
    *) echo "unsupported arch $MACHINE" >&2; exit 1 ;;
esac
JOBS="${JOBS:-$( (sysctl -n hw.ncpu 2>/dev/null || nproc) )}"

EDITOR_BIN="$ENGINE_DIR/bin/godot.$HOST_PLATFORM.editor.$HOST_ARCH.mono"
TEMPLATE_ZIP="$ENGINE_DIR/bin/godot.web.template_release.wasm32.mono.zip"
NUPKGS="$ENGINE_DIR/bin/GodotSharp/Tools/nupkgs"
GODOTSHARP_DLL="$ENGINE_DIR/bin/GodotSharp/Api/Release/GodotSharp.dll"
if [[ "$HOST_PLATFORM" == macos ]]; then
    BUILD_LOGS="$HOME/Library/Application Support/Godot/mono/build_logs"
else
    BUILD_LOGS="${XDG_DATA_HOME:-$HOME/.local/share}/godot/mono/build_logs"
fi

log()  { printf '\n== %s ==\n' "$*"; }
info() { printf '   %s\n' "$*"; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
mtime() { if [[ "$HOST_PLATFORM" == macos ]]; then stat -f %m "$1"; else stat -c %Y "$1"; fi; }
have() { command -v "$1" >/dev/null 2>&1; }

dotnet_env() {
    [[ -x "$DOTNET_DIR/dotnet" ]] || die "no .NET SDK at $DOTNET_DIR — run: $0 toolchain"
    export DOTNET_ROOT="$DOTNET_DIR"
    export PATH="$DOTNET_DIR:$PATH"
    # GodotTools ignores DOTNET_ROOT/PATH and prefers the system dotnet, which
    # lacks wasm-tools; this override is the fork's, and it is the one that counts
    # for the export. scons, on the other hand, needs DOTNET_ROOT+PATH.
    export GODOT_DOTNET_EXE="$DOTNET_DIR/dotnet"
}
emsdk_env() {
    [[ -f "$EMSDK_DIR/emsdk_env.sh" ]] || die "no emsdk at $EMSDK_DIR — run: $0 toolchain"
    # shellcheck disable=SC1091
    EMSDK_QUIET=1 source "$EMSDK_DIR/emsdk_env.sh" >/dev/null 2>&1
    have emcc || die "emcc not on PATH after sourcing $EMSDK_DIR/emsdk_env.sh"
}

# ---------------------------------------------------------------- toolchain --
cmd_toolchain() {
    log "host packages"
    if [[ "$HOST_PLATFORM" == macos ]]; then
        have brew || die "Homebrew is needed for scons/glslang/molten-vk: https://brew.sh"
        for pkg in scons glslang molten-vk; do
            brew list --versions "$pkg" >/dev/null 2>&1 || brew install "$pkg"
        done
    else
        local missing=()
        have scons || missing+=(scons)
        have glslangValidator || missing+=(glslang-tools)
        have pkg-config || missing+=(pkg-config)
        have python3 || missing+=(python3)
        [[ ${#missing[@]} -eq 0 ]] || die "install first: sudo apt-get install -y build-essential ${missing[*]} git curl unzip zip libx11-dev libxcursor-dev libxinerama-dev libgl1-mesa-dev libglu1-mesa-dev libasound2-dev libpulse-dev libudev-dev libxi-dev libxrandr-dev libwayland-dev"
    fi
    have glslangValidator || die "glslangValidator must be on PATH: the template precompiles its shader corpus to WGSL with it, and without it that table is silently empty"

    log "emsdk $EMSDK_VERSION at $EMSDK_DIR"
    mkdir -p "$WASM_HOME"
    if [[ ! -d "$EMSDK_DIR" ]]; then
        git clone --depth 1 https://github.com/emscripten-core/emsdk "$EMSDK_DIR"
    fi
    if ! "$EMSDK_DIR/upstream/emscripten/emcc" --version 2>/dev/null | head -1 | grep -q "$EMSDK_VERSION"; then
        (cd "$EMSDK_DIR" && git pull --ff-only >/dev/null 2>&1 || true)
        "$EMSDK_DIR/emsdk" install "$EMSDK_VERSION"
        "$EMSDK_DIR/emsdk" activate "$EMSDK_VERSION"
    fi
    info "$("$EMSDK_DIR/upstream/emscripten/emcc" --version | head -1)"

    log ".NET 9 SDK ($DOTNET_ARCH) at $DOTNET_DIR"
    # Must be the native-arch SDK: an x64 SDK under Rosetta wedges the
    # wasm-tools workload install at 0 % CPU forever.
    if [[ ! -x "$DOTNET_DIR/dotnet" ]]; then
        curl -sSL https://dot.net/v1/dotnet-install.sh | bash -s -- \
            --channel 9.0 --architecture "$DOTNET_ARCH" --install-dir "$DOTNET_DIR"
    fi
    if ! DOTNET_ROOT="$DOTNET_DIR" "$DOTNET_DIR/dotnet" workload list 2>/dev/null | grep -q '^wasm-tools'; then
        DOTNET_ROOT="$DOTNET_DIR" "$DOTNET_DIR/dotnet" workload install wasm-tools
    fi
    info "dotnet $(DOTNET_ROOT="$DOTNET_DIR" "$DOTNET_DIR/dotnet" --version), wasm-tools installed"
}

# ------------------------------------------------------------------- engine --
mono_sources_newer_than_assemblies() {
    [[ -f "$GODOTSHARP_DLL" ]] || return 0
    local commit_ts
    commit_ts="$(git -C "$ENGINE_DIR" log -1 --format=%ct -- modules/mono 2>/dev/null || echo 0)"
    [[ "$commit_ts" -gt "$(mtime "$GODOTSHARP_DLL")" ]]
}

purge_nuget_cache() {
    # NuGet reuses a cached 4.7.1 and never re-resolves through the source
    # mapping, so a stale or nuget.org copy silently wins over the fork's.
    local p
    for p in godotsharp godotsharpeditor godot.net.sdk godot.sourcegenerators; do
        rm -rf "$HOME/.nuget/packages/$p"
    done
    info "purged Godot packages from ~/.nuget/packages"
}

cmd_engine() {
    have scons || die "scons missing — run: $0 toolchain"
    have glslangValidator || die "glslangValidator missing — run: $0 toolchain"
    dotnet_env
    cd "$ENGINE_DIR"
    info "engine: $ENGINE_DIR @ $(git rev-parse --short HEAD 2>/dev/null || echo '?') ($(git branch --show-current 2>/dev/null || echo '?'))"

    log "editor ($HOST_PLATFORM $HOST_ARCH, mono)"
    if [[ "$FORCE" == 1 || ! -x "$EDITOR_BIN" ]]; then
        local extra=()
        if [[ "$HOST_PLATFORM" == macos ]]; then
            extra+=(accesskit=no angle=no)
            if have brew && brew --prefix molten-vk >/dev/null 2>&1; then
                extra+=("vulkan_sdk_path=$(brew --prefix molten-vk)")
            fi
        fi
        scons platform="$HOST_PLATFORM" target=editor arch="$HOST_ARCH" module_mono_enabled=yes "${extra[@]}" -j"$JOBS"
    else
        info "present: $EDITOR_BIN"
    fi
    [[ -x "$EDITOR_BIN" ]] || die "editor build did not produce $EDITOR_BIN"

    log "C# glue + GodotSharp packages"
    # The fork changes the binding layer (engine calls are P/Invokes on the
    # web), so stock GodotSharp from nuget.org cannot run in this template —
    # and the fork's own packages go stale whenever modules/mono moves.
    if [[ "$FORCE" == 1 || ! -f "$GODOTSHARP_DLL" ]] || mono_sources_newer_than_assemblies; then
        "$EDITOR_BIN" --headless --generate-mono-glue modules/mono/glue
        python3 modules/mono/build_scripts/build_assemblies.py \
            --godot-output-dir=./bin --push-nupkgs-local "$NUPKGS"
        purge_nuget_cache
    else
        info "present and newer than modules/mono: $GODOTSHARP_DLL"
    fi
    [[ -f "$NUPKGS/GodotSharp.4.7.1.nupkg" ]] || die "no GodotSharp nupkg under $NUPKGS"

    log "bootstrap web template"
    # No AOT images in it, so it cannot run a game; it exists so the first
    # export has a template to write against. Same flags as the relink.
    if [[ "$FORCE" == 1 || ! -f "$TEMPLATE_ZIP" ]]; then
        emsdk_env
        # shellcheck disable=SC2086
        scons $TEMPLATE_FLAGS -j"$JOBS"
    else
        info "present: $TEMPLATE_ZIP"
    fi
    [[ -f "$TEMPLATE_ZIP" ]] || die "template build did not produce $TEMPLATE_ZIP"
}

# ------------------------------------------------------------------ prepare --
resolve_game() {
    local dir="${1:-}"
    [[ -n "$dir" ]] || die "usage: $0 $CMD <game-dir>"
    GAME="$(cd "$dir" && pwd)"
    [[ -f "$GAME/project.godot" ]] || die "$GAME has no project.godot"
    if [[ -n "${CSPROJ:-}" ]]; then
        CSPROJ_PATH="$(cd "$(dirname "$CSPROJ")" && pwd)/$(basename "$CSPROJ")"
    else
        local found=()
        while IFS= read -r f; do found+=("$f"); done < <(find "$GAME" -maxdepth 1 -name '*.csproj' | sort)
        [[ ${#found[@]} -eq 1 ]] || die "expected exactly one .csproj in $GAME (found ${#found[@]}); set CSPROJ=path"
        CSPROJ_PATH="${found[0]}"
    fi
    [[ -f "$CSPROJ_PATH" ]] || die "no csproj at $CSPROJ_PATH"
    ASSEMBLY="$(sed -n 's/^project\/assembly_name="\(.*\)"$/\1/p' "$GAME/project.godot" | head -1)"
    [[ -n "$ASSEMBLY" ]] || ASSEMBLY="$(basename "$CSPROJ_PATH" .csproj)"
    AOT_DIR="$GAME/.godot/mono/temp/obj/ExportRelease/browser-wasm/wasm/for-publish"
}

cmd_prepare() {
    resolve_game "${1:-}"
    dotnet_env
    log "prepare $GAME (assembly $ASSEMBLY)"

    # nuget.config: the fork's packages carry the same 4.7.1 version as
    # nuget.org's, so only the source mapping decides which one a restore gets.
    local nuget="$GAME/nuget.config"
    if [[ -f "$nuget" ]] && grep -qF "$NUPKGS" "$nuget"; then
        info "nuget.config already maps Godot.* to $NUPKGS"
    else
        [[ -f "$nuget" ]] && { cp "$nuget" "$nuget.bak"; info "backed up existing nuget.config to nuget.config.bak"; }
        cat > "$nuget" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<!-- Generated by godot-aw3 misc/web-export/wasm.sh: Godot.* packages must come from the fork. -->
<configuration>
  <packageSources>
    <add key="nuget.org" value="https://api.nuget.org/v3/index.json" />
    <add key="GodotAw3Fork" value="$NUPKGS" />
  </packageSources>
  <packageSourceMapping>
    <packageSource key="GodotAw3Fork">
      <package pattern="Godot.*" />
      <package pattern="GodotSharp*" />
    </packageSource>
    <packageSource key="nuget.org">
      <package pattern="*" />
    </packageSource>
  </packageSourceMapping>
</configuration>
EOF
        info "wrote nuget.config"
    fi
    # A cached copy from anywhere else wins over the mapping; check provenance.
    local meta="$HOME/.nuget/packages/godotsharp/4.7.1/.nupkg.metadata"
    if [[ -f "$meta" ]] && ! grep -qF "$NUPKGS" "$meta"; then
        info "cached GodotSharp 4.7.1 came from $(sed -n 's/.*"source": *"\(.*\)".*/\1/p' "$meta"), not $NUPKGS"
        purge_nuget_cache
    fi

    # The MSBuild side lives in a generated .props the csproj imports, so the
    # csproj itself changes by one line.
    local props="$(dirname "$CSPROJ_PATH")/godot-aw3-web.props"
    cat > "$props" <<'EOF'
<Project>
  <!-- Generated by godot-aw3 misc/web-export/wasm.sh prepare. Re-run prepare to
       regenerate (AOT_MODE=... changes the AOT mode). Every entry is load-bearing;
       the reasons are in AW3's docs/gameclient/web-csharp-export.md. -->
  <ItemGroup>
    <!-- The web publish builds an executable and needs an entry point; keep it
         out of every other target. -->
    <Compile Remove="GodotAw3WasmEntry.cs" Condition="'$(RuntimeIdentifier)' != 'browser-wasm'" />
  </ItemGroup>
  <PropertyGroup Condition="'$(RuntimeIdentifier)' == 'browser-wasm'">
    <!-- The web Mono runtime has no ICU; a culture-sensitive string call aborts. -->
    <InvariantGlobalization>true</InvariantGlobalization>
    <!-- AOT is the only configuration that runs: the interpreter cannot expand
         PackedSimd intrinsics and dies with a StackOverflow the moment SIMD BCL
         code is reached. -->
    <RunAOTCompilation>true</RunAOTCompilation>
    <!-- LLVMOnlyInterp keeps an interpreter for methods the AOT compiler could
         not produce (value-type generic instantiations, mostly); LLVMOnly has
         no fallback and aborts on them. Ship LLVMOnly once a coverage pass of
         the whole game runs clean. -->
    <AOTMode>@AOT_MODE@</AOTMode>
    <!-- Must match the template (threads=yes) and the runtime pack. -->
    <WasmEnableThreads>true</WasmEnableThreads>
    <WasmEnableExceptionHandling>true</WasmEnableExceptionHandling>
    <WasmEnableSIMD>true</WasmEnableSIMD>
    <!-- Godot publishes as "ExportRelease", which the SDK does not recognise as
         Release, so without this every AOT-compiled method is built at -Oz. -->
    <WasmBitcodeCompileOptimizationFlag>-O2</WasmBitcodeCompileOptimizationFlag>
    <!-- The publish links a dotnet.native.wasm this project never ships; it
         cannot resolve the engine's godotsharp_* symbols and must not fail. -->
    <WasmAllowUndefinedSymbols>true</WasmAllowUndefinedSymbols>
  </PropertyGroup>
  <Target Name="GodotAw3WasmAotArguments" BeforeTargets="_WasmAotCompileApp">
    <ItemGroup>
      <!-- direct-icalls does not survive Godot embedding the runtime. -->
      <MonoAOTCompilerDefaultAotArguments Remove="direct-icalls" />
    </ItemGroup>
  </Target>
  <ItemGroup Condition="'$(RuntimeIdentifier)' == 'browser-wasm'">
    <!-- P/Invokes into the engine are declared against module "godot"; it has
         to be in the SDK's pinvoke table or the symbols are missing at runtime. -->
    <_WasmPInvokeModules Include="godot" />
    <!-- The publish is trimmed and ILLink sees no roots into the game (native
         code enters it via reflection). Do NOT disable trimming instead: the
         pinvoke table is generated from the trimmed output. -->
    <TrimmerRootAssembly Include="$(AssemblyName)" />
    <TrimmerRootAssembly Include="GodotSharp" />
    <TrimmerRootAssembly Include="System.Private.CoreLib" />
    <TrimmerRootAssembly Include="System.Runtime" />
  </ItemGroup>
</Project>
EOF
    sed -i.bak "s/@AOT_MODE@/$AOT_MODE/" "$props" && rm -f "$props.bak"
    info "wrote $(basename "$props") (AOTMode=$AOT_MODE)"
    if grep -qF 'godot-aw3-web.props' "$CSPROJ_PATH"; then
        info "csproj already imports it"
    else
        python3 - "$CSPROJ_PATH" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
i = s.rstrip().rfind("</Project>")
assert i >= 0, "no </Project> in " + p
s = s[:i] + '  <Import Project="godot-aw3-web.props" />\n' + s[i:]
open(p, "w").write(s)
PY
        info "added <Import Project=\"godot-aw3-web.props\" /> to $(basename "$CSPROJ_PATH")"
    fi

    local entry="$(dirname "$CSPROJ_PATH")/GodotAw3WasmEntry.cs"
    if [[ ! -f "$entry" ]]; then
        printf '// Web export only: the .NET SDK needs an entry point when publishing for\n// browser-wasm. Godot never calls this. Excluded from every other target by\n// godot-aw3-web.props.\n{ }\n' > "$entry"
        info "wrote GodotAw3WasmEntry.cs"
    fi

    # GodotTools resolves the solution by looking for one that references the
    # csproj, or falls back to <assembly>.sln, which must exist.
    if ! ls "$GAME"/*.sln "$GAME"/*.slnx >/dev/null 2>&1; then
        (cd "$GAME" && dotnet new sln -n "$ASSEMBLY" >/dev/null && dotnet sln "$ASSEMBLY.sln" add "$CSPROJ_PATH" >/dev/null)
        info "created $ASSEMBLY.sln"
    fi

    # Either RenderingDevice renderer makes the export plugin write
    # renderingDriver: "webgpu" into index.html; gl_compatibility keeps WebGL2.
    python3 - "$GAME/project.godot" rendering renderer/rendering_method.web "\"$RENDERING_METHOD\"" <<'PY'
import sys
path, section, key, value = sys.argv[1:5]
lines = open(path).read().split("\n")
header = "[" + section + "]"
try:
    start = lines.index(header)
except ValueError:
    while lines and lines[-1] == "":
        lines.pop()
    lines += ["", header, "", key + "=" + value, ""]
else:
    end = next((i for i in range(start + 1, len(lines)) if lines[i].startswith("[")), len(lines))
    for i in range(start + 1, end):
        if lines[i].split("=", 1)[0] == key:
            lines[i] = key + "=" + value
            break
    else:
        lines.insert(start + 1, key + "=" + value)
        lines.insert(start + 1, "")
open(path, "w").write("\n".join(lines))
PY
    info "project.godot: renderer/rendering_method.web=\"$RENDERING_METHOD\""

    python3 - "$GAME/export_presets.cfg" "$PRESET" "$TEMPLATE_ZIP" <<'PY'
import os, re, sys
path, name, template = sys.argv[1:4]
text = open(path).read() if os.path.exists(path) else ""
blocks = []  # [header, [lines]]
for line in text.split("\n"):
    if re.match(r"^\[preset\.\d+(\.options)?\]$", line):
        blocks.append([line, []])
    elif blocks:
        blocks[-1][1].append(line)
    else:
        blocks.append([None, [line]])

def setkv(lines, key, value):
    for i, l in enumerate(lines):
        if l.split("=", 1)[0] == key:
            lines[i] = key + "=" + value
            return
    while lines and lines[-1] == "":
        lines.pop()
    lines.append(key + "=" + value)
    lines.append("")

options = [
    ("custom_template/debug", '"%s"' % template),
    ("custom_template/release", '"%s"' % template),
    ("variant/extensions_support", "false"),
    ("variant/thread_support", "true"),
    ("threads/emscripten_pool_size", "8"),
    ("vram_texture_compression/for_desktop", "true"),
    ("vram_texture_compression/for_mobile", "false"),
    ("html/export_icon", "true"),
    ("html/custom_html_shell", '""'),
    ("html/head_include", '""'),
    ("html/canvas_resize_policy", "2"),
    ("html/focus_canvas_on_start", "true"),
    ("html/experimental_virtual_keyboard", "false"),
    ("progressive_web_app/enabled", "false"),
]
idx = None
for h, lines in blocks:
    if h and not h.endswith(".options]") and any(l == 'name="%s"' % name for l in lines):
        idx = int(re.search(r"\d+", h).group())
        if not any(l == 'platform="Web"' for l in lines):
            sys.exit("preset %r exists but is not a Web preset" % name)
        setkv(lines, "export_path", '"builds/web/index.html"')
        setkv(lines, "runnable", "true")
if idx is None:
    nums = [int(re.search(r"\d+", h).group()) for h, _ in blocks if h]
    idx = (max(nums) + 1) if nums else 0
    main = ["", 'name="%s"' % name, 'platform="Web"', "runnable=true", "advanced_options=false",
            "dedicated_server=false", 'custom_features=""', 'export_filter="all_resources"',
            'include_filter=""', 'exclude_filter=""', 'export_path="builds/web/index.html"',
            "patches=PackedStringArray()", 'encryption_include_filters=""',
            'encryption_exclude_filters=""', "seed=0", "encrypt_pck=false",
            "encrypt_directory=false", "script_export_mode=2", ""]
    blocks.append(["[preset.%d]" % idx, main])
    blocks.append(["[preset.%d.options]" % idx, [""]])
opt_header = "[preset.%d.options]" % idx
for h, lines in blocks:
    if h == opt_header:
        for k, v in options:
            setkv(lines, k, v)
out = []
for h, lines in blocks:
    if h:
        out.append(h)
    out.extend(lines)
open(path, "w").write("\n".join(out).rstrip("\n") + "\n")
print("   export_presets.cfg: preset %r -> builds/web/index.html, template %s" % (name, os.path.basename(template)))
PY
    info "prepare done"
}

# ------------------------------------------------------------------- export --
newest_build_log() {
    ls -t "$BUILD_LOGS"/*/msbuild_log.txt 2>/dev/null | head -1 || true
}

run_editor() {
    # Godot's headless import occasionally crashes at 99 % in the font reimport
    # pass; a second run completes in seconds. Retry once for any editor step.
    local attempt
    for attempt in 1 2; do
        if "$EDITOR_BIN" "$@"; then return 0; fi
        [[ $attempt -eq 1 ]] && info "editor step failed (attempt $attempt), retrying once"
    done
    return 1
}

cmd_export() {
    resolve_game "${1:-}"
    [[ -x "$EDITOR_BIN" ]] || die "no editor at $EDITOR_BIN — run: $0 engine"
    [[ -f "$TEMPLATE_ZIP" ]] || die "no web template at $TEMPLATE_ZIP — run: $0 engine"
    [[ -f "$GAME/godot-aw3-web.props" || -f "$(dirname "$CSPROJ_PATH")/godot-aw3-web.props" ]] || die "project not prepared — run: $0 prepare $GAME"
    dotnet_env
    emsdk_env
    local start logs out
    start="$(date +%s)"
    out="$GAME/builds/web"
    logs="$GAME/builds/wasm-logs"
    mkdir -p "$out" "$logs"
    # A rebuilt file next to a stale pre-compressed sibling means the browser
    # keeps getting the OLD one from any server that prefers .br/.gz.
    rm -f "$out"/*.br "$out"/*.gz

    log "import ($GAME)"
    run_editor --headless --path "$GAME" --import > "$logs/import.log" 2>&1 || {
        tail -30 "$logs/import.log"; die "import failed; full log: $logs/import.log"; }
    info "ok ($logs/import.log)"

    log "pass 1: export preset '$PRESET' (publishes C#, emits AOT objects)"
    run_editor --headless --path "$GAME" --export-release "$PRESET" builds/web/index.html > "$logs/export.log" 2>&1 || {
        tail -30 "$logs/export.log"; die "export failed; full log: $logs/export.log"; }
    local obj="$AOT_DIR/$ASSEMBLY.dll.o"
    if [[ ! -f "$obj" || "$(mtime "$obj")" -lt "$start" ]]; then
        local ml; ml="$(newest_build_log)"
        [[ -n "$ml" ]] && { info "msbuild log: $ml"; grep -E 'error|WASM0001|NETSDK1147' "$ml" | head -20 || true; }
        die "no fresh AOT object at $obj — the publish failed silently (export only warns). See the msbuild log above."
    fi
    local ml; ml="$(newest_build_log)"
    if [[ -n "$ml" ]] && grep -q 'WASM0001' "$ml"; then
        grep 'WASM0001' "$ml" | head -10
        die "WASM0001 in the publish: a P/Invoke returns a struct by value or uses floating point in its signature. Its symbol will be missing at runtime; pass such values through pointers."
    fi
    info "AOT objects: $(ls "$AOT_DIR"/*.dll.o | wc -l | tr -d ' ') under $AOT_DIR"
    [[ -f "$out/index.pck" ]] || die "export produced no $out/index.pck"

    log "pass 2: relink template with the AOT objects ($ENGINE_DIR)"
    # Fed to scons as sources (a fork change), so a changed object relinks. The
    # flags must equal the bootstrap's or this recompiles the whole engine.
    # shellcheck disable=SC2086
    (cd "$ENGINE_DIR" && scons $TEMPLATE_FLAGS mono_aot_dir="$AOT_DIR" -j"$JOBS") 2>&1 | tee "$logs/relink.log" | grep -E 'AOT-compiled|error|Error|scons: done building|scons: \*\*\*' || true
    grep -q 'scons: done building targets' "$logs/relink.log" || die "relink did not finish; log: $logs/relink.log"
    grep -qE 'linking [0-9]+ AOT-compiled assemblies' "$logs/relink.log" || die "scons never reported 'linking N AOT-compiled assemblies' — the template was not linked against $AOT_DIR; log: $logs/relink.log"
    [[ "$(mtime "$TEMPLATE_ZIP")" -ge "$start" ]] || die "$TEMPLATE_ZIP was not rewritten by the relink (a no-op link ships the previous game's code)"
    info "relink took $(( $(date +%s) - start ))s in total so far; template $(du -h "$TEMPLATE_ZIP" | cut -f1)"

    log "swap the relinked engine into the export"
    # Not a third export: a re-publish could regenerate the objects and desync
    # them from the template. The pck keeps the assemblies the objects came from.
    local tmp; tmp="$(mktemp -d)"
    unzip -oq "$TEMPLATE_ZIP" -d "$tmp"
    cp "$tmp/godot.wasm" "$out/index.wasm"
    cp "$tmp/godot.js"   "$out/index.js"
    rm -rf "$tmp"
    info "index.wasm $(du -h "$out/index.wasm" | cut -f1), index.pck $(du -h "$out/index.pck" | cut -f1)"
    grep -q '"renderingDriver": *"webgpu"\|renderingDriver":"webgpu"\|"renderingDriver":"webgpu"' "$out/index.html" \
        && info "index.html: renderingDriver webgpu" \
        || info "WARNING: index.html does not select the webgpu driver — check renderer/rendering_method.web in project.godot"
    log "done in $(( $(date +%s) - start ))s -> $out"
    info "serve it: $0 serve $GAME  (COOP/COEP headers; needs a browser with WebGPU)"
}

# -------------------------------------------------------------------- serve --
cmd_serve() {
    resolve_game "${1:-}"
    local port="${2:-8080}"
    [[ -f "$GAME/builds/web/index.html" ]] || die "no export at $GAME/builds/web — run: $0 export $GAME"
    # Threaded: HTTP/1.1 keep-alive on a single-threaded server queues every
    # parallel fetch behind the first connection and the page never loads.
    python3 - "$GAME/builds/web" "$port" <<'PY'
import functools, http.server, os, socketserver, sys
class Handler(http.server.SimpleHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def end_headers(self):
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        self.send_header("Cache-Control", "no-store")
        super().end_headers()
    def log_message(self, fmt, *args):
        sys.stderr.write("%s\n" % (fmt % args))
class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True
d, port = os.path.abspath(sys.argv[1]), int(sys.argv[2])
with Server(("127.0.0.1", port), functools.partial(Handler, directory=d)) as s:
    print("serving %s on http://127.0.0.1:%d/" % (d, port), flush=True)
    s.serve_forever()
PY
}

# ------------------------------------------------------------------- doctor --
cmd_doctor() {
    log "toolchain"
    info "emsdk:   $EMSDK_DIR $( [[ -x "$EMSDK_DIR/upstream/emscripten/emcc" ]] && "$EMSDK_DIR/upstream/emscripten/emcc" --version 2>/dev/null | head -1 || echo MISSING )"
    info "dotnet:  $DOTNET_DIR $( [[ -x "$DOTNET_DIR/dotnet" ]] && DOTNET_ROOT="$DOTNET_DIR" "$DOTNET_DIR/dotnet" --version || echo MISSING )"
    info "wasm-tools: $( [[ -x "$DOTNET_DIR/dotnet" ]] && DOTNET_ROOT="$DOTNET_DIR" "$DOTNET_DIR/dotnet" workload list 2>/dev/null | grep -c '^wasm-tools' || echo 0 ) installed"
    info "scons: $(command -v scons || echo MISSING)   glslangValidator: $(command -v glslangValidator || echo MISSING)"
    log "engine $ENGINE_DIR"
    info "commit:   $(git -C "$ENGINE_DIR" rev-parse --short HEAD 2>/dev/null || echo '?') on $(git -C "$ENGINE_DIR" branch --show-current 2>/dev/null || echo '?')"
    info "editor:   $( [[ -x "$EDITOR_BIN" ]] && echo "ok  $(date -r "$(mtime "$EDITOR_BIN")" '+%F %R')" || echo MISSING )  $EDITOR_BIN"
    info "template: $( [[ -f "$TEMPLATE_ZIP" ]] && echo "ok  $(date -r "$(mtime "$TEMPLATE_ZIP")" '+%F %R')  $(du -h "$TEMPLATE_ZIP" | cut -f1)" || echo MISSING )"
    if [[ -f "$GODOTSHARP_DLL" ]]; then
        info "GodotSharp: $(date -r "$(mtime "$GODOTSHARP_DLL")" '+%F %R')  $( mono_sources_newer_than_assemblies && echo 'STALE: modules/mono has newer commits — run engine (or FORCE=1 engine)' || echo 'newer than the last modules/mono commit' )"
    else
        info "GodotSharp: MISSING"
    fi
    if [[ -f "$ENGINE_DIR/.scons_env.json" ]]; then
        info "last web link: mono_aot_dir=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('mono_aot_dir','(none)'))" "$ENGINE_DIR/.scons_env.json" 2>/dev/null || echo '?')"
    fi
    local meta="$HOME/.nuget/packages/godotsharp/4.7.1/.nupkg.metadata"
    if [[ -f "$meta" ]]; then
        local src; src="$(sed -n 's/.*"source": *"\(.*\)".*/\1/p' "$meta")"
        info "nuget cache GodotSharp 4.7.1 from: $src $( [[ "$src" == "$NUPKGS" ]] && echo '(this engine)' || echo '(NOT this engine — prepare purges it)' )"
    else
        info "nuget cache: no GodotSharp 4.7.1 cached"
    fi
    if [[ -n "${1:-}" ]]; then
        resolve_game "$1"
        log "game $GAME"
        info "csproj: $CSPROJ_PATH (assembly $ASSEMBLY)"
        info "imports godot-aw3-web.props: $(grep -qF godot-aw3-web.props "$CSPROJ_PATH" && echo yes || echo NO)"
        info "nuget.config -> this engine: $( [[ -f "$GAME/nuget.config" ]] && grep -qF "$NUPKGS" "$GAME/nuget.config" && echo yes || echo NO )"
        info "rendering_method.web: $(sed -n 's/^renderer\/rendering_method.web=//p' "$GAME/project.godot" | head -1)"
        info "Web preset: $( [[ -f "$GAME/export_presets.cfg" ]] && grep -q "name=\"$PRESET\"" "$GAME/export_presets.cfg" && echo present || echo MISSING )"
        info "AOT objects: $( ls "$AOT_DIR"/*.dll.o 2>/dev/null | wc -l | tr -d ' ' ) $( [[ -f "$AOT_DIR/$ASSEMBLY.dll.o" ]] && echo "(game .o $(date -r "$(mtime "$AOT_DIR/$ASSEMBLY.dll.o")" '+%F %R'))" )"
        info "export: $( [[ -f "$GAME/builds/web/index.wasm" ]] && echo "index.wasm $(date -r "$(mtime "$GAME/builds/web/index.wasm")" '+%F %R') $(du -h "$GAME/builds/web/index.wasm" | cut -f1)" || echo none )"
    fi
}

# ---------------------------------------------------------------------- main --
CMD="${1:-}"
shift || true
case "$CMD" in
    toolchain) cmd_toolchain ;;
    engine)    cmd_engine ;;
    prepare)   cmd_prepare "$@" ;;
    export)    cmd_export "$@" ;;
    serve)     cmd_serve "$@" ;;
    doctor)    cmd_doctor "$@" ;;
    all)       cmd_toolchain; cmd_engine; cmd_prepare "$@"; cmd_export "$@" ;;
    *) sed -n '2,32p' "$0"; exit 1 ;;
esac
