import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const source = await readFile(new URL('./library_godot_fetch.js', import.meta.url), 'utf8');

function fixture(chunks) {
	const request = { response: {}, chunks: chunks.slice(), buffered: chunks.reduce((n, chunk) => n + chunk.length, 0) };
	const heap = new Uint8Array(1024);
	let reads = 0;
	const dependencies = [
		{ get: (id) => id === 7 ? request : null },
		{ heapCopy: (_heap, data, offset) => heap.set(data, offset) },
		heap,
		{ BUFFER_CAP: 8 * 1024 * 1024, read: (id) => { assert.equal(id, 7); reads++; } },
	];
	const load = (name) => {
		const match = source.match(new RegExp(`\\n\\t${name}: (function \\([^]*?\\n\\t\\}),`));
		assert.ok(match, `${name} implementation was not found`);
		// Execute the actual library implementation with a small simulated heap.
		// eslint-disable-next-line no-new-func
		return Function('IDHandler', 'GodotRuntime', 'HEAP8', 'GodotFetch', `return (${match[1]});`)(...dependencies);
	};
	return { request, heap, buffered: load('godot_js_fetch_get_buffered_size'),
		read: load('godot_js_fetch_read_chunk'), reads: () => reads };
}

test('partial reads retain immutable fetch views and drain chunks in order', () => {
	const first = Uint8Array.from([1, 2, 3, 4, 5]);
	const f = fixture([first, Uint8Array.from([6, 7]), Uint8Array.from([8, 9, 10])]);
	assert.equal(f.buffered(7), 10);
	assert.equal(f.read(7, 11, 3), 3);
	assert.deepEqual([...f.heap.subarray(11, 14)], [1, 2, 3]);
	assert.equal(f.request.chunks[0].buffer, first.buffer, 'the remainder is a view without another copy');
	assert.deepEqual([...first], [1, 2, 3, 4, 5], 'read does not mutate fetch data');
	assert.equal(f.buffered(7), 7);
	assert.equal(f.read(7, 14, 7), 7);
	assert.deepEqual([...f.heap.subarray(11, 21)], [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
	assert.equal(f.buffered(7), 0);
	assert.equal(f.request.chunks.length, 0);
	assert.equal(f.read(7, 0, 0), 0);
	assert.equal(f.reads(), 3, 'even an empty read starts/resumes the asynchronous reader');
	assert.equal(f.buffered(99), 0);
	assert.equal(f.read(99, 0, 32), 0);
});

test('variable-sized consumer polls preserve the exact response and bounded counts', () => {
	const bytes = Uint8Array.from({ length: 251 }, (_, i) => i);
	const chunks = [];
	for (let offset = 0; offset < bytes.length; offset += 13) chunks.push(bytes.subarray(offset, offset + 13));
	const f = fixture(chunks);
	let offset = 0;
	while (f.buffered(7)) {
		const available = Math.min(1 + offset % 29, f.buffered(7));
		assert.equal(f.read(7, offset, available), available);
		offset += available;
		assert.equal(f.buffered(7), bytes.length - offset);
	}
	assert.deepEqual(f.heap.subarray(0, offset), bytes);
	f.request.buffered = 0x80000000;
	assert.equal(f.buffered(7), 0x7fffffff, 'the signed integer ABI cannot overflow');
});
