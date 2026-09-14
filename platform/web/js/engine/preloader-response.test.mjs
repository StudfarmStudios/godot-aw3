import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';

const source = await readFile(new URL('./preloader.js', import.meta.url), 'utf8');
const engineSource = await readFile(new URL('./engine.js', import.meta.url), 'utf8');

function makePreloader(response) {
	const context = vm.createContext({
		ArrayBuffer,
		Headers,
		Promise,
		ReadableStream,
		Response,
		Uint8Array,
		fetch: async () => response,
		setTimeout,
	});
	vm.runInContext(`${source}\nglobalThis.Preloader = Preloader;`, context);
	return new context.Preloader();
}

test('native wasm Response is returned unchanged for streaming and progress uses a clone', async () => {
	const response = new Response(new Uint8Array([0, 97, 115, 109, 1, 0, 0, 0]), {
		headers: { 'content-type': 'application/wasm' },
	});
	Object.defineProperty(response, 'url', { value: 'https://example.test/game.wasm' });
	const clone = response.clone;
	const preloader = makePreloader(response);

	const loaded = await preloader.loadPromise('game.wasm', 8, true);
	assert.strictEqual(loaded, response);
	assert.equal(loaded.url, 'https://example.test/game.wasm');
	assert.strictEqual(loaded.clone, clone);
	assert.equal(loaded.headers.get('content-type'), 'application/wasm');
	await WebAssembly.instantiateStreaming(Promise.resolve(loaded.clone()));
	assert.deepEqual([...new Uint8Array(await loaded.arrayBuffer())], [0, 97, 115, 109, 1, 0, 0, 0]);
});

test('incorrect wasm MIME gets a corrected fallback Response while preserving body metadata', async () => {
	const response = new Response(new Uint8Array([4, 5]), {
		status: 206,
		statusText: 'Partial Content',
		headers: {
			'content-type': 'application/octet-stream',
			'x-test-header': 'kept',
		},
	});
	Object.defineProperty(response, 'url', { value: 'https://example.test/game.wasm' });
	const preloader = makePreloader(response);

	const loaded = await preloader.loadPromise('game.wasm', 2, true);
	assert.notStrictEqual(loaded, response);
	assert.equal(loaded.url, '', 'constructed fallback Responses cannot retain Response.url');
	assert.equal(loaded.status, 206);
	assert.equal(loaded.statusText, 'Partial Content');
	assert.equal(loaded.headers.get('content-type'), 'application/wasm');
	assert.equal(loaded.headers.get('x-test-header'), 'kept');
	assert.deepEqual([...new Uint8Array(await loaded.arrayBuffer())], [4, 5]);
});

test('parameterized wasm MIME also takes the fallback required by instantiateStreaming', async () => {
	const wasm = new Response(new Uint8Array([0, 97, 115, 109, 1, 0, 0, 0]), {
		headers: { 'content-type': 'application/wasm; charset=utf-8' },
	});
	const preloader = makePreloader(wasm);
	const loaded = await preloader.loadPromise('game.wasm', 8, true);
	assert.notStrictEqual(loaded, wasm);
	assert.equal(loaded.headers.get('content-type'), 'application/wasm');
	await WebAssembly.instantiateStreaming(Promise.resolve(loaded));
});

test('engine clones the preloader Response for restart-safe initialization', () => {
	assert.match(engineSource, /getModuleConfig\(loadPath, response\.clone\(\)\)/);
});
