/**************************************************************************/
/*  rendering_device_driver.cpp                                           */
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

#include "rendering_device_driver.h"

/**************/
/**** MISC ****/
/**************/

uint64_t RenderingDeviceDriver::api_trait_get(ApiTrait p_trait) {
	// Sensible canonical defaults.
	switch (p_trait) {
		case API_TRAIT_HONORS_PIPELINE_BARRIERS:
			return 1;
		case API_TRAIT_SHADER_CHANGE_INVALIDATION:
			return SHADER_CHANGE_INVALIDATION_ALL_BOUND_UNIFORM_SETS;
		case API_TRAIT_TEXTURE_TRANSFER_ALIGNMENT:
			return 1;
		case API_TRAIT_TEXTURE_DATA_ROW_PITCH_STEP:
			return 1;
		case API_TRAIT_SECONDARY_VIEWPORT_SCISSOR:
			return 1;
		case API_TRAIT_CLEARS_WITH_COPY_ENGINE:
			return true;
		case API_TRAIT_USE_GENERAL_IN_COPY_QUEUES:
			return false;
		case API_TRAIT_BUFFERS_REQUIRE_TRANSITIONS:
			return false;
		case API_TRAIT_TEXTURE_OUTPUTS_REQUIRE_CLEARS:
			return false;
		case API_TRAIT_GPU_CALLS_MAIN_THREAD_ONLY:
			// Only WebGPU is pinned to the thread that created the device. Answering
			// here rather than in every driver keeps Metal/Vulkan/D3D12 off the error
			// path below - this is queried per frame, so the miss showed up as ~11k
			// "Method/function failed" lines in a 100-second desktop run.
			return false;
		// The traits below are WebGPU bridge-overhead optimizations: each is
		// defined as "if non-zero, take the WebGPU path", so every other driver
		// wants 0. Answering here rather than falling through to the error path
		// matters because they are queried per frame (some per draw) - on a
		// Vulkan device they produced a solid wall of "Method/function failed"
		// lines, and on a device that logs to slow storage the ERR_PRINT itself
		// costs more than the work being decided.
		case API_TRAIT_TEXTURE_GET_DATA_VIA_DRIVER:
		case API_TRAIT_TEXTURE_INITIALIZE_DIRECT_WRITE:
		case API_TRAIT_BUFFER_CREATE_MAPPED_AT_CREATION:
		case API_TRAIT_STAGING_BUFFER_MAX_SIZE_MB:
		case API_TRAIT_SKELETON_BUFFER_DIRECT_WRITE:
		case API_TRAIT_FORCE_OMNI_DUAL_PARABOLOID:
		case API_TRAIT_BATCH_INSTANCE_DRAWS:
		case API_TRAIT_FIRST_INSTANCE_INDEX:
			return 0;
		default:
			ERR_FAIL_V(0);
	}
}

/******************/

RenderingDeviceDriver::~RenderingDeviceDriver() {}
