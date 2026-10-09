/**************************************************************************/
/*  tint_wrapper.cpp                                                      */
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

#include "tint_wrapper.h"

#include "src/tint/api/tint.h"
#include "src/tint/lang/core/ir/function.h"
#include "src/tint/lang/core/ir/module.h"
#include "src/tint/lang/core/ir/validator.h"
#include "src/tint/lang/core/type/pointer.h"
#include "src/tint/lang/spirv/reader/reader.h"
#include "src/tint/lang/wgsl/writer/common/options.h"
#include "src/tint/lang/wgsl/writer/writer.h"

#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

// Godot compiles a single stage per module. WebGPU permits only read access
// to vertex storage buffers. Change pointer types structurally, including derived
// values and helper signatures, then validate: actual writes remain an error.
static tint::Result<std::string> _spirv_to_wgsl_with_vertex_access(const std::vector<uint32_t> &p_words, const tint::wgsl::writer::Options &p_options) {
	TINT_CHECK_RESULT_UNWRAP(module, tint::spirv::reader::ReadIR(p_words));
	uint32_t entries = 0;
	bool vertex = false;
	for (auto *function : module.functions) {
		if (function->IsEntryPoint()) {
			entries++;
			vertex = function->IsVertex();
		}
	}
	if (entries == 1 && vertex) {
		auto read_pointer = [&](const tint::core::type::Type *p_type) -> const tint::core::type::Type * {
			const auto *pointer = p_type ? p_type->As<tint::core::type::Pointer>() : nullptr;
			if (pointer && pointer->AddressSpace() == tint::core::AddressSpace::kStorage && pointer->Access() != tint::core::Access::kRead) {
				return module.Types().ptr(tint::core::AddressSpace::kStorage, pointer->StoreType(), tint::core::Access::kRead);
			}
			return p_type;
		};
		// A flat walk avoids recursive use-chain traversal and covers function
		// parameters/block results that are not reachable via a variable's users.
		for (auto *value : module.Values()) {
			value->SetType(read_pointer(value->Type()));
		}
		for (auto *function : module.functions) {
			function->SetReturnType(read_pointer(function->ReturnType()));
		}
		TINT_CHECK_RESULT(tint::core::ir::Validate(module, tint::core::ir::Capabilities{ tint::core::ir::Capability::kAllowOverrides, tint::core::ir::Capability::kAllowStructMemberSizeMismatch, tint::core::ir::Capability::kAllowPhonyInstructions }, "after WebGPU vertex storage access"));
	}
	TINT_CHECK_RESULT_UNWRAP(output, tint::wgsl::writer::WgslFromIR(module, p_options));
	return output.wgsl;
}

void tint_wrapper_initialize() {
	tint::Initialize();
}

char *tint_wrapper_spirv_to_wgsl(const uint32_t *p_spirv_words, size_t p_word_count, char **r_error) {
	std::vector<uint32_t> words(p_spirv_words, p_spirv_words + p_word_count);

	// Allow all WGSL extensions and language features so Tint can emit
	// constructs like readonly storage textures without validation errors.
	tint::wgsl::writer::Options wgsl_options;
	wgsl_options.allowed_features = tint::wgsl::AllowedFeatures::Everything();
	// Godot's GLSL shaders use textureSample/dpdx in non-uniform control flow
	// (valid in Vulkan, but WGSL requires uniform control flow for derivatives).
	// This inserts `diagnostic(off, derivative_uniformity)` in the output.
	wgsl_options.allow_non_uniform_derivatives = true;
	// SPIR-V control-flow reconstruction can append unreachable fallback returns.
	// Avoid warning callbacks for this generated code: Chromium can re-enter
	// its command-buffer lock if logging allocates and finalizes GPU objects.
	wgsl_options.disable_unreachable_code_warning = true;

	auto result = _spirv_to_wgsl_with_vertex_access(words, wgsl_options);
	if (result != tint::Success) {
		if (r_error) {
			const std::string &reason = result.Failure().reason;
			char *err = (char *)malloc(reason.size() + 1);
			if (err) {
				memcpy(err, reason.c_str(), reason.size() + 1);
			}
			*r_error = err;
		}
		return nullptr;
	}

	const std::string &wgsl = result.Get();
	char *out = (char *)malloc(wgsl.size() + 1);
	if (!out) {
		return nullptr;
	}
	memcpy(out, wgsl.c_str(), wgsl.size() + 1);
	return out;
}
