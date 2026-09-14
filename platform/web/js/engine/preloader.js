const Preloader = /** @constructor */ function () { // eslint-disable-line no-unused-vars
	const startupTiming = typeof globalThis !== 'undefined'
		&& globalThis['GODOT_WEB_STARTUP_TIMING'] === true
		&& typeof performance !== 'undefined' && typeof performance.mark === 'function';
	function markDownload(file, phase) {
		if (!startupTiming) {
			return;
		}
		const basename = file.split('/').pop().replace(/[^a-zA-Z0-9_.-]/g, '_');
		performance.mark(`godot-web-${phase}-${basename}`);
	}

	function onloadprogress(reader, load_status, controller) {
		return reader.read().then(function (result) {
			if (load_status.done) {
				return Promise.resolve();
			}
			if (result.value) {
				if (controller) {
					controller.enqueue(result.value);
				}
				load_status.loaded += result.value.length;
			}
			if (!result.done) {
				return onloadprogress(reader, load_status, controller);
			}
			load_status.done = true;
			markDownload(load_status.file, 'download-end');
			return Promise.resolve();
		});
	}

	function getTrackedResponse(response, load_status) {
		const reader = response.body.getReader();
		return new Response(new ReadableStream({
			start: function (controller) {
				onloadprogress(reader, load_status, controller).then(function () {
					controller.close();
				});
			},
		}), { headers: response.headers });
	}

	function hasWasmContentType(response) {
		const contentType = response.headers.get('content-type');
		// WebAssembly.instantiateStreaming requires this exact MIME value. A
		// parameter or different casing must use the corrected fallback below.
		return contentType === 'application/wasm';
	}

	function withWasmContentType(response) {
		if (hasWasmContentType(response)) {
			// Keep the browser's original Response. In particular, this retains its
			// URL and native clone/cache metadata for WebAssembly streaming.
			return response;
		}
		const headers = new Headers(response.headers);
		headers.set('content-type', 'application/wasm');
		const init = { headers };
		// Opaque responses have status 0, which Response() does not accept. The
		// normal same-origin path keeps the original status and status text.
		if (response.status >= 200 && response.status <= 599) {
			init.status = response.status;
			init.statusText = response.statusText;
		}
		return new Response(response.clone().body, init);
	}

	function getNativeTrackedResponse(response, load_status) {
		try {
			// Read a clone solely for progress. Returning the original Response lets
			// instantiateStreaming retain its URL and browser code-cache identity.
			const progressResponse = response.clone();
			const reader = progressResponse.body && progressResponse.body.getReader();
			if (!reader) {
				load_status.done = true;
				markDownload(load_status.file, 'download-end');
				return response;
			}
			onloadprogress(reader, load_status, null).catch(function () {
				// Keep a failed progress side-channel from producing an unhandled
				// rejection or keeping the loading indicator alive forever.
				load_status.done = true;
			});
		} catch (e) {
			// Older/incomplete Fetch implementations may not support clone(). The
			// caller still receives the response and can consume it normally.
			load_status.done = true;
		}
		return response;
	}

	function loadFetch(file, tracker, fileSize, raw) {
		tracker[file] = {
			total: fileSize || 0,
			loaded: 0,
			done: false,
			file,
		};
		markDownload(file, 'download-start');
		return fetch(file).then(function (response) {
			if (!response.ok) {
				return Promise.reject(new Error(`Failed loading file '${file}'`));
			}
			if (raw) {
				return Promise.resolve(getNativeTrackedResponse(withWasmContentType(response), tracker[file]));
			}
			const tr = getTrackedResponse(response, tracker[file]);
			return tr.arrayBuffer();
		});
	}

	function retry(func, attempts = 1) {
		function onerror(err) {
			if (attempts <= 1) {
				return Promise.reject(err);
			}
			return new Promise(function (resolve, reject) {
				setTimeout(function () {
					retry(func, attempts - 1).then(resolve).catch(reject);
				}, 1000);
			});
		}
		return func().catch(onerror);
	}

	const DOWNLOAD_ATTEMPTS_MAX = 4;
	const loadingFiles = {};
	const lastProgress = { loaded: 0, total: 0 };
	let progressFunc = null;

	const animateProgress = function () {
		let loaded = 0;
		let total = 0;
		let totalIsValid = true;
		let progressIsFinal = true;

		Object.keys(loadingFiles).forEach(function (file) {
			const stat = loadingFiles[file];
			if (!stat.done) {
				progressIsFinal = false;
			}
			if (!totalIsValid || stat.total === 0) {
				totalIsValid = false;
				total = 0;
			} else {
				total += stat.total;
			}
			loaded += stat.loaded;
		});
		if (loaded !== lastProgress.loaded || total !== lastProgress.total) {
			lastProgress.loaded = loaded;
			lastProgress.total = total;
			if (typeof progressFunc === 'function') {
				progressFunc(loaded, total);
			}
		}
		if (!progressIsFinal) {
			requestAnimationFrame(animateProgress);
		}
	};

	this.animateProgress = animateProgress;

	this.setProgressFunc = function (callback) {
		progressFunc = callback;
	};

	this.loadPromise = function (file, fileSize, raw = false) {
		return retry(loadFetch.bind(null, file, loadingFiles, fileSize, raw), DOWNLOAD_ATTEMPTS_MAX);
	};

	this.preloadedFiles = [];
	this.preload = function (pathOrBuffer, destPath, fileSize) {
		let buffer = null;
		if (typeof pathOrBuffer === 'string') {
			const me = this;
			return this.loadPromise(pathOrBuffer, fileSize).then(function (buf) {
				me.preloadedFiles.push({
					path: destPath || pathOrBuffer,
					buffer: buf,
					// The buffer came from fetch() and this queue is consumed exactly
					// once by Engine.start().  MEMFS may retain its view directly,
					// avoiding a second copy of large packs.  Buffers supplied by a
					// caller below deliberately do not receive this marker.
					transferOwnership: true,
				});
				return Promise.resolve();
			});
		} else if (pathOrBuffer instanceof ArrayBuffer) {
			buffer = new Uint8Array(pathOrBuffer);
		} else if (ArrayBuffer.isView(pathOrBuffer)) {
			buffer = new Uint8Array(pathOrBuffer.buffer);
		}
		if (buffer) {
			this.preloadedFiles.push({
				path: destPath,
				buffer: pathOrBuffer,
			});
			return Promise.resolve();
		}
		return Promise.reject(new Error('Invalid object for preloading'));
	};
};
