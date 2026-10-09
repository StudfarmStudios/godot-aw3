# Outstanding queue-completion fence lifetimes

The browser's nonblocking fence wait can recycle a fence before its previous
queue-completion callback fires. Tracking one pending boolean lets an earlier
callback clear the flag or delete retired userdata while newer callbacks still
hold the same pointer. The driver now counts registrations, decrements on every
completion, and signals or deletes only when the final completion drains.
Native blocking waits and the browser's nonblocking behavior remain unchanged.

Run this focused production-code regression without building Godot:

```sh
python3 webgpu_tests/fence_lifetime/run_native.py --output /private/tmp/fence-lifetime
```

The runner extracts the actual `WGFence` structure, completion callbacks,
`fence_free`, and registration statements from current production files and from
baseline commit `74d783e44d`. It compiles these under ASan/UBSan with browser
preprocessor selection. A destructor counter is the only injected observation;
it does not replace ownership logic. Native API type stubs allow this bounded
lifetime test without a Godot or browser process.

The six cases cover no callbacks, one callback pending at retirement, three
callbacks with retirement before or after the first completion, final-only
signaling, and resubmission with older callbacks outstanding. The baseline gives
three confirmed ASan heap-use-after-free failures and one premature-signal
assertion; both simple controls pass. The corrected code passes all six with
exactly one destruction and no sanitizer error. macOS leak detection is disabled;
this is not a leak-detector or full GPU test.

`results/native-asan.json` preserves source hashes and all expected controls.
`results/header-compatibility.json` records the post-counter repeat of all eight
old/current WebGPU-header strict syntax checks; the earlier API-fix proof in
`browser_fork_ports/results/emscripten-header-compatibility.json` remains unchanged.
The real nonthreaded browser negative also aborts from `_fence_work_done_callback`
inside `emwgpuOnWorkDoneCompleted` during graceful shutdown. The separate [browser fixture](../browser_fork_ports/README.md) now passes all
16 corrected threaded/nonthreaded Chrome/Firefox runs with clean shutdown, plus
two nonzero-exit probes. This sanitizer fixture alone makes no browser or
Windows/D3D12 pass claim.
