// These minimums keep the candidate smoke on Forward+ instead of silently
// accepting the engine's Mobile fallback.
export const requiredForwardPlusLimits = Object.freeze({
    maxSampledTexturesPerShaderStage: 48,
    maxStorageTexturesPerShaderStage: 8,
    maxStorageBuffersPerShaderStage: 8,
});

export function assertForwardPlusLimits(limits, label = 'adapter', required = requiredForwardPlusLimits) {
    const failures = Object.entries(required)
        .filter(([name, minimum]) => !Number.isFinite(limits?.[name]) || limits[name] < minimum)
        .map(([name, minimum]) => `${name}=${limits?.[name]} (requires >=${minimum})`);
    if (failures.length) {
        throw new Error(`WebGPU ${label} cannot support Forward+: ${failures.join(', ')}`);
    }
}

export function launchOptions(platform = process.platform) {
    return {
        headless: false,
        args: [
            '--enable-unsafe-webgpu',
            '--enable-features=Vulkan,UseSkiaRenderer',
            '--disable-gpu-sandbox',
            ...(platform === 'linux' ? [
                // Select the bundled SwiftShader ICD for ANGLE as well as Dawn;
                // generic Vulkan can select an unavailable system driver.
                // https://chromium.googlesource.com/chromium/src/+/main/docs/gpu/swiftshader.md
                '--use-gl=angle',
                '--use-angle=swiftshader',
                '--use-vulkan=swiftshader',
                '--use-webgpu-adapter=swiftshader',
                '--disable-vulkan-surface',
                // Keep the watchdog finite, but allow CPU rendering/compilation
                // more time on CI. The smoke still has its own 600-second bound.
                // The pinned Chromium switch is seconds, before any multiplier.
                // https://github.com/chromium/chromium/blob/156.0.8078.4/gpu/ipc/service/gpu_watchdog_thread.cc#L55
                '--gpu-watchdog-timeout-seconds=120',
                // SwiftShader has enough sampled/storage bindings, but its
                // dynamic-buffer counts reduce Dawn's entire resource tier.
                // Expose the real normalized limits; keep all validation.
                // Chromium 156.0.8078.4: webgpu_decoder_impl.cc:1143-1146.
                // https://github.com/chromium/chromium/blob/156.0.8078.4/gpu/command_buffer/service/webgpu_decoder_impl.cc#L1143
                // Dawn still validates required limits in Adapter.cpp:293.
                // https://github.com/google/dawn/blob/0a2c7df818e285d6db0f085135139cda04cee8bb/src/dawn/native/Adapter.cpp#L293
                '--disable-dawn-features=tiered_adapter_limits',
            ] : ['--use-angle=vulkan']),
        ],
    };
}
