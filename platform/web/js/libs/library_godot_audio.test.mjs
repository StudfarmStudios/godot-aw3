import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const source = await readFile(new URL('./library_godot_audio.js', import.meta.url), 'utf8');
const calls = [
	{ name: 'start', args: [16, 32, 2, 0.25, 1.5, 64], pointers: [0, 1, 5] },
	{ name: 'stop', args: [16], pointers: [0] },
	{ name: 'update_pitch_scale', args: [16, 1.5], pointers: [0] },
	{ name: 'set_volumes_linear', args: [16, 128, 2, 160, 4], pointers: [0, 1, 3] },
];

function loadLibrary(isRuntimeThread) {
	const library = {};
	const memory = new ArrayBuffer(4096);
	const heap32 = new Int32Array(memory);
	const heapF32 = new Float32Array(memory);
	heapF32.set([0.125, 0.25, 0.375, 0.5, 0.625, 0.75, 0.875, 1], 64 >> 2);
	heap32.set([3, 7], 128 >> 2);
	heapF32.set([0.25, 0.5, 0.75, 1], 160 >> 2);
	const strings = new Map([[16, 'playback'], [32, 'stream']]);
	const allocations = [];
	const submitted = [];
	let nextPointer = 512;
	const runtime = {
		malloc(size) {
			const pointer = nextPointer;
			nextPointer += Math.ceil(size / 8) * 8;
			allocations.push(pointer);
			return pointer;
		},
		parseString: (pointer) => strings.get(pointer),
		allocString(value) {
			const pointer = this.malloc(value.length + 1);
			strings.set(pointer, value);
			return pointer;
		},
	};
	const context = {
		LibraryManager: { library },
		autoAddDeps() {},
		mergeInto: (target, values) => Object.assign(target, values),
		GodotRuntime: runtime,
		HEAP32: heap32,
		HEAPF32: heapF32,
		_emscripten_is_main_runtime_thread: () => Number(isRuntimeThread),
	};
	for (const call of calls) {
		context[`_godot_audio_sample_${call.name}_main`] = (...args) => submitted.push(args);
	}
	// ENVIRONMENT_IS_PTHREAD intentionally does not exist in this context.
	vm.runInNewContext(source, context);
	return { library, heap32, heapF32, strings, allocations, submitted };
}

for (const isRuntimeThread of [true, false]) {
	for (const call of calls) {
		test(`${call.name}: ${isRuntimeThread ? 'runtime thread preserves borrowed arguments' : 'pthread owns copies before asynchronous dispatch'}`, () => {
			const fixture = loadLibrary(isRuntimeThread);
			const name = `godot_audio_sample_${call.name}`;
			fixture.library[name](...call.args);
			assert.ok(fixture.library[`${name}__deps`].includes('emscripten_is_main_runtime_thread'));
			assert.equal(fixture.library[`${name}_main__proxy`], 'async');
			assert.equal(fixture.submitted.length, 1);
			const args = fixture.submitted[0];
			assert.equal(args.at(-1), Number(!isRuntimeThread));
			if (isRuntimeThread) {
				assert.deepEqual(args.slice(0, -1), call.args);
				assert.deepEqual(fixture.allocations, []);
				return;
			}
			assert.equal(fixture.allocations.length, call.pointers.length);
			for (let index = 0; index < call.args.length; index++) {
				if (call.pointers.includes(index)) {
					assert.notEqual(args[index], call.args[index]);
				} else {
					assert.equal(args[index], call.args[index]);
				}
			}
			assert.equal(fixture.strings.get(args[0]), 'playback');
			fixture.strings.set(16, 'overwritten');
			assert.equal(fixture.strings.get(args[0]), 'playback');
			if (call.name === 'start') {
				assert.equal(fixture.strings.get(args[1]), 'stream');
				const expected = [...fixture.heapF32.subarray(16, 24)];
				fixture.heapF32.fill(99, 16, 24);
				assert.deepEqual([...fixture.heapF32.subarray(args[5] >> 2, (args[5] >> 2) + 8)], expected);
			}
			if (call.name === 'set_volumes_linear') {
				fixture.heap32.fill(99, 32, 34);
				fixture.heapF32.fill(99, 40, 44);
				assert.deepEqual([...fixture.heap32.subarray(args[1] >> 2, (args[1] >> 2) + 2)], [3, 7]);
				assert.deepEqual([...fixture.heapF32.subarray(args[3] >> 2, (args[3] >> 2) + 4)], [0.25, 0.5, 0.75, 1]);
			}
		});
	}
}
