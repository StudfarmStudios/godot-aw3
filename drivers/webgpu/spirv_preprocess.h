/**************************************************************************/
/*  spirv_preprocess.h                                                    */
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

#pragma once

#include "core/templates/hash_map.h"
#include "core/templates/hash_set.h"
#include "core/templates/vector.h"

#include <cstdint>

namespace spirv_preprocess {

// Result struct for fix_depth2_images, which returns both the modified
// SPIR-V bytes and a list of (image_type_id, dim, arrayed) tuples for
// any depth=2 images that were changed.
struct DepthImageFixResult {
	Vector<uint8_t> bytes;
	struct DepthImageInfo {
		uint32_t image_type_id;
		uint32_t dim;
		uint32_t arrayed;
	};
	Vector<DepthImageInfo> depth_images;
};

// Run every preprocessing pass, in the order the WebGPU backend needs. Both the
// runtime driver and the build-time tint_convert_cli go through this, so the two
// cannot drift apart - they used to keep separate copies of the list, and a pass
// added to one silently did not apply to the other.
// r_depth_images receives the depth=2 images fix_depth2_images rewrote, if wanted.
// Image type of a descriptor binding, straight from OpTypeImage. Types do not
// vary with specialization constants, so this is the answer for every
// specialization - unlike reading it back from a translated module, where the
// declaration may have been pruned as unused for the default constant values.
struct ImageBindingInfo {
	uint32_t dim = 0; // SPIR-V Dim: 0=1D, 1=2D, 2=3D, 3=Cube.
	uint32_t depth = 0;
	uint32_t arrayed = 0;
	uint32_t multisampled = 0;
};

void binding_image_info(const Vector<uint8_t> &p_bytes, HashMap<uint32_t, ImageBindingInfo> *r_info);

// Collect (set << 16 | binding) for every descriptor-decorated variable that any
// function in the module mentions, in Godot's own binding numbering. Runs on the
// module before specialization constants are frozen, so the result covers every
// specialization that can be built from it - which is what a bind group layout,
// built once per shader, has to remain valid for.
void reachable_binding_keys(const Vector<uint8_t> &p_bytes, HashSet<uint32_t> *r_keys);

// r_unused_binding_keys receives (set << 16 | binding) for resources the passes
// made unreachable, which the caller needs so it can stop claiming they are
// visible to a shader stage.
Vector<uint8_t> run_all(const Vector<uint8_t> &p_bytes, Vector<DepthImageFixResult::DepthImageInfo> *r_depth_images = nullptr, Vector<uint32_t> *r_unused_binding_keys = nullptr);

// Evaluate OpSpecConstantOp instructions with default values and replace
// them with regular OpConstant instructions. Also converts OpSpecConstant*
// to their non-specialization equivalents and strips SpecId decorations.
Vector<uint8_t> freeze_spec_constant_ops(const Vector<uint8_t> &p_bytes);

// Convert push-constant variables to storage buffer (read-only) at
// descriptor set 3, binding 120 (the ring-buffer slot used by the
// WebGPU backend).
Vector<uint8_t> convert_push_constants_to_uniforms(const Vector<uint8_t> &p_bytes);

// Rewrite OpCopyLogical (SPIR-V 1.4+) to OpCopyObject.
// OpCopyLogical copies between logically equivalent struct types with
// different decorations; OpCopyObject is the simpler equivalent.
Vector<uint8_t> rewrite_copy_logical(const Vector<uint8_t> &p_bytes);

// Rewrite OpTerminateInvocation (SPV_KHR_terminate_invocation) to OpKill.
// OpTerminateInvocation has defined helper-invocation semantics but some
// frontends do not support it; OpKill is the SPIR-V 1.0 equivalent.
Vector<uint8_t> rewrite_terminate_invocation(const Vector<uint8_t> &p_bytes);

// Split combined image+sampler variables into separate image and sampler
// variables. Rewrites bindings (original binding N becomes sampler=N*2,
// image=N*2+1), inserts new types/variables, and replaces OpLoad of
// combined vars with separate loads + OpSampledImage.
Vector<uint8_t> split_combined_samplers(const Vector<uint8_t> &p_bytes);

// Fix OpTypeImage with depth=2 (unknown) by setting depth=1 (explicit
// depth). Returns the modified bytes and info about changed image types.
DepthImageFixResult fix_depth2_images(const Vector<uint8_t> &p_bytes);

// Negate the Y component of gl_Position in vertex shaders.
// Compensates for the difference between Vulkan's Y-down NDC (which
// Godot's GLSL shaders target) and WebGPU's Y-up NDC.
// Without this, all rendered content appears flipped vertically.
// Tint has no built-in coordinate space adjustment option, so this
// is done as a SPIR-V preprocessing pass instead.
Vector<uint8_t> negate_position_y(const Vector<uint8_t> &p_bytes);

// Strip OpDecorate/OpMemberDecorate for decorations unsupported by Tint:
// Restrict (19) — memory hint from glslang, no WGSL equivalent.
// InputAttachmentIndex (43) — Vulkan subpass inputs, no WebGPU equivalent.
Vector<uint8_t> strip_restrict_decoration(const Vector<uint8_t> &p_bytes);

// Replace OpMemoryBarrier with OpNop. Tint does not support
// OpMemoryBarrier (SPIR-V 225); WGSL has no direct equivalent.
// workgroupBarrier() (from OpControlBarrier) covers synchronization.
Vector<uint8_t> strip_memory_barrier(const Vector<uint8_t> &p_bytes);

// Replace non-finite (infinity, NaN) float constants with FLT_MAX/MIN.
// Tint asserts std::isfinite on all float literal values.
Vector<uint8_t> fix_nonfinite_literals(const Vector<uint8_t> &p_bytes);

// Unwrap arrays of handle types (images, samplers, sampled images)
// into single variables. Tint does not support arrays of handle types.
// Rewrites pointer types, removes access chains, and updates loads.
Vector<uint8_t> flatten_binding_arrays(const Vector<uint8_t> &p_bytes);

// Infer read-only storage buffers by analyzing write operations.
// Adds OpDecorate NonWritable to StorageBuffer variables that are never
// written to (no OpStore, OpAtomicStore, OpCopyMemory, etc.). This allows
// Tint to emit var<storage, read> instead of var<storage, read_write>.
Vector<uint8_t> infer_readonly_storage(const Vector<uint8_t> &p_bytes);

// Drop NonReadable (write-only) from storage *buffers*. GLSL allows writeonly
// buffers, WGSL has only read and read_write, and Tint rejects the write-only
// access it would otherwise emit ("vars in the 'storage' address space must
// have access 'read' or 'read-write'"). Read-write is a safe superset: the
// shader never reads. Storage textures are left alone - write-only is both
// legal and the norm for those in WGSL, and making them read_write would
// require the readonly_and_readwrite_storage_textures feature.
Vector<uint8_t> strip_nonreadable_storage_buffers(const Vector<uint8_t> &p_bytes);

// Inline every call that passes a texture, sampler or sampled image across a
// function boundary (SPIRV-Tools' InlineOpaquePass). Tint's SPIR-V reader only
// rewrites image-typed function parameters along its depth-texture path, so an
// ordinary texture passed to a helper reaches texture lowering still typed as
// spirv.image and trips an internal assert. Godot 4.7's area-light shaders do
// exactly that (fetch_ltc_lod(..., texture2D area_light_atlas, sampler)).
// No-op for modules that never pass opaque types to functions.
Vector<uint8_t> inline_opaque_functions(const Vector<uint8_t> &p_bytes);

// Constant-fold and delete unreachable code (SPIRV-Tools). Run after the
// specialization constants have been frozen, so ubershader branches that can no
// longer be taken - and the resources only they referenced - disappear.
Vector<uint8_t> eliminate_dead_code(const Vector<uint8_t> &p_bytes);

// Point Godot's four anisotropic static samplers at their trilinear equivalents.
// WebGPU allows 16 samplers per shader stage on Metal and the Forward Mobile
// fragment shader wants 18; anisotropy is the cheapest of those to give up.
// Matches on the engine's sampler names, so it no-ops on anything else.
Vector<uint8_t> alias_anisotropic_samplers(const Vector<uint8_t> &p_bytes, Vector<uint32_t> *r_removed_binding_keys = nullptr);

} // namespace spirv_preprocess
