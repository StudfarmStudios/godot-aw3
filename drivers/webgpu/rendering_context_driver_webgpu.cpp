/**************************************************************************/
/*  rendering_context_driver_webgpu.cpp                                   */
/**************************************************************************/
/*                         This file is part of:                          */
/*                             GODOT ENGINE                               */
/*                        https://godotengine.org                         */
/**************************************************************************/
/* Copyright (c) 2014-present Godot Engine contributors (see AUTHORS.md). */
/* Copyright (c) 2007-2014 Juan Linietsky, Ariel Manzur.                  */
/*                                                                        */
/* Permission is hereby granted, free of charge, to any person obtaining  */
/* a copy of this software and associated documentation files (the        */
/* "Software"), to deal in the Software without restriction, including    */
/* without limitation the rights to use, copy, modify, merge, publish,    */
/* distribute, sublicense, and/or sell copies of the Software, and to     */
/* permit persons to whom the Software is furnished to do so, subject to  */
/* the following conditions:                                              */
/*                                                                        */
/* The above copyright notice and this permission notice shall be         */
/* included in all copies or substantial portions of the Software.        */
/*                                                                        */
/* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,        */
/* EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF     */
/* MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. */
/* IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY   */
/* CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,   */
/* TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE      */
/* SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.                 */
/**************************************************************************/

#ifdef WEBGPU_ENABLED

#include "rendering_context_driver_webgpu.h"
#include "rendering_device_driver_webgpu.h"

#ifdef __EMSCRIPTEN__
// html5_webgpu.h was removed in Emscripten 5.x when USE_WEBGPU was dropped.
// Device is now created from C++ using the emdawnwebgpu port's Dawn API.
#include <emscripten/emscripten.h>
#else
#include "core/templates/vector.h"

#include <cstdint>

namespace {

static String _string_from_webgpu(WGPUStringView p_string) {
	if (p_string.data == nullptr) {
		return String();
	}
	return String::utf8(p_string.data, p_string.length == WGPU_STRLEN ? -1 : (int)p_string.length);
}

struct AdapterRequestResult {
	WGPUAdapter adapter = nullptr;
	String message;
};

struct DeviceRequestResult {
	WGPUDevice device = nullptr;
	String message;
};

static void _adapter_request_callback(WGPURequestAdapterStatus p_status, WGPUAdapter p_adapter, WGPUStringView p_message, void *p_userdata1, void *p_userdata2) {
	AdapterRequestResult *result = static_cast<AdapterRequestResult *>(p_userdata1);
	if (p_status == WGPURequestAdapterStatus_Success) {
		result->adapter = p_adapter;
	}
	result->message = _string_from_webgpu(p_message);
}

static void _device_request_callback(WGPURequestDeviceStatus p_status, WGPUDevice p_device, WGPUStringView p_message, void *p_userdata1, void *p_userdata2) {
	DeviceRequestResult *result = static_cast<DeviceRequestResult *>(p_userdata1);
	if (p_status == WGPURequestDeviceStatus_Success) {
		result->device = p_device;
	}
	result->message = _string_from_webgpu(p_message);
}

static void _device_lost_callback(WGPUDevice const *p_device, WGPUDeviceLostReason p_reason, WGPUStringView p_message, void *p_userdata1, void *p_userdata2) {
	if (p_reason == WGPUDeviceLostReason_Destroyed) {
		print_verbose("WebGPU: Dawn device destroyed.");
		return;
	}
	ERR_PRINT(vformat("WebGPU: Dawn device lost (reason %d): %s", (int)p_reason, _string_from_webgpu(p_message)));
}

static void _uncaptured_error_callback(WGPUDevice const *p_device, WGPUErrorType p_type, WGPUStringView p_message, void *p_userdata1, void *p_userdata2) {
	ERR_PRINT(vformat("WebGPU: Dawn uncaptured error (type %d): %s", (int)p_type, _string_from_webgpu(p_message)));
}

static bool _wait_for_future(WGPUInstance p_instance, WGPUFuture p_future) {
	WGPUFutureWaitInfo wait_info = WGPU_FUTURE_WAIT_INFO_INIT;
	wait_info.future = p_future;
	return wgpuInstanceWaitAny(p_instance, 1, &wait_info, UINT64_MAX) == WGPUWaitStatus_Success && wait_info.completed;
}

static bool _adapter_has_feature(const WGPUSupportedFeatures &p_supported, WGPUFeatureName p_feature) {
	for (size_t i = 0; i < p_supported.featureCount; i++) {
		if (p_supported.features[i] == p_feature) {
			return true;
		}
	}
	return false;
}

} // namespace
#endif

RenderingContextDriverWebGPU::RenderingContextDriverWebGPU() {
}

RenderingContextDriverWebGPU::~RenderingContextDriverWebGPU() {
	if (queue) {
		wgpuQueueRelease(queue);
		queue = nullptr;
	}
	if (device) {
		wgpuDeviceRelease(device);
		device = nullptr;
	}
	if (adapter) {
		wgpuAdapterRelease(adapter);
		adapter = nullptr;
	}
	if (instance) {
		wgpuInstanceRelease(instance);
		instance = nullptr;
	}
}

Error RenderingContextDriverWebGPU::initialize() {
#ifdef __EMSCRIPTEN__
	// The HTML shell pre-initializes a GPUDevice and stores it in Module.preinitializedWebGPUDevice.
	// We use the emdawnwebgpu port's WebGPU.importJsDevice() to wrap it in a C WGPUDevice handle.
	// Note: emdawnwebgpu is a thin JS wrapper around the browser's WebGPU API.
	// SPIR-V is NOT supported — we use Tint (C++, linked in) for SPIR-V → WGSL
	// conversion in shader_create_from_container() instead.
	// Create a WGPUInstance — needed for wgpuInstanceProcessEvents() which
	// processes async callbacks (buffer map readback, query results, etc.).
	WGPUInstanceDescriptor inst_desc = {};
	instance = wgpuCreateInstance(&inst_desc);
	if (!instance) {
		WARN_PRINT("WebGPU: wgpuCreateInstance returned null — async readback may not work.");
	}

	device = (WGPUDevice)(uintptr_t)EM_ASM_PTR({
		var d = Module["preinitializedWebGPUDevice"];
		if (!d) { return 0; }
		return WebGPU["importJsDevice"](d);
	});
	ERR_FAIL_COND_V_MSG(device == nullptr, ERR_CANT_CREATE, "WebGPU: Failed to get pre-initialized device. Ensure JS shell calls navigator.gpu.requestDevice() before WASM.");

	queue = wgpuDeviceGetQueue(device);
	ERR_FAIL_COND_V_MSG(queue == nullptr, ERR_CANT_CREATE, "WebGPU: Failed to get device queue.");

	// Populate device info.
	device_info.name = "WebGPU Device";
	device_info.vendor = Vendor::VENDOR_UNKNOWN;
	device_info.type = DEVICE_TYPE_INTEGRATED_GPU;

	print_verbose("WebGPU: Device imported from JS successfully.");
#else
	// TimedWaitAny lets startup synchronously wait for Dawn's async adapter and
	// device requests without spinning the macOS event loop.
	WGPUInstanceFeatureName instance_feature = WGPUInstanceFeatureName_TimedWaitAny;
	WGPUInstanceLimits instance_limits = WGPU_INSTANCE_LIMITS_INIT;
	instance_limits.timedWaitAnyMaxCount = 1;
	WGPUInstanceDescriptor instance_desc = WGPU_INSTANCE_DESCRIPTOR_INIT;
	instance_desc.requiredFeatureCount = 1;
	instance_desc.requiredFeatures = &instance_feature;
	instance_desc.requiredLimits = &instance_limits;
	instance = wgpuCreateInstance(&instance_desc);
	ERR_FAIL_NULL_V_MSG(instance, ERR_CANT_CREATE, "WebGPU: Dawn failed to create an instance.");

	AdapterRequestResult adapter_result;
	WGPURequestAdapterOptions adapter_options = WGPU_REQUEST_ADAPTER_OPTIONS_INIT;
	adapter_options.powerPreference = WGPUPowerPreference_HighPerformance;
	adapter_options.backendType = WGPUBackendType_Metal;
	WGPURequestAdapterCallbackInfo adapter_callback = WGPU_REQUEST_ADAPTER_CALLBACK_INFO_INIT;
	adapter_callback.mode = WGPUCallbackMode_WaitAnyOnly;
	adapter_callback.callback = _adapter_request_callback;
	adapter_callback.userdata1 = &adapter_result;
	WGPUFuture adapter_future = wgpuInstanceRequestAdapter(instance, &adapter_options, adapter_callback);
	ERR_FAIL_COND_V_MSG(!_wait_for_future(instance, adapter_future), ERR_CANT_CREATE, "WebGPU: Timed out waiting for Dawn's Metal adapter.");
	ERR_FAIL_NULL_V_MSG(adapter_result.adapter, ERR_CANT_CREATE, vformat("WebGPU: Dawn failed to create a Metal adapter: %s", adapter_result.message));
	adapter = adapter_result.adapter;

	// Match the optional features requested by the browser shell. Native Dawn
	// exposes more implementation-only features; deliberately avoid enabling
	// those so native runs remain representative of browser WebGPU.
	static const WGPUFeatureName optional_features[] = {
		WGPUFeatureName_TimestampQuery,
		WGPUFeatureName_Depth32FloatStencil8,
		WGPUFeatureName_DepthClipControl,
		WGPUFeatureName_TextureFormatsTier1,
		WGPUFeatureName_TextureFormatsTier2,
		WGPUFeatureName_Float32Filterable,
		WGPUFeatureName_Float32Blendable,
		WGPUFeatureName_RG11B10UfloatRenderable,
		WGPUFeatureName_ClipDistances,
		WGPUFeatureName_DualSourceBlending,
		WGPUFeatureName_TextureCompressionBC,
		WGPUFeatureName_TextureCompressionETC2,
		WGPUFeatureName_TextureCompressionASTC,
	};
	WGPUSupportedFeatures supported_features = WGPU_SUPPORTED_FEATURES_INIT;
	wgpuAdapterGetFeatures(adapter, &supported_features);
	Vector<WGPUFeatureName> required_features;
	for (WGPUFeatureName feature : optional_features) {
		if (_adapter_has_feature(supported_features, feature)) {
			required_features.push_back(feature);
		}
	}

	WGPULimits adapter_limits = WGPU_LIMITS_INIT;
	bool have_adapter_limits = wgpuAdapterGetLimits(adapter, &adapter_limits) == WGPUStatus_Success;
	WGPUDeviceDescriptor device_desc = WGPU_DEVICE_DESCRIPTOR_INIT;
	device_desc.label = WGPUStringView{ "Godot WebGPU device", WGPU_STRLEN };
	device_desc.requiredFeatureCount = required_features.size();
	device_desc.requiredFeatures = required_features.is_empty() ? nullptr : required_features.ptr();
	device_desc.requiredLimits = have_adapter_limits ? &adapter_limits : nullptr;
	device_desc.deviceLostCallbackInfo.mode = WGPUCallbackMode_AllowSpontaneous;
	device_desc.deviceLostCallbackInfo.callback = _device_lost_callback;
	device_desc.uncapturedErrorCallbackInfo.callback = _uncaptured_error_callback;

	DeviceRequestResult device_result;
	WGPURequestDeviceCallbackInfo device_callback = WGPU_REQUEST_DEVICE_CALLBACK_INFO_INIT;
	device_callback.mode = WGPUCallbackMode_WaitAnyOnly;
	device_callback.callback = _device_request_callback;
	device_callback.userdata1 = &device_result;
	WGPUFuture device_future = wgpuAdapterRequestDevice(adapter, &device_desc, device_callback);
	ERR_FAIL_COND_V_MSG(!_wait_for_future(instance, device_future), ERR_CANT_CREATE, "WebGPU: Timed out waiting for Dawn's Metal device.");
	wgpuSupportedFeaturesFreeMembers(supported_features);
	ERR_FAIL_NULL_V_MSG(device_result.device, ERR_CANT_CREATE, vformat("WebGPU: Dawn failed to create a Metal device: %s", device_result.message));
	device = device_result.device;

	queue = wgpuDeviceGetQueue(device);
	ERR_FAIL_NULL_V_MSG(queue, ERR_CANT_CREATE, "WebGPU: Dawn failed to get the device queue.");

	WGPUAdapterInfo adapter_info = WGPU_ADAPTER_INFO_INIT;
	if (wgpuAdapterGetInfo(adapter, &adapter_info) == WGPUStatus_Success) {
		device_info.name = _string_from_webgpu(adapter_info.device);
		if (device_info.name.is_empty()) {
			device_info.name = _string_from_webgpu(adapter_info.description);
		}
		device_info.vendor = adapter_info.vendorID;
		switch (adapter_info.adapterType) {
			case WGPUAdapterType_DiscreteGPU:
				device_info.type = DEVICE_TYPE_DISCRETE_GPU;
				break;
			case WGPUAdapterType_IntegratedGPU:
				device_info.type = DEVICE_TYPE_INTEGRATED_GPU;
				break;
			case WGPUAdapterType_CPU:
				device_info.type = DEVICE_TYPE_CPU;
				break;
			default:
				device_info.type = DEVICE_TYPE_OTHER;
				break;
		}
		wgpuAdapterInfoFreeMembers(adapter_info);
	} else {
		device_info.name = "Dawn Metal device";
		device_info.vendor = Vendor::VENDOR_APPLE;
		device_info.type = DEVICE_TYPE_INTEGRATED_GPU;
	}

	print_verbose(vformat("WebGPU: Native Dawn Metal device initialized: %s", device_info.name));
#endif
	return OK;
}

const RenderingContextDriver::Device &RenderingContextDriverWebGPU::device_get(uint32_t p_device_index) const {
	DEV_ASSERT(p_device_index == 0);
	return device_info;
}

uint32_t RenderingContextDriverWebGPU::device_get_count() const {
	return 1;
}

bool RenderingContextDriverWebGPU::device_supports_present(uint32_t p_device_index, SurfaceID p_surface) const {
	return true; // Single device always supports the canvas surface.
}

RenderingDeviceDriver *RenderingContextDriverWebGPU::driver_create() {
	return memnew(RenderingDeviceDriverWebGPU(this));
}

void RenderingContextDriverWebGPU::driver_free(RenderingDeviceDriver *p_driver) {
	memdelete(p_driver);
}

RenderingContextDriver::SurfaceID RenderingContextDriverWebGPU::surface_create(const void *p_platform_data) {
#ifdef __EMSCRIPTEN__
	// p_platform_data is expected to contain a canvas selector string (e.g., "#canvas").
	// For the web platform, we use the default canvas "#canvas".
	const char *canvas_selector = "#canvas";
	if (p_platform_data != nullptr) {
		// TODO: Extract canvas selector from platform data if provided.
		// For now, use default.
	}

	// Emscripten 5.x / emdawnwebgpu renamed this struct.
	WGPUEmscriptenSurfaceSourceCanvasHTMLSelector canvas_desc = {};
	canvas_desc.chain.sType = WGPUSType_EmscriptenSurfaceSourceCanvasHTMLSelector;
	canvas_desc.selector = WGPUStringView{ canvas_selector, WGPU_STRLEN };

	WGPUSurfaceDescriptor surface_desc = {};
	surface_desc.nextInChain = (WGPUChainedStruct *)&canvas_desc;

	// Note: We need an instance to create a surface. If we don't have one,
	// create a minimal one. In Emscripten, the instance is a lightweight wrapper.
	if (instance == nullptr) {
		WGPUInstanceDescriptor inst_desc = {};
		instance = wgpuCreateInstance(&inst_desc);
	}
#else
	const WindowPlatformData *window_data = static_cast<const WindowPlatformData *>(p_platform_data);
	ERR_FAIL_NULL_V_MSG(window_data, 0, "WebGPU: Missing macOS window platform data.");
	ERR_FAIL_NULL_V_MSG(window_data->metal_layer, 0, "WebGPU: Missing CAMetalLayer for the native Dawn surface.");

	WGPUSurfaceSourceMetalLayer metal_desc = WGPU_SURFACE_SOURCE_METAL_LAYER_INIT;
	metal_desc.layer = window_data->metal_layer;
	WGPUSurfaceDescriptor surface_desc = WGPU_SURFACE_DESCRIPTOR_INIT;
	surface_desc.nextInChain = &metal_desc.chain;
#endif

	WGPUSurface wgpu_surface = wgpuInstanceCreateSurface(instance, &surface_desc);
	ERR_FAIL_COND_V_MSG(wgpu_surface == nullptr, 0, "WebGPU: Failed to create the presentation surface.");

	SurfaceID id = next_surface_id++;
	Surface &surface = surfaces[id];
	surface.handle = wgpu_surface;
	surface.width = 0;
	surface.height = 0;
	surface.needs_resize = true;

	return id;
}

void RenderingContextDriverWebGPU::surface_set_size(SurfaceID p_surface, uint32_t p_width, uint32_t p_height) {
	ERR_FAIL_COND(!surfaces.has(p_surface));
	Surface &surface = surfaces[p_surface];
	if (surface.width != p_width || surface.height != p_height) {
		surface.width = p_width;
		surface.height = p_height;
		surface.needs_resize = true;
	}
}

void RenderingContextDriverWebGPU::surface_set_vsync_mode(SurfaceID p_surface, DisplayServerEnums::VSyncMode p_vsync_mode) {
	ERR_FAIL_COND(!surfaces.has(p_surface));
	surfaces[p_surface].vsync_mode = p_vsync_mode;
}

DisplayServerEnums::VSyncMode RenderingContextDriverWebGPU::surface_get_vsync_mode(SurfaceID p_surface) const {
	ERR_FAIL_COND_V(!surfaces.has(p_surface), DisplayServerEnums::VSYNC_ENABLED);
	return surfaces[p_surface].vsync_mode;
}

uint32_t RenderingContextDriverWebGPU::surface_get_width(SurfaceID p_surface) const {
	ERR_FAIL_COND_V(!surfaces.has(p_surface), 0);
	return surfaces[p_surface].width;
}

uint32_t RenderingContextDriverWebGPU::surface_get_height(SurfaceID p_surface) const {
	ERR_FAIL_COND_V(!surfaces.has(p_surface), 0);
	return surfaces[p_surface].height;
}

void RenderingContextDriverWebGPU::surface_set_needs_resize(SurfaceID p_surface, bool p_needs_resize) {
	ERR_FAIL_COND(!surfaces.has(p_surface));
	surfaces[p_surface].needs_resize = p_needs_resize;
}

bool RenderingContextDriverWebGPU::surface_get_needs_resize(SurfaceID p_surface) const {
	ERR_FAIL_COND_V(!surfaces.has(p_surface), false);
	return surfaces[p_surface].needs_resize;
}

void RenderingContextDriverWebGPU::surface_destroy(SurfaceID p_surface) {
	ERR_FAIL_COND(!surfaces.has(p_surface));
	Surface &surface = surfaces[p_surface];
	if (surface.handle) {
		wgpuSurfaceRelease(surface.handle);
	}
	surfaces.erase(p_surface);
}

bool RenderingContextDriverWebGPU::is_debug_utils_enabled() const {
	return false; // No debug utils in browser WebGPU.
}

WGPUSurface RenderingContextDriverWebGPU::surface_get_handle(SurfaceID p_surface) const {
	const Surface *s = surfaces.getptr(p_surface);
	ERR_FAIL_COND_V(s == nullptr, nullptr);
	return s->handle;
}

#endif // WEBGPU_ENABLED
