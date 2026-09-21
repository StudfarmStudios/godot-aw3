# Material dependency regression probe

This project verifies that instance teardown registers pending material
dependencies before freeing resources. In one uninterrupted RenderingServer
command batch it assigns a fresh override to a surviving instance, frees an
unrelated instance, and frees the override. The survivor must fall back to its
blue base material without a stale RID or dependency error.

Run the fixture graphically; a headless dummy renderer does not cover this
path. From the engine checkout root:

```sh
BASELINE=/absolute/path/to/baseline/godot.macos.editor.arm64.mono
CANDIDATE=/absolute/path/to/candidate/godot.macos.editor.arm64.mono
PROBE="$PWD/misc/rendering/material-dependency-probe"

"$BASELINE" --path "$PROBE" --rendering-driver metal --fixed-fps 60 -- \
  --output=/tmp/material-dependency-baseline
"$CANDIDATE" --path "$PROBE" --rendering-driver metal --fixed-fps 60 -- \
  --output=/tmp/material-dependency-candidate

python3 "$PROBE/compare.py" \
  /tmp/material-dependency-baseline /tmp/material-dependency-candidate
```

Each run must exit zero, print `MATERIAL_DEPENDENCY PASS captures=5`, and
produce no renderer, RID, or dependency errors. The comparison must report
five exact image hashes. Repeat each binary into a second output directory and
include those directories in the same comparison when checking determinism.

Do not add a query, draw, synchronization, or `await` between the three
frame-one mutations; doing so drains the dirty instance and hides the
regression.
