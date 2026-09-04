#!/usr/bin/env bash
# Rebuild and push the godot-editor image family for the engine commit checked
# out here — the engine-side entry point, for when the engine is what moved.
#
#   misc/aw3/build-images.sh                  # base + every target, push
#   misc/aw3/build-images.sh --no-push        # build only
#   misc/aw3/build-images.sh linux wasm       # base + just these
#
# The images are:
#
#   godot-editor            this fork's headless Linux editor + .NET toolchain
#   godot-editor-linux      + Linux x86_64 template   (the AW3 dedicated server)
#   godot-editor-windows    + Windows x86_64 template (MinGW cross-build)
#   godot-editor-wasm       + emsdk, web template, warm web object tree
#
# The Dockerfiles live in the AW3 game repo (tools/builder), not here: they are
# about how that game is exported — its presets, its CI, its NuGet layout —
# while this repo stays a plain engine fork. This script only points that build
# at the commit you have checked out; everything it needs from the engine is
# fetched from GitHub by sha, so the commit has to be pushed first.
#
# The build runs on whatever Docker daemon is configured. The images are
# linux/amd64 because the runners that consume them are, so on Apple Silicon
# this is a Rosetta build at roughly 2x native — point DOCKER_HOST at an amd64
# machine to build natively:
#
#   DOCKER_HOST=ssh://root@<amd64 host> misc/aw3/build-images.sh
set -euo pipefail

ENGINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SHA="$(git -C "$ENGINE" rev-parse HEAD)"

# The image build clones this commit from GitHub. A local-only commit fails it,
# but only after apt and the .NET SDK have installed — so check here instead.
if ! git -C "$ENGINE" branch -r --contains "$SHA" 2>/dev/null | grep -q .; then
    echo "HEAD ($SHA) is not on any remote branch — push it first." >&2
    exit 1
fi

# Sibling checkout by default; AW3_DIR overrides.
AW3_DIR="${AW3_DIR:-}"
if [[ -z "$AW3_DIR" ]]; then
    for candidate in "$ENGINE/../aw3" "$ENGINE/../assaultwing"; do
        if [[ -f "$candidate/tools/builder/build-image.sh" ]]; then
            AW3_DIR="$(cd "$candidate" && pwd)"
            break
        fi
    done
fi
if [[ -z "$AW3_DIR" || ! -f "$AW3_DIR/tools/builder/build-image.sh" ]]; then
    echo "no AW3 checkout with tools/builder next to $ENGINE — set AW3_DIR." >&2
    exit 1
fi

echo "== engine $SHA -> $AW3_DIR/tools/builder =="
ENGINE_SHA="$SHA" ENGINE_DIR="$ENGINE" exec "$AW3_DIR/tools/builder/build-image.sh" "$@"
