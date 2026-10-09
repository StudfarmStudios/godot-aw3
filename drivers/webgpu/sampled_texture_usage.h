/**************************************************************************/
/*  sampled_texture_usage.h                                               */
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

#include "core/io/marshalls.h"
#include "core/templates/hash_map.h"
#include "core/templates/hash_set.h"
#include "core/templates/local_vector.h"
#include "core/templates/vector.h"

#include <thirdparty/spirv-headers/include/spirv/unified1/spirv.h>
#include <thirdparty/spirv-tools/include/spirv-tools/libspirv.h>

// Original, pre-specialization SPIR-V is the contract: a default-false branch
// may sample a texture in a later pipeline, and helper arguments may alias more
// than one binding. Unknown handle operations conservatively require filtering.
// Results use Godot's original (set << 16 | binding) numbering.
static bool webgpu_collect_sampled_texture_usage(const Vector<uint8_t> &p_spirv, HashSet<uint32_t> &r_analyzed, HashSet<uint32_t> &r_filtering) {
	if (p_spirv.size() < 20 || p_spirv.size() % 4) {
		return false;
	}
	const uint32_t words = p_spirv.size() / 4;
	auto word = [&](uint32_t p_index) { return decode_uint32(p_spirv.ptr() + p_index * 4); };
	if (word(0) != SpvMagicNumber) {
		return false;
	}

	struct Instruction {
		uint32_t pos;
		uint32_t count;
		SpvOp op;
		uint32_t type_id;
		uint32_t result_id;
		uint32_t id_begin;
		uint32_t id_count;
	};
	struct Binding {
		uint32_t set = UINT32_MAX;
		uint32_t binding = UINT32_MAX;
	};
	struct GroupTarget {
		uint32_t group;
		uint32_t target;
	};
	struct ParsedInstructions {
		LocalVector<Instruction> instructions;
		LocalVector<uint32_t> ids;
		uint32_t next_word = 5;
	} parsed;
	// SPIR-V operands have grammar-defined roles. Scanning raw words mistakes
	// literals (for example GLSL FMax's instruction number 40) for resource IDs.
	// The already-linked SPIRV-Tools parser also handles composite indices,
	// control masks and debug literals without an opcode exception list.
	LocalVector<uint32_t> native_words;
	native_words.resize(words);
	for (uint32_t i = 0; i < words; i++) {
		native_words[i] = word(i);
	}
	spv_context context = spvContextCreate(SPV_ENV_UNIVERSAL_1_6);
	if (!context) {
		return false;
	}
	auto collect_instruction = [](void *p_data, const spv_parsed_instruction_t *p_instruction) -> spv_result_t {
		ParsedInstructions &out = *static_cast<ParsedInstructions *>(p_data);
		const uint32_t begin = out.ids.size();
		for (uint32_t i = 0; i < p_instruction->num_operands; i++) {
			const spv_parsed_operand_t &operand = p_instruction->operands[i];
			if (operand.type == SPV_OPERAND_TYPE_ID || operand.type == SPV_OPERAND_TYPE_MEMORY_SEMANTICS_ID || operand.type == SPV_OPERAND_TYPE_SCOPE_ID) {
				out.ids.push_back(p_instruction->words[operand.offset]);
			}
		}
		out.instructions.push_back({ out.next_word, p_instruction->num_words, SpvOp(p_instruction->opcode), p_instruction->type_id, p_instruction->result_id, begin, out.ids.size() - begin });
		out.next_word += p_instruction->num_words;
		return SPV_SUCCESS;
	};
	spv_result_t result = spvBinaryParse(context, &parsed, native_words.ptr(), words, nullptr, collect_instruction, nullptr);
	spvContextDestroy(context);
	if (result != SPV_SUCCESS) {
		return false; // Unknown grammar keeps the original filtered contract.
	}
	const LocalVector<Instruction> &instructions = parsed.instructions;
	LocalVector<GroupTarget> groups;
	HashMap<uint32_t, Binding> bindings;
	HashSet<uint32_t> handle_types;
	HashMap<uint32_t, LocalVector<uint32_t>> type_children;
	HashMap<uint32_t, uint32_t> value_types;
	HashMap<uint32_t, LocalVector<uint32_t>> parameters;
	uint32_t function = 0;
	for (const Instruction &instruction : instructions) {
		const uint32_t pos = instruction.pos;
		const uint32_t count = instruction.count;
		const SpvOp op = instruction.op;
		if (instruction.type_id && instruction.result_id) {
			value_types[instruction.result_id] = instruction.type_id;
		}
		switch (op) {
			case SpvOpTypeImage:
			case SpvOpTypeSampler:
			case SpvOpTypeSampledImage:
				if (count >= 2) {
					handle_types.insert(word(pos + 1));
				}
				break;
			case SpvOpTypePointer:
				if (count >= 4) {
					type_children[word(pos + 1)].push_back(word(pos + 3));
				}
				break;
			case SpvOpTypeArray:
			case SpvOpTypeRuntimeArray:
				if (count >= 3) {
					type_children[word(pos + 1)].push_back(word(pos + 2));
				}
				break;
			case SpvOpTypeStruct:
				for (uint32_t i = 2; i < count; i++) {
					type_children[word(pos + 1)].push_back(word(pos + i));
				}
				break;
			case SpvOpDecorate:
				if (count >= 4) {
					if (word(pos + 2) == SpvDecorationDescriptorSet) {
						bindings[word(pos + 1)].set = word(pos + 3);
					}
					if (word(pos + 2) == SpvDecorationBinding) {
						bindings[word(pos + 1)].binding = word(pos + 3);
					}
				}
				break;
			case SpvOpGroupDecorate:
				for (uint32_t i = 2; i < count; i++) {
					groups.push_back({ word(pos + 1), word(pos + i) });
				}
				break;
			case SpvOpFunction:
				if (count >= 3) {
					function = word(pos + 2);
				}
				break;
			case SpvOpFunctionParameter:
				if (count >= 3) {
					parameters[function].push_back(word(pos + 2));
				}
				break;
			case SpvOpFunctionEnd:
				function = 0;
				break;
			default:
				break;
		}
	}
	for (const GroupTarget &group : groups) {
		const Binding *source = bindings.getptr(group.group);
		if (!source) {
			continue;
		}
		const Binding copy = *source;
		if (copy.set != UINT32_MAX) {
			bindings[group.target].set = copy.set;
		}
		if (copy.binding != UINT32_MAX) {
			bindings[group.target].binding = copy.binding;
		}
	}
	// Expand pointer/array/structure types to a fixed point. Cycles without an
	// image or sampler are ordinary data; they need no descriptor provenance.
	bool changed = true;
	while (changed) {
		changed = false;
		for (const KeyValue<uint32_t, LocalVector<uint32_t>> &entry : type_children) {
			if (handle_types.has(entry.key)) {
				continue;
			}
			for (uint32_t child : entry.value) {
				if (handle_types.has(child)) {
					handle_types.insert(entry.key);
					changed = true;
					break;
				}
			}
		}
	}
	HashSet<uint32_t> handles;
	for (const KeyValue<uint32_t, uint32_t> &entry : value_types) {
		if (handle_types.has(entry.value)) {
			handles.insert(entry.key);
		}
	}
	HashMap<uint32_t, LocalVector<uint32_t>> dependencies;
	LocalVector<uint32_t> filtering_roots;
	auto depend = [&](uint32_t p_result, uint32_t p_source) {
		if (handles.has(p_source)) {
			dependencies[p_result].push_back(p_source);
		}
	};
	function = 0;
	for (const Instruction &instruction : instructions) {
		const uint32_t p = instruction.pos;
		const uint32_t count = instruction.count;
		const SpvOp op = instruction.op;
		if (op == SpvOpFunction && count >= 3) {
			function = word(p + 2);
			continue;
		}
		if (op == SpvOpFunctionEnd) {
			function = 0;
			continue;
		}
		if (!function) {
			continue;
		}
		switch (op) {
			case SpvOpFunctionParameter:
				break;
			case SpvOpVariable:
				if (count >= 5) {
					depend(word(p + 2), word(p + 4));
				}
				break;
			case SpvOpLoad:
			case SpvOpCopyObject:
			case SpvOpAccessChain:
			case SpvOpInBoundsAccessChain:
			case SpvOpPtrAccessChain:
			case SpvOpInBoundsPtrAccessChain:
			case SpvOpImage:
				if (count >= 4) {
					depend(word(p + 2), word(p + 3));
				}
				break;
			case SpvOpStore:
				if (count >= 3) {
					depend(word(p + 1), word(p + 2));
				}
				break;
			case SpvOpSampledImage:
				if (count >= 5) {
					depend(word(p + 2), word(p + 3));
					depend(word(p + 2), word(p + 4));
				}
				break;
			case SpvOpPhi:
				for (uint32_t i = 3; i + 1 < count; i += 2) {
					depend(word(p + 2), word(p + i));
				}
				break;
			case SpvOpSelect:
				if (count >= 6) {
					depend(word(p + 2), word(p + 4));
					depend(word(p + 2), word(p + 5));
				}
				break;
			case SpvOpFunctionCall: {
				if (count < 4) {
					return false;
				}
				const uint32_t callee = word(p + 3);
				if (handles.has(word(p + 2))) {
					dependencies[word(p + 2)].push_back(callee);
				}
				const LocalVector<uint32_t> *args = parameters.getptr(callee);
				if (count > 4 && (!args || args->size() != count - 4)) {
					return false;
				}
				for (uint32_t i = 4; i < count; i++) {
					depend((*args)[i - 4], word(p + i));
				}
			} break;
			case SpvOpReturnValue:
				if (count >= 2) {
					depend(function, word(p + 1));
				}
				break;
			case SpvOpImageFetch:
			case SpvOpImageRead:
			case SpvOpImageWrite:
			case SpvOpImageQuerySizeLod:
			case SpvOpImageQuerySize:
			case SpvOpImageQueryLevels:
			case SpvOpImageQuerySamples:
				break; // Exact loads, stores and dimensions do not filter.
			default:
				// Includes image sampling/gather operations and unfamiliar handle
				// uses. Only actual ID operands can refer to descriptor handles.
				for (uint32_t i = 0; i < instruction.id_count; i++) {
					const uint32_t id = parsed.ids[instruction.id_begin + i];
					if (handles.has(id)) {
						filtering_roots.push_back(id);
					}
				}
				break;
		}
	}
	HashSet<uint32_t> visited;
	while (!filtering_roots.is_empty()) {
		const uint32_t id = filtering_roots[filtering_roots.size() - 1];
		filtering_roots.resize(filtering_roots.size() - 1);
		if (visited.has(id)) {
			continue;
		}
		visited.insert(id);
		if (const LocalVector<uint32_t> *sources = dependencies.getptr(id)) {
			for (uint32_t source : *sources) {
				filtering_roots.push_back(source);
			}
		}
	}
	for (const KeyValue<uint32_t, Binding> &entry : bindings) {
		if (!handles.has(entry.key) || entry.value.set == UINT32_MAX || entry.value.binding == UINT32_MAX) {
			continue;
		}
		const uint32_t key = (entry.value.set << 16) | entry.value.binding;
		r_analyzed.insert(key);
		if (visited.has(entry.key)) {
			r_filtering.insert(key);
		}
	}
	return true;
}
