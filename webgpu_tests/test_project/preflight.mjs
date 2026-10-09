/**
 * Bounded browser/backend check before building the candidate engine.
 * Run on Linux with: xvfb-run -a node preflight.mjs
 * Requires Playwright and its Chromium browser. Writes the full JSON result to
 * stdout and exits nonzero for unsupported limits or any GPU/browser error.
 * This software backend check does not establish hardware-driver coverage.
 */
import { createServer } from 'node:http';
import { assertForwardPlusLimits, launchOptions, requiredForwardPlusLimits } from './browser_config.mjs';

const started = Date.now();
const timeoutMs = 120000;
const options = launchOptions();
const report = {
    passed: false,
    platform: process.platform,
    timeoutMs,
    launchOptions: options,
    requiredLimits: requiredForwardPlusLimits,
    stage: 'starting',
    consoleErrors: [],
    pageErrors: [],
    gpuErrors: [],
    deviceLost: null,
};
const server = createServer((request, response) => {
    response.writeHead(request.url === '/favicon.ico' ? 204 : 200, { 'Content-Type': 'text/html' });
    response.end(request.url === '/favicon.ico' ? '' : '<!doctype html><title>WebGPU preflight</title>');
});
let browser;
let page;
const deadline = setTimeout(() => {
    report.error = `WebGPU preflight exceeded ${timeoutMs} milliseconds`;
    report.elapsedMs = Date.now() - started;
    console.log(JSON.stringify(report, null, 2));
    process.exit(1);
}, timeoutMs);

try {
    const { chromium } = await import('playwright');
    await new Promise((resolve, reject) => {
        server.once('error', reject);
        server.listen(0, '127.0.0.1', resolve);
    });
    report.stage = 'launch';
    browser = await chromium.launch(options);
    report.browserVersion = browser.version();
    page = await browser.newPage();
    page.on('console', (message) => {
        if (message.type() === 'error') report.consoleErrors.push(message.text());
    });
    page.on('pageerror', (error) => report.pageErrors.push(String(error.stack || error)));
    await page.goto(`http://127.0.0.1:${server.address().port}`);

    report.stage = 'adapter';
    report.adapter = await page.evaluate(async () => {
        if (!navigator.gpu) throw new Error('navigator.gpu unavailable');
        const adapter = await navigator.gpu.requestAdapter();
        if (!adapter) throw new Error('No WebGPU adapter');
        // Retain the actual adapter between inspection and requestDevice.
        globalThis.preflightState = { adapter, errors: [], deviceLost: null, deliberateDestroy: false };
        const limits = Object.fromEntries(Object.getOwnPropertyNames(Object.getPrototypeOf(adapter.limits))
            .filter((key) => typeof adapter.limits[key] === 'number')
            .map((key) => [key, adapter.limits[key]]));
        return {
            info: Object.fromEntries(['vendor', 'architecture', 'device', 'description']
                .map((key) => [key, adapter.info[key]])),
            features: [...adapter.features].sort(),
            limits,
        };
    });
    assertForwardPlusLimits(report.adapter.limits, 'adapter');

    report.stage = 'device';
    report.device = await page.evaluate(async (requiredLimits) => {
        const state = globalThis.preflightState;
        state.device = await state.adapter.requestDevice({ requiredLimits });
        state.device.lost.then((info) => {
            if (!state.deliberateDestroy || info.reason !== 'destroyed') {
                state.deviceLost = { reason: info.reason, message: info.message };
            }
        });
        state.device.addEventListener('uncapturederror', (event) => state.errors.push(event.error.message));
        return {
            limits: Object.fromEntries(Object.getOwnPropertyNames(Object.getPrototypeOf(state.device.limits))
                .filter((key) => typeof state.device.limits[key] === 'number')
                .map((key) => [key, state.device.limits[key]])),
        };
    }, requiredForwardPlusLimits);
    assertForwardPlusLimits(report.device.limits, 'device');

    report.stage = 'compute-readback';
    report.compute = await page.evaluate(async () => {
        const state = globalThis.preflightState;
        const device = state.device;
        // Keep all 64 bindings live in a single dispatch. Numerical readback
        // verifies all eight buffers and all eight storage textures.
        const declarations = [];
        const statements = ['var sum = 0.0;'];
        const entries = [];
        const input = device.createTexture({
            size: [1, 1], format: 'rgba8unorm',
            usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST,
        });
        device.queue.writeTexture({ texture: input }, new Uint8Array([255, 255, 255, 255]), {}, [1, 1]);
        const inputView = input.createView();
        for (let i = 0; i < 48; i++) {
            declarations.push(`@group(0) @binding(${i}) var t${i}: texture_2d<f32>;`);
            statements.push(`sum += textureLoad(t${i}, vec2i(0), 0).r;`);
            entries.push({ binding: i, resource: inputView });
        }
        const textures = [];
        const buffers = [];
        for (let i = 0; i < 8; i++) {
            declarations.push(`@group(0) @binding(${48 + i}) var s${i}: texture_storage_2d<rgba8unorm, write>;`);
            declarations.push(`@group(0) @binding(${56 + i}) var<storage, read_write> b${i}: array<u32>;`);
            statements.push(`textureStore(s${i}, vec2i(0), vec4f(sum / 48.0, 0.0, 0.0, 1.0)); b${i}[0] = u32(sum);`);
            const texture = device.createTexture({
                size: [1, 1], format: 'rgba8unorm',
                usage: GPUTextureUsage.STORAGE_BINDING | GPUTextureUsage.COPY_SRC,
            });
            const buffer = device.createBuffer({ size: 4, usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_SRC });
            textures.push(texture);
            buffers.push(buffer);
            entries.push({ binding: 48 + i, resource: texture.createView() });
            entries.push({ binding: 56 + i, resource: { buffer } });
        }
        device.pushErrorScope('validation');
        const module = device.createShaderModule({
            code: `${declarations.join('\n')}\n@compute @workgroup_size(1) fn main() { ${statements.join('\n')} }`,
        });
        const messages = (await module.getCompilationInfo()).messages.filter((message) => message.type === 'error');
        if (messages.length) throw new Error(messages.map((message) => message.message).join('\n'));
        const pipeline = await device.createComputePipelineAsync({
            layout: 'auto', compute: { module, entryPoint: 'main' },
        });
        const group = device.createBindGroup({ layout: pipeline.getBindGroupLayout(0), entries });
        // The first row holds buffer outputs; each later aligned row holds one texture pixel.
        const readback = device.createBuffer({ size: 9 * 256, usage: GPUBufferUsage.COPY_DST | GPUBufferUsage.MAP_READ });
        const encoder = device.createCommandEncoder();
        const pass = encoder.beginComputePass();
        pass.setPipeline(pipeline);
        pass.setBindGroup(0, group);
        pass.dispatchWorkgroups(1);
        pass.end();
        buffers.forEach((buffer, index) => encoder.copyBufferToBuffer(buffer, 0, readback, index * 4, 4));
        textures.forEach((texture, index) => encoder.copyTextureToBuffer(
            { texture }, { buffer: readback, offset: (index + 1) * 256, bytesPerRow: 256 }, [1, 1]));
        device.queue.submit([encoder.finish()]);
        await readback.mapAsync(GPUMapMode.READ);
        const mapped = readback.getMappedRange();
        const bufferValues = [...new Uint32Array(mapped, 0, 8)];
        const textureValues = textures.map((_, index) => [...new Uint8Array(mapped, (index + 1) * 256, 4)]);
        readback.unmap();
        const validationError = await device.popErrorScope();
        if (validationError) state.errors.push(validationError.message);
        await device.queue.onSubmittedWorkDone();
        input.destroy();
        textures.forEach((texture) => texture.destroy());
        buffers.forEach((buffer) => buffer.destroy());
        readback.destroy();
        return { sampledTextures: 48, storageTextures: 8, storageBuffers: 8, bufferValues, textureValues };
    });
    if (report.compute.bufferValues.some((value) => value !== 48)
        || report.compute.textureValues.some((pixel) => pixel.join(',') !== '255,0,0,255')) {
        throw new Error(`Incorrect GPU results: ${JSON.stringify(report.compute)}`);
    }
    report.stage = 'cleanup';
    await page.evaluate(() => {
        const state = globalThis.preflightState;
        state.deliberateDestroy = true;
        state.device.destroy();
    });
    await page.waitForTimeout(1000);
} catch (error) {
    report.error = String(error.stack || error);
} finally {
    if (page && !page.isClosed()) {
        try {
            const gpu = await page.evaluate(() => ({
                errors: globalThis.preflightState?.errors || [],
                deviceLost: globalThis.preflightState?.deviceLost || null,
            }));
            report.gpuErrors = gpu.errors;
            report.deviceLost = gpu.deviceLost;
        } catch (error) {
            report.pageErrors.push(String(error.stack || error));
        }
    }
    if (browser) {
        try {
            await browser.close();
        } catch (error) {
            report.pageErrors.push(String(error.stack || error));
        }
    }
    if (server.listening) await new Promise((resolve) => server.close(resolve));
    clearTimeout(deadline);
}
report.passed = !report.error && report.stage === 'cleanup'
    && report.consoleErrors.length === 0 && report.pageErrors.length === 0
    && report.gpuErrors.length === 0 && !report.deviceLost;
report.elapsedMs = Date.now() - started;
console.log(JSON.stringify(report, null, 2));
process.exitCode = report.passed ? 0 : 1;
