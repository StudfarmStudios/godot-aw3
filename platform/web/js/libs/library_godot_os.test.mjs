import { URL } from 'node:url';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const source = await readFile(new URL('./library_godot_os.js', import.meta.url), 'utf8');
const helperSource = source.match(/\n\t\treserve_file: (function \(p_fd, p_capacity\) \{[\s\S]*?\n\t\t\}),\n/);
assert.ok(helperSource, 'reserve_file implementation was not found');
// Evaluate the exact Emscripten library helper rather than copying its logic into the test.
// eslint-disable-next-line no-new-func
const reserveFile = Function(`"use strict"; return (${helperSource[1]});`)();

function createMemfsFile(initialBytes) {
	const node = { mode: 0x8000, usedBytes: 0, contents: new Uint8Array(0) };
	const expand = (target, capacity) => {
		const contents = new Uint8Array(capacity);
		contents.set(target.contents.subarray(0, target.usedBytes));
		target.contents = contents;
	};
	globalThis.FS = {
		getStream: (fd) => fd === 7 ? { node } : null,
		isFile: (mode) => mode === 0x8000,
	};
	globalThis.MEMFS = { expandFileStorage: expand, stream_ops: { write() {} } };
	node.stream_ops = { write: globalThis.MEMFS.stream_ops.write };

	const write = (bytes) => {
		const data = Uint8Array.from(bytes);
		// Match MEMFS's first-write fast path: an empty file replaces any
		// preallocated buffer, which is why HTTPRequest reserves afterwards.
		if (node.usedBytes === 0) {
			node.contents = data.slice();
		} else if (node.usedBytes + data.length > node.contents.byteLength) {
			expand(node, node.usedBytes + data.length);
		}
		node.contents.set(data, node.usedBytes);
		node.usedBytes += data.length;
	};
	write(initialBytes);
	return { node, write };
}

test('MEMFS reservation preserves bytes and logical length through append, short EOF, and overrun', () => {
	const { node, write } = createMemfsFile([1, 2, 3]);
	assert.equal(reserveFile(7, 12), 1);
	assert.equal(node.usedBytes, 3);
	assert.deepEqual([...node.contents.subarray(0, node.usedBytes)], [1, 2, 3]);
	assert.ok(node.contents.byteLength >= 12);

	write([4, 5]);
	assert.equal(node.usedBytes, 5, 'an early EOF remains the bytes actually written');
	assert.deepEqual([...node.contents.subarray(0, node.usedBytes)], [1, 2, 3, 4, 5]);

	write([6, 7, 8, 9, 10, 11, 12, 13, 14]);
	assert.equal(node.usedBytes, 14, 'the hint is not a response-size limit');
	assert.deepEqual([...node.contents.subarray(0, node.usedBytes)],
		[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14]);
});

test('failed or unsupported reservation preserves incremental writes', () => {
	const { node, write } = createMemfsFile([21, 22]);
	globalThis.MEMFS.expandFileStorage = () => {
		throw new RangeError('out of memory');
	};
	assert.equal(reserveFile(7, 64), 0);
	assert.equal(node.usedBytes, 2);
	assert.deepEqual([...node.contents], [21, 22]);

	globalThis.MEMFS.expandFileStorage = (target, capacity) => {
		const contents = new Uint8Array(capacity);
		contents.set(target.contents.subarray(0, target.usedBytes));
		target.contents = contents;
	};
	write([23]);
	assert.equal(node.usedBytes, 3);
	assert.deepEqual([...node.contents.subarray(0, node.usedBytes)], [21, 22, 23]);

	assert.equal(reserveFile(99, 64), 0, 'unknown file descriptor falls back');
	node.mode = 0x4000;
	assert.equal(reserveFile(7, 64), 0, 'non-regular files fall back');
	node.mode = 0x8000;
	assert.equal(reserveFile(7, -1), 0, 'invalid capacities fall back');
	node.stream_ops = { write() {} };
	assert.equal(reserveFile(7, 64), 0, 'other filesystem backends fall back');
});
