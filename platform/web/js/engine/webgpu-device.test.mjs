import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';

// Supply the actual separately Closure-compiled wrapper to exercise its public
// API boundary. Without it, test the same concatenated sources as SCsub.
const source = process.env.GODOT_ENGINE_WRAPPER
	? await readFile(process.env.GODOT_ENGINE_WRAPPER, 'utf8')
	: (await Promise.all(['features.js', 'preloader.js', 'config.js', 'engine.js']
		.map((name) => readFile(new URL(name, import.meta.url), 'utf8')))).join('\n')
		.replaceAll('___GODOT_THREADS_ENABLED', 'false')
		.replaceAll('___GODOT_PROXY_TO_PTHREAD_ENABLED', 'false');

function loadWrapper(gpu, navigatorAvailable = true) {
	const errors = [];
	const context = vm.createContext({
		console: { error: (message) => errors.push(String(message)) },
		window: {},
	});
	if (navigatorAvailable) context.navigator = { gpu };
	vm.runInContext(source, context);
	return { engine: context.window.Engine, errors };
}

function makeGPU(features = [], limits = {}) {
	const calls = {};
	let resolveLost;
	const device = {
		lost: new Promise((resolve) => { resolveLost = resolve; }),
		addEventListener(type, callback) { calls[type] = callback; },
	};
	const adapter = {
		features: new Set(features),
		limits,
		requestDevice(descriptor) {
			calls.descriptor = descriptor;
			return Promise.resolve(device);
		},
	};
	const gpu = {
		requestAdapter(options) {
			calls.options = options;
			return Promise.resolve(adapter);
		},
	};
	return { gpu, calls, device, resolveLost };
}

test('public WebGPU methods, feature names and limit descriptor keys survive Closure', async () => {
	const fixture = makeGPU(['timestamp-query', 'float32-filterable', 'texture-compression-bc'], {
		maxStorageBuffersPerShaderStage: 12,
		maxStorageTexturesInFragmentStage: 8,
	});
	const { engine } = loadWrapper(fixture.gpu);
	assert.strictEqual(await engine.requestWebGPUDevice(), fixture.device);
	assert.equal(fixture.calls.options.powerPreference, 'high-performance');
	assert.deepEqual(Array.from(fixture.calls.descriptor.requiredFeatures), [
		'timestamp-query', 'float32-filterable', 'texture-compression-bc',
	]);
	assert.deepEqual(Object.keys(fixture.calls.descriptor).sort(), ['requiredFeatures', 'requiredLimits']);
	assert.equal(fixture.calls.descriptor.requiredLimits.maxStorageBuffersPerShaderStage, 12);
	assert.equal(fixture.calls.descriptor.requiredLimits.maxStorageTexturesInFragmentStage, 8);
	assert.equal(fixture.calls.descriptor.requiredLimits.maxBufferSize, undefined);
});

test('caller-provided browser dictionaries keep their public keys and identity', async () => {
	const fixture = makeGPU(['float32-filterable']);
	const { engine } = loadWrapper(fixture.gpu);
	const options = { powerPreference: 'low-power', forceFallbackAdapter: true };
	const descriptor = {
		label: 'test device',
		requiredFeatures: ['caller-feature'],
		requiredLimits: { maxComputeInvocationsPerWorkgroup: 128 },
		defaultQueue: { label: 'test queue' },
	};
	assert.strictEqual(await engine.requestWebGPUDevice(options, descriptor), fixture.device);
	assert.strictEqual(fixture.calls.options, options);
	assert.strictEqual(fixture.calls.descriptor, descriptor);
	assert.deepEqual(descriptor.requiredFeatures, ['caller-feature', 'float32-filterable']);
	assert.equal(descriptor.requiredLimits.maxComputeInvocationsPerWorkgroup, 128);
	assert.equal(descriptor.defaultQueue.label, 'test queue');
});

test('missing optional features and limits do not invent browser requirements', async () => {
	const fixture = makeGPU([], null);
	const { engine } = loadWrapper(fixture.gpu);
	assert.strictEqual(await engine.requestWebGPUDevice(), fixture.device);
	assert.deepEqual(Array.from(fixture.calls.descriptor.requiredFeatures), []);
	assert.deepEqual(Object.keys(fixture.calls.descriptor.requiredLimits), []);
});

test('device loss and validation errors retain public event fields and diagnostics', async () => {
	const fixture = makeGPU();
	const { engine, errors } = loadWrapper(fixture.gpu);
	await engine.requestWebGPUDevice();
	fixture.resolveLost({ reason: 'destroyed', message: 'device retired' });
	await Promise.resolve();
	class GPUValidationError extends Error {}
	fixture.calls.uncapturederror({ error: new GPUValidationError('invalid binding') });
	assert.deepEqual(errors, [
		'[Godot] WebGPU device lost (reason: destroyed): device retired',
		'[Godot] WebGPU uncaptured error: GPUValidationError: invalid binding',
	]);
});

test('missing navigator or GPU rejects without attempting browser calls', async () => {
	for (const navigatorAvailable of [false, true]) {
		const { engine } = loadWrapper(undefined, navigatorAvailable);
		await assert.rejects(engine.requestWebGPUDevice(), /WebGPU is not supported/);
	}
});

test('a missing adapter remains an explicit rejection', async () => {
	const { engine } = loadWrapper({ requestAdapter: async () => null });
	await assert.rejects(engine.requestWebGPUDevice(), /WebGPU adapter not found/);
});
