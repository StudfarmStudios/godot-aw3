/**************************************************************************/
/*  spirv_preprocess.cpp                                                  */
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

#include "spirv_preprocess.h"

#include "spirv-tools/libspirv.h"
#include "spirv-tools/optimizer.hpp"

#include <string>
#include <unordered_map>
#include <vector>

#include "core/templates/hash_map.h"
#include "core/templates/hash_set.h"
#include "core/templates/vector.h"

#include <cfloat>
#include <cstdio>
#include <cstdlib>
#include <cmath>
#include <cstring>

namespace spirv_preprocess {

// ---- SPIR-V opcode constants ----

static constexpr uint16_t OP_NAME = 5;
static constexpr uint16_t OP_TYPE_BOOL = 20;
static constexpr uint16_t OP_TYPE_FUNCTION = 33;
static constexpr uint16_t OP_TYPE_INT = 21;
static constexpr uint16_t OP_TYPE_FLOAT = 22;
static constexpr uint16_t OP_TYPE_IMAGE = 25;
static constexpr uint16_t OP_TYPE_SAMPLER = 26;
static constexpr uint16_t OP_TYPE_SAMPLED_IMAGE = 27;
static constexpr uint16_t OP_TYPE_POINTER = 32;
static constexpr uint16_t OP_CONSTANT_TRUE = 41;
static constexpr uint16_t OP_CONSTANT_FALSE = 42;
static constexpr uint16_t OP_CONSTANT = 43;
static constexpr uint16_t OP_CONSTANT_COMPOSITE = 44;
static constexpr uint16_t OP_SPEC_CONSTANT_TRUE = 48;
static constexpr uint16_t OP_SPEC_CONSTANT_FALSE = 49;
static constexpr uint16_t OP_SPEC_CONSTANT = 50;
static constexpr uint16_t OP_SPEC_CONSTANT_COMPOSITE = 51;
static constexpr uint16_t OP_SPEC_CONSTANT_OP = 52;
static constexpr uint16_t OP_FUNCTION = 54;
static constexpr uint16_t OP_FUNCTION_PARAMETER = 55;
static constexpr uint16_t OP_FUNCTION_END = 56;
static constexpr uint16_t OP_FUNCTION_CALL = 57;
static constexpr uint16_t OP_VARIABLE = 59;
static constexpr uint16_t OP_LOAD = 61;
static constexpr uint16_t OP_DECORATE = 71;
static constexpr uint16_t OP_COPY_OBJECT = 83;
static constexpr uint16_t OP_SAMPLED_IMAGE = 86;
static constexpr uint16_t OP_IMAGE = 100;
static constexpr uint16_t OP_TYPE_VECTOR = 23;
static constexpr uint16_t OP_STORE = 62;
static constexpr uint16_t OP_ACCESS_CHAIN = 65;
static constexpr uint16_t OP_MEMBER_DECORATE = 72;
static constexpr uint16_t OP_FNEGATE = 127;
static constexpr uint16_t OP_KILL = 252;
static constexpr uint16_t OP_RETURN = 253;
static constexpr uint16_t OP_RETURN_VALUE = 254;
static constexpr uint16_t OP_COPY_LOGICAL = 400;
static constexpr uint16_t OP_TERMINATE_INVOCATION = 4416;
static constexpr uint16_t OP_ENTRY_POINT = 15;
static constexpr uint16_t OP_TYPE_ARRAY = 28;
static constexpr uint16_t OP_TYPE_RUNTIME_ARRAY = 29;
static constexpr uint16_t OP_IN_BOUNDS_ACCESS_CHAIN = 66;
static constexpr uint16_t OP_PTR_ACCESS_CHAIN = 67;
static constexpr uint16_t OP_COPY_MEMORY = 38;
static constexpr uint16_t OP_COPY_MEMORY_SIZED = 39;
static constexpr uint16_t OP_ATOMIC_STORE = 228;
static constexpr uint16_t OP_IN_BOUNDS_PTR_ACCESS_CHAIN = 216;
static constexpr uint16_t OP_DECORATION_GROUP = 73;

// OpAtomicLoad .. OpAtomicXor, all of which carry <result-type> <result-id>
// <pointer>. OpAtomicStore sits inside the range but has no result and is handled
// with the other pointer-first instructions.
static constexpr uint16_t OP_ATOMIC_LOAD = 227;
static constexpr uint16_t OP_ATOMIC_XOR = 242;
static constexpr uint16_t OP_ATOMIC_FLAG_TEST_AND_SET = 247;
static constexpr uint16_t OP_ATOMIC_FLAG_CLEAR = 248;

// WGSL has no read-only atomic: `var<storage, read>` cannot hold an `atomic<T>`.
// So a buffer the shader only ever atomically *reads* still has to be declared
// read_write, which makes every atomic instruction a write for our purposes.
static bool _is_atomic_with_result(uint16_t p_op) {
	return (p_op >= OP_ATOMIC_LOAD && p_op <= OP_ATOMIC_XOR && p_op != OP_ATOMIC_STORE) ||
			p_op == OP_ATOMIC_FLAG_TEST_AND_SET;
}

// SPIR-V storage class values.
static constexpr uint32_t SC_UNIFORM_CONSTANT = 0;
static constexpr uint32_t SC_OUTPUT = 3;
static constexpr uint32_t SC_STORAGE_BUFFER = 12;
static constexpr uint32_t SC_PUSH_CONSTANT = 9;

// SPIR-V decoration values.
static constexpr uint32_t DECO_BUILTIN = 11;
static constexpr uint32_t DECO_NON_WRITABLE = 24;
static constexpr uint32_t DECO_SPEC_ID = 1;
static constexpr uint32_t DECO_BINDING = 33;
static constexpr uint32_t DECO_DESCRIPTOR_SET = 34;

// SPIR-V BuiltIn values.
static constexpr uint32_t BUILTIN_POSITION = 0;
static constexpr uint32_t BUILTIN_POINT_SIZE = 1;
static constexpr uint32_t BUILTIN_HELPER_INVOCATION = 23;

static constexpr uint16_t OP_CAPABILITY = 17;
// OpIsNan .. OpSignBitSet, a contiguous run in the spec.
static constexpr uint16_t OP_IS_NAN = 156;
static constexpr uint16_t OP_SIGN_BIT_SET = 160;

// SPIR-V execution model values.
static constexpr uint32_t EXEC_MODEL_VERTEX = 0;

// Binding slot used by the push-constant ring buffer emulation inside group 3.
// Must match the C++ constant PUSH_CONSTANT_RING_BINDING in
// rendering_device_driver_webgpu.cpp.
static constexpr uint32_t PC_RING_BUFFER_BINDING = 120;

// ---- Inline helpers ----

// Read a little-endian u32 from byte data at the given word index.
// Returns 0 for out-of-bounds access (malformed SPIR-V safety).
static inline uint32_t read_word(const uint8_t *p_data, int64_t p_size, uint32_t p_word_idx) {
	uint32_t off = p_word_idx * 4;
	if (off + 3 >= (uint32_t)p_size) {
		return 0;
	}
	uint32_t val;
	memcpy(&val, p_data + off, 4);
	return val; // Assumes little-endian host (which Godot targets require).
}

// Append a u32 as 4 little-endian bytes to a Vector<uint8_t>.
static inline void push_word(Vector<uint8_t> &r_out, uint32_t p_word) {
	int64_t old_size = r_out.size();
	r_out.resize(old_size + 4);
	memcpy(r_out.ptrw() + old_size, &p_word, 4);
}

// Copy a range of bytes from source data to Vector<uint8_t>.
static inline void append_bytes(Vector<uint8_t> &r_out, const uint8_t *p_src, int64_t p_offset, int64_t p_count) {
	if (p_count <= 0) {
		return;
	}
	int64_t old_size = r_out.size();
	r_out.resize(old_size + p_count);
	memcpy(r_out.ptrw() + old_size, p_src + p_offset, p_count);
}

// ---- eval_spec_op ----

// Evaluate a SPIR-V specialization constant operation.
// Returns the computed value as a u64.
static uint64_t eval_spec_op(uint32_t p_opcode, const Vector<uint64_t> &p_operands) {
	auto a = [&]() -> uint64_t { return p_operands.size() > 0 ? p_operands[0] : 0; };
	auto b = [&]() -> uint64_t { return p_operands.size() > 1 ? p_operands[1] : 0; };
	auto c = [&]() -> uint64_t { return p_operands.size() > 2 ? p_operands[2] : 0; };

	switch (p_opcode) {
		// Integer arithmetic.
		case 126: return (uint64_t)(-(int32_t)a()); // SNegate
		case 128: return a() + b(); // IAdd (wrapping)
		case 130: return a() - b(); // ISub (wrapping)
		case 132: return a() * b(); // IMul (wrapping)
		case 134: return b() != 0 ? a() / b() : 0; // UDiv
		case 135: { // SDiv
			int32_t d = (int32_t)b();
			return d != 0 ? (uint64_t)((int32_t)a() / d) : 0;
		}
		case 137: return b() != 0 ? a() % b() : 0; // UMod

		// Logical.
		case 164: return (uint64_t)(a() == b()); // LogicalEqual
		case 165: return (uint64_t)(a() != b()); // LogicalNotEqual
		case 166: return (uint64_t)((a() != 0) || (b() != 0)); // LogicalOr
		case 167: return (uint64_t)((a() != 0) && (b() != 0)); // LogicalAnd
		case 168: return (uint64_t)(a() == 0); // LogicalNot

		// Select: condition, true_val, false_val.
		case 169: return a() != 0 ? b() : c(); // Select

		// Integer comparison.
		case 170: return (uint64_t)(a() == b()); // IEqual
		case 171: return (uint64_t)(a() != b()); // INotEqual
		case 172: return (uint64_t)((uint32_t)a() > (uint32_t)b()); // UGreaterThan
		case 173: return (uint64_t)((int32_t)a() > (int32_t)b()); // SGreaterThan
		case 174: return (uint64_t)((uint32_t)a() >= (uint32_t)b()); // UGreaterThanEqual
		case 175: return (uint64_t)((int32_t)a() >= (int32_t)b()); // SGreaterThanEqual
		case 176: return (uint64_t)((uint32_t)a() < (uint32_t)b()); // ULessThan
		case 177: return (uint64_t)((int32_t)a() < (int32_t)b()); // SLessThan
		case 178: return (uint64_t)((uint32_t)a() <= (uint32_t)b()); // ULessThanEqual
		case 179: return (uint64_t)((int32_t)a() <= (int32_t)b()); // SLessThanEqual

		// Bitwise.
		case 194: return (uint64_t)((uint32_t)a() >> ((uint32_t)b() & 31)); // ShiftRightLogical
		case 195: return (uint64_t)((int32_t)a() >> ((uint32_t)b() & 31)); // ShiftRightArithmetic
		case 196: return (uint64_t)((uint32_t)a() << ((uint32_t)b() & 31)); // ShiftLeftLogical
		case 197: return a() | b(); // BitwiseOr
		case 198: return a() ^ b(); // BitwiseXor
		case 199: return a() & b(); // BitwiseAnd
		case 200: return (uint64_t)(~(uint32_t)a()); // Not

		// Composite.
		case 81: return a(); // CompositeExtract (return first operand)

		// Conversion (values unchanged for const-eval of integers).
		case 109:
		case 110:
		case 111:
		case 112:
		case 113:
		case 114: return a(); // ConvertF/S/U, UConvert, SConvert

		// Default: return 0 for unhandled operations.
		default: return 0;
	}
}

// ---- freeze_spec_constant_ops ----

Vector<uint8_t> freeze_spec_constant_ops(const Vector<uint8_t> &p_bytes) {
	const uint8_t *data = p_bytes.ptr();
	const int64_t len = p_bytes.size();
	const uint32_t total_words = (uint32_t)(len / 4);

	if (total_words < 5) {
		return p_bytes;
	}

	// Collect type info: type_id -> true if bool type.
	HashMap<uint32_t, bool> type_bool;
	// Collect type info for int types: type_id -> (width, signed).
	HashMap<uint32_t, uint32_t> type_int_width;

	// Collect constant scalar values: result_id -> value (as u64).
	HashMap<uint32_t, uint64_t> constants;
	// Track which IDs are bool-typed.
	HashSet<uint32_t> bool_ids;

	// First pass: collect types and constant values.
	uint32_t pos = 5;
	while (pos < total_words) {
		uint32_t w0 = read_word(data, len, pos);
		uint32_t wc = (w0 >> 16);
		uint16_t op = (uint16_t)(w0 & 0xFFFF);

		if (wc == 0 || pos + wc > total_words) {
			break;
		}

		switch (op) {
			case OP_TYPE_BOOL: {
				if (wc >= 2) {
					uint32_t id = read_word(data, len, pos + 1);
					type_bool.insert(id, true);
				}
			} break;

			case OP_TYPE_INT: {
				if (wc >= 4) {
					uint32_t id = read_word(data, len, pos + 1);
					uint32_t width = read_word(data, len, pos + 2);
					type_int_width.insert(id, width);
				}
			} break;

			case OP_CONSTANT:
			case OP_SPEC_CONSTANT: {
				if (wc >= 4) {
					uint32_t type_id = read_word(data, len, pos + 1);
					uint32_t result_id = read_word(data, len, pos + 2);
					uint64_t val = (uint64_t)read_word(data, len, pos + 3);
					// For 64-bit constants, also grab the high word.
					if (wc >= 5) {
						val |= ((uint64_t)read_word(data, len, pos + 4) << 32);
					}
					constants.insert(result_id, val);
					if (type_bool.has(type_id)) {
						bool_ids.insert(result_id);
					}
				}
			} break;

			case OP_CONSTANT_TRUE:
			case OP_SPEC_CONSTANT_TRUE: {
				if (wc >= 3) {
					uint32_t result_id = read_word(data, len, pos + 2);
					constants.insert(result_id, 1);
					bool_ids.insert(result_id);
				}
			} break;

			case OP_CONSTANT_FALSE:
			case OP_SPEC_CONSTANT_FALSE: {
				if (wc >= 3) {
					uint32_t result_id = read_word(data, len, pos + 2);
					constants.insert(result_id, 0);
					bool_ids.insert(result_id);
				}
			} break;

			case OP_SPEC_CONSTANT_OP: {
				if (wc >= 4) {
					uint32_t type_id = read_word(data, len, pos + 1);
					uint32_t result_id = read_word(data, len, pos + 2);
					uint32_t spec_op = read_word(data, len, pos + 3);

					Vector<uint64_t> operands;
					for (uint32_t i = 4; i < wc; i++) {
						uint32_t id = read_word(data, len, pos + i);
						const uint64_t *val_ptr = constants.getptr(id);
						operands.push_back(val_ptr ? *val_ptr : 0);
					}

					uint64_t val = eval_spec_op(spec_op, operands);
					constants.insert(result_id, val);
					if (type_bool.has(type_id)) {
						bool_ids.insert(result_id);
					}
				}
			} break;

			default:
				break;
		}

		pos += wc;
	}

	// Second pass: rewrite, replacing OpSpecConstantOp with OpConstant,
	// and converting OpSpecConstant* to their non-specialization equivalents.
	Vector<uint8_t> out;
	out.resize(0);

	// Copy header (5 words = 20 bytes).
	append_bytes(out, data, 0, 20);

	pos = 5;
	while (pos < total_words) {
		uint32_t w0 = read_word(data, len, pos);
		uint32_t wc = (w0 >> 16);
		uint16_t op = (uint16_t)(w0 & 0xFFFF);

		if (wc == 0 || pos + wc > total_words) {
			break;
		}

		if (op == OP_DECORATE && wc >= 3 && read_word(data, len, pos + 2) == DECO_SPEC_ID) {
			// Strip OpDecorate ... SpecId decorations -- not valid after freezing.
			pos += wc;
			continue;
		} else if (op == OP_SPEC_CONSTANT_OP) {
			// Replace OpSpecConstantOp with evaluated OpConstant.
			uint32_t type_id = read_word(data, len, pos + 1);
			uint32_t result_id = read_word(data, len, pos + 2);
			const uint64_t *val_ptr = constants.getptr(result_id);
			uint64_t val = val_ptr ? *val_ptr : 0;

			if (bool_ids.has(result_id) || type_bool.has(type_id)) {
				uint16_t bool_op = (val != 0) ? OP_CONSTANT_TRUE : OP_CONSTANT_FALSE;
				push_word(out, (3u << 16) | (uint32_t)bool_op);
				push_word(out, type_id);
				push_word(out, result_id);
			} else {
				push_word(out, (4u << 16) | (uint32_t)OP_CONSTANT);
				push_word(out, type_id);
				push_word(out, result_id);
				push_word(out, (uint32_t)val);
			}
		} else if (op == OP_SPEC_CONSTANT_TRUE) {
			// Rewrite as OpConstantTrue (same layout, different opcode).
			push_word(out, ((uint32_t)wc << 16) | (uint32_t)OP_CONSTANT_TRUE);
			for (uint32_t i = 1; i < wc; i++) {
				push_word(out, read_word(data, len, pos + i));
			}
		} else if (op == OP_SPEC_CONSTANT_FALSE) {
			push_word(out, ((uint32_t)wc << 16) | (uint32_t)OP_CONSTANT_FALSE);
			for (uint32_t i = 1; i < wc; i++) {
				push_word(out, read_word(data, len, pos + i));
			}
		} else if (op == OP_SPEC_CONSTANT) {
			push_word(out, ((uint32_t)wc << 16) | (uint32_t)OP_CONSTANT);
			for (uint32_t i = 1; i < wc; i++) {
				push_word(out, read_word(data, len, pos + i));
			}
		} else if (op == OP_SPEC_CONSTANT_COMPOSITE) {
			push_word(out, ((uint32_t)wc << 16) | (uint32_t)OP_CONSTANT_COMPOSITE);
			for (uint32_t i = 1; i < wc; i++) {
				push_word(out, read_word(data, len, pos + i));
			}
		} else {
			// Copy instruction as-is.
			append_bytes(out, data, pos * 4, wc * 4);
		}

		pos += wc;
	}

	return out;
}

// ---- convert_push_constants_to_uniforms ----

Vector<uint8_t> convert_push_constants_to_uniforms(const Vector<uint8_t> &p_bytes) {
	const uint8_t *data = p_bytes.ptr();
	const int64_t len = p_bytes.size();
	const uint32_t total_words = (uint32_t)(len / 4);

	if (total_words < 5) {
		return p_bytes;
	}

	// Pass 1: find all OpVariable IDs with StorageClass == PushConstant,
	// and also collect their result_type_id (which is an OpTypePointer).
	Vector<uint32_t> pc_var_ids;
	Vector<uint32_t> pc_ptr_type_ids;

	uint32_t pos = 5;
	while (pos < total_words) {
		uint32_t w0 = read_word(data, len, pos);
		uint32_t wc = (w0 >> 16);
		uint16_t op = (uint16_t)(w0 & 0xFFFF);
		if (wc == 0 || pos + wc > total_words) {
			break;
		}

		if (op == OP_VARIABLE && wc >= 4) {
			uint32_t type_id = read_word(data, len, pos + 1);
			uint32_t result_id = read_word(data, len, pos + 2);
			uint32_t sc = read_word(data, len, pos + 3);
			if (sc == SC_PUSH_CONSTANT) {
				pc_var_ids.push_back(result_id);
				if (pc_ptr_type_ids.find(type_id) == -1) {
					pc_ptr_type_ids.push_back(type_id);
				}
			}
		}
		pos += wc;
	}

	if (pc_var_ids.is_empty()) {
		return p_bytes;
	}

	// Build decode set: which var IDs already have DescriptorSet / Binding decorations.
	HashSet<uint32_t> has_set;
	HashSet<uint32_t> has_binding;
	pos = 5;
	while (pos < total_words) {
		uint32_t w0 = read_word(data, len, pos);
		uint32_t wc = (w0 >> 16);
		uint16_t op = (uint16_t)(w0 & 0xFFFF);
		if (wc == 0 || pos + wc > total_words) {
			break;
		}
		if (op == OP_DECORATE && wc >= 3) {
			uint32_t target = read_word(data, len, pos + 1);
			uint32_t deco = read_word(data, len, pos + 2);
			if (pc_var_ids.find(target) != -1) {
				if (deco == DECO_DESCRIPTOR_SET) {
					has_set.insert(target);
				}
				if (deco == DECO_BINDING) {
					has_binding.insert(target);
				}
			}
		}
		pos += wc;
	}

	// Pass 2: rewrite SPIR-V.
	Vector<uint8_t> out;

	// Copy 5-word SPIR-V header.
	append_bytes(out, data, 0, 20);

	bool injected_decorations = false;

	pos = 5;
	while (pos < total_words) {
		uint32_t w0 = read_word(data, len, pos);
		uint32_t wc = (w0 >> 16);
		uint16_t op = (uint16_t)(w0 & 0xFFFF);
		if (wc == 0 || pos + wc > total_words) {
			break;
		}

		// Injection point: before the first type instruction (opcode 19-32).
		if (!injected_decorations && op >= 19 && op <= 32) {
			injected_decorations = true;
			for (int i = 0; i < pc_var_ids.size(); i++) {
				uint32_t var_id = pc_var_ids[i];
				// OpDecorate <var_id> DescriptorSet 3.
				push_word(out, (4u << 16) | 71u);
				push_word(out, var_id);
				push_word(out, DECO_DESCRIPTOR_SET);
				push_word(out, 3);
				// OpDecorate <var_id> Binding <PC_RING_BUFFER_BINDING>.
				push_word(out, (4u << 16) | 71u);
				push_word(out, var_id);
				push_word(out, DECO_BINDING);
				push_word(out, PC_RING_BUFFER_BINDING);
				// OpDecorate <var_id> NonWritable -- results in var<storage, read> in WGSL.
				push_word(out, (3u << 16) | 71u);
				push_word(out, var_id);
				push_word(out, DECO_NON_WRITABLE);
			}
		}

		// Remove any pre-existing DescriptorSet / Binding decorations on PC vars
		// to avoid duplicates that would conflict with the injected ones above.
		if (op == OP_DECORATE && wc >= 3) {
			uint32_t target = read_word(data, len, pos + 1);
			if (pc_var_ids.find(target) != -1) {
				uint32_t deco = read_word(data, len, pos + 2);
				if (deco == DECO_DESCRIPTOR_SET || deco == DECO_BINDING) {
					pos += wc;
					continue; // Skip.
				}
			}
		}

		// Rewrite ALL OpTypePointer PushConstant -> StorageBuffer.
		// This covers both the variable's own pointer type AND the pointer
		// types used by OpAccessChain results (e.g. PushConstant %v2int).
		if (op == OP_TYPE_POINTER && wc == 4) {
			uint32_t ptr_result_id = read_word(data, len, pos + 1);
			uint32_t ptr_sc = read_word(data, len, pos + 2);
			if (ptr_sc == SC_PUSH_CONSTANT) {
				push_word(out, (4u << 16) | (uint32_t)OP_TYPE_POINTER);
				push_word(out, ptr_result_id);
				push_word(out, SC_STORAGE_BUFFER); // Changed storage class.
				push_word(out, read_word(data, len, pos + 3)); // Pointee type_id.
				pos += wc;
				continue;
			}
		}

		if (op == OP_VARIABLE && wc >= 4) {
			uint32_t result_id = read_word(data, len, pos + 2);
			if (pc_var_ids.find(result_id) != -1) {
				// Emit OpVariable with StorageClass changed to StorageBuffer.
				push_word(out, ((uint32_t)wc << 16) | (uint32_t)OP_VARIABLE);
				push_word(out, read_word(data, len, pos + 1)); // type_id.
				push_word(out, result_id);
				push_word(out, SC_STORAGE_BUFFER); // Changed!
				for (uint32_t i = 4; i < wc; i++) {
					push_word(out, read_word(data, len, pos + i));
				}
				pos += wc;
				continue;
			}
		}

		// Copy instruction as-is.
		append_bytes(out, data, pos * 4, wc * 4);
		pos += wc;
	}

	return out;
}

// ---- rewrite_copy_logical ----

Vector<uint8_t> rewrite_copy_logical(const Vector<uint8_t> &p_bytes) {
	const int64_t len = p_bytes.size();
	const uint32_t total_words = (uint32_t)(len / 4);

	if (total_words < 5) {
		return p_bytes;
	}

	const uint8_t *data = p_bytes.ptr();

	// Quick scan: if no CopyLogical present, return as-is.
	bool found = false;
	uint32_t pos = 5;
	while (pos < total_words) {
		uint32_t w0 = read_word(data, len, pos);
		uint32_t wc = (w0 >> 16);
		uint16_t op = (uint16_t)(w0 & 0xFFFF);
		if (wc == 0 || pos + wc > total_words) {
			break;
		}
		if (op == OP_COPY_LOGICAL) {
			found = true;
			break;
		}
		pos += wc;
	}

	if (!found) {
		return p_bytes;
	}

	// Rewrite: replace OpCopyLogical with OpCopyObject (same word count and layout).
	Vector<uint8_t> out = p_bytes;
	uint8_t *out_data = out.ptrw();

	pos = 5;
	while (pos < total_words) {
		uint32_t w0 = read_word(out_data, len, pos);
		uint32_t wc = (w0 >> 16);
		uint16_t op = (uint16_t)(w0 & 0xFFFF);
		if (wc == 0 || pos + wc > total_words) {
			break;
		}
		if (op == OP_COPY_LOGICAL) {
			// Replace opcode in-place: keep word count, change opcode to CopyObject.
			uint32_t new_w0 = (wc << 16) | (uint32_t)OP_COPY_OBJECT;
			uint32_t off = pos * 4;
			memcpy(out_data + off, &new_w0, 4);
		}
		pos += wc;
	}

	return out;
}

// ---- rewrite_terminate_invocation ----

Vector<uint8_t> rewrite_terminate_invocation(const Vector<uint8_t> &p_bytes) {
	const int64_t len = p_bytes.size();
	const uint32_t total_words = (uint32_t)(len / 4);

	if (total_words < 5) {
		return p_bytes;
	}

	const uint8_t *data = p_bytes.ptr();

	// Quick scan: if no TerminateInvocation present, return as-is.
	bool found = false;
	uint32_t pos = 5;
	while (pos < total_words) {
		uint32_t w0 = read_word(data, len, pos);
		uint32_t wc = (w0 >> 16);
		uint16_t op = (uint16_t)(w0 & 0xFFFF);
		if (wc == 0 || pos + wc > total_words) {
			break;
		}
		if (op == OP_TERMINATE_INVOCATION) {
			found = true;
			break;
		}
		pos += wc;
	}

	if (!found) {
		return p_bytes;
	}

	// Rewrite in-place.
	Vector<uint8_t> out = p_bytes;
	uint8_t *out_data = out.ptrw();

	pos = 5;
	while (pos < total_words) {
		uint32_t w0 = read_word(out_data, len, pos);
		uint32_t wc = (w0 >> 16);
		uint16_t op = (uint16_t)(w0 & 0xFFFF);
		if (wc == 0 || pos + wc > total_words) {
			break;
		}
		if (op == OP_TERMINATE_INVOCATION) {
			// Replace opcode in-place: keep word count, change opcode to OpKill.
			uint32_t new_w0 = (wc << 16) | (uint32_t)OP_KILL;
			uint32_t off = pos * 4;
			memcpy(out_data + off, &new_w0, 4);
		}
		pos += wc;
	}

	return out;
}

// ---- split_combined_samplers ----

Vector<uint8_t> split_combined_samplers(const Vector<uint8_t> &p_bytes) {
	const uint8_t *data = p_bytes.ptr();
	const int64_t len = p_bytes.size();
	const uint32_t total_words = (uint32_t)(len / 4);

	if (total_words < 5) {
		return p_bytes;
	}

	// --- First pass: collect type info and combined sampler variables ---

	// sampled_image_type_id -> image_type_id.
	HashMap<uint32_t, uint32_t> sampled_image_types;
	// image_type_ids that are multisampled (MS field == 1).
	HashSet<uint32_t> multisampled_image_types;
	// sampled_image_type_ids that wrap a multisampled image (to be stripped).
	HashSet<uint32_t> multisampled_sampled_image_types;
	// pointer_type_id -> base_type_id (for UniformConstant pointers).
	HashMap<uint32_t, uint32_t> uc_pointer_types;
	// variable_id -> pointer_type_id (for UniformConstant variables).
	HashMap<uint32_t, uint32_t> uc_variables;
	// Track decorations: id -> set, id -> binding.
	HashMap<uint32_t, uint32_t> var_sets;
	HashMap<uint32_t, uint32_t> var_bind_nums;
	// Sampler type ID (if any exists).
	uint32_t existing_sampler_type = 0;
	bool has_sampler_type = false;
	// Current max ID for allocating new IDs.
	uint32_t bound = read_word(data, len, 3);

	uint32_t pos = 5;
	while (pos < total_words) {
		uint32_t w0 = read_word(data, len, pos);
		uint32_t wc = (w0 >> 16);
		uint16_t op = (uint16_t)(w0 & 0xFFFF);
		if (wc == 0 || pos + wc > total_words) {
			break;
		}

		switch (op) {
			case OP_TYPE_IMAGE: { // OpTypeImage
				// OpTypeImage %result %sampled_type %dim %depth %arrayed %ms %sampled %format
				// MS field is at word index 6 (0-based from instruction start). 1 = multisampled.
				if (wc >= 9) {
					uint32_t id = read_word(data, len, pos + 1);
					uint32_t ms = read_word(data, len, pos + 6);
					if (ms == 1) {
						multisampled_image_types.insert(id);
					}
				}
			} break;

			case OP_TYPE_SAMPLED_IMAGE: { // OpTypeSampledImage
				if (wc >= 3) {
					uint32_t id = read_word(data, len, pos + 1);
					uint32_t image_id = read_word(data, len, pos + 2);
					sampled_image_types.insert(id, image_id);
					if (multisampled_image_types.has(image_id)) {
						multisampled_sampled_image_types.insert(id);
					}
				}
			} break;

			case OP_TYPE_SAMPLER: { // OpTypeSampler
				if (wc >= 2) {
					existing_sampler_type = read_word(data, len, pos + 1);
					has_sampler_type = true;
				}
			} break;

			case OP_TYPE_POINTER: { // OpTypePointer
				if (wc >= 4) {
					uint32_t id = read_word(data, len, pos + 1);
					uint32_t sc = read_word(data, len, pos + 2);
					uint32_t base = read_word(data, len, pos + 3);
					if (sc == SC_UNIFORM_CONSTANT) {
						uc_pointer_types.insert(id, base);
					}
				}
			} break;

			case OP_VARIABLE: { // OpVariable
				if (wc >= 4) {
					uint32_t type_id = read_word(data, len, pos + 1);
					uint32_t id = read_word(data, len, pos + 2);
					uint32_t sc = read_word(data, len, pos + 3);
					if (sc == SC_UNIFORM_CONSTANT) {
						uc_variables.insert(id, type_id);
					}
				}
			} break;

			case OP_DECORATE: { // OpDecorate
				if (wc >= 4) {
					uint32_t target = read_word(data, len, pos + 1);
					uint32_t decoration = read_word(data, len, pos + 2);
					uint32_t value = read_word(data, len, pos + 3);
					if (decoration == DECO_DESCRIPTOR_SET) {
						var_sets.insert(target, value);
					} else if (decoration == DECO_BINDING) {
						var_bind_nums.insert(target, value);
					}
				}
			} break;

			default:
				break;
		}

		pos += wc;
	}

	// Build binding map: var_id -> (set, binding).
	HashMap<uint32_t, uint32_t> var_binding_set; // var_id -> set
	HashMap<uint32_t, uint32_t> var_binding_num; // var_id -> binding
	for (const KeyValue<uint32_t, uint32_t> &kv : uc_variables) {
		uint32_t var_id = kv.key;
		const uint32_t *set_ptr = var_sets.getptr(var_id);
		const uint32_t *bind_ptr = var_bind_nums.getptr(var_id);
		if (set_ptr && bind_ptr) {
			var_binding_set.insert(var_id, *set_ptr);
			var_binding_num.insert(var_id, *bind_ptr);
		}
	}

	// Identify which variables are combined image samplers.
	// combined_var_id -> image_type_id.
	struct CombinedVarInfo {
		uint32_t image_type_id;
		uint32_t sampled_image_type_id;
		uint32_t set;
		uint32_t binding;
		bool is_multisampled;
	};
	HashMap<uint32_t, CombinedVarInfo> combined_vars;

	for (const KeyValue<uint32_t, uint32_t> &kv : uc_variables) {
		uint32_t var_id = kv.key;
		uint32_t ptr_type_id = kv.value;
		const uint32_t *base_type_ptr = uc_pointer_types.getptr(ptr_type_id);
		if (!base_type_ptr) {
			continue;
		}
		const uint32_t *image_type_ptr = sampled_image_types.getptr(*base_type_ptr);
		if (!image_type_ptr) {
			continue;
		}
		const uint32_t *set_ptr = var_binding_set.getptr(var_id);
		const uint32_t *bind_ptr = var_binding_num.getptr(var_id);
		if (!set_ptr || !bind_ptr) {
			continue;
		}
		CombinedVarInfo info;
		info.image_type_id = *image_type_ptr;
		info.sampled_image_type_id = *base_type_ptr;
		info.set = *set_ptr;
		info.binding = *bind_ptr;
		info.is_multisampled = multisampled_image_types.has(*image_type_ptr);
		combined_vars.insert(var_id, info);
	}

	// NOTE: Do NOT early-return when combined_vars is empty.
	// The binding-doubling logic below must run for ALL shaders so that
	// non-combined bindings are also doubled (matching the BGL's u.binding*2).

	// --- Allocate new IDs ---
	uint32_t next_id = bound;
	auto alloc_id = [&]() -> uint32_t {
		uint32_t id = next_id;
		next_id++;
		return id;
	};

	// For each combined var, reuse the original var as the image var (just change
	// its binding and type pointer). Allocate NEW IDs for:
	//   image_ptr_type_id: OpTypePointer UniformConstant image_type_id
	//   sampler_ptr_type_id: OpTypePointer UniformConstant sampler_type_id
	//   sampler_var_id: the new separate sampler variable
	struct SplitInfo {
		uint32_t image_type_id;
		uint32_t sampled_image_type_id;
		uint32_t original_ptr_type_id;
		uint32_t image_ptr_type_id;
		uint32_t sampler_ptr_type_id;
		uint32_t image_var_id;
		uint32_t sampler_var_id;
		uint32_t set;
		uint32_t binding;
		bool is_multisampled;
	};

	// Check if any non-multisampled combined vars need a sampler type.
	bool has_non_ms_combined = false;
	for (const KeyValue<uint32_t, CombinedVarInfo> &kv : combined_vars) {
		if (!kv.value.is_multisampled) {
			has_non_ms_combined = true;
			break;
		}
	}
	uint32_t sampler_type_id = 0;
	bool need_sampler_type = false;
	if (has_non_ms_combined) {
		if (has_sampler_type) {
			sampler_type_id = existing_sampler_type;
		} else {
			sampler_type_id = alloc_id();
		}
		need_sampler_type = !has_sampler_type;
	}

	// Pre-compute image_ptr_type_id per unique image_type_id.
	HashMap<uint32_t, uint32_t> image_ptr_type_map; // image_type_id -> image_ptr_type_id
	for (const KeyValue<uint32_t, CombinedVarInfo> &kv : combined_vars) {
		if (!image_ptr_type_map.has(kv.value.image_type_id)) {
			image_ptr_type_map.insert(kv.value.image_type_id, alloc_id());
		}
	}

	HashMap<uint32_t, SplitInfo> splits;
	for (const KeyValue<uint32_t, CombinedVarInfo> &kv : combined_vars) {
		uint32_t var_id = kv.key;
		const CombinedVarInfo &info = kv.value;
		uint32_t original_ptr_type_id = uc_variables[var_id];

		SplitInfo split;
		split.image_type_id = info.image_type_id;
		split.sampled_image_type_id = info.sampled_image_type_id;
		split.original_ptr_type_id = original_ptr_type_id;
		split.image_ptr_type_id = image_ptr_type_map[info.image_type_id];
		split.sampler_ptr_type_id = alloc_id();
		split.image_var_id = var_id; // Reuse the combined var ID as the image var.
		split.sampler_var_id = alloc_id();
		split.set = info.set;
		split.binding = info.binding;
		split.is_multisampled = info.is_multisampled;
		splits.insert(var_id, split);
	}

	// --- Collect function parameters that receive combined vars at call sites ---
	// (func_id, param_index) -> combined_var_id.
	HashMap<uint64_t, uint32_t> call_combined_args; // Pack (func_id, param_index) into uint64_t.
	// func_id -> list of param_ids.
	HashMap<uint32_t, Vector<uint32_t>> function_param_ids;
	// func_id -> func_type_id (from OpFunction word 4).
	HashMap<uint32_t, uint32_t> function_type_ids;
	// func_type_id -> list of param_type_ids (from OpTypeFunction).
	HashMap<uint32_t, Vector<uint32_t>> func_type_params;

	// First scan: collect OpTypeFunction definitions.
	{
		uint32_t pos2 = 5;
		while (pos2 < total_words) {
			uint32_t w0 = read_word(data, len, pos2);
			uint32_t wc2 = (w0 >> 16);
			uint16_t op2 = (uint16_t)(w0 & 0xFFFF);
			if (wc2 == 0 || pos2 + wc2 > total_words) {
				break;
			}
			if (op2 == OP_TYPE_FUNCTION && wc2 >= 3) {
				uint32_t type_id = read_word(data, len, pos2 + 1);
				// return type at word 2, params start at word 3.
				Vector<uint32_t> params;
				for (uint32_t i = 3; i < wc2; i++) {
					params.push_back(read_word(data, len, pos2 + i));
				}
				func_type_params.insert(type_id, params);
			}
			pos2 += wc2;
		}
	}

	{
		uint32_t cur_func = 0;
		uint32_t cur_func_type = 0;
		Vector<uint32_t> cur_params;
		uint32_t pos2 = 5;
		while (pos2 < total_words) {
			uint32_t w0 = read_word(data, len, pos2);
			uint32_t wc2 = (w0 >> 16);
			uint16_t op2 = (uint16_t)(w0 & 0xFFFF);
			if (wc2 == 0 || pos2 + wc2 > total_words) {
				break;
			}

			switch (op2) {
				case OP_FUNCTION: { // OpFunction
					if (cur_func != 0) {
						function_param_ids.insert(cur_func, cur_params);
						function_type_ids.insert(cur_func, cur_func_type);
					}
					cur_func = read_word(data, len, pos2 + 2); // result_id.
					cur_func_type = (wc2 >= 5) ? read_word(data, len, pos2 + 4) : 0;
					cur_params.clear();
				} break;

				case OP_FUNCTION_PARAMETER: { // OpFunctionParameter
					if (wc2 >= 3) {
						cur_params.push_back(read_word(data, len, pos2 + 2));
					}
				} break;

				case OP_FUNCTION_END: { // OpFunctionEnd
					if (cur_func != 0) {
						function_param_ids.insert(cur_func, cur_params);
						function_type_ids.insert(cur_func, cur_func_type);
						cur_func = 0;
						cur_func_type = 0;
						cur_params.clear();
					}
				} break;

				case OP_FUNCTION_CALL: { // OpFunctionCall
					if (wc2 >= 4) {
						uint32_t func_id = read_word(data, len, pos2 + 3);
						for (uint32_t arg_idx = 0; arg_idx < wc2 - 4; arg_idx++) {
							uint32_t arg_id = read_word(data, len, pos2 + 4 + arg_idx);
							if (combined_vars.has(arg_id)) {
								uint64_t key = ((uint64_t)func_id << 32) | (uint64_t)arg_idx;
								call_combined_args.insert(key, arg_id);
							}
						}
					}
				} break;

				default:
					break;
			}

			pos2 += wc2;
		}
		if (cur_func != 0) {
			function_param_ids.insert(cur_func, cur_params);
			function_type_ids.insert(cur_func, cur_func_type);
		}
	}

	// Build: param_id -> combined_var_id (for function parameters that receive combined vars).
	HashMap<uint32_t, uint32_t> param_combined;
	for (const KeyValue<uint64_t, uint32_t> &kv : call_combined_args) {
		uint32_t func_id = (uint32_t)(kv.key >> 32);
		uint32_t param_pos_val = (uint32_t)(kv.key & 0xFFFFFFFF);
		uint32_t combined_var_id = kv.value;
		const Vector<uint32_t> *params = function_param_ids.getptr(func_id);
		if (params && (int)param_pos_val < params->size()) {
			param_combined.insert((*params)[param_pos_val], combined_var_id);
		}
	}

	// Build: func_id -> new_func_type_id for functions with combined-var params.
	// Also build: param_id -> image_ptr_type_id for parameter type rewriting.
	HashMap<uint32_t, uint32_t> param_new_type; // param_id -> new pointer type (image_ptr_type_id)
	HashMap<uint32_t, uint32_t> func_new_type_id; // func_id -> new OpTypeFunction id
	// new_func_type_id -> (return_type, [param_types...]) for injection.
	struct NewFuncType {
		uint32_t new_type_id;
		uint32_t return_type;
		Vector<uint32_t> param_types;
	};
	Vector<NewFuncType> new_func_types;

	for (const KeyValue<uint32_t, uint32_t> &kv : param_combined) {
		const SplitInfo &split = splits[kv.value];
		param_new_type.insert(kv.key, split.image_ptr_type_id);
	}

	// For each function that has combined-var params, create a new func type.
	{
		HashSet<uint32_t> funcs_needing_new_type;
		for (const KeyValue<uint64_t, uint32_t> &kv : call_combined_args) {
			uint32_t func_id = (uint32_t)(kv.key >> 32);
			funcs_needing_new_type.insert(func_id);
		}
		for (uint32_t func_id : funcs_needing_new_type) {
			const uint32_t *ft_ptr = function_type_ids.getptr(func_id);
			if (!ft_ptr) {
				continue;
			}
			uint32_t old_ft = *ft_ptr;
			const Vector<uint32_t> *old_params = func_type_params.getptr(old_ft);
			if (!old_params) {
				continue;
			}
			const Vector<uint32_t> *param_ids = function_param_ids.getptr(func_id);
			if (!param_ids) {
				continue;
			}

			// Build new param type list, replacing SampledImage ptr types with Image ptr types.
			NewFuncType nft;
			nft.new_type_id = alloc_id();
			// Return type is at word 2 of OpTypeFunction. Read it from the original type.
			// We need to find the return type. It's stored separately: OpFunction has it at word 1.
			// But we can also find it in the OpTypeFunction definition.
			// func_type_params stores params starting at word 3, return type is word 2.
			// Let's scan for the return type from the original OpTypeFunction.
			nft.return_type = 0;
			{
				uint32_t pos2 = 5;
				while (pos2 < total_words) {
					uint32_t w0 = read_word(data, len, pos2);
					uint32_t wc2 = (w0 >> 16);
					uint16_t op2 = (uint16_t)(w0 & 0xFFFF);
					if (wc2 == 0 || pos2 + wc2 > total_words) {
						break;
					}
					if (op2 == OP_TYPE_FUNCTION && wc2 >= 3 && read_word(data, len, pos2 + 1) == old_ft) {
						nft.return_type = read_word(data, len, pos2 + 2);
						break;
					}
					pos2 += wc2;
				}
			}

			for (int i = 0; i < old_params->size(); i++) {
				uint32_t param_type = (*old_params)[i];
				// Check if this parameter position needs remapping.
				if (i < (int)param_ids->size()) {
					uint32_t param_id = (*param_ids)[i];
					const uint32_t *new_type = param_new_type.getptr(param_id);
					if (new_type) {
						param_type = *new_type;
					}
				}
				nft.param_types.push_back(param_type);
			}

			func_new_type_id.insert(func_id, nft.new_type_id);
			new_func_types.push_back(nft);
		}
	}

	// Collect OpLoad result IDs that load from combined vars or combined-var function params.
	// load_result_id -> combined_var_id.
	HashMap<uint32_t, uint32_t> combined_loads;
	pos = 5;
	while (pos < total_words) {
		uint32_t w0 = read_word(data, len, pos);
		uint32_t wc = (w0 >> 16);
		uint16_t op = (uint16_t)(w0 & 0xFFFF);
		if (wc == 0 || pos + wc > total_words) {
			break;
		}
		if (op == OP_LOAD && wc >= 4) {
			uint32_t result_id = read_word(data, len, pos + 2);
			uint32_t pointer_id = read_word(data, len, pos + 3);
			if (combined_vars.has(pointer_id)) {
				combined_loads.insert(result_id, pointer_id);
			} else {
				const uint32_t *cv = param_combined.getptr(pointer_id);
				if (cv) {
					combined_loads.insert(result_id, *cv);
				}
			}
		}
		pos += wc;
	}

	// Allocate IDs for split loads.
	// For non-multisampled: variable is ptr(Image), so:
	//   si_load_id:   OpLoad Image from variable
	//   img_id:       (unused, kept for allocation consistency)
	//   samp_load_id: OpLoad sampler from sampler variable
	// Then OpSampledImage recombines into result_id.
	struct LoadSplitIds {
		uint32_t si_load_id;
		uint32_t img_id;
		uint32_t samp_load_id;
	};
	HashMap<uint32_t, LoadSplitIds> load_splits;
	for (const KeyValue<uint32_t, uint32_t> &kv : combined_loads) {
		LoadSplitIds ids;
		ids.si_load_id = alloc_id();
		ids.img_id = alloc_id();
		ids.samp_load_id = alloc_id();
		load_splits.insert(kv.key, ids);
	}

	// --- Second pass: rewrite ---
	Vector<uint8_t> out;

	// Copy header but update bound.
	append_bytes(out, data, 0, 12);
	push_word(out, next_id); // Updated bound.
	push_word(out, read_word(data, len, 4)); // Schema.

	// Track injection state.
	bool decorations_injected = false;
	bool types_injected = false;
	HashSet<uint32_t> image_ptr_injected; // Set of image_type_ids already injected.

	pos = 5;
	while (pos < total_words) {
		uint32_t w0 = read_word(data, len, pos);
		uint32_t wc = (w0 >> 16);
		uint16_t op = (uint16_t)(w0 & 0xFFFF);
		if (wc == 0 || pos + wc > total_words) {
			break;
		}

		// Rewrite OpEntryPoint: keep combined var (now = image var), add sampler_var.
		if (op == OP_ENTRY_POINT) {
			uint32_t exec_model = read_word(data, len, pos + 1);
			uint32_t entry_id = read_word(data, len, pos + 2);

			// Find end of name string (null-terminated, packed into words).
			uint32_t name_end = pos + 3;
			while (name_end < pos + wc) {
				uint32_t w = read_word(data, len, name_end);
				name_end++;
				if ((w & 0xFF) == 0 || ((w >> 8) & 0xFF) == 0 ||
						((w >> 16) & 0xFF) == 0 || ((w >> 24) & 0xFF) == 0) {
					break;
				}
			}

			// Keep combined var IDs (they are now image vars), add sampler_var IDs.
			Vector<uint32_t> new_vars;
			for (uint32_t i = name_end; i < pos + wc; i++) {
				uint32_t var_id = read_word(data, len, i);
				new_vars.push_back(var_id);
				const SplitInfo *split = splits.getptr(var_id);
				if (split && !split->is_multisampled) {
					new_vars.push_back(split->sampler_var_id);
				}
			}

			uint32_t new_wc = (name_end - pos) + new_vars.size();
			push_word(out, (new_wc << 16) | (uint32_t)OP_ENTRY_POINT);
			push_word(out, exec_model);
			push_word(out, entry_id);
			for (uint32_t i = pos + 3; i < name_end; i++) {
				push_word(out, read_word(data, len, i));
			}
			for (int i = 0; i < new_vars.size(); i++) {
				push_word(out, new_vars[i]);
			}

			pos += wc;
			continue;
		}

		// Inject decorations before the first type instruction (opcodes 19-33).
		if (!decorations_injected && op >= 19 && op <= 33) {
			decorations_injected = true;
			for (const KeyValue<uint32_t, SplitInfo> &kv : splits) {
				const SplitInfo &split = kv.value;
				if (split.is_multisampled) {
					continue; // No sampler variable for multisampled.
				}
				// Decorations for sampler var only.
				push_word(out, (4u << 16) | 71u); // OpDecorate
				push_word(out, split.sampler_var_id);
				push_word(out, DECO_DESCRIPTOR_SET);
				push_word(out, split.set);

				push_word(out, (4u << 16) | 71u); // OpDecorate
				push_word(out, split.sampler_var_id);
				push_word(out, DECO_BINDING);
				push_word(out, split.binding * 2);
			}
		}

		// Inject new types/variables before first OpFunction.
		if (op == OP_FUNCTION && !types_injected) {
			types_injected = true;
			// Emit OpTypeSampler if needed.
			if (need_sampler_type) {
				push_word(out, (2u << 16) | (uint32_t)OP_TYPE_SAMPLER);
				push_word(out, sampler_type_id);
			}
			// For each split, emit the sampler pointer type + sampler variable.
			for (const KeyValue<uint32_t, SplitInfo> &kv : splits) {
				const SplitInfo &split = kv.value;
				if (split.is_multisampled) {
					continue; // No sampler variable for multisampled.
				}
				// OpTypePointer %sampler_ptr UniformConstant %sampler_type.
				push_word(out, (4u << 16) | (uint32_t)OP_TYPE_POINTER);
				push_word(out, split.sampler_ptr_type_id);
				push_word(out, SC_UNIFORM_CONSTANT);
				push_word(out, sampler_type_id);

				// OpVariable %sampler_ptr %sampler_var UniformConstant.
				push_word(out, (4u << 16) | (uint32_t)OP_VARIABLE);
				push_word(out, split.sampler_ptr_type_id);
				push_word(out, split.sampler_var_id);
				push_word(out, SC_UNIFORM_CONSTANT);
			}
			// Emit new OpTypeFunction for functions with combined-var params.
			for (const NewFuncType &nft : new_func_types) {
				uint32_t wc2 = 3 + nft.param_types.size();
				push_word(out, (wc2 << 16) | (uint32_t)OP_TYPE_FUNCTION);
				push_word(out, nft.new_type_id);
				push_word(out, nft.return_type);
				for (int i = 0; i < nft.param_types.size(); i++) {
					push_word(out, nft.param_types[i]);
				}
			}
		}

		// Rewrite OpFunction: use new func type if this function had combined-var params.
		if (op == OP_FUNCTION && wc >= 5) {
			uint32_t func_id = read_word(data, len, pos + 2);
			const uint32_t *new_ft = func_new_type_id.getptr(func_id);
			if (new_ft) {
				push_word(out, w0);
				push_word(out, read_word(data, len, pos + 1)); // return type
				push_word(out, func_id);
				push_word(out, read_word(data, len, pos + 3)); // function control
				push_word(out, *new_ft); // new function type
				pos += wc;
				continue;
			}
		}

		// Rewrite OpFunctionParameter: change type for combined-var params.
		if (op == OP_FUNCTION_PARAMETER && wc >= 3) {
			uint32_t param_id = read_word(data, len, pos + 2);
			const uint32_t *new_type = param_new_type.getptr(param_id);
			if (new_type) {
				push_word(out, w0);
				push_word(out, *new_type); // new type (ptr(Image) instead of ptr(SampledImage))
				push_word(out, param_id);
				pos += wc;
				continue;
			}
		}

		// Rewrite OpDecorate for combined sampler vars and adjust bindings.
		if (op == OP_DECORATE && wc >= 3) {
			uint32_t target = read_word(data, len, pos + 1);
			uint32_t decoration = read_word(data, len, pos + 2);

			if (combined_vars.has(target)) {
				if (decoration == DECO_BINDING) {
					// Change Binding from original to binding*2+1 (image slot).
					const CombinedVarInfo &cinfo = combined_vars[target];
					push_word(out, w0); // Same wc|op.
					push_word(out, target);
					push_word(out, DECO_BINDING);
					// Multisampled: no sampler, so image gets binding*2 (like non-combined).
					// Regular: image gets binding*2+1, sampler gets binding*2.
					push_word(out, cinfo.is_multisampled ? cinfo.binding * 2 : cinfo.binding * 2 + 1);
					pos += wc;
					continue;
				} else if (decoration == DECO_NON_WRITABLE) {
					// Remove NonWritable on combined vars.
					pos += wc;
					continue;
				}
				// Keep DescriptorSet and all other decorations as-is.
			} else if (decoration == DECO_BINDING) {
				// Binding for non-combined var: double it.
				uint32_t old_binding = (wc >= 4) ? read_word(data, len, pos + 3) : 0;
				// Don't double the PC ring-buffer binding.
				uint32_t new_binding = (old_binding == PC_RING_BUFFER_BINDING) ? old_binding : old_binding * 2;
				push_word(out, w0);
				push_word(out, target);
				push_word(out, decoration);
				push_word(out, new_binding);
				for (uint32_t i = 4; i < wc; i++) {
					push_word(out, read_word(data, len, pos + i));
				}
				pos += wc;
				continue;
			}
		}

		// Rewrite OpVariable for ALL combined vars.
		// Change type from ptr(SampledImage) to ptr(Image) so Tint's built-in
		// SplitCombinedImageSamplerPass won't see them as combined samplers
		// and try to split them again (which would create extra bindings that
		// don't exist in the BGL, causing "Binding doesn't exist" errors).
		if (op == OP_VARIABLE && wc >= 4) {
			uint32_t var_id = read_word(data, len, pos + 2);
			const SplitInfo *sp = splits.getptr(var_id);
			if (sp) {
				push_word(out, w0);
				push_word(out, sp->image_ptr_type_id); // ptr(Image) instead of ptr(SampledImage)
				push_word(out, var_id);
				push_word(out, read_word(data, len, pos + 3)); // storage class
				pos += wc;
				continue;
			}
		}

		// Rewrite OpLoad of combined image sampler (from global var or function param).
		if (op == OP_LOAD && wc >= 4) {
			uint32_t result_id = read_word(data, len, pos + 2);
			const uint32_t *combined_var_ptr = combined_loads.getptr(result_id);
			if (combined_var_ptr) {
				const SplitInfo &split = splits[*combined_var_ptr];
				const LoadSplitIds &lids = load_splits[result_id];

				if (split.is_multisampled) {
					// Multisampled: variable type was changed to ptr(Image),
					// so load Image directly. No sampler needed.
					push_word(out, (4u << 16) | (uint32_t)OP_LOAD);
					push_word(out, split.image_type_id);
					push_word(out, result_id); // Original result_id, now image type.
					push_word(out, split.image_var_id);
				} else {
					// Non-multisampled: variable type was changed to ptr(Image),
					// so load Image directly, load sampler separately, then
					// recombine with OpSampledImage for downstream consumers.
					//
					// OpLoad %ImageType %si_load %image_var
					push_word(out, (4u << 16) | (uint32_t)OP_LOAD);
					push_word(out, split.image_type_id);
					push_word(out, lids.si_load_id);
					push_word(out, split.image_var_id);

					// OpLoad %SamplerType %samp_load %sampler_var
					push_word(out, (4u << 16) | (uint32_t)OP_LOAD);
					push_word(out, sampler_type_id);
					push_word(out, lids.samp_load_id);
					push_word(out, split.sampler_var_id);

					// OpSampledImage %SampledImageType %result_id %si_load %samp_load
					push_word(out, (5u << 16) | (uint32_t)OP_SAMPLED_IMAGE);
					push_word(out, split.sampled_image_type_id);
					push_word(out, result_id);
					push_word(out, lids.si_load_id);
					push_word(out, lids.samp_load_id);
				}

				pos += wc;
				continue;
			}
		}

		// Strip OpImage instructions that extract from multisampled combined loads.
		// After the load rewrite, the load already produces the image type directly,
		// so OpImage is no longer needed. Replace with OpCopyObject.
		if (op == OP_IMAGE && wc >= 4) {
			uint32_t result_type = read_word(data, len, pos + 1);
			uint32_t result_id = read_word(data, len, pos + 2);
			uint32_t sampled_image_id = read_word(data, len, pos + 3);
			const uint32_t *combined_var_ptr = combined_loads.getptr(sampled_image_id);
			if (combined_var_ptr && splits.has(*combined_var_ptr) && splits[*combined_var_ptr].is_multisampled) {
				// The load already produces image type directly. Emit OpCopyObject
				// so downstream instructions still find this result_id.
				push_word(out, (4u << 16) | (uint32_t)OP_COPY_OBJECT);
				push_word(out, result_type);
				push_word(out, result_id);
				push_word(out, sampled_image_id); // Now points to an image load, not sampled-image.
				pos += wc;
				continue;
			}
		}

		// Copy instruction as-is.
		append_bytes(out, data, pos * 4, wc * 4);

		// After copying an OpTypeImage, inject the image pointer type for any
		// split that uses this image_type_id as its base. This ensures the
		// OpTypePointer is defined AFTER its base type and BEFORE the OpVariable.
		if (op == OP_TYPE_IMAGE && wc >= 9) {
			uint32_t image_type_id = read_word(data, len, pos + 1);
			for (const KeyValue<uint32_t, SplitInfo> &kv : splits) {
				if (kv.value.image_type_id == image_type_id && !image_ptr_injected.has(image_type_id)) {
					image_ptr_injected.insert(image_type_id);
					// OpTypePointer image_ptr_type_id UniformConstant image_type_id.
					push_word(out, (4u << 16) | (uint32_t)OP_TYPE_POINTER);
					push_word(out, kv.value.image_ptr_type_id);
					push_word(out, SC_UNIFORM_CONSTANT);
					push_word(out, kv.value.image_type_id);
				}
			}
		}

		pos += wc;
	}

	return out;
}

// ---- fix_depth2_images ----

DepthImageFixResult fix_depth2_images(const Vector<uint8_t> &p_bytes) {
	DepthImageFixResult result;
	const int64_t len = p_bytes.size();
	const uint32_t total_words = (uint32_t)(len / 4);

	if (total_words < 5) {
		result.bytes = p_bytes;
		return result;
	}

	result.bytes = p_bytes;
	uint8_t *out_data = result.bytes.ptrw();

	uint32_t pos = 5;
	while (pos < total_words) {
		uint32_t w0 = read_word(out_data, len, pos);
		uint32_t wc = (w0 >> 16);
		uint16_t op = (uint16_t)(w0 & 0xFFFF);
		if (wc == 0 || pos + wc > total_words) {
			break;
		}

		if (op == OP_TYPE_IMAGE && wc >= 9) {
			uint32_t depth = read_word(out_data, len, pos + 4);
			if (depth == 2) {
				// Set depth=2 -> depth=1 (explicit depth).
				uint32_t off = (pos + 4) * 4;
				uint32_t new_depth = 1;
				memcpy(out_data + off, &new_depth, 4);
			}
		}

		pos += wc;
	}

	return result;
}

// ---- negate_position_y ----

Vector<uint8_t> negate_position_y(const Vector<uint8_t> &p_bytes) {
	const uint8_t *data = p_bytes.ptr();
	const int64_t len = p_bytes.size();
	const uint32_t total_words = (uint32_t)(len / 4);

	if (total_words < 5) {
		return p_bytes;
	}

	// --- Pass 1: Collect type info, find Position variable, find vertex entry point ---

	uint32_t bound = read_word(data, len, 3);

	// Find BuiltIn Position decoration.
	// Case A: OpDecorate %var BuiltIn Position → direct variable
	// Case B: OpMemberDecorate %struct member BuiltIn Position → struct member
	uint32_t position_var_id = 0; // Direct position variable (case A).
	uint32_t position_struct_type = 0; // Struct type with Position member (case B).
	uint32_t position_member_idx = 0; // Member index within struct.
	bool position_is_member = false;

	// Find vertex entry point function ID.
	uint32_t vertex_func_id = 0;

	// Type info.
	uint32_t float32_type_id = 0;
	HashSet<uint32_t> int_type_ids; // All integer type IDs (for filtering constants).
	HashMap<uint32_t, uint32_t> ptr_type_base; // ptr_type_id → base_type_id (for Output pointers).
	HashMap<uint32_t, uint32_t> var_ptr_type; // var_id → ptr_type_id (for Output variables).

	// Integer constants: value → result_id.
	HashMap<uint32_t, uint32_t> int_constants;

	uint32_t pos = 5;
	while (pos < total_words) {
		uint32_t w0 = read_word(data, len, pos);
		uint32_t wc = (w0 >> 16);
		uint16_t op = (uint16_t)(w0 & 0xFFFF);
		if (wc == 0 || pos + wc > total_words) {
			break;
		}

		switch (op) {
			case OP_ENTRY_POINT: {
				if (wc >= 3) {
					uint32_t exec_model = read_word(data, len, pos + 1);
					if (exec_model == EXEC_MODEL_VERTEX) {
						vertex_func_id = read_word(data, len, pos + 2);
					}
				}
			} break;

			case OP_DECORATE: {
				if (wc >= 4) {
					uint32_t target = read_word(data, len, pos + 1);
					uint32_t deco = read_word(data, len, pos + 2);
					uint32_t value = read_word(data, len, pos + 3);
					if (deco == DECO_BUILTIN && value == BUILTIN_POSITION) {
						position_var_id = target;
						position_is_member = false;
					}
				}
			} break;

			case OP_MEMBER_DECORATE: {
				if (wc >= 4) {
					uint32_t struct_type = read_word(data, len, pos + 1);
					uint32_t member = read_word(data, len, pos + 2);
					uint32_t deco = read_word(data, len, pos + 3);
					if (deco == DECO_BUILTIN && wc >= 5) {
						uint32_t value = read_word(data, len, pos + 4);
						if (value == BUILTIN_POSITION) {
							position_struct_type = struct_type;
							position_member_idx = member;
							position_is_member = true;
						}
					}
				}
			} break;

			case OP_TYPE_INT: {
				if (wc >= 3) {
					int_type_ids.insert(read_word(data, len, pos + 1));
				}
			} break;

			case OP_TYPE_FLOAT: {
				if (wc >= 3) {
					uint32_t width = read_word(data, len, pos + 2);
					if (width == 32) {
						float32_type_id = read_word(data, len, pos + 1);
					}
				}
			} break;

			case OP_TYPE_VECTOR: {
				// Tracked for potential future use (vec4<f32> identification).
			} break;

			case OP_TYPE_POINTER: {
				if (wc >= 4) {
					uint32_t id = read_word(data, len, pos + 1);
					uint32_t sc = read_word(data, len, pos + 2);
					uint32_t base = read_word(data, len, pos + 3);
					if (sc == SC_OUTPUT) {
						ptr_type_base.insert(id, base);
					}
				}
			} break;

			case OP_VARIABLE: {
				if (wc >= 4) {
					uint32_t type_id = read_word(data, len, pos + 1);
					uint32_t id = read_word(data, len, pos + 2);
					uint32_t sc = read_word(data, len, pos + 3);
					if (sc == SC_OUTPUT) {
						var_ptr_type.insert(id, type_id);
					}
				}
			} break;

			case OP_CONSTANT: {
				if (wc >= 4) {
					uint32_t type_id = read_word(data, len, pos + 1);
					uint32_t id = read_word(data, len, pos + 2);
					uint32_t value = read_word(data, len, pos + 3);
					// Only track small integer constants (for member/component indices).
					// Must verify the constant's type is actually an integer type,
					// not a float (e.g. 0.0f has bit pattern 0x00000000 which == 0).
					if (value <= 4 && int_type_ids.has(type_id)) {
						int_constants.insert(value, id);
					}
				}
			} break;

			default:
				break;
		}

		pos += wc;
	}

	// Bail if no vertex entry point or no Position found.
	if (vertex_func_id == 0) {
		return p_bytes;
	}
	if (!position_is_member && position_var_id == 0) {
		return p_bytes;
	}
	if (position_is_member && position_struct_type == 0) {
		return p_bytes;
	}

	// For case B (struct member): find the Output variable whose pointer type
	// points to the struct containing Position.
	uint32_t output_var_id = 0;
	if (position_is_member) {
		for (const KeyValue<uint32_t, uint32_t> &kv : var_ptr_type) {
			uint32_t var_id = kv.key;
			uint32_t ptr_id = kv.value;
			const uint32_t *base = ptr_type_base.getptr(ptr_id);
			if (base && *base == position_struct_type) {
				output_var_id = var_id;
				break;
			}
		}
		if (output_var_id == 0) {
			return p_bytes;
		}
	} else {
		output_var_id = position_var_id;
	}

	if (float32_type_id == 0) {
		return p_bytes;
	}

	// --- Allocate new IDs ---
	uint32_t next_id = bound;
	auto alloc_id = [&]() -> uint32_t { return next_id++; };

	// We need:
	// - A pointer type: OpTypePointer Output float32
	// - Integer constants for member index and component index 1 (Y)
	uint32_t ptr_output_float_id = alloc_id();
	uint32_t const_member_idx_id = 0;
	uint32_t const_1_id = 0;

	// Check if we already have the integer constants we need.
	if (position_is_member) {
		const uint32_t *existing = int_constants.getptr(position_member_idx);
		if (existing) {
			const_member_idx_id = *existing;
		} else {
			const_member_idx_id = alloc_id();
		}
	}
	{
		const uint32_t *existing = int_constants.getptr(1);
		if (existing) {
			const_1_id = *existing;
		} else {
			const_1_id = alloc_id();
		}
	}

	// IDs for the Y-negate sequence (per OpReturn).
	// We'll allocate fresh IDs during the rewrite pass.

	// Find an integer type for constants (32-bit signed or unsigned).
	uint32_t int32_type_id = 0;
	pos = 5;
	while (pos < total_words) {
		uint32_t w0 = read_word(data, len, pos);
		uint32_t wc = (w0 >> 16);
		uint16_t op = (uint16_t)(w0 & 0xFFFF);
		if (wc == 0 || pos + wc > total_words) {
			break;
		}
		if (op == OP_TYPE_INT && wc >= 4) {
			uint32_t width = read_word(data, len, pos + 2);
			if (width == 32) {
				int32_type_id = read_word(data, len, pos + 1);
				break;
			}
		}
		pos += wc;
	}

	if (int32_type_id == 0) {
		// No 32-bit int type? Can't create constants. Bail.
		return p_bytes;
	}

	// --- Pass 2: Count OpReturn/OpReturnValue in vertex function to pre-allocate IDs ---
	uint32_t return_count = 0;
	bool in_vertex_func = false;
	pos = 5;
	while (pos < total_words) {
		uint32_t w0 = read_word(data, len, pos);
		uint32_t wc = (w0 >> 16);
		uint16_t op = (uint16_t)(w0 & 0xFFFF);
		if (wc == 0 || pos + wc > total_words) {
			break;
		}
		if (op == OP_FUNCTION && wc >= 3) {
			uint32_t func_id = read_word(data, len, pos + 2);
			in_vertex_func = (func_id == vertex_func_id);
		}
		if (op == OP_FUNCTION_END) {
			in_vertex_func = false;
		}
		if (in_vertex_func && (op == OP_RETURN || op == OP_RETURN_VALUE)) {
			return_count++;
		}
		pos += wc;
	}

	if (return_count == 0) {
		return p_bytes;
	}

	// Per return site, we need 3 new IDs: access_chain_result, load_result, fnegate_result.
	Vector<uint32_t> ac_ids;
	Vector<uint32_t> load_ids;
	Vector<uint32_t> neg_ids;
	for (uint32_t i = 0; i < return_count; i++) {
		ac_ids.push_back(alloc_id());
		load_ids.push_back(alloc_id());
		neg_ids.push_back(alloc_id());
	}

	// --- Pass 3: Rewrite ---
	Vector<uint8_t> out;

	// Copy header but update bound.
	append_bytes(out, data, 0, 12);
	push_word(out, next_id); // Updated bound.
	push_word(out, read_word(data, len, 4)); // Schema.

	bool types_injected = false;
	in_vertex_func = false;
	uint32_t return_idx = 0;

	pos = 5;
	while (pos < total_words) {
		uint32_t w0 = read_word(data, len, pos);
		uint32_t wc = (w0 >> 16);
		uint16_t op = (uint16_t)(w0 & 0xFFFF);
		if (wc == 0 || pos + wc > total_words) {
			break;
		}

		// Inject new types/constants before the first OpFunction.
		if (op == OP_FUNCTION && !types_injected) {
			types_injected = true;

			// OpTypePointer %ptr_output_float Output %float32.
			push_word(out, (4u << 16) | (uint32_t)OP_TYPE_POINTER);
			push_word(out, ptr_output_float_id);
			push_word(out, SC_OUTPUT);
			push_word(out, float32_type_id);

			// Integer constant for member index (if not already existing).
			if (position_is_member && !int_constants.has(position_member_idx)) {
				push_word(out, (4u << 16) | (uint32_t)OP_CONSTANT);
				push_word(out, int32_type_id);
				push_word(out, const_member_idx_id);
				push_word(out, position_member_idx);
			}

			// Integer constant for 1 (Y component index).
			if (!int_constants.has(1)) {
				push_word(out, (4u << 16) | (uint32_t)OP_CONSTANT);
				push_word(out, int32_type_id);
				push_word(out, const_1_id);
				push_word(out, 1);
			}
		}

		if (op == OP_FUNCTION && wc >= 3) {
			uint32_t func_id = read_word(data, len, pos + 2);
			in_vertex_func = (func_id == vertex_func_id);
		}
		if (op == OP_FUNCTION_END) {
			in_vertex_func = false;
		}

		// Before OpReturn in vertex function, insert Y-negate sequence.
		if (in_vertex_func && (op == OP_RETURN || op == OP_RETURN_VALUE) && return_idx < return_count) {
			uint32_t ac_id = ac_ids[return_idx];
			uint32_t ld_id = load_ids[return_idx];
			uint32_t ng_id = neg_ids[return_idx];
			return_idx++;

			if (position_is_member) {
				// OpAccessChain %ptr_output_float %output_var %member_idx %const_1
				push_word(out, (6u << 16) | (uint32_t)OP_ACCESS_CHAIN);
				push_word(out, ptr_output_float_id);
				push_word(out, ac_id);
				push_word(out, output_var_id);
				push_word(out, const_member_idx_id);
				push_word(out, const_1_id);
			} else {
				// Direct vec4 position variable:
				// OpAccessChain %ptr_output_float %output_var %const_1
				push_word(out, (5u << 16) | (uint32_t)OP_ACCESS_CHAIN);
				push_word(out, ptr_output_float_id);
				push_word(out, ac_id);
				push_word(out, output_var_id);
				push_word(out, const_1_id);
			}

			// OpLoad %float32 %ld_id %ac_id
			push_word(out, (4u << 16) | (uint32_t)OP_LOAD);
			push_word(out, float32_type_id);
			push_word(out, ld_id);
			push_word(out, ac_id);

			// OpFNegate %float32 %ng_id %ld_id
			push_word(out, (4u << 16) | (uint32_t)OP_FNEGATE);
			push_word(out, float32_type_id);
			push_word(out, ng_id);
			push_word(out, ld_id);

			// OpStore %ac_id %ng_id
			push_word(out, (3u << 16) | (uint32_t)OP_STORE);
			push_word(out, ac_id);
			push_word(out, ng_id);
		}

		// Copy original instruction.
		append_bytes(out, data, pos * 4, wc * 4);
		pos += wc;
	}

	return out;
}

// ---- strip_restrict_decoration ----

Vector<uint8_t> strip_restrict_decoration(const Vector<uint8_t> &p_bytes) {
	const int64_t len = p_bytes.size();
	const uint32_t total_words = (uint32_t)(len / 4);

	if (total_words < 5) {
		return p_bytes;
	}

	const uint8_t *data = p_bytes.ptr();
	static constexpr uint32_t DECO_RESTRICT = 19;
	static constexpr uint32_t DECO_VOLATILE = 21;
	static constexpr uint32_t DECO_COHERENT = 23;
	static constexpr uint32_t DECO_INPUT_ATTACHMENT_INDEX = 43;

	// Helper: is this a decoration we need to strip?
	// Volatile and Coherent are memory-ordering hints with no WGSL equivalent -
	// Tint's SPIR-V parser hits TINT_UNIMPLEMENTED on them rather than ignoring
	// them, and dropping them is safe for a single-queue backend.
	auto is_stripped_deco = [](uint32_t d) {
		return d == DECO_RESTRICT || d == DECO_VOLATILE || d == DECO_COHERENT ||
				d == DECO_INPUT_ATTACHMENT_INDEX;
	};

	// Quick scan: any stripped decoration present?
	bool found = false;
	uint32_t pos = 5;
	while (pos < total_words) {
		uint32_t w0 = read_word(data, len, pos);
		uint32_t wc = (w0 >> 16);
		uint16_t op = (uint16_t)(w0 & 0xFFFF);
		if (wc == 0 || pos + wc > total_words) {
			break;
		}
		if (op == OP_DECORATE && wc >= 3 && is_stripped_deco(read_word(data, len, pos + 2))) {
			found = true;
			break;
		}
		if (op == OP_MEMBER_DECORATE && wc >= 4 && is_stripped_deco(read_word(data, len, pos + 3))) {
			found = true;
			break;
		}
		pos += wc;
	}

	if (!found) {
		return p_bytes;
	}

	// Strip all OpDecorate/OpMemberDecorate with stripped decorations.
	Vector<uint8_t> out;
	append_bytes(out, data, 0, 20);

	pos = 5;
	while (pos < total_words) {
		uint32_t w0 = read_word(data, len, pos);
		uint32_t wc = (w0 >> 16);
		uint16_t op = (uint16_t)(w0 & 0xFFFF);
		if (wc == 0 || pos + wc > total_words) {
			break;
		}

		bool skip = false;
		if (op == OP_DECORATE && wc >= 3 && is_stripped_deco(read_word(data, len, pos + 2))) {
			skip = true;
		}
		if (op == OP_MEMBER_DECORATE && wc >= 4 && is_stripped_deco(read_word(data, len, pos + 3))) {
			skip = true;
		}

		if (!skip) {
			append_bytes(out, data, pos * 4, wc * 4);
		}
		pos += wc;
	}

	return out;
}

static Vector<uint8_t> _remap_ids_by_grammar(const Vector<uint8_t> &p_bytes, const HashMap<uint32_t, uint32_t> &p_remap, bool p_uses_in_functions_only = false);

// ---- alias_anisotropic_samplers ----

Vector<uint8_t> alias_anisotropic_samplers(const Vector<uint8_t> &p_bytes, Vector<uint32_t> *r_removed_binding_keys) {
	const uint8_t *data = p_bytes.ptr();
	const int64_t len = p_bytes.size();
	if (len < 20 || (len % 4) != 0) {
		return p_bytes;
	}
	const uint32_t nwords = (uint32_t)(len / 4);

	// Collect OpName for every id, so the engine's sampler names can be matched.
	// std::string here, not Godot's String: this file is also compiled into the
	// host tint_convert_cli against a minimal shim.
	std::unordered_map<std::string, uint32_t> by_name;
	{
		uint32_t pos = 5;
		while (pos < nwords) {
			uint32_t w0 = read_word(data, len, pos);
			uint32_t wc = (w0 >> 16);
			uint16_t op = (uint16_t)(w0 & 0xFFFF);
			if (wc == 0 || pos + wc > nwords) {
				break;
			}
			if (op == OP_NAME && wc >= 3) {
				uint32_t target = read_word(data, len, pos + 1);
				const char *str = (const char *)(data + (pos + 2) * 4);
				size_t max_len = (size_t)(wc - 2) * 4;
				size_t str_len = strnlen(str, max_len);
				by_name.emplace(std::string(str, str_len), target);
			}
			pos += wc;
		}
	}

	if (by_name.empty()) {
		return p_bytes;
	}

	// WebGPU caps samplers per shader stage (16 on Metal), and Godot's Forward
	// Mobile fragment shader declares 18: two special ones plus the twelve static
	// filter/repeat combinations, four of which differ only by anisotropy. Point
	// those four at their trilinear equivalents; dead variable elimination then
	// removes them and the stage fits. The cost is anisotropic filtering, which
	// WebGPU can express but cannot spare a binding slot for here.
	static const char *aniso_pairs[][2] = {
		{ "SAMPLER_NEAREST_WITH_MIPMAPS_ANISOTROPIC_CLAMP", "SAMPLER_NEAREST_WITH_MIPMAPS_CLAMP" },
		{ "SAMPLER_LINEAR_WITH_MIPMAPS_ANISOTROPIC_CLAMP", "SAMPLER_LINEAR_WITH_MIPMAPS_CLAMP" },
		{ "SAMPLER_NEAREST_WITH_MIPMAPS_ANISOTROPIC_REPEAT", "SAMPLER_NEAREST_WITH_MIPMAPS_REPEAT" },
		{ "SAMPLER_LINEAR_WITH_MIPMAPS_ANISOTROPIC_REPEAT", "SAMPLER_LINEAR_WITH_MIPMAPS_REPEAT" },
	};

	HashMap<uint32_t, uint32_t> remap;
	for (const char *const *pair : aniso_pairs) {
		auto from = by_name.find(pair[0]);
		auto to = by_name.find(pair[1]);
		if (from != by_name.end() && to != by_name.end() && from->second != to->second) {
			remap.insert(from->second, to->second);
		}
	}

	if (remap.is_empty()) {
		return p_bytes;
	}

	// Report where the now-unused samplers lived, so the driver can drop them from
	// the stages' visibility instead of guessing from reflection.
	if (r_removed_binding_keys) {
		HashMap<uint32_t, uint32_t> var_set;
		HashMap<uint32_t, uint32_t> var_binding;
		uint32_t pos = 5;
		while (pos < nwords) {
			uint32_t w0 = read_word(data, len, pos);
			uint32_t wc = (w0 >> 16);
			uint16_t op = (uint16_t)(w0 & 0xFFFF);
			if (wc == 0 || pos + wc > nwords) {
				break;
			}
			if (op == OP_DECORATE && wc >= 4) {
				uint32_t target = read_word(data, len, pos + 1);
				uint32_t deco = read_word(data, len, pos + 2);
				uint32_t value = read_word(data, len, pos + 3);
				if (deco == 34 /* DescriptorSet */) {
					var_set.insert(target, value);
				} else if (deco == 33 /* Binding */) {
					var_binding.insert(target, value);
				}
			}
			pos += wc;
		}
		for (const KeyValue<uint32_t, uint32_t> &kv : remap) {
			const uint32_t *set_index = var_set.getptr(kv.key);
			const uint32_t *binding = var_binding.getptr(kv.key);
			if (set_index && binding) {
				r_removed_binding_keys->push_back((*set_index << 16) | *binding);
			}
		}
	}

	return _remap_ids_by_grammar(p_bytes, remap, true /* uses inside functions only */);
}

// ---- eliminate_dead_code ----

Vector<uint8_t> eliminate_dead_code(const Vector<uint8_t> &p_bytes) {
	const int64_t len = p_bytes.size();
	if (len < 20 || (len % 4) != 0) {
		return p_bytes;
	}

	std::vector<uint32_t> input((size_t)(len / 4));
	memcpy(input.data(), p_bytes.ptr(), (size_t)len);

	spvtools::Optimizer optimizer(SPV_ENV_VULKAN_1_3);
	bool failed = false;
	optimizer.SetMessageConsumer([&failed](spv_message_level_t level, const char *, const spv_position_t &, const char *message) {
		if (level == SPV_MSG_FATAL || level == SPV_MSG_INTERNAL_ERROR || level == SPV_MSG_ERROR) {
			failed = true;
			fprintf(stderr, "SPIR-V dead code elimination: %s\n", message ? message : "unknown error");
		}
	});
	// Fold the constants first so branches on frozen specialization constants
	// become statically false, then delete what that makes unreachable.
	const char *chain = getenv("AW3_DCE_CHAIN");
	if (chain == nullptr) {
		// Deliberately no aggressive DCE: it decides the fragment output store is
		// dead once preprocessing has rewritten the entry point's interface, and
		// strips the shader to nothing. Constant folding, dead branches, dead
		// functions and unreferenced globals are all safe, and the last of those
		// is what actually drops the surplus sampler bindings.
		chain = "fold,dbe,edf,dve";
	}
	auto uses = [chain](const char *p_key) -> bool { return strstr(chain, p_key) != nullptr; };
	if (uses("fold")) {
		optimizer.RegisterPass(spvtools::CreateFoldSpecConstantOpAndCompositePass());
	}
	if (uses("ccp")) {
		optimizer.RegisterPass(spvtools::CreateCCPPass());
	}
	if (uses("dbe")) {
		optimizer.RegisterPass(spvtools::CreateDeadBranchElimPass());
	}
	if (uses("adce")) {
		optimizer.RegisterPass(spvtools::CreateAggressiveDCEPass(true /* preserve_interface */));
	}
	if (uses("edf")) {
		optimizer.RegisterPass(spvtools::CreateEliminateDeadFunctionsPass());
	}
	if (uses("dve")) {
		optimizer.RegisterPass(spvtools::CreateDeadVariableEliminationPass());
	}

	std::vector<uint32_t> output;
	if (!optimizer.Run(input.data(), input.size(), &output) || failed || output.empty()) {
		return p_bytes;
	}

	Vector<uint8_t> out;
	out.resize((int)(output.size() * 4));
	memcpy(out.ptrw(), output.data(), output.size() * 4);
	return out;
}

// ---- reachable_binding_keys ----

void reachable_binding_keys(const Vector<uint8_t> &p_bytes, HashSet<uint32_t> *r_keys) {
	if (!r_keys) {
		return;
	}
	const uint8_t *data = p_bytes.ptr();
	const int64_t len = p_bytes.size();
	if (len < 20 || (len % 4) != 0) {
		return;
	}
	const uint32_t nwords = (uint32_t)(len / 4);

	// Descriptor set / binding for every decorated variable.
	HashMap<uint32_t, uint32_t> var_set;
	HashMap<uint32_t, uint32_t> var_binding;
	{
		uint32_t pos = 5;
		while (pos < nwords) {
			uint32_t w0 = read_word(data, len, pos);
			uint32_t wc = (w0 >> 16);
			uint16_t op = (uint16_t)(w0 & 0xFFFF);
			if (wc == 0 || pos + wc > nwords) {
				break;
			}
			if (op == OP_DECORATE && wc >= 4) {
				uint32_t target = read_word(data, len, pos + 1);
				uint32_t deco = read_word(data, len, pos + 2);
				uint32_t value = read_word(data, len, pos + 3);
				if (deco == 34 /* DescriptorSet */) {
					var_set.insert(target, value);
				} else if (deco == 33 /* Binding */) {
					var_binding.insert(target, value);
				}
			}
			pos += wc;
		}
	}

	if (var_binding.is_empty()) {
		return;
	}

	// Which of them any function body mentions. Deliberately conservative - it
	// does not follow the call graph, and it runs before specialization constants
	// are frozen, so a binding used by any specialization of this module counts.
	// That is the point: the bind group layout is built once and has to stay valid
	// for every specialized module built from this shader later.
	uint32_t pos = 5;
	bool in_function = false;
	while (pos < nwords) {
		uint32_t w0 = read_word(data, len, pos);
		uint32_t wc = (w0 >> 16);
		uint16_t op = (uint16_t)(w0 & 0xFFFF);
		if (wc == 0 || pos + wc > nwords) {
			break;
		}
		if (op == 54 /* OpFunction */) {
			in_function = true;
		} else if (op == 56 /* OpFunctionEnd */) {
			in_function = false;
		} else if (in_function) {
			for (uint32_t i = 1; i < wc; i++) {
				uint32_t word = read_word(data, len, pos + i);
				const uint32_t *binding = var_binding.getptr(word);
				if (binding == nullptr) {
					continue;
				}
				const uint32_t *set_index = var_set.getptr(word);
				r_keys->insert(((set_index ? *set_index : 0u) << 16) | *binding);
			}
		}
		pos += wc;
	}
}

// ---- binding_image_info ----

void binding_image_info(const Vector<uint8_t> &p_bytes, HashMap<uint32_t, ImageBindingInfo> *r_info) {
	if (!r_info) {
		return;
	}
	const uint8_t *data = p_bytes.ptr();
	const int64_t len = p_bytes.size();
	if (len < 20 || (len % 4) != 0) {
		return;
	}
	const uint32_t nwords = (uint32_t)(len / 4);

	HashMap<uint32_t, ImageBindingInfo> image_types; // OpTypeImage id -> info
	HashMap<uint32_t, uint32_t> sampled_image_to_image;
	HashMap<uint32_t, uint32_t> array_to_element;
	HashMap<uint32_t, uint32_t> pointer_to_pointee;
	HashMap<uint32_t, uint32_t> var_to_pointer;
	HashMap<uint32_t, uint32_t> var_set;
	HashMap<uint32_t, uint32_t> var_binding;

	uint32_t pos = 5;
	while (pos < nwords) {
		uint32_t w0 = read_word(data, len, pos);
		uint32_t wc = (w0 >> 16);
		uint16_t op = (uint16_t)(w0 & 0xFFFF);
		if (wc == 0 || pos + wc > nwords) {
			break;
		}
		switch (op) {
			case OP_TYPE_IMAGE: {
				if (wc >= 9) {
					ImageBindingInfo info;
					info.dim = read_word(data, len, pos + 3);
					info.depth = read_word(data, len, pos + 4);
					info.arrayed = read_word(data, len, pos + 5);
					info.multisampled = read_word(data, len, pos + 6);
					image_types.insert(read_word(data, len, pos + 1), info);
				}
			} break;
			case OP_TYPE_SAMPLED_IMAGE: {
				if (wc >= 3) {
					sampled_image_to_image.insert(read_word(data, len, pos + 1), read_word(data, len, pos + 2));
				}
			} break;
			case OP_TYPE_ARRAY:
			case OP_TYPE_RUNTIME_ARRAY: {
				if (wc >= 3) {
					array_to_element.insert(read_word(data, len, pos + 1), read_word(data, len, pos + 2));
				}
			} break;
			case OP_TYPE_POINTER: {
				if (wc >= 4) {
					pointer_to_pointee.insert(read_word(data, len, pos + 1), read_word(data, len, pos + 3));
				}
			} break;
			case OP_VARIABLE: {
				if (wc >= 4) {
					var_to_pointer.insert(read_word(data, len, pos + 2), read_word(data, len, pos + 1));
				}
			} break;
			case OP_DECORATE: {
				if (wc >= 4) {
					uint32_t target = read_word(data, len, pos + 1);
					uint32_t deco = read_word(data, len, pos + 2);
					uint32_t value = read_word(data, len, pos + 3);
					if (deco == 34 /* DescriptorSet */) {
						var_set.insert(target, value);
					} else if (deco == 33 /* Binding */) {
						var_binding.insert(target, value);
					}
				}
			} break;
			default:
				break;
		}
		pos += wc;
	}

	for (const KeyValue<uint32_t, uint32_t> &kv : var_binding) {
		const uint32_t *ptr = var_to_pointer.getptr(kv.key);
		if (!ptr) {
			continue;
		}
		const uint32_t *pointee = pointer_to_pointee.getptr(*ptr);
		if (!pointee) {
			continue;
		}
		// An array of handles (lightmap_textures[16], voxel_gi_textures[8]) points at
		// an OpTypeArray, so unwrap to the element type before looking for the image.
		// Miss this and the binding falls back to a plain 2D view, which fails to
		// create against a 3D or layered texture.
		uint32_t image_id = *pointee;
		for (int depth = 0; depth < 4; depth++) {
			const uint32_t *element = array_to_element.getptr(image_id);
			if (!element) {
				break;
			}
			image_id = *element;
		}
		if (const uint32_t *unwrapped = sampled_image_to_image.getptr(image_id)) {
			image_id = *unwrapped;
		}
		const ImageBindingInfo *info = image_types.getptr(image_id);
		if (!info) {
			continue;
		}
		const uint32_t *set_index = var_set.getptr(kv.key);
		r_info->insert(((set_index ? *set_index : 0u) << 16) | kv.value, *info);
	}
}

// ---- spec_constants_used_in_types ----

// True when any specialization constant reaches a type declaration - in practice
// an array length. WGSL cannot express those as overrides outside workgroup
// memory, so such a module has to be frozen to constants and re-translated per
// specialization. Everything else keeps its constants as WGSL overrides, which
// lets one module serve every pipeline specialization.
static bool _spec_constants_used_in_types(const Vector<uint8_t> &p_bytes) {
	const uint8_t *data = p_bytes.ptr();
	const int64_t len = p_bytes.size();
	if (len < 20 || (len % 4) != 0) {
		return false;
	}
	const uint32_t nwords = (uint32_t)(len / 4);

	HashSet<uint32_t> spec_ids;
	HashMap<uint32_t, std::vector<uint32_t>> derived_from; // result -> operands
	std::vector<uint32_t> type_length_ids;

	uint32_t pos = 5;
	while (pos < nwords) {
		uint32_t w0 = read_word(data, len, pos);
		uint32_t wc = (w0 >> 16);
		uint16_t op = (uint16_t)(w0 & 0xFFFF);
		if (wc == 0 || pos + wc > nwords) {
			break;
		}
		switch (op) {
			case OP_SPEC_CONSTANT_TRUE:
			case OP_SPEC_CONSTANT_FALSE:
			case OP_SPEC_CONSTANT: {
				if (wc >= 3) {
					spec_ids.insert(read_word(data, len, pos + 2));
				}
			} break;
			case OP_SPEC_CONSTANT_COMPOSITE:
			case OP_SPEC_CONSTANT_OP: {
				if (wc >= 3) {
					uint32_t result = read_word(data, len, pos + 2);
					spec_ids.insert(result);
					std::vector<uint32_t> operands;
					for (uint32_t i = 3; i < wc; i++) {
						operands.push_back(read_word(data, len, pos + i));
					}
					derived_from.insert(result, operands);
				}
			} break;
			case OP_TYPE_ARRAY: {
				if (wc >= 4) {
					type_length_ids.push_back(read_word(data, len, pos + 3));
				}
			} break;
			default:
				break;
		}
		pos += wc;
	}

	if (spec_ids.is_empty() || type_length_ids.empty()) {
		return false;
	}

	// Walk each array length back through any specialization arithmetic.
	HashSet<uint32_t> visited;
	std::vector<uint32_t> worklist = type_length_ids;
	while (!worklist.empty()) {
		uint32_t id = worklist.back();
		worklist.pop_back();
		if (visited.has(id)) {
			continue;
		}
		visited.insert(id);
		if (spec_ids.has(id)) {
			return true;
		}
		if (const std::vector<uint32_t> *operands = derived_from.getptr(id)) {
			for (uint32_t operand : *operands) {
				worklist.push_back(operand);
			}
		}
	}
	return false;
}

// ---- run_all ----

Vector<uint8_t> run_all(const Vector<uint8_t> &p_bytes, Vector<DepthImageFixResult::DepthImageInfo> *r_depth_images, Vector<uint32_t> *r_unused_binding_keys) {
	Vector<uint8_t> spv = p_bytes;

	// Debug aid: AW3_PASSES_UPTO=<n> stops after the n-th pass, so a module that
	// comes out wrong can be bisected against the pass that did it.
	int pass_limit = -1;
	if (const char *limit_env = getenv("AW3_PASSES_UPTO")) {
		pass_limit = atoi(limit_env);
	}
	int pass_index = 0;
	auto want = [&](void) -> bool {
		pass_index++;
		return pass_limit < 0 || pass_index <= pass_limit;
	};

	// The passes below emit constructs that need SPIR-V 1.3 (the StorageBuffer
	// storage class), which the input may predate. Declare that up front: the
	// SPIRV-Tools passes validate as they go, and against a 1.0 header they reject
	// the module with "StorageBuffer requires SPV_KHR_storage_buffer_storage_class"
	// rather than the shader's real problem.
	if (spv.size() >= 20) {
		uint32_t version;
		memcpy(&version, spv.ptr() + 4, 4);
		if (version < 0x00010300) {
			version = 0x00010300;
			memcpy(spv.ptrw() + 4, &version, 4);
		}
	}

	// Opaque inlining goes first: every pass below rewrites variables, and none
	// of them follow a texture or sampler across a function boundary.
	if (want()) { spv = inline_opaque_functions(spv); }
	// Freezing specialization constants costs a full re-translation per pipeline
	// specialization (~200 ms for the scene shader) because it strips the SpecId
	// decorations Tint turns into WGSL overrides. Only do it when the module
	// actually needs it. AW3_SKIP_FREEZE=1 forces it off for experiments.
	if (want() && getenv("AW3_SKIP_FREEZE") == nullptr && _spec_constants_used_in_types(spv)) {
		spv = freeze_spec_constant_ops(spv);
	}
	if (want()) { spv = rewrite_copy_logical(spv); }
	if (want()) { spv = rewrite_terminate_invocation(spv); }
	if (want()) { spv = convert_push_constants_to_uniforms(spv); }
	if (want()) { spv = split_combined_samplers(spv); }

	if (want()) {
		DepthImageFixResult depth_result = fix_depth2_images(spv);
		spv = depth_result.bytes;
		if (r_depth_images) {
			*r_depth_images = depth_result.depth_images;
		}
	}

	if (want()) { spv = negate_position_y(spv); }
	if (want()) { spv = strip_restrict_decoration(spv); }
	if (want()) { spv = strip_memory_barrier(spv); }
	if (want()) { spv = fix_nonfinite_literals(spv); }
	if (want()) { spv = flatten_binding_arrays(spv); }
	if (want()) { spv = infer_readonly_storage(spv); }
	if (want()) { spv = strip_nonreadable_storage_buffers(spv); }

	// Last: freezing specialization constants above turns ubershader branches into
	// statically dead code, but the samplers and textures they mention stay
	// referenced, and WebGPU counts them against a hard per-stage limit (16
	// samplers on Metal, which Godot's Forward Mobile vertex stage otherwise
	// exceeds). Deleting the dead code drops those references.
	// Before the dead code sweep, so the samplers this frees up get removed by it.
	if (want()) { spv = alias_anisotropic_samplers(spv, r_unused_binding_keys); }
	if (want()) { spv = eliminate_dead_code(spv); }

	return spv;
}

// ---- find_untranslatable_construct ----

std::string find_untranslatable_construct(const Vector<uint8_t> &p_bytes) {
	const uint8_t *data = p_bytes.ptr();
	int64_t len = p_bytes.size();
	if (len < 20 || (len % 4) != 0) {
		return "module is too small to be SPIR-V";
	}
	uint32_t nwords = (uint32_t)(len / 4);

	// Capability ids from the SPIR-V spec. Everything here describes something
	// WGSL has no spelling for, so Tint gives up on it one way or another.
	struct UnsupportedCapability {
		uint32_t id;
		const char *reason;
	};
	static const UnsupportedCapability unsupported_capabilities[] = {
		{ 10, "64-bit floats (WGSL has no f64)" },
		{ 11, "64-bit integers (WGSL has no i64/u64)" },
		{ 12, "64-bit atomics" },
		{ 22, "16-bit integers (WGSL has no i16/u16)" },
		{ 39, "8-bit integers (WGSL has no i8/u8)" },
		{ 56, "storage image writes without a format qualifier (WGSL needs a concrete texel format)" },
		{ 61, "subgroup operations" },
		{ 62, "subgroup vote operations" },
		{ 63, "subgroup arithmetic operations" },
		{ 64, "subgroup ballot operations" },
		{ 65, "subgroup shuffle operations" },
		{ 66, "subgroup relative shuffle operations" },
		{ 67, "clustered subgroup operations" },
		{ 68, "subgroup quad operations" },
		{ 4423, "subgroup ballot operations (KHR)" },
		{ 4431, "subgroup vote operations (KHR)" },
	};

	uint32_t pos = 5;
	while (pos < nwords) {
		uint32_t word0 = read_word(data, len, pos);
		uint32_t wc = (word0 >> 16) & 0xFFFF;
		uint16_t op = word0 & 0xFFFF;
		if (wc == 0 || pos + wc > nwords) {
			break;
		}

		if (op == OP_CAPABILITY && wc >= 2) {
			uint32_t capability = read_word(data, len, pos + 1);
			for (const UnsupportedCapability &unsupported : unsupported_capabilities) {
				if (unsupported.id == capability) {
					return unsupported.reason;
				}
			}
		} else if (op >= OP_IS_NAN && op <= OP_SIGN_BIT_SET) {
			// OpIsNan .. OpSignBitSet. WGSL dropped all of these, and the reader
			// has no lowering for them; `x != x` and a magnitude test against
			// FLT_MAX are the usual replacements.
			return "an IEEE classification instruction (isnan/isinf/isfinite)";
		} else if (op == OP_DECORATE && wc >= 4 &&
				read_word(data, len, pos + 2) == DECO_BUILTIN &&
				read_word(data, len, pos + 3) == BUILTIN_HELPER_INVOCATION) {
			return "the HelperInvocation builtin (WGSL cannot ask whether an invocation is a helper)";
		}

		pos += wc;
	}

	return std::string();
}

// ---- inline_opaque_functions ----

Vector<uint8_t> inline_opaque_functions(const Vector<uint8_t> &p_bytes) {
	const int64_t len = p_bytes.size();
	if (len < 20 || (len % 4) != 0) {
		return p_bytes;
	}

	std::vector<uint32_t> input((size_t)(len / 4));
	memcpy(input.data(), p_bytes.ptr(), (size_t)len);

	// SPIR-V 1.6 is what glslang emits for Godot's shaders; the inliner itself
	// is version-agnostic, this only picks the grammar tables.
	spvtools::Optimizer optimizer(SPV_ENV_VULKAN_1_3);
	bool failed = false;
	// This file is also compiled into the host tint_convert_cli against a minimal
	// shim, so no Godot error macros here.
	optimizer.SetMessageConsumer([&failed](spv_message_level_t level, const char *, const spv_position_t &, const char *message) {
		if (level == SPV_MSG_FATAL || level == SPV_MSG_INTERNAL_ERROR || level == SPV_MSG_ERROR) {
			failed = true;
			fprintf(stderr, "SPIR-V opaque inlining: %s\n", message ? message : "unknown error");
		}
	});
	optimizer.RegisterPass(spvtools::CreateInlineOpaquePass());

	std::vector<uint32_t> output;
	if (!optimizer.Run(input.data(), input.size(), &output) || failed || output.empty()) {
		// Leave the module untouched; the caller will report whatever Tint makes
		// of it, which is more useful than failing here.
		return p_bytes;
	}

	Vector<uint8_t> out;
	out.resize((int)(output.size() * 4));
	memcpy(out.ptrw(), output.data(), output.size() * 4);
	return out;
}

// ---- strip_nonreadable_storage_buffers ----

Vector<uint8_t> strip_nonreadable_storage_buffers(const Vector<uint8_t> &p_bytes) {
	const uint8_t *data = p_bytes.ptr();
	const int64_t len = p_bytes.size();
	if (len < 20 || (len % 4) != 0) {
		return p_bytes;
	}
	const uint32_t nwords = (uint32_t)(len / 4);

	static constexpr uint32_t DECO_NON_READABLE = 25;

	// Collect storage-buffer variables and the struct types they point at.
	// Storage *textures* may legitimately be write-only in WGSL, so only
	// buffers are considered here.
	HashSet<uint32_t> storage_vars;
	HashSet<uint32_t> storage_structs;
	HashMap<uint32_t, uint32_t> pointer_to_pointee;
	{
		uint32_t pos = 5;
		while (pos < nwords) {
			uint32_t word0 = read_word(data, len, pos);
			uint32_t wc = (word0 >> 16) & 0xFFFF;
			uint16_t op = word0 & 0xFFFF;
			if (wc == 0 || pos + wc > nwords) {
				break;
			}
			if (op == OP_TYPE_POINTER && wc >= 4) {
				uint32_t result_id = read_word(data, len, pos + 1);
				uint32_t storage_class = read_word(data, len, pos + 2);
				uint32_t pointee = read_word(data, len, pos + 3);
				if (storage_class == SC_STORAGE_BUFFER) {
					pointer_to_pointee.insert(result_id, pointee);
					storage_structs.insert(pointee);
				}
			} else if (op == OP_VARIABLE && wc >= 4) {
				uint32_t result_id = read_word(data, len, pos + 2);
				uint32_t storage_class = read_word(data, len, pos + 3);
				if (storage_class == SC_STORAGE_BUFFER) {
					storage_vars.insert(result_id);
				}
			}
			pos += wc;
		}
	}

	if (storage_vars.is_empty() && storage_structs.is_empty()) {
		return p_bytes;
	}

	// Quick scan: is there anything to strip?
	bool found = false;
	{
		uint32_t pos = 5;
		while (pos < nwords) {
			uint32_t word0 = read_word(data, len, pos);
			uint32_t wc = (word0 >> 16) & 0xFFFF;
			uint16_t op = word0 & 0xFFFF;
			if (wc == 0 || pos + wc > nwords) {
				break;
			}
			if (op == OP_DECORATE && wc >= 3 && read_word(data, len, pos + 2) == DECO_NON_READABLE &&
					storage_vars.has(read_word(data, len, pos + 1))) {
				found = true;
				break;
			}
			if (op == OP_MEMBER_DECORATE && wc >= 4 && read_word(data, len, pos + 3) == DECO_NON_READABLE &&
					storage_structs.has(read_word(data, len, pos + 1))) {
				found = true;
				break;
			}
			pos += wc;
		}
	}

	if (!found) {
		return p_bytes;
	}

	Vector<uint8_t> out;
	append_bytes(out, data, 0, 20);

	uint32_t pos = 5;
	while (pos < nwords) {
		uint32_t word0 = read_word(data, len, pos);
		uint32_t wc = (word0 >> 16) & 0xFFFF;
		uint16_t op = word0 & 0xFFFF;
		if (wc == 0 || pos + wc > nwords) {
			break;
		}

		bool skip = false;
		if (op == OP_DECORATE && wc >= 3 && read_word(data, len, pos + 2) == DECO_NON_READABLE &&
				storage_vars.has(read_word(data, len, pos + 1))) {
			skip = true;
		}
		if (op == OP_MEMBER_DECORATE && wc >= 4 && read_word(data, len, pos + 3) == DECO_NON_READABLE &&
				storage_structs.has(read_word(data, len, pos + 1))) {
			skip = true;
		}

		if (!skip) {
			append_bytes(out, data, pos * 4, wc * 4);
		}
		pos += wc;
	}

	return out;
}

// ---- strip_memory_barrier ----

Vector<uint8_t> strip_memory_barrier(const Vector<uint8_t> &p_bytes) {
	const int64_t len = p_bytes.size();
	const uint32_t total_words = (uint32_t)(len / 4);

	if (total_words < 5) {
		return p_bytes;
	}

	const uint8_t *data = p_bytes.ptr();
	static constexpr uint16_t OP_MEMORY_BARRIER = 225;

	// Quick scan.
	bool found = false;
	uint32_t pos = 5;
	while (pos < total_words) {
		uint32_t w0 = read_word(data, len, pos);
		uint32_t wc = (w0 >> 16);
		uint16_t op = (uint16_t)(w0 & 0xFFFF);
		if (wc == 0 || pos + wc > total_words) {
			break;
		}
		if (op == OP_MEMORY_BARRIER) {
			found = true;
			break;
		}
		pos += wc;
	}

	if (!found) {
		return p_bytes;
	}

	// Strip OpMemoryBarrier by skipping it entirely.
	Vector<uint8_t> out;
	append_bytes(out, data, 0, 20);

	pos = 5;
	while (pos < total_words) {
		uint32_t w0 = read_word(data, len, pos);
		uint32_t wc = (w0 >> 16);
		uint16_t op = (uint16_t)(w0 & 0xFFFF);
		if (wc == 0 || pos + wc > total_words) {
			break;
		}

		if (op == OP_MEMORY_BARRIER) {
			// Skip — Tint does not support OpMemoryBarrier.
			pos += wc;
			continue;
		} else {
			append_bytes(out, data, pos * 4, wc * 4);
		}
		pos += wc;
	}

	return out;
}

// ---- fix_nonfinite_literals ----

Vector<uint8_t> fix_nonfinite_literals(const Vector<uint8_t> &p_bytes) {
	const int64_t len = p_bytes.size();
	const uint32_t total_words = (uint32_t)(len / 4);

	if (total_words < 5) {
		return p_bytes;
	}

	const uint8_t *data = p_bytes.ptr();

	// Pass 1: Find float type IDs and their widths.
	HashMap<uint32_t, uint32_t> float_types; // type_id -> width_in_bits
	uint32_t pos = 5;
	while (pos < total_words) {
		uint32_t w0 = read_word(data, len, pos);
		uint32_t wc = (w0 >> 16);
		uint16_t op = (uint16_t)(w0 & 0xFFFF);
		if (wc == 0 || pos + wc > total_words) {
			break;
		}
		if (op == OP_TYPE_FLOAT && wc >= 3) {
			uint32_t id = read_word(data, len, pos + 1);
			uint32_t width = read_word(data, len, pos + 2);
			float_types.insert(id, width);
		}
		pos += wc;
	}

	if (float_types.is_empty()) {
		return p_bytes;
	}

	// Quick check: any non-finite constant?
	bool has_nonfinite = false;
	pos = 5;
	while (pos < total_words) {
		uint32_t w0 = read_word(data, len, pos);
		uint32_t wc = (w0 >> 16);
		uint16_t op = (uint16_t)(w0 & 0xFFFF);
		if (wc == 0 || pos + wc > total_words) {
			break;
		}

		if ((op == OP_CONSTANT || op == OP_SPEC_CONSTANT) && wc >= 4) {
			uint32_t type_id = read_word(data, len, pos + 1);
			const uint32_t *width = float_types.getptr(type_id);
			if (width) {
				if (*width == 32) {
					uint32_t bits = read_word(data, len, pos + 3);
					float f;
					memcpy(&f, &bits, 4);
					if (!std::isfinite(f)) {
						has_nonfinite = true;
						break;
					}
				} else if (*width == 64 && wc >= 5) {
					uint32_t lo = read_word(data, len, pos + 3);
					uint32_t hi = read_word(data, len, pos + 4);
					uint64_t bits64 = ((uint64_t)hi << 32) | lo;
					double d;
					memcpy(&d, &bits64, 8);
					if (!std::isfinite(d)) {
						has_nonfinite = true;
						break;
					}
				}
			}
		}
		pos += wc;
	}

	if (!has_nonfinite) {
		return p_bytes;
	}

	// In-place rewrite: replace non-finite float constants with FLT_MAX/MIN.
	Vector<uint8_t> out = p_bytes;
	uint8_t *out_data = out.ptrw();

	pos = 5;
	while (pos < total_words) {
		uint32_t w0 = read_word(out_data, len, pos);
		uint32_t wc = (w0 >> 16);
		uint16_t op = (uint16_t)(w0 & 0xFFFF);
		if (wc == 0 || pos + wc > total_words) {
			break;
		}

		if ((op == OP_CONSTANT || op == OP_SPEC_CONSTANT) && wc >= 4) {
			uint32_t type_id = read_word(out_data, len, pos + 1);
			const uint32_t *width = float_types.getptr(type_id);
			if (width) {
				if (*width == 32) {
					uint32_t off = (pos + 3) * 4;
					uint32_t bits;
					memcpy(&bits, out_data + off, 4);
					float f;
					memcpy(&f, &bits, 4);
					if (!std::isfinite(f)) {
						float replacement = std::signbit(f) ? -FLT_MAX : FLT_MAX;
						memcpy(out_data + off, &replacement, 4);
					}
				} else if (*width == 64 && wc >= 5) {
					uint32_t off = (pos + 3) * 4;
					double d;
					memcpy(&d, out_data + off, 8);
					if (!std::isfinite(d)) {
						double replacement = std::signbit(d) ? -DBL_MAX : DBL_MAX;
						memcpy(out_data + off, &replacement, 8);
					}
				}
			}
		}
		pos += wc;
	}

	return out;
}

// ---- flatten_binding_arrays ----
//
// Tint rejects OpTypeArray/OpTypeRuntimeArray of handle types (image, sampler,
// sampled_image) regardless of array size. We must fully eliminate these array
// types from SPIR-V and replace them with scalar element types.
//
// Strategy: build a map of array_type_id → element_type_id, then do a
// comprehensive ID replacement across all instructions. Every operand word
// that matches an array type ID gets replaced with the element type ID.
// Then the OpTypeArray instruction itself is stripped (the ID is no longer
// referenced anywhere). OpAccessChain into handle array variables becomes
// a direct variable reference.
//
// Literal values in OpConstant/OpSpecConstant/OpSwitch are excluded from
// replacement to avoid false positives.

// Remap SPIR-V result/reference IDs using SPIRV-Tools' grammar, so only true ID
// operands are touched.
//
// Doing this by hand - walking every word of every instruction and substituting
// anything that matches an ID being remapped - silently corrupts literals that
// happen to share a value with a remapped ID. That is not hypothetical: it
// rewrote "OpDecorate %x ArrayStride 240" to stride 22 and an OpExtInst
// instruction number to 4558, which surfaced far away as Tint complaining that a
// struct was smaller than its last member, and as invalid SPIR-V.
static Vector<uint8_t> _remap_ids_by_grammar(const Vector<uint8_t> &p_bytes, const HashMap<uint32_t, uint32_t> &p_remap, bool p_uses_in_functions_only) {
	if (p_remap.is_empty() || p_bytes.size() < 20 || (p_bytes.size() % 4) != 0) {
		return p_bytes;
	}

	Vector<uint32_t> words;
	words.resize((int)(p_bytes.size() / 4));
	memcpy(words.ptrw(), p_bytes.ptr(), (size_t)p_bytes.size());

	struct RemapState {
		uint32_t *base;
		size_t word_count;
		const HashMap<uint32_t, uint32_t> *remap;
		// Aliasing one variable onto another must rewrite only uses inside function
		// bodies: rewriting the definition would produce a duplicate id, and
		// rewriting OpName/OpDecorate targets would move the alias's binding
		// decorations onto the variable it aliases.
		bool uses_in_functions_only;
		bool in_function;
	} state{ words.ptrw(), (size_t)words.size(), &p_remap, p_uses_in_functions_only, false };

	spv_context context = spvContextCreate(SPV_ENV_VULKAN_1_3);
	auto parse_instruction = [](void *p_user, const spv_parsed_instruction_t *p_inst) -> spv_result_t {
		RemapState *st = (RemapState *)p_user;
		if (p_inst->opcode == 54 /* OpFunction */) {
			st->in_function = true;
		} else if (p_inst->opcode == 56 /* OpFunctionEnd */) {
			st->in_function = false;
		}
		if (st->uses_in_functions_only && !st->in_function) {
			return SPV_SUCCESS;
		}
		for (uint16_t i = 0; i < p_inst->num_operands; i++) {
			const spv_parsed_operand_t &operand = p_inst->operands[i];
			if (st->uses_in_functions_only && operand.type == SPV_OPERAND_TYPE_RESULT_ID) {
				continue;
			}
			switch (operand.type) {
				case SPV_OPERAND_TYPE_ID:
				case SPV_OPERAND_TYPE_TYPE_ID:
				case SPV_OPERAND_TYPE_RESULT_ID:
				case SPV_OPERAND_TYPE_MEMORY_SEMANTICS_ID:
				case SPV_OPERAND_TYPE_SCOPE_ID:
				case SPV_OPERAND_TYPE_OPTIONAL_ID: {
					// operand.offset is relative to the instruction; p_inst->words
					// points into the buffer being rewritten.
					size_t index = (size_t)(p_inst->words - st->base) + operand.offset;
					if (index >= st->word_count) {
						break;
					}
					const uint32_t *replacement = st->remap->getptr(st->base[index]);
					if (replacement) {
						st->base[index] = *replacement;
					}
				} break;
				default:
					break;
			}
		}
		return SPV_SUCCESS;
	};

	spv_diagnostic diagnostic = nullptr;
	spv_result_t result = spvBinaryParse(context, &state, words.ptr(), (size_t)words.size(),
			nullptr, parse_instruction, &diagnostic);
	if (diagnostic) {
		spvDiagnosticDestroy(diagnostic);
	}
	spvContextDestroy(context);

	if (result != SPV_SUCCESS) {
		// Leave the module alone rather than half-rewrite it.
		return p_bytes;
	}

	Vector<uint8_t> out;
	out.resize((int)(words.size() * 4));
	memcpy(out.ptrw(), words.ptr(), (size_t)words.size() * 4);
	return out;
}

Vector<uint8_t> flatten_binding_arrays(const Vector<uint8_t> &p_bytes) {
	const uint8_t *data = p_bytes.ptr();
	const int64_t len = p_bytes.size();
	const uint32_t total_words = (uint32_t)(len / 4);

	if (total_words < 5) {
		return p_bytes;
	}

	// Pass 1: Collect handle types and find arrays of handles.
	HashSet<uint32_t> handle_types;
	HashMap<uint32_t, uint32_t> array_to_elem; // array_type_id → element_type_id

	uint32_t pos = 5;
	while (pos < total_words) {
		uint32_t w0 = read_word(data, len, pos);
		uint32_t wc = (w0 >> 16);
		uint16_t op = (uint16_t)(w0 & 0xFFFF);
		if (wc == 0 || pos + wc > total_words) {
			break;
		}

		switch (op) {
			case OP_TYPE_IMAGE:
			case OP_TYPE_SAMPLER:
			case OP_TYPE_SAMPLED_IMAGE: {
				if (wc >= 2) {
					handle_types.insert(read_word(data, len, pos + 1));
				}
			} break;

			case OP_TYPE_ARRAY: {
				if (wc >= 4) {
					uint32_t result_id = read_word(data, len, pos + 1);
					uint32_t elem_type = read_word(data, len, pos + 2);
					if (handle_types.has(elem_type)) {
						array_to_elem.insert(result_id, elem_type);
					}
				}
			} break;

			case OP_TYPE_RUNTIME_ARRAY: {
				if (wc >= 3) {
					uint32_t result_id = read_word(data, len, pos + 1);
					uint32_t elem_type = read_word(data, len, pos + 2);
					if (handle_types.has(elem_type)) {
						array_to_elem.insert(result_id, elem_type);
					}
				}
			} break;

			default:
				break;
		}
		pos += wc;
	}

	if (array_to_elem.is_empty()) {
		return p_bytes;
	}

	// Pass 2: Identify pointer types for handle arrays and handle array variables,
	// needed to detect OpAccessChain targets.
	// Also collect ALL OpTypePointer for deduplication after array→elem replacement.
	HashSet<uint32_t> handle_array_ptr_types;
	HashSet<uint32_t> handle_array_vars;
	HashMap<uint32_t, uint32_t> ac_to_var; // access_chain_result → variable_id

	// For pointer type dedup: collect (storage_class, base_type) → first_ptr_id.
	// After array→elem replacement, two OpTypePointer can become identical
	// (same sc + same base type but different IDs). SPIR-V validates types by ID,
	// so we must remap duplicates to a single canonical ID.
	struct PtrTypeInfo {
		uint32_t ptr_id;
		uint32_t storage_class;
		uint32_t base_type;
	};
	Vector<PtrTypeInfo> all_ptr_types;

	pos = 5;
	while (pos < total_words) {
		uint32_t w0 = read_word(data, len, pos);
		uint32_t wc = (w0 >> 16);
		uint16_t op = (uint16_t)(w0 & 0xFFFF);
		if (wc == 0 || pos + wc > total_words) {
			break;
		}
		if (op == OP_TYPE_POINTER && wc >= 4) {
			uint32_t ptr_id = read_word(data, len, pos + 1);
			uint32_t sc = read_word(data, len, pos + 2);
			uint32_t base_type = read_word(data, len, pos + 3);
			all_ptr_types.push_back({ ptr_id, sc, base_type });
			if (array_to_elem.has(base_type)) {
				handle_array_ptr_types.insert(ptr_id);
			}
		}
		if (op == OP_VARIABLE && wc >= 4) {
			uint32_t type_id = read_word(data, len, pos + 1);
			if (handle_array_ptr_types.has(type_id)) {
				handle_array_vars.insert(read_word(data, len, pos + 2));
			}
		}
		pos += wc;
	}

	// Pointer type deduplication: after array_to_elem replacement, some
	// OpTypePointer instructions will point to the same (sc, base_type).
	// Find these duplicates and remap them to a single canonical ID.
	HashMap<uint32_t, uint32_t> ptr_remap; // duplicate_ptr_id → canonical_ptr_id
	HashSet<uint32_t> strip_ptr_ids; // duplicate OpTypePointer to remove
	{
		// Build effective (sc, base_type) for each pointer type after replacement.
		// Key: (sc << 32 | effective_base_type) → first ptr_id seen (canonical).
		HashMap<uint64_t, uint32_t> sc_base_to_canonical;
		for (int i = 0; i < all_ptr_types.size(); i++) {
			const PtrTypeInfo &info = all_ptr_types[i];
			// Compute effective base type after array→elem replacement.
			uint32_t effective_base = info.base_type;
			const uint32_t *elem = array_to_elem.getptr(effective_base);
			if (elem) {
				effective_base = *elem;
			}
			uint64_t key = ((uint64_t)info.storage_class << 32) | effective_base;
			uint32_t *canonical = sc_base_to_canonical.getptr(key);
			if (canonical) {
				// This pointer type is a duplicate. Remap to canonical.
				ptr_remap.insert(info.ptr_id, *canonical);
				strip_ptr_ids.insert(info.ptr_id);
			} else {
				sc_base_to_canonical.insert(key, info.ptr_id);
			}
		}
	}

	// Pass 3: Find OpAccessChain/OpInBoundsAccessChain on handle array vars.
	pos = 5;
	while (pos < total_words) {
		uint32_t w0 = read_word(data, len, pos);
		uint32_t wc = (w0 >> 16);
		uint16_t op = (uint16_t)(w0 & 0xFFFF);
		if (wc == 0 || pos + wc > total_words) {
			break;
		}
		if ((op == OP_ACCESS_CHAIN || op == OP_IN_BOUNDS_ACCESS_CHAIN) && wc >= 5) {
			uint32_t result_id = read_word(data, len, pos + 2);
			uint32_t base_id = read_word(data, len, pos + 3);
			if (handle_array_vars.has(base_id)) {
				ac_to_var.insert(result_id, base_id);
			}
		}
		pos += wc;
	}

	// Pass 4: Rewrite the SPIR-V.
	// - Strip OpTypeArray/OpTypeRuntimeArray for handle types.
	// - Strip duplicate OpTypePointer (from pointer dedup).
	// - Strip OpAccessChain for handle array vars.
	// - In all other instructions, replace array type IDs with element type IDs,
	//   access chain results with the underlying variable ID,
	//   and duplicate pointer type IDs with canonical IDs.
	Vector<uint8_t> out;
	append_bytes(out, data, 0, 20); // Copy header.

	pos = 5;
	while (pos < total_words) {
		uint32_t w0 = read_word(data, len, pos);
		uint32_t wc = (w0 >> 16);
		uint16_t op = (uint16_t)(w0 & 0xFFFF);
		if (wc == 0 || pos + wc > total_words) {
			break;
		}

		// Strip OpTypeArray/OpTypeRuntimeArray for handle types.
		if ((op == OP_TYPE_ARRAY || op == OP_TYPE_RUNTIME_ARRAY) && wc >= 3) {
			uint32_t type_id = read_word(data, len, pos + 1);
			if (array_to_elem.has(type_id)) {
				pos += wc;
				continue;
			}
		}

		// Strip duplicate OpTypePointer instructions (pointer dedup).
		if (op == OP_TYPE_POINTER && wc >= 4) {
			uint32_t ptr_id = read_word(data, len, pos + 1);
			if (strip_ptr_ids.has(ptr_id)) {
				pos += wc;
				continue;
			}
		}

		// Strip OpAccessChain/OpInBoundsAccessChain for handle array vars.
		if ((op == OP_ACCESS_CHAIN || op == OP_IN_BOUNDS_ACCESS_CHAIN) && wc >= 5) {
			uint32_t result_id = read_word(data, len, pos + 2);
			if (ac_to_var.has(result_id)) {
				pos += wc;
				continue;
			}
		}

		append_bytes(out, data, pos * 4, wc * 4);
		pos += wc;
	}

	// Substitute the IDs only where the grammar says an ID lives.
	HashMap<uint32_t, uint32_t> remap;
	for (const KeyValue<uint32_t, uint32_t> &kv : array_to_elem) {
		remap.insert(kv.key, kv.value);
	}
	for (const KeyValue<uint32_t, uint32_t> &kv : ac_to_var) {
		remap.insert(kv.key, kv.value);
	}
	for (const KeyValue<uint32_t, uint32_t> &kv : ptr_remap) {
		remap.insert(kv.key, kv.value);
	}
	return _remap_ids_by_grammar(out, remap);
}

// ---- infer_readonly_storage ----

Vector<uint8_t> infer_readonly_storage(const Vector<uint8_t> &p_bytes) {
	const uint8_t *data = p_bytes.ptr();
	int64_t len = p_bytes.size();
	if (len < 20 || (len % 4) != 0) {
		return p_bytes;
	}
	uint32_t nwords = (uint32_t)(len / 4);

	// Pass 1: Collect all OpVariable with StorageBuffer storage class (12).
	HashSet<uint32_t> storage_vars;
	{
		uint32_t pos = 5;
		while (pos < nwords) {
			uint32_t word0 = read_word(data, len, pos);
			uint32_t wc = (word0 >> 16) & 0xFFFF;
			uint16_t op = word0 & 0xFFFF;
			if (wc == 0 || pos + wc > nwords) {
				break;
			}
			if (op == OP_VARIABLE && wc >= 4) {
				uint32_t result_id = read_word(data, len, pos + 2);
				uint32_t storage_class = read_word(data, len, pos + 3);
				if (storage_class == SC_STORAGE_BUFFER) {
					storage_vars.insert(result_id);
				}
			}
			pos += wc;
		}
	}

	if (storage_vars.is_empty()) {
		return p_bytes;
	}

	// Pass 2: Track which storage vars are written to.
	// Uses pointer-to-root mapping for access chain chaining.
	// Multiple iterations handle nested access chains.
	HashMap<uint32_t, uint32_t> ptr_to_root;
	HashSet<uint32_t> written_vars;

	for (int iter = 0; iter < 3; iter++) {
		uint32_t pos = 5;
		while (pos < nwords) {
			uint32_t word0 = read_word(data, len, pos);
			uint32_t wc = (word0 >> 16) & 0xFFFF;
			uint16_t op = word0 & 0xFFFF;
			if (wc == 0 || pos + wc > nwords) {
				break;
			}

			switch (op) {
				// OpAccessChain / OpInBoundsAccessChain: result_type result_id base indices...
				case OP_ACCESS_CHAIN:
				case OP_IN_BOUNDS_ACCESS_CHAIN: {
					if (wc >= 4) {
						uint32_t result_id = read_word(data, len, pos + 2);
						uint32_t base_id = read_word(data, len, pos + 3);
						if (storage_vars.has(base_id)) {
							ptr_to_root.insert(result_id, base_id);
						} else {
							const uint32_t *root = ptr_to_root.getptr(base_id);
							if (root) {
								ptr_to_root.insert(result_id, *root);
							}
						}
					}
				} break;

				// OpPtrAccessChain / OpInBoundsPtrAccessChain: result_type result_id base element indices...
				case OP_PTR_ACCESS_CHAIN:
				case OP_IN_BOUNDS_PTR_ACCESS_CHAIN: {
					if (wc >= 5) {
						uint32_t result_id = read_word(data, len, pos + 2);
						uint32_t base_id = read_word(data, len, pos + 3);
						if (storage_vars.has(base_id)) {
							ptr_to_root.insert(result_id, base_id);
						} else {
							const uint32_t *root = ptr_to_root.getptr(base_id);
							if (root) {
								ptr_to_root.insert(result_id, *root);
							}
						}
					}
				} break;

				// OpStore: pointer value [memory_access]
				case OP_STORE: {
					if (wc >= 3) {
						uint32_t ptr_id = read_word(data, len, pos + 1);
						if (storage_vars.has(ptr_id)) {
							written_vars.insert(ptr_id);
						} else {
							const uint32_t *root = ptr_to_root.getptr(ptr_id);
							if (root) {
								written_vars.insert(*root);
							}
						}
					}
				} break;

				// OpAtomicStore / OpAtomicFlagClear: pointer scope semantics [value]
				case OP_ATOMIC_STORE:
				case OP_ATOMIC_FLAG_CLEAR: {
					if (wc >= 4) {
						uint32_t ptr_id = read_word(data, len, pos + 1);
						if (storage_vars.has(ptr_id)) {
							written_vars.insert(ptr_id);
						} else {
							const uint32_t *root = ptr_to_root.getptr(ptr_id);
							if (root) {
								written_vars.insert(*root);
							}
						}
					}
				} break;

				// OpCopyMemory / OpCopyMemorySized: target is at pos+1
				case OP_COPY_MEMORY:
				case OP_COPY_MEMORY_SIZED: {
					if (wc >= 3) {
						uint32_t ptr_id = read_word(data, len, pos + 1);
						if (storage_vars.has(ptr_id)) {
							written_vars.insert(ptr_id);
						} else {
							const uint32_t *root = ptr_to_root.getptr(ptr_id);
							if (root) {
								written_vars.insert(*root);
							}
						}
					}
				} break;

				// OpFunctionCall: result_type result_id function arg0 arg1 ...
				// Conservatively mark any storage var passed as argument as writable.
				case OP_FUNCTION_CALL: {
					if (wc >= 4) {
						for (uint32_t arg_pos = pos + 4; arg_pos < pos + wc; arg_pos++) {
							uint32_t arg_id = read_word(data, len, arg_pos);
							if (storage_vars.has(arg_id)) {
								written_vars.insert(arg_id);
							} else {
								const uint32_t *root = ptr_to_root.getptr(arg_id);
								if (root) {
									written_vars.insert(*root);
								}
							}
						}
					}
				} break;

				default: {
					// OpAtomicExchange(229) through OpAtomicXor(242):
					// result_type result_id pointer scope ... — pointer at pos+3
					if (op >= 229 && op <= 242 && wc >= 6) {
						uint32_t ptr_id = read_word(data, len, pos + 3);
						if (storage_vars.has(ptr_id)) {
							written_vars.insert(ptr_id);
						} else {
							const uint32_t *root = ptr_to_root.getptr(ptr_id);
							if (root) {
								written_vars.insert(*root);
							}
						}
					}
				} break;
			}

			pos += wc;
		}
	}

	// Pass 3: Find storage vars that already have NonWritable decoration.
	HashSet<uint32_t> already_nonwritable;
	{
		uint32_t pos = 5;
		while (pos < nwords) {
			uint32_t word0 = read_word(data, len, pos);
			uint32_t wc = (word0 >> 16) & 0xFFFF;
			uint16_t op = word0 & 0xFFFF;
			if (wc == 0 || pos + wc > nwords) {
				break;
			}
			if (op == OP_DECORATE && wc >= 3) {
				uint32_t target = read_word(data, len, pos + 1);
				uint32_t deco = read_word(data, len, pos + 2);
				if (deco == DECO_NON_WRITABLE) {
					already_nonwritable.insert(target);
				}
			}
			pos += wc;
		}
	}

	// Determine which vars need NonWritable added.
	Vector<uint32_t> to_add;
	for (const uint32_t &var_id : storage_vars) {
		if (!written_vars.has(var_id) && !already_nonwritable.has(var_id)) {
			to_add.push_back(var_id);
		}
	}

	if (to_add.is_empty()) {
		return p_bytes;
	}

	// Build output: insert OpDecorate NonWritable before first annotation.
	Vector<uint8_t> out;
	out.resize(0);
	append_bytes(out, data, 0, 20); // Copy header.

	bool inserted = false;
	uint32_t pos = 5;
	while (pos < nwords) {
		uint32_t word0 = read_word(data, len, pos);
		uint32_t wc = (word0 >> 16) & 0xFFFF;
		uint16_t op = word0 & 0xFFFF;
		if (wc == 0) {
			break;
		}
		if (pos + wc > nwords) {
			append_bytes(out, data, pos * 4, len - pos * 4);
			break;
		}

		if (!inserted && (op == OP_DECORATE || op == OP_MEMBER_DECORATE || op == OP_DECORATION_GROUP)) {
			for (int64_t i = 0; i < to_add.size(); i++) {
				push_word(out, (3u << 16) | OP_DECORATE);
				push_word(out, to_add[i]);
				push_word(out, DECO_NON_WRITABLE);
			}
			inserted = true;
		}

		append_bytes(out, data, pos * 4, wc * 4);
		pos += wc;
	}

	if (!inserted) {
		// Fallback: append at end.
		for (int64_t i = 0; i < to_add.size(); i++) {
			push_word(out, (3u << 16) | OP_DECORATE);
			push_word(out, to_add[i]);
			push_word(out, DECO_NON_WRITABLE);
		}
	}

	return out;
}

} // namespace spirv_preprocess
