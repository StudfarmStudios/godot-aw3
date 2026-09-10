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

## Game-specific measurements

The matched Assault Wing binaries, gameplay timings, and production decision
live with the game in [AW3’s PGO measurement record](https://github.com/StudfarmStudios/aw3/blob/main/docs/gameclient/pgo-measurements-2026-09-10.md).
