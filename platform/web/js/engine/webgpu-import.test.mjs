import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile, mkdtemp, writeFile, rm } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { dirname, resolve, join } from 'node:path';
import { tmpdir } from 'node:os';
import vm from 'node:vm';

// Compile the production EM_ASM body together with the installed emdawn helper,
// as Emscripten does. The wrapper-only test cannot exercise this internal API.
const compiler = process.env.GODOT_CLOSURE_COMPILER;
assert.ok(compiler, 'Set GODOT_CLOSURE_COMPILER to the Emscripten Closure executable');
const sdkRoot = resolve(dirname(compiler), '../..');
const libraryPath = process.env.GODOT_EMDAWN_LIBRARY || join(sdkRoot,
	'cache/ports/emdawnwebgpu/emdawnwebgpu_pkg/webgpu/src/library_webgpu.js');
const library = await readFile(libraryPath, 'utf8');
const helper = library.match(/\n    importJsDevice: \(device, parentPtr = 0\) => \{([\s\S]*?)\n    \},/);
assert.ok(helper, 'The installed emdawn import helper must be present');
const driver = await readFile(new URL('../../../../drivers/webgpu/rendering_context_driver_webgpu.cpp', import.meta.url), 'utf8');
const body = driver.match(/device = \(WGPUDevice\)\(uintptr_t\)EM_ASM_PTR\(\{([\s\S]*?)\n\t\}\);/);
assert.ok(body, 'The production device import EM_ASM body must be present');

async function compileImport(importBody) {
	const directory = await mkdtemp(join(tmpdir(), 'godot-webgpu-closure-'));
	try {
		const input = join(directory, 'import.js');
		const output = join(directory, 'import.compiled.js');
		await writeFile(input, `
const objects = {};
function _emwgpuCreateQueue(parent) { return parent + 1; }
function _emwgpuCreateDevice(parent, queue) { return parent + 2; }
const WebGPU = {
  Internals: { jsObjectInsert: (ptr, object) => { objects[ptr] = object; } },
  importJsDevice: (device, parentPtr = 0) => { ${helper[1]} }
};
const Module = {};
globalThis['runImport'] = function(device) {
  Module['preinitializedWebGPUDevice'] = device;
  const handle = (function() { ${importBody} })();
  return { 'handle': handle, 'queue': objects[1], 'device': objects[2] };
};
`);
		execFileSync(process.execPath, [compiler, '--compilation_level', 'ADVANCED_OPTIMIZATIONS',
			'--externs', join(dirname(libraryPath), 'webgpu-externs.js'),
			'--js', input, '--js_output_file', output], { timeout: 60_000, stdio: 'pipe' });
		const context = vm.createContext({});
		vm.runInContext(await readFile(output, 'utf8'), context);
		return context.runImport;
	} finally {
		await rm(directory, { recursive: true, force: true });
	}
}

test('actual Closure keeps the production device import linked to the emdawn helper', async () => {
	const runImport = await compileImport(body[1]);
	const device = { queue: { label: 'queue' }, label: 'device' };
	const result = runImport(device);
	assert.equal(result.handle, 2);
	assert.strictEqual(result.device, device);
	assert.strictEqual(result.queue, device.queue);
	assert.equal(runImport(null).handle, 0);
});

test('old quoted import call fails against the same Closure-compiled helper', async () => {
	assert.match(body[1], /WebGPU\.importJsDevice\(d\)/);
	const oldBody = body[1].replace('WebGPU.importJsDevice(d)', 'WebGPU["importJsDevice"](d)');
	const runImport = await compileImport(oldBody);
	assert.throws(() => runImport({ queue: {} }), /importJsDevice is not a function/);
});
