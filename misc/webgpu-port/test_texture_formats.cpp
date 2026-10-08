// Copyright (c) 2014-present Godot Engine contributors.
// SPDX-License-Identifier: MIT

#include "drivers/webgpu/storage_format_remap.h"
#include "drivers/webgpu/texture_format_conversion.h"

#include <array>
#include <cassert>
#include <cstdio>

#ifdef NDEBUG
#error These regression tests require assertions enabled.
#endif

using namespace WebGPUTextureConversion;

static void test_half_float() {
	// Check every binary16 bit pattern, including denormals and negative zero.
	for (uint32_t value = 0; value <= UINT16_MAX; value++) {
		const float decoded = half_to_float(value);
		if ((value & 0x7fff) > 0x7c00) {
			assert(std::isnan(decoded));
		} else {
			assert(float_to_half(decoded) == value);
			assert(float_to_half_software(decoded) == value);
		}
#if defined(__FLT16_MANT_DIG__)
		const uint16_t bits = value;
		_Float16 native;
		memcpy(&native, &bits, sizeof(bits));
		assert(std::isnan(decoded) ? std::isnan(float(native)) : decoded == float(native));
#endif
	}
	assert(float_to_half(std::ldexp(1.0f, -24)) == 1);
	assert(float_to_half(std::ldexp(1.0f, -25)) == 0); // Ties to even.
	assert(float_to_half(65520.0f) == 0x7c00);
#if defined(__FLT16_MANT_DIG__)
	// A separate compiler implementation is the oracle for rounding values that
	// are not already exactly representable as binary16.
	uint32_t state = 17;
	for (uint32_t i = 0; i < 100000; i++) {
		state = state * 1664525u + 1013904223u;
		float value;
		memcpy(&value, &state, sizeof(value));
		_Float16 native = value;
		uint16_t expected;
		memcpy(&expected, &native, sizeof(expected));
		const uint16_t actual = float_to_half(value);
		assert(std::isnan(value) ? (actual & 0x7fff) > 0x7c00 : actual == expected);
		const uint16_t software = float_to_half_software(value);
		assert(std::isnan(value) ? (software & 0x7fff) > 0x7c00 : software == expected);
	}
#endif
}

static void test_packed_formats() {
	std::array<uint8_t, 8> gpu{};
	uint32_t result = 0;
	for (uint32_t i = 0; i < 4096; i++) {
		const uint32_t packed = (i & 1023) | ((1023 - (i & 1023)) << 10) | (((i ^ 341) & 1023) << 20) | ((i >> 10) << 30);
		for (Encoding encoding : { Encoding::RGB10A2_UNORM, Encoding::RGB10A2_UINT }) {
			const Format cpu{ encoding, 4 };
			const Format physical{ encoding == Encoding::RGB10A2_UINT ? Encoding::UINT16 : Encoding::FLOAT16, 4 };
			assert(convert(cpu, physical, reinterpret_cast<const uint8_t *>(&packed), 4, gpu.data(), 8, 1, 1));
			assert(convert(physical, cpu, gpu.data(), 8, reinterpret_cast<uint8_t *>(&result), 4, 1, 1));
			assert(result == packed);
		}
	}
	const uint32_t red = 0xc00003ff;
	assert(convert({ Encoding::RGB10A2_UNORM, 4 }, { Encoding::FLOAT16, 4 },
			reinterpret_cast<const uint8_t *>(&red), 4, gpu.data(), 8, 1, 1));
	assert(load<uint16_t>(gpu.data()) == 0x3c00);
	assert(load<uint16_t>(gpu.data() + 2) == 0);
	assert(load<uint16_t>(gpu.data() + 4) == 0);
	assert(load<uint16_t>(gpu.data() + 6) == 0x3c00);
	for (uint32_t value = 0; value < 2048; value++) {
		const uint32_t packed = value | (value << 11) | ((value & 1023) << 22);
		assert(convert({ Encoding::RG11B10_UFLOAT, 3 }, { Encoding::FLOAT16, 4 },
				reinterpret_cast<const uint8_t *>(&packed), 4, gpu.data(), 8, 1, 1));
		assert(load<uint16_t>(gpu.data() + 6) == 0x3c00); // Implicit alpha is one.
		assert(convert({ Encoding::FLOAT16, 4 }, { Encoding::RG11B10_UFLOAT, 3 },
				gpu.data(), 8, reinterpret_cast<uint8_t *>(&result), 4, 1, 1));
		for (uint32_t c = 0; c < 3; c++) {
			const uint32_t mantissa = c == 2 ? 5 : 6;
			const uint32_t mask = c == 2 ? 1023 : 2047;
			const uint32_t original = (packed >> (c * 11)) & mask;
			const uint32_t roundtrip = (result >> (c * 11)) & mask;
			assert((original > (31u << mantissa)) ? std::isnan(ufloat_to_float(roundtrip, mantissa)) : roundtrip == original);
		}
	}
	assert(ufloat_to_float(15 << 6, 6) == 1.0f);
	assert(ufloat_to_float(1, 6) == std::ldexp(1.0f, -20));
	assert(ufloat_to_float(1, 5) == std::ldexp(1.0f, -19));
	assert(float_to_ufloat(-1.0f, 6) == 0);
}

static void test_narrow_formats_and_pitches() {
	// Unaligned data and different row pitches catch the old byte-count-as-
	// component-count bug for R16/RG16, as well as signed-value conversion bugs.
	for (const auto encoding : { Encoding::UNORM8, Encoding::SNORM8, Encoding::UINT8, Encoding::SINT8,
			 Encoding::UINT16, Encoding::SINT16, Encoding::FLOAT16 }) {
		for (uint32_t channels : { 1u, 2u }) {
			const bool floating = encoding == Encoding::UNORM8 || encoding == Encoding::SNORM8 || encoding == Encoding::FLOAT16;
			const bool signed_integer = encoding == Encoding::SINT8 || encoding == Encoding::SINT16;
			Format cpu{ encoding, channels };
			Format physical{ floating ? Encoding::FLOAT32 : (signed_integer ? Encoding::SINT32 : Encoding::UINT32), channels };
			constexpr uint32_t width = 3;
			const uint32_t cpu_pitch = pixel_size(cpu) * width + 5;
			const uint32_t gpu_pitch = pixel_size(physical) * width + 7;
			std::array<uint8_t, 128> source, gpu, roundtrip;
			source.fill(0xa5);
			gpu.fill(0xa5);
			roundtrip.fill(0xa5);
			for (uint32_t y = 0; y < 2; y++) {
				for (uint32_t x = 0; x < width; x++) {
					double values[4] = { double(int(x) - 1), double(int(y) - 1), 0, 1 };
					if (!floating) {
						values[0] *= 127;
						values[1] *= 127;
					}
					pack(source.data() + 1 + y * cpu_pitch + x * pixel_size(cpu), cpu, values);
				}
			}
			assert(convert(cpu, physical, source.data() + 1, cpu_pitch, gpu.data() + 1, gpu_pitch, width, 2));
			assert(convert(physical, cpu, gpu.data() + 1, gpu_pitch, roundtrip.data() + 1, cpu_pitch, width, 2));
			assert(source == roundtrip);
			assert(gpu.front() == 0xa5 && gpu.back() == 0xa5);
			for (uint32_t y = 0; y < 2; y++) {
				for (uint32_t b = width * pixel_size(physical); b < gpu_pitch; b++) {
					assert(gpu[1 + y * gpu_pitch + b] == 0xa5);
				}
			}
			const auto unchanged = gpu;
			assert(!convert(cpu, physical, source.data(), 1, gpu.data(), gpu_pitch, width, 2));
			assert(gpu == unchanged);
		}
	}
	const int16_t signed_values[] = { INT16_MIN, -1, INT16_MAX };
	int32_t expanded[3] = {};
	assert(convert({ Encoding::SINT16, 1 }, { Encoding::SINT32, 1 },
			reinterpret_cast<const uint8_t *>(signed_values), 6, reinterpret_cast<uint8_t *>(expanded), 12, 3, 1));
	assert(expanded[0] == INT16_MIN && expanded[1] == -1 && expanded[2] == INT16_MAX);
}

static void test_shader_format_contract() {
	using WebGPUStorageFormats::remap_wgsl;
	const std::string source = "var r8uint_name: texture_storage_2d<r8uint, write>;\n"
			"var hdr: texture_storage_3d<rg11b10ufloat, write>;\n"
			"var normal: texture_storage_2d_array<rgb10a2unorm, write>;\n"
			"var index: texture_storage_1d<rgb10a2uint, write>;\n"
			"var half: texture_storage_2d<rg16float, write>;\n"
			"const rgb10a2unorm_user_identifier = 1;\n";
	for (bool tier1 : { false, true }) {
		for (bool tier2 : { false, true }) {
			const std::string result = remap_wgsl(source, tier1, tier2);
			assert(result.find(tier1 ? "<r8uint," : "<r32uint,") != std::string::npos);
			assert(result.find(tier2 ? "<rg11b10ufloat," : "<rgba16float,") != std::string::npos);
			assert(result.find(tier2 ? "<rgb10a2uint," : "<rgba16uint,") != std::string::npos);
			assert(result.find("<rg32float,") != std::string::npos);
			assert(result.find("r8uint_name") != std::string::npos);
			assert(result.find("rgb10a2unorm_user_identifier") != std::string::npos);
			assert(remap_wgsl(result, tier1, tier2).empty());
		}
	}
	assert(remap_wgsl("var tex: texture_storage_2d<rgba16float, write>;", false, false).empty());
	assert(remap_wgsl("const r16float_user_identifier = 1;", false, false).empty());
	assert(remap_wgsl("let texture_storage_foo = bitcast<r16float>(x);", false, false).empty());
	assert(remap_wgsl("var my_texture_storage_2d<r8uint, write>;", false, false).empty());
	assert(remap_wgsl("var tex: texture_storage_2d<\n\tr8uint , write>;", false, false).find("r32uint") != std::string::npos);
}

int main() {
	test_half_float();
	test_packed_formats();
	test_narrow_formats_and_pitches();
	test_shader_format_contract();
	puts("PASS: production texture conversions and WGSL format remapping");
}
