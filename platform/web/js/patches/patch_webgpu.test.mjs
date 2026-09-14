import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const patchPath = new URL('./patch_webgpu.js', import.meta.url);
const patchSource = await readFile(patchPath, 'utf8');

function installPatch(bytes) {
	const memory = new Uint8Array(256);
	memory.set(bytes, 64);
	const heapU32 = new Uint32Array(memory.buffer);
	const calls = [];
	const oldString = () => 'old';
	const oldOptionalString = () => 'old-optional';
	const context = {
		WebGPU: {
			makeStringFromStringView: oldString,
			makeStringFromOptionalStringView: oldOptionalString,
		},
		HEAPU32: heapU32,
		UTF8ToString: (ptr, length, ignoreNul) => {
			calls.push({ ptr, length, ignoreNul });
			if (!ptr) {
				return '';
			}
			const end = ptr + length;
			let data = memory.subarray(ptr, end);
			if (!ignoreNul) {
				const nul = data.indexOf(0);
				if (nul !== -1) {
					data = data.subarray(0, nul);
				}
			}
			return new TextDecoder().decode(data);
		},
	};
	vm.runInNewContext(patchSource, context, { filename: patchPath.pathname });
	assert.notEqual(context.WebGPU.makeStringFromStringView, oldString);
	assert.notEqual(context.WebGPU.makeStringFromOptionalStringView, oldOptionalString);
	return { context, memory, heapU32, calls };
}

function setView(heapU32, address, ptr, length) {
	heapU32[address >> 2] = ptr;
	heapU32[(address + 4) >> 2] = length;
}

test('installs immediately and tolerates a missing WebGPU bridge', () => {
	const context = {
		HEAPU32: new Uint32Array(2),
		UTF8ToString: () => '',
	};
	assert.doesNotThrow(() => vm.runInNewContext(patchSource, context, { filename: patchPath.pathname }));
});

test('finite string views decode the exact byte range without scanning for NUL', () => {
	const { context, heapU32, calls } = installPatch(new TextEncoder().encode('a\0πtail'));
	setView(heapU32, 0, 64, 4); // a, NUL, π's first byte, π's second byte
	const value = context.WebGPU.makeStringFromStringView(0);
	assert.equal(value, 'a\0π');
	assert.deepEqual(calls.at(-1), { ptr: 64, length: 4, ignoreNul: true });
});

test('optional views preserve empty and undefined pointer semantics', () => {
	const { context, heapU32 } = installPatch(new Uint8Array());
	setView(heapU32, 0, 0, 0);
	assert.equal(context.WebGPU.makeStringFromOptionalStringView(0), '');
	setView(heapU32, 0, 0, 2);
	assert.equal(context.WebGPU.makeStringFromOptionalStringView(0), undefined);
	setView(heapU32, 0, 64, 0);
	assert.equal(context.WebGPU.makeStringFromOptionalStringView(0), '');
});

test('WGPU_STRLEN keeps null-terminated bridge behavior', () => {
	const { context, heapU32, calls } = installPatch(new TextEncoder().encode('sentinel\0tail'));
	setView(heapU32, 0, 64, 0xffffffff);
	assert.equal(context.WebGPU.makeStringFromStringView(0), 'sentinel');
	assert.deepEqual(calls.at(-1), { ptr: 64, length: 0xffffffff, ignoreNul: false });
});

test('non-optional null pointers still become empty strings', () => {
	const { context, heapU32, calls } = installPatch(new Uint8Array());
	setView(heapU32, 0, 0, 12);
	assert.equal(context.WebGPU.makeStringFromStringView(0), '');
	assert.deepEqual(calls.at(-1), { ptr: 0, length: 12, ignoreNul: true });
});
