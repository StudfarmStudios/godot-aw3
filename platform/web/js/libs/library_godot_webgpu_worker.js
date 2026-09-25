/**************************************************************************/
/*  library_godot_webgpu_worker.js                                       */
/**************************************************************************/
/*                         This file is part of:                          */
/*                             GODOT ENGINE                               */
/**************************************************************************/
/* Copyright (c) 2014-present Godot Engine contributors (see AUTHORS.md). */
/* Copyright (c) 2007-2014 Juan Linietsky, Ariel Manzur.                  */
/*                                                                        */
/* Permission is hereby granted, free of charge, to any person obtaining  */
/* a copy of this software and associated documentation files (the        */
/* "Software"), to deal in the Software without restriction, including   */
/* without limitation the rights to use, copy, modify, merge, publish,    */
/* distribute, sublicense, and/or sell copies of the Software, and to     */
/* permit persons to whom the Software is furnished to do so, subject to  */
/* the following conditions:                                              */
/*                                                                        */
/* The above copyright notice and this permission notice shall be         */
/* included in all copies or substantial portions of the Software.        */
/*                                                                        */
/* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,       */
/* EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF    */
/* MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. */
/* IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY    */
/* CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,   */
/* TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE      */
/* SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.                 */
/**************************************************************************/

const GodotWebGPUWorker = {
	$GodotWebGPUWorker__deps: ['$GodotRuntime'],
	$GodotWebGPUWorker: {
		device: null,

		getDeviceDescriptor: function (adapter) {
			const requiredFeatures = [];
			if (adapter.features.has('timestamp-query')) {
				requiredFeatures.push('timestamp-query');
			}
			const optionalFeatures = [
				'readonly-and-readwrite-storage-textures',
				'depth32float-stencil8',
				'depth-clip-control',
				'texture-formats-tier1',
				'texture-formats-tier2',
				'float32-filterable',
				'float32-blendable',
				'rg11b10ufloat-renderable',
				'clip-distances',
				'dual-source-blending',
				'texture-compression-bc',
				'texture-compression-etc2',
				'texture-compression-astc',
			];
			for (const feature of optionalFeatures) {
				if (adapter.features.has(feature)) {
					requiredFeatures.push(feature);
				}
			}

			const requiredLimits = {};
			const limitsToMax = [
				'maxStorageBuffersPerShaderStage',
				'maxStorageBufferBindingSize',
				'maxBufferSize',
				'maxUniformBufferBindingSize',
				'maxUniformBuffersPerShaderStage',
				'maxSampledTexturesPerShaderStage',
				'maxSamplersPerShaderStage',
				'maxStorageTexturesPerShaderStage',
				'maxColorAttachments',
				'maxInterStageShaderVariables',
				'maxBindGroups',
				'maxStorageBuffersInFragmentStage',
				'maxStorageBuffersInVertexStage',
				'maxStorageTexturesInFragmentStage',
				'maxStorageTexturesInVertexStage',
			];
			for (const limit of limitsToMax) {
				if (adapter.limits[limit] !== undefined) {
					requiredLimits[limit] = adapter.limits[limit];
				}
			}
			return { requiredFeatures, requiredLimits };
		},

		monitorDevice: function (device) {
			device.lost.then(function (info) {
				if (info.reason !== 'destroyed') {
					console.error(`[Godot] WebGPU device lost (reason: ${info.reason || 'unknown'}): ${info.message || ''}`);
				}
			});
			device.addEventListener('uncapturederror', function (event) {
				const error = event.error;
				const kind = (error && error.constructor && error.constructor.name) || 'UnknownError';
				const message = (error && error.message) ? error.message : String(error);
				console.error(`[Godot] WebGPU uncaptured error: ${kind}: ${message}`);
			});
		},
	},

	// Intentionally unproxied: the GPUDevice and emdawn table must be created in
	// the PROXY_TO_PTHREAD application Worker's JavaScript realm.
	godot_js_webgpu_worker_preinitialize__sig: 'vi',
	godot_js_webgpu_worker_preinitialize: function (p_callback) {
		const callback = GodotRuntime.get_func(p_callback);
		let finished = false;
		const finish = function (error) {
			if (finished) {
				return false;
			}
			finished = true;
			clearTimeout(timeout);
			callback(error);
			return true;
		};
		const timeout = setTimeout(function () {
			console.error('[Godot] Timed out creating WebGPU device in the application Worker.');
			finish(1);
		}, 15000);

		if (typeof WorkerGlobalScope === 'undefined' || !(self instanceof WorkerGlobalScope)) {
			console.error('[Godot] Application-Worker WebGPU boot did not run in a Worker.');
			finish(1);
			return;
		}
		if (!navigator.gpu) {
			console.error('[Godot] WebGPU is unavailable in the application Worker.');
			finish(1);
			return;
		}

		navigator.gpu.requestAdapter({ powerPreference: 'high-performance' }).then(function (adapter) {
			if (!adapter) {
				throw new Error('WebGPU adapter not found in the application Worker');
			}
			return adapter.requestDevice(GodotWebGPUWorker.getDeviceDescriptor(adapter));
		}).then(function (device) {
			if (finished) {
				device.destroy();
				return;
			}
			GodotWebGPUWorker.device = device;
			Module['preinitializedWebGPUDevice'] = device;
			GodotWebGPUWorker.monitorDevice(device);
			finish(0);
		}).catch(function (error) {
			if (!finished) {
				console.error('[Godot] Failed to create WebGPU device in the application Worker:', error);
				finish(1);
				return;
			}
			// The device was delivered and the engine callback itself threw. That
			// exception unwound straight through the wasm frames of everything the
			// callback was running — no C++ destructor ran, so any lock those frames
			// held stays held, and this thread now sits idle with the engine half
			// started. Swallowing it here turned that into a silent hang; make it
			// impossible to miss instead.
			console.error('[Godot] Engine startup threw inside the WebGPU-ready callback (the thread is now idle):', error);
			throw error;
		});
	},

	// Also intentionally unproxied. RenderingContextDriverWebGPU releases its
	// imported C wrapper first; this destroys the underlying JS GPUDevice in the
	// same Worker realm and clears the last owned reference.
	godot_js_webgpu_worker_cleanup__sig: 'v',
	godot_js_webgpu_worker_cleanup: function () {
		if (GodotWebGPUWorker.device) {
			GodotWebGPUWorker.device.destroy();
			GodotWebGPUWorker.device = null;
		}
		Module['preinitializedWebGPUDevice'] = null;
	},
};

autoAddDeps(GodotWebGPUWorker, '$GodotWebGPUWorker');
addToLibrary(GodotWebGPUWorker);
