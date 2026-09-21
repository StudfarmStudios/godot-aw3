# Cull dependency-order regression probe

This project verifies dependency-only instance draining against the original
general dirty-list order. It covers an AABB-only item upgraded in place to a
dependency update, transparent draw ordering, light and particle-collider pair
repair, and a dependency notification emitted by dirty-resource processing.

Run the baseline and candidate graphically from the engine checkout root:

```sh
BASELINE=/absolute/path/to/baseline/godot.macos.editor.arm64.mono
CANDIDATE=/absolute/path/to/candidate/godot.macos.editor.arm64.mono
PROBE="$PWD/misc/rendering/cull-dependency-order-probe"

"$BASELINE" --path "$PROBE" --rendering-driver metal --fixed-fps 60 -- \
  --output=/tmp/cull-dependency-baseline
"$CANDIDATE" --path "$PROBE" --rendering-driver metal --fixed-fps 60 -- \
  --output=/tmp/cull-dependency-candidate

python3 "$PROBE/compare.py" \
  /tmp/cull-dependency-baseline /tmp/cull-dependency-candidate
```

Each run must exit zero, print `CULL_DEPENDENCY_ORDER PASS captures=5`, and
have no renderer, dependency, `SelfList`, RID, or API-validation errors. The
comparison must print `CULL_DEPENDENCY_ORDER_COMPARE PASS` with exact image,
sample, event, and foreground data. Repeated outputs from either binary may be
passed to `compare.py` in the same command.

Keep `_exercise_partial_drain()` uninterrupted. A query, draw, synchronization,
or `await` there changes the dirty-list state and invalidates the test.
