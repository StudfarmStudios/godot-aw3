/**************************************************************************/
/*  fsr.cpp                                                               */
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

#include "fsr.h"

#include "servers/rendering/renderer_rd/effects/copy_effects.h"
#include "servers/rendering/renderer_rd/framebuffer_cache_rd.h"
#include "servers/rendering/renderer_rd/storage_rd/material_storage.h"
#include "servers/rendering/renderer_rd/uniform_set_cache_rd.h"

using namespace RendererRD;

FSR::FSR() {
	Vector<String> fsr_upscale_modes;
	fsr_upscale_modes.push_back("\n#define MODE_FSR_UPSCALE_NORMAL\n");
	fsr_upscale_modes.push_back("\n#define MODE_FSR_UPSCALE_FALLBACK\n");
	fsr_shader.initialize(fsr_upscale_modes);

	if (RD::get_singleton()->has_feature(RD::SUPPORTS_HALF_FLOAT)) {
		shader_variant = FSR_SHADER_VARIANT_NORMAL;
	} else {
		shader_variant = FSR_SHADER_VARIANT_FALLBACK;
		// The normal variant uses 16-bit types the driver cannot run (WGSL has
		// no i16/u16) - do not compile what can only fail.
		fsr_shader.set_variant_enabled(FSR_SHADER_VARIANT_NORMAL, false);
	}

	shader_version = fsr_shader.version_create();
	pipeline.create_compute_pipeline(fsr_shader.version_get_shader(shader_version, shader_variant));
}

FSR::~FSR() {
	pipeline.free();
	fsr_shader.version_free(shader_version);
}

void FSR::process(Ref<RenderSceneBuffersRD> p_render_buffers, RID p_source_rd_texture, RID p_destination_texture) {
	UniformSetCacheRD *uniform_set_cache = UniformSetCacheRD::get_singleton();
	ERR_FAIL_NULL(uniform_set_cache);
	MaterialStorage *material_storage = MaterialStorage::get_singleton();
	ERR_FAIL_NULL(material_storage);

	ERR_FAIL_COND(p_render_buffers.is_null());
	RID shader = fsr_shader.version_get_shader(shader_version, shader_variant);
	ERR_FAIL_COND(shader.is_null());
	RID pipeline_rid = pipeline.get_rid();
	ERR_FAIL_COND(pipeline_rid.is_null());

	Size2i internal_size = p_render_buffers->get_internal_size();
	Size2i target_size = p_render_buffers->get_target_size();
	float fsr_upscale_sharpness = p_render_buffers->get_fsr_sharpness();
	ERR_FAIL_COND(internal_size.x <= 0 || internal_size.y <= 0 || target_size.x <= 0 || target_size.y <= 0);

	// Both passes declare an rgba16f image2D. Render targets may omit storage
	// usage (e.g. WebGPU targets with sRGB views), or use a different format.
	const RD::TextureFormat destination_format = RD::get_singleton()->texture_get_format(p_destination_texture);
	ERR_FAIL_COND(destination_format.texture_type != RD::TEXTURE_TYPE_2D || destination_format.array_layers != 1);
	ERR_FAIL_COND(destination_format.width != uint32_t(target_size.x) || destination_format.height != uint32_t(target_size.y));
	const bool needs_raster_copy = !(destination_format.usage_bits & RD::TEXTURE_USAGE_STORAGE_BIT) || destination_format.format != RD::DATA_FORMAT_R16G16B16A16_SFLOAT || destination_format.samples != RD::TEXTURE_SAMPLES_1;
	CopyEffects *copy_effects = nullptr;
	RID destination_framebuffer;
	if (needs_raster_copy) {
		ERR_FAIL_COND(!(destination_format.usage_bits & RD::TEXTURE_USAGE_COLOR_ATTACHMENT_BIT));
		copy_effects = CopyEffects::get_singleton();
		ERR_FAIL_NULL(copy_effects);
		FramebufferCacheRD *framebuffer_cache = FramebufferCacheRD::get_singleton();
		ERR_FAIL_NULL(framebuffer_cache);
		destination_framebuffer = framebuffer_cache->get_cache(p_destination_texture);
		ERR_FAIL_COND(destination_framebuffer.is_null());
	}

	if (!p_render_buffers->has_texture(SNAME("FSR"), SNAME("upscale_texture"))) {
		RD::DataFormat format = RD::DATA_FORMAT_R16G16B16A16_SFLOAT;
		uint32_t usage_bits = RD::TEXTURE_USAGE_SAMPLING_BIT | RD::TEXTURE_USAGE_STORAGE_BIT | RD::TEXTURE_USAGE_COLOR_ATTACHMENT_BIT;
		uint32_t layers = 1; // we only need one layer, in multiview we're processing one layer at a time.

		p_render_buffers->create_texture(SNAME("FSR"), SNAME("upscale_texture"), format, usage_bits, RD::TEXTURE_SAMPLES_1, target_size, layers);
	}

	RID upscale_texture = p_render_buffers->get_texture(SNAME("FSR"), SNAME("upscale_texture"));
	ERR_FAIL_COND(upscale_texture.is_null());

	RID rcas_output_texture = p_destination_texture;
	if (needs_raster_copy) {
		if (!p_render_buffers->has_texture(SNAME("FSR"), SNAME("rcas_output"))) {
			uint32_t usage_bits = RD::TEXTURE_USAGE_STORAGE_BIT | RD::TEXTURE_USAGE_SAMPLING_BIT;
			// Each invocation processes one view; reuse one layer for all views.
			p_render_buffers->create_texture(SNAME("FSR"), SNAME("rcas_output"), RD::DATA_FORMAT_R16G16B16A16_SFLOAT, usage_bits, RD::TEXTURE_SAMPLES_1, target_size, 1);
		}
		rcas_output_texture = p_render_buffers->get_texture(SNAME("FSR"), SNAME("rcas_output"));
		ERR_FAIL_COND(rcas_output_texture.is_null());
	}

	RID default_sampler = material_storage->sampler_rd_get_default(RSE::CANVAS_ITEM_TEXTURE_FILTER_LINEAR, RSE::CANVAS_ITEM_TEXTURE_REPEAT_DISABLED);
	RD::Uniform u_source_rd_texture(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 0, { default_sampler, p_source_rd_texture });
	RD::Uniform u_upscale_texture(RD::UNIFORM_TYPE_IMAGE, 0, { upscale_texture });
	RD::Uniform u_upscale_texture_with_sampler(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 0, { default_sampler, upscale_texture });
	RD::Uniform u_destination_texture(RD::UNIFORM_TYPE_IMAGE, 0, { rcas_output_texture });

	RID easu_source_set = uniform_set_cache->get_cache(shader, 0, u_source_rd_texture);
	RID easu_destination_set = uniform_set_cache->get_cache(shader, 1, u_upscale_texture);
	RID rcas_source_set = uniform_set_cache->get_cache(shader, 0, u_upscale_texture_with_sampler);
	RID rcas_destination_set = uniform_set_cache->get_cache(shader, 1, u_destination_texture);
	ERR_FAIL_COND(easu_source_set.is_null() || easu_destination_set.is_null() || rcas_source_set.is_null() || rcas_destination_set.is_null());

	FSRUpscalePushConstant push_constant;
	memset(&push_constant, 0, sizeof(FSRUpscalePushConstant));

	int dispatch_x = (target_size.x + 15) / 16;
	int dispatch_y = (target_size.y + 15) / 16;

	RD::ComputeListID compute_list = RD::get_singleton()->compute_list_begin();
	RD::get_singleton()->compute_list_bind_compute_pipeline(compute_list, pipeline_rid);

	push_constant.resolution_width = internal_size.width;
	push_constant.resolution_height = internal_size.height;
	push_constant.upscaled_width = target_size.width;
	push_constant.upscaled_height = target_size.height;
	push_constant.sharpness = fsr_upscale_sharpness;

	// FSR EASU.
	push_constant.pass = FSR_UPSCALE_PASS_EASU;
	RD::get_singleton()->compute_list_bind_uniform_set(compute_list, easu_source_set, 0);
	RD::get_singleton()->compute_list_bind_uniform_set(compute_list, easu_destination_set, 1);

	RD::get_singleton()->compute_list_set_push_constant(compute_list, &push_constant, sizeof(FSRUpscalePushConstant));

	RD::get_singleton()->compute_list_dispatch(compute_list, dispatch_x, dispatch_y, 1);
	RD::get_singleton()->compute_list_add_barrier(compute_list);

	// FSR RCAS.
	push_constant.pass = FSR_UPSCALE_PASS_RCAS;
	RD::get_singleton()->compute_list_bind_uniform_set(compute_list, rcas_source_set, 0);
	RD::get_singleton()->compute_list_bind_uniform_set(compute_list, rcas_destination_set, 1);

	RD::get_singleton()->compute_list_set_push_constant(compute_list, &push_constant, sizeof(FSRUpscalePushConstant));

	RD::get_singleton()->compute_list_dispatch(compute_list, dispatch_x, dispatch_y, 1);

	RD::get_singleton()->compute_list_end();

	if (needs_raster_copy) {
		// Rasterization converts to the destination format without an additional
		// resample. RenderSceneBuffersRD clears these cached textures on resize.
		copy_effects->copy_to_fb_rect(rcas_output_texture, destination_framebuffer, Rect2i(Point2i(), target_size), false, false, false, false, RID(), false, false, false, false, Rect2(), 1.0, false);
	}
}
