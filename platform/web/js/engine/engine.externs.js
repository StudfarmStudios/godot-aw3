var Godot;
var WebAssembly = {};
WebAssembly.instantiate = function(buffer, imports) {};
WebAssembly.instantiateStreaming = function(response, imports) {};

// WebGPU is not covered by Closure's default externs. The separately compiled
// engine wrapper must preserve these browser-owned names (navigator.gpu must
// not become navigator.g), including feature/limit dictionaries and callbacks.
Navigator.prototype.gpu;
/** @constructor */
var GPU = function() {};
GPU.prototype.requestAdapter = function(options) {};
var GPURequestAdapterOptions = {};
GPURequestAdapterOptions.powerPreference;
/** @constructor */
var GPUAdapter = function() {};
GPUAdapter.prototype.features;
GPUAdapter.prototype.limits;
GPUAdapter.prototype.requestDevice = function(descriptor) {};
var GPUDeviceDescriptor = {};
GPUDeviceDescriptor.requiredFeatures;
GPUDeviceDescriptor.requiredLimits;
/** @constructor */
var GPUDevice = function() {};
GPUDevice.prototype.lost;
var GPUDeviceLostInfo = {};
GPUDeviceLostInfo.reason;
GPUDeviceLostInfo.message;
var GPUUncapturedErrorEvent = {};
GPUUncapturedErrorEvent.error;
