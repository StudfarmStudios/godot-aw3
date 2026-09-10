# Chromium shader-warning callback deadlock

A cold WebGPU Mobile startup in Chrome 152.0.7977.83 on macOS arm64 can stop while the split-pack loader still shows zero downloaded bytes. The preserved PGO build reproduced it repeatedly, while a matched ordinary AOT build passed. This was a timing-sensitive browser deadlock, not evidence that LLVM discarded unvisited code or miscompiled the game.

## Native evidence

The Chrome framework UUID was `4C4C44C3-5555-3144-A15B-808C73C84BC7`. Decoding its native sample with Google's matching published symbols showed the main thread in this chain:

1. `gpu::CommandBufferProxyImpl::OnReturnData` holds `shared_state_lock_` while dispatching a Dawn wire response.
2. Dawn's device logging callback reaches `blink::GPUDevice::OnLoggingImpl`.
3. Allocating a `ConsoleMessage` enters cppgc sweeping and finalizes an older GPU object.
4. `dawn::wire::client::ObjectBase::DeleteThis` unregisters the object and serializes a new command.
5. Expanding the transfer ring calls `CommandBufferProxyImpl::CreateTransferBuffer`, which tries to acquire the already-held non-recursive `shared_state_lock_`.

The exact Chrome source confirms the lock at [OnReturnData](https://chromium.googlesource.com/chromium/src/+/152.0.7977.83/gpu/ipc/client/command_buffer_proxy_impl.cc#746), its re-acquisition at [CreateTransferBuffer](https://chromium.googlesource.com/chromium/src/+/152.0.7977.83/gpu/ipc/client/command_buffer_proxy_impl.cc#507), and the allocation in [GPUDevice::OnLoggingImpl](https://chromium.googlesource.com/chromium/src/+/152.0.7977.83/third_party/blink/renderer/modules/webgpu/gpu_device.cc#396).

The pending log was Tint's generated `code is unreachable` warning. Disabling WASM tier-up or forcing eager compilation let startup finish, but those comparisons merely changed allocation and callback timing. Neither is a production remedy.

## Engine-side workaround

Enable Tint's existing `disable_unreachable_code_warning` writer option, which emits `diagnostic(off, chromium.unreachable_code);`. SPIR-V control-flow reconstruction may append fallback returns that are unreachable in the reconstructed WGSL. These compiler-generated warnings do not indicate a failed shader.

Also prepend this directive when copying old cached or build-time precompiled WGSL for a module. That covers existing downloaded seeds and persisted caches without invalidating them or repeating translation. The copying path already allocates a mutable module string; the directive uses that same allocation.

This suppresses only the generated unreachable-code diagnostic. Shader validation, compilation errors, and other diagnostics remain enabled. It avoids this observed callback trigger; it does not repair Chromium's underlying re-entrant logging bug or guarantee that another browser-generated warning cannot encounter it.

## Verification

- Preserved failing PGO binary: two normal Mobile boots passed with only this directive added; default browser compiler settings, cold shader seeds, 3440x1280, all three asset packs mounted, no errors.
- Browser validation fixture: the original fallback-return shader reports its warning, the directive removes that warning, and an intentionally invalid shader still reports both compilation and validation errors.
- Fresh instrumented engine and all 33 AOT modules: menu/map coverage completed, followed by two 120-second active eight-bot demo matches; no runtime errors or generated unreachable-code warnings.
- Final uninstrumented PGO release: normal Mobile startup passed at 3440x1280 with both cold shader seeds and the existing production seed. All three split packs mounted, and both runs reported zero runtime errors and zero generated unreachable-code warnings.
- Final Forward+ and automatic Mobile fallback: shader harvesting completed every menu and exactly the three active arena pools, without runtime or shader errors. The final renderer-specific seeds were installed identically in both releases.
- Six uncapped demo/practice runs with eight bots passed at 3440x1280; 300 measured seconds per build after warmup. Inspected final PGO menu and gameplay screenshots: both rendered normally.

## Matched release inputs

Game revision: `d75ee7d1c29532989dcb2c1bc5c6faab05187abf`. Engine base: `24528685cc8ed4021f54a565b76336a8fa0cff4a`, plus the two-file workaround described above. Both releases use the same patch, packs, SDK, and all 33 managed AOT bitcode modules. This does not change managed method selection or content inclusion.

| Release | WASM bytes | SHA-256 |
| --- | ---: | --- |
| Ordinary release AOT | 120,864,991 | `fc212f2d979a43297a59866b9adc9920a40ef26eecbd16556eab19414c536b59` |
| LLVM profile-use release | 107,185,819 | `29dc473a7ba4026a402df80d867a5ecba9e5009f21f736cc256256a53b9379d5` |

The profile-use build has no training-counter symbols and reported no profile mismatch warnings. The merged profile SHA-256 is `a27dcf0b57318149cc7c835489803f72f3aee4bf62ab6ba4a338716f1526e492`.


## Gameplay measurements (2026-09-10)

Chrome 152.0.7977.83, native arm64, Apple M1 Ultra, WebGPU Forward+.
Both releases used the same 3440x1280 canvas, fresh matched shader seeds, release
packs, and `--demo --practice --bots=8 --arena=spacejunk_mayhem_2` with VSync and
the frame cap disabled. Each browser had an isolated profile. Compilers were
stopped. No profiling instrumentation was present in either release.

Measured order: baseline 60s, PGO 60s, PGO 60s, baseline 60s, PGO 180s,
baseline 180s. Every sample started 20s after warmup ended. Browser visibility,
canvas dimensions, runtime errors, active autopilot, and binary hashes were
checked. This is a single-machine, nondeterministic bot comparison; do not
interpret the modest pooled difference as a guaranteed improvement.

| Run | Seconds | Browser FPS | p95 interval | p99 interval | Largest interval |
| --- | ---: | ---: | ---: | ---: | ---: |
| baseline-a | 60.1 | 92.85 | 14.15 ms | 17.81 ms | 132.21 ms |
| use-a | 60.1 | 101.97 | 13.18 ms | 15.74 ms | 98.01 ms |
| use-b | 60.1 | 92.79 | 14.40 ms | 17.17 ms | 102.00 ms |
| baseline-b | 60.1 | 96.21 | 13.67 ms | 16.64 ms | 97.67 ms |
| use-c | 180.2 | 94.56 | 13.75 ms | 16.73 ms | 1057.45 ms |
| baseline-c | 180.2 | 91.25 | 14.79 ms | 20.67 ms | 113.47 ms |

| Pooled result | Ordinary AOT | PGO |
| --- | ---: | ---: |
| Browser FPS | 92.56 | 95.69 |
| Mean browser interval | 10.80 ms | 10.45 ms |
| p95 browser interval | 14.47 ms | 13.82 ms |
| p99 browser interval | 17.81 ms | 16.68 ms |
| Intervals over 16.7ms | 1.35% | 1.00% |
| Intervals over 33.3ms | 0.12% | 0.05% |

PGO improved pooled browser FPS by 3.4% and reduced the uncompressed WASM size
by 11.3%. Run distributions overlapped. Average active ship, mine, and bullet
counts were broadly similar, but draw calls and combat effects varied with the
bots and camera. The two early 60s runs alone suggested a misleading ~10% win.

The PGO 180s sample contained a **1,057ms browser interval**, with a matching
1,062ms main-thread long task about 112s into the measured window. The sample
continued and had no runtime error. Shader compilation counters did not move
across that stall, and no C# collection was logged at that moment. Its cause
was not established. Other PGO slow frames coincided with nursery collections
(the logger reported 56–73ms frame deltas); coincidence is not a measurement of
the collector's own pause duration.

The game delta-based average understated the one-second interval. These
headline measurements use browser requestAnimationFrame intervals and retain
that outlier; they are not GPU presentation timestamps. The unmodified game
frame logs are retained as a cross-check, not a replacement for wall time.

**Decision:** keep PGO experimental until the remaining browser stall is
understood or reliably excluded. The shader-warning workaround is useful
independently of PGO. Production remained on ordinary release AOT; this
investigation did not deploy an instrumented or profile-use build.
