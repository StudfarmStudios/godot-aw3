# Scene process-order probe

This probe prints a deterministic callback trace while nodes are added, removed,
re-added from their own callbacks, reprioritized, moved between siblings, and
reparented. Run every mode with separate clean baseline and candidate binaries;
the `trace=` values and exit status must match exactly. No experiment variables
are used.

```sh
/path/to/baseline-godot --headless --path misc/scene-process-order-probe
/path/to/candidate-godot --headless --path misc/scene-process-order-probe
/path/to/baseline-godot --headless --path misc/scene-process-order-probe -- --physics
/path/to/candidate-godot --headless --path misc/scene-process-order-probe -- --physics
```

Pass `--default-group` after `--` to repeat either mode in the default process
group. The default probe uses a dedicated main-thread process group so it also
exercises independent `SceneTree::ProcessGroup` state.

Use `--sub-thread-pair` to run two process groups concurrently. Callback traces
are collected independently under a mutex, so scheduling between groups does not
affect the oracle. All add/remove, priority, sibling-order, and reparent mutations
run on the main thread between completed process passes:

```sh
/path/to/baseline-godot --headless --path misc/scene-process-order-probe -- --sub-thread-pair
/path/to/candidate-godot --headless --path misc/scene-process-order-probe -- --sub-thread-pair
/path/to/baseline-godot --headless --path misc/scene-process-order-probe -- --sub-thread-pair --physics
/path/to/candidate-godot --headless --path misc/scene-process-order-probe -- --sub-thread-pair --physics
```
