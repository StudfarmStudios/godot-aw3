/**************************************************************************/
/*  rendering_shader_container_webgpu.cpp                                 */
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

#include "rendering_shader_container_webgpu.h"

#include <thirdparty/misc/smolv.h>

// =========================================================================
// SPIR-V Storage
// =========================================================================
//
// Architecture decision (see copilot-instructions.md #6):
//   GLSL → SPIR-V (glslang) → stored in the shader container.
//   The rendering driver decompresses it before preprocessing and Tint
//   translation, so the SPIR-V bytes used for WGSL cache keys stay stable.
//
// Push constant handling:
//   Godot's push constants are emulated via a uniform buffer at a fixed
//   bind group slot (default: group 3, binding 0).
//   The bind group slot is recorded in HeaderData and used by the driver
//   to create the pipeline layout and bind the ring buffer at draw time.

bool RenderingShaderContainerWebGPU::_set_code_from_spirv(const ReflectShader &p_shader) {
	const uint32_t stage_count = p_shader.shader_stages.size();
	shaders.resize(stage_count);

	for (uint32_t i = 0; i < stage_count; i++) {
		const ReflectShaderStage &stage = p_shader.shader_stages[i];
		const Vector<uint8_t> spirv_bytes = stage.spirv_data();
		ERR_FAIL_COND_V_MSG(spirv_bytes.is_empty(), false,
				vformat("Cannot store empty SPIR-V for WebGPU shader stage #%d.", i));
		ERR_FAIL_COND_V_MSG(spirv_bytes.size() > UINT32_MAX, false,
				vformat("SPIR-V for WebGPU shader stage #%d is too large.", i));

		RenderingShaderContainer::Shader &shader = shaders.write[i];
		shader.shader_stage = stage.shader_stage;

		// SMOL-V is lossless with kEncodeFlagNone, so the decoded bytes keep the
		// existing WGSL cache keys. Its structural encoding also remains friendly
		// to compression applied to the complete exported PCK.
		smolv::ByteArray smolv_bytes;
		const bool encoded = smolv::Encode(spirv_bytes.ptr(), spirv_bytes.size(), smolv_bytes, smolv::kEncodeFlagNone);

		if (encoded && smolv_bytes.size() < size_t(spirv_bytes.size())) {
			shader.code_decompressed_size = uint32_t(spirv_bytes.size());
			shader.code_compression_flags = COMPRESSION_FLAG_SMOLV;
			shader.code_compressed_bytes.resize(smolv_bytes.size());
			memcpy(shader.code_compressed_bytes.ptrw(), smolv_bytes.data(), smolv_bytes.size());
		} else {
			shader.code_decompressed_size = 0;
			shader.code_compression_flags = 0;
			shader.code_compressed_bytes = spirv_bytes;
		}
	}

	// Decide push constant bind group slot.
	if (p_shader.push_constant_size > 0) {
		// Convention: push constants use bind group 3, binding PUSH_CONSTANT_RING_BINDING (120).
		// Chosen high enough to avoid collision with split combined-sampler bindings
		// (original binding N → sampler@N*2, image@N*2+1; max reasonable N ~20 → max~41).
		// Must match the binding in spirv_preprocess::convert_push_constants_to_uniforms()
		// and PUSH_CONSTANT_RING_BINDING in rendering_device_driver_webgpu.h.
		header_data.push_constant_bind_group = 3;
		header_data.push_constant_binding = 120; // PUSH_CONSTANT_RING_BINDING
	} else {
		header_data.push_constant_bind_group = RenderingShaderContainerWebGPU::NO_PUSH_CONSTANTS;
		header_data.push_constant_binding = 120; // PUSH_CONSTANT_RING_BINDING
	}

	return true;
}

// =========================================================================
// Serialization
// =========================================================================

uint32_t RenderingShaderContainerWebGPU::_from_bytes_header_extra_data(const uint8_t *p_bytes) {
	if (p_bytes) {
		memcpy(&header_data, p_bytes, sizeof(HeaderData));
	}
	return sizeof(HeaderData);
}

uint32_t RenderingShaderContainerWebGPU::_to_bytes_header_extra_data(uint8_t *p_bytes) const {
	if (p_bytes) {
		memcpy(p_bytes, &header_data, sizeof(HeaderData));
	}
	return sizeof(HeaderData);
}

// =========================================================================
// Public API
// =========================================================================

RenderingShaderContainerWebGPU::RenderingShaderContainerWebGPU() {
}

RenderingShaderContainerWebGPU::~RenderingShaderContainerWebGPU() {
}

#endif // WEBGPU_ENABLED
