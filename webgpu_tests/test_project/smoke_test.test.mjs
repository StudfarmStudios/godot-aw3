import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { createContext, runInContext } from 'node:vm';
import { runSmokeTest } from './smoke_test.mjs';
import { requiredForwardPlusLimits } from './browser_config.mjs';

async function runMock(t, scenario = 'pass', overrides = {}) {
    const dir = mkdtempSync(join(tmpdir(), 'godot-webgpu-smoke-'));
    t.after(() => rmSync(dir, { recursive: true, force: true }));
    writeFileSync(join(dir, 'index.html'), '<!doctype html>');
    const state = {
        browserClosed: false, serverClosed: false, adapterRequests: 0, deviceRequests: 0,
        output: [], textureCalls: [], textureResults: [], clock: 100,
    };
    const events = new Map();
    const emit = (type, text) => events.get('console')?.({ type: () => type, text: () => text });
    const limits = { ...requiredForwardPlusLimits };
    const adapterLimits = { ...limits };
    const deviceLimits = { ...limits };
    if (scenario === 'low-adapter') adapterLimits.maxSampledTexturesPerShaderStage = 16;
    if (scenario === 'missing-limit') delete adapterLimits.maxStorageTexturesPerShaderStage;
    if (scenario === 'low-device') deviceLimits.maxStorageTexturesPerShaderStage = 4;
    let loseDevice;
    let uncapturedError;
    const device = {
        limits: deviceLimits, features: new Set(),
        lost: new Promise((accept) => { loseDevice = accept; }),
        addEventListener: (_name, callback) => { uncapturedError = callback; },
    };
    const adapter = {
        limits: adapterLimits, info: { vendor: 'mock', architecture: 'mock' }, features: new Set(),
        requestDevice: async () => { state.deviceRequests++; return device; },
    };
    const canvasDescriptor = { device, format: 'rgba8unorm', alphaMode: 'opaque' };
    const texture = { kind: 'mock-texture' };
    const textureArguments = [{ untouched: true }, 'extra-argument'];
    const textureFailure = new Error('Original getCurrentTexture failure');
    class GPUCanvasContext {
        constructor() {
            this.canvas = { width: 813, height: 457 };
        }

        configure(descriptor) {
            state.configureReceiver = this;
            state.configureDescriptor = descriptor;
            return 'original-configure-result';
        }

        getCurrentTexture(...args) {
            state.textureCalls.push({ receiver: this, args });
            if (scenario === 'texture-request-throws') throw textureFailure;
            return texture;
        }
    }
    const context = createContext({
        navigator: { gpu: { requestAdapter: async () => { state.adapterRequests++; return adapter; } } },
        console: { log: (text) => emit('log', text), error: (text) => emit('error', text) },
        GPUCanvasContext, canvasDescriptor, textureArguments,
        performance: { now: () => state.clock },
    });
    let init;
    let initArgument;
    const page = {
        on: (name, callback) => events.set(name, callback),
        addInitScript: async (callback, argument) => { init = callback; initArgument = argument; },
        goto: async () => {
            if (scenario === 'navigation-error') throw new Error('Navigation failed');
            context.requiredLimits = initArgument;
            // Execute the production page hook, rather than manufacturing its capability messages.
            runInContext(`(${init.toString()})(requiredLimits)`, context);
            try {
                if (scenario !== 'missing-device') {
                    await runInContext('(async () => { const a = await navigator.gpu.requestAdapter(); '
                        + 'return a.requestDevice({requiredLimits}); })()', context);
                    context.canvasContext = runInContext('new GPUCanvasContext()', context);
                    state.configureResult = runInContext('canvasContext.configure(canvasDescriptor)', context);
                    for (let request = 0; request < 2; request++) {
                        state.clock += 25;
                        state.textureResults.push(runInContext('canvasContext.getCurrentTexture(...textureArguments)', context));
                    }
                }
            } catch (error) {
                state.caughtError = error;
                events.get('pageerror')(error);
                return;
            }
            if (scenario !== 'missing-start') emit('log', '[ShaderCoverage] Starting');
            if (scenario === 'mobile') emit('warning', 'Defaulting to Mobile renderer.');
            if (scenario === 'console-error') emit('error', 'An engine console error');
            if (scenario === 'script-error') emit('log', 'SCRIPT ERROR: invalid property');
            if (scenario === 'shader-error') emit('log', '[SHADER] failed to compile');
            if (scenario === 'validation-error') uncapturedError({ error: new Error('GPUValidationError: incompatible format') });
            if (scenario === 'warning') emit('log', 'WARNING: 7 RIDs of type "Texture" were leaked.');
            if (scenario === 'page-error') events.get('pageerror')(new Error('Unhandled page failure'));
            if (scenario === 'many-errors') {
                for (let i = 0; i < 25; i++) emit('error', `diagnostic-${i}`);
            }
            if (scenario === 'device-loss') {
                loseDevice({ reason: 'unknown', message: 'A valid external Instance reference no longer exists.' });
                await Promise.resolve();
                await Promise.resolve();
            }
            if (scenario === 'engine-fail') emit('log', '[ShaderCoverage] FAIL');
            else if (scenario !== 'missing-completion') emit('log', '[ShaderCoverage] PASS');
        },
    };
    const reportPath = join(dir, 'smoke-result.json');
    const report = await runSmokeTest({
        exportDir: dir, reportPath,
        timeoutMs: ['low-adapter', 'low-device', 'missing-limit'].includes(scenario) ? 5000 : 5,
        pollIntervalMs: 1,
        chromium: { launch: async () => {
            if (scenario === 'launch-error') throw new Error('Launch failed');
            return {
                version: () => 'Mock Chromium 156',
                newPage: async (options) => { state.pageOptions = options; return page; },
                close: async () => { state.browserClosed = true; },
            };
        } },
        serve: async () => ({
            url: 'http://mock.invalid',
            server: { close: (callback) => { state.serverClosed = true; callback(); } },
        }),
        options: { headless: false, args: ['--mock-backend'] },
        logger: { log: (message) => state.output.push(message) },
        ...overrides,
    });
    assert.deepEqual(JSON.parse(readFileSync(reportPath, 'utf8')), report, 'complete artifact matches returned result');
    assert.equal(state.serverClosed, true, 'server always closes');
    assert.equal(state.browserClosed, scenario !== 'launch-error', 'every launched browser closes');
    if (state.configureDescriptor) {
        assert.equal(state.configureDescriptor, canvasDescriptor, 'canvas descriptor is passed through unchanged');
        assert.equal(state.configureDescriptor.device, device, 'canvas device is unchanged');
        assert.equal(state.configureDescriptor.format, 'rgba8unorm', 'canvas format is unchanged');
        assert.ok(state.configureReceiver instanceof GPUCanvasContext, 'original receiver is preserved');
        assert.equal(state.configureResult, 'original-configure-result', 'configure result is preserved');
    }
    for (const call of state.textureCalls) {
        assert.equal(call.receiver, state.configureReceiver, 'texture request receiver is preserved');
        assert.equal(call.args.length, textureArguments.length, 'texture request arguments are preserved');
        call.args.forEach((argument, index) => assert.equal(argument, textureArguments[index]));
    }
    for (const result of state.textureResults) assert.equal(result, texture, 'original GPU texture is returned unchanged');
    if (scenario === 'texture-request-throws') assert.equal(state.caughtError, textureFailure, 'original exception is preserved');
    return { report, state };
}

test('actual adapter/device capabilities plus engine completion pass', async (t) => {
    const { report, state } = await runMock(t);
    assert.equal(report.passed, true);
    assert.equal(report.browserVersion, 'Mock Chromium 156');
    assert.deepEqual(report.launchOptions, { headless: false, args: ['--mock-backend'] });
    assert.equal(report.adapters.length, 1);
    assert.equal(report.devices.length, 1);
    assert.equal(state.adapterRequests, 1, 'monitor creates no extra adapter');
    assert.equal(state.deviceRequests, 1, 'monitor creates no extra device');
    assert.deepEqual(report.canvases, [{ width: 813, height: 457 }], 'diagnostic records actual canvas dimensions');
    assert.ok(state.output.some((line) => line === '[log] [WebGPU canvas] {"width":813,"height":457}'));
});

test('successful texture requests report count, actual dimensions and timestamps without asserting GPU completion', async (t) => {
    const { report, state } = await runMock(t);
    assert.equal(report.passed, true);
    assert.equal(state.textureCalls.length, 2, 'observer issues no extra texture requests');
    assert.deepEqual(report.textureRequests.map(({ timestamp, ...request }) => request), [
        { request: 1, width: 813, height: 457, elapsedMs: 25 },
        { request: 2, width: 813, height: 457, elapsedMs: 50 },
    ]);
    for (const request of report.textureRequests) assert.ok(Number.isFinite(Date.parse(request.timestamp)));
    assert.equal(state.output.filter((line) => line.startsWith('[log] [WebGPU texture request] ')).length, 2);
});

for (const platform of ['linux', 'darwin', 'win32']) {
    test(`${platform} selects the intended default viewport and timeout`, async (t) => {
        const { report, state } = await runMock(t, 'pass', { platform, timeoutMs: undefined });
        const viewport = platform === 'linux' ? { width: 320, height: 180 } : { width: 1280, height: 720 };
        assert.equal(report.passed, true);
        assert.equal(report.platform, platform);
        assert.deepEqual(report.viewport, viewport);
        assert.deepEqual(state.pageOptions, { viewport });
        assert.equal(report.timeoutMs, platform === 'linux' ? 1800000 : 120000);
    });

    test(`${platform} accepts explicit viewport and timeout overrides`, async (t) => {
        const viewport = { width: 640, height: 360 };
        const { report, state } = await runMock(t, 'pass', { platform, viewport, timeoutMs: 1234 });
        assert.equal(report.passed, true);
        assert.deepEqual(report.viewport, viewport);
        assert.deepEqual(state.pageOptions, { viewport });
        assert.equal(report.timeoutMs, 1234);
    });
}

for (const scenario of ['low-adapter', 'low-device', 'missing-limit']) {
    test(`${scenario} fails immediately instead of waiting for scene timeout`, async (t) => {
        const { report, state } = await runMock(t, scenario);
        assert.equal(report.passed, false);
        assert.equal(report.capabilityFailure, true);
        assert.equal(report.timedOut, false);
        assert.ok(report.seconds < 2, 'five-second scene timeout was not consumed');
        assert.equal(state.deviceRequests, scenario === 'low-device' ? 1 : 0);
    });
}

for (const scenario of [
    'mobile', 'device-loss', 'engine-fail', 'missing-completion', 'missing-start', 'missing-device',
    'console-error', 'script-error', 'shader-error', 'validation-error', 'warning', 'page-error',
    'navigation-error', 'launch-error', 'texture-request-throws',
]) {
    test(`${scenario} cannot pass`, async (t) => {
        const { report } = await runMock(t, scenario);
        assert.equal(report.passed, false);
        if (scenario === 'missing-completion') assert.equal(report.timedOut, true);
        if (scenario === 'mobile') assert.equal(report.mobileFallback, true);
        if (scenario === 'shader-error') assert.equal(report.shaderErrors.length, 1);
        if (scenario === 'texture-request-throws') assert.deepEqual(report.textureRequests, [], 'failed requests emit no progress');
        if (scenario === 'device-loss') {
            assert.equal(report.deviceLost, true);
            assert.match(report.deviceLosses[0], /external Instance/);
        }
    });
}

test('all errors survive stdout and the JSON report without ten-message truncation', async (t) => {
    const { report, state } = await runMock(t, 'many-errors');
    assert.equal(report.passed, false);
    for (let i = 0; i < 25; i++) {
        assert.ok(report.errors.includes(`diagnostic-${i}`));
        assert.ok(state.output.some((line) => line === `[error] diagnostic-${i}`));
    }
});
