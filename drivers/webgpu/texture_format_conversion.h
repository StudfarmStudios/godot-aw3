/**************************************************************************/
/*  texture_format_conversion.h                                           */
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

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>

// Numerical conversions used when a WebGPU allocation has a different texel
// representation from the RenderingDevice format. Kept independent of the GPU
// so the exact production code can be tested with sanitizers on the host.
namespace WebGPUTextureConversion {

enum class Encoding {
	INVALID,
	UNORM8,
	SNORM8,
	UINT8,
	SINT8,
	UINT16,
	SINT16,
	FLOAT16,
	UINT32,
	SINT32,
	FLOAT32,
	RGB10A2_UNORM,
	RGB10A2_UINT,
	RG11B10_UFLOAT,
};

struct Format {
	Encoding encoding = Encoding::INVALID;
	uint32_t channels = 0;
};

template <typename T>
inline T load(const uint8_t *p_bytes) {
	T value;
	memcpy(&value, p_bytes, sizeof(T));
	return value;
}

template <typename T>
inline void store(uint8_t *p_bytes, T p_value) {
	memcpy(p_bytes, &p_value, sizeof(T));
}

inline uint32_t component_size(Encoding p_encoding) {
	switch (p_encoding) {
		case Encoding::UNORM8:
		case Encoding::SNORM8:
		case Encoding::UINT8:
		case Encoding::SINT8:
			return 1;
		case Encoding::UINT16:
		case Encoding::SINT16:
		case Encoding::FLOAT16:
			return 2;
		case Encoding::UINT32:
		case Encoding::SINT32:
		case Encoding::FLOAT32:
			return 4;
		default:
			return 0;
	}
}

inline uint32_t pixel_size(Format p_format) {
	if (p_format.channels == 0 || p_format.channels > 4) {
		return 0;
	}
	switch (p_format.encoding) {
		case Encoding::RGB10A2_UNORM:
		case Encoding::RGB10A2_UINT:
			return p_format.channels == 4 ? 4 : 0;
		case Encoding::RG11B10_UFLOAT:
			return p_format.channels == 3 ? 4 : 0;
		default:
			return component_size(p_format.encoding) * p_format.channels;
	}
}

inline uint32_t round_shift_even(uint32_t p_value, uint32_t p_shift) {
	if (p_shift == 0) {
		return p_value;
	}
	if (p_shift >= 32) {
		return 0;
	}
	const uint32_t base = p_value >> p_shift;
	const uint32_t remainder = p_value & ((1u << p_shift) - 1);
	const uint32_t midpoint = 1u << (p_shift - 1);
	return base + (remainder > midpoint || (remainder == midpoint && (base & 1)));
}

// The packed 11/10-bit floats and binary16 share a five-bit exponent and bias
// 15. Preserve subnormals, infinities and NaNs; Math::make_half_float deliberately
// flushes subnormals, which would corrupt packed HDR uploads and readbacks.
inline uint32_t float_to_ufloat(float p_value, uint32_t p_mantissa_bits) {
	uint32_t bits;
	memcpy(&bits, &p_value, sizeof(bits));
	const uint32_t exponent = (bits >> 23) & 255;
	const uint32_t mantissa = bits & 0x7fffff;
	if (exponent == 255 && mantissa) {
		return (31u << p_mantissa_bits) | (1u << (p_mantissa_bits - 1));
	}
	if (bits & 0x80000000u) {
		return 0;
	}
	if (exponent >= 143) {
		return 31u << p_mantissa_bits;
	}
	if (exponent < 113) {
		return round_shift_even(mantissa | 0x800000, 113 - exponent + 23 - p_mantissa_bits);
	}
	return round_shift_even(((exponent - 112) << 23) | mantissa, 23 - p_mantissa_bits);
}

inline float ufloat_to_float(uint32_t p_value, uint32_t p_mantissa_bits) {
	int32_t exponent = p_value >> p_mantissa_bits;
	uint32_t mantissa = p_value & ((1u << p_mantissa_bits) - 1);
	uint32_t bits;
	if (exponent == 31) {
		bits = 0x7f800000 | (mantissa ? 0x400000 : 0);
	} else {
		if (exponent == 0) {
			if (mantissa == 0) {
				return 0.0f;
			}
			exponent = 1;
			while (!(mantissa & (1u << p_mantissa_bits))) {
				mantissa <<= 1;
				exponent--;
			}
			mantissa &= (1u << p_mantissa_bits) - 1;
		}
		bits = (uint32_t(exponent + 112) << 23) | (mantissa << (23 - p_mantissa_bits));
	}
	float result;
	memcpy(&result, &bits, sizeof(result));
	return result;
}

// Portable round-to-nearest-even conversion. Normal values need only an
// exponent-bias adjustment and rounding-bit addition; handle small and special
// values separately so the common upload loop remains vectorizable.
inline uint16_t float_to_half_software(float p_value) {
	uint32_t bits;
	memcpy(&bits, &p_value, sizeof(bits));
	const uint32_t sign = (bits >> 16) & 0x8000;
	bits &= 0x7fffffff;
	uint32_t result;
	if (bits >= (143u << 23)) {
		result = bits > 0x7f800000 ? 0x7e00 : 0x7c00;
	} else if (bits < (113u << 23)) {
		// Adding 0.5 shifts the subnormal mantissa to binary16's precision.
		// IEEE binary32 addition supplies nearest-even rounding, including the
		// exact halfway case between zero and the smallest half subnormal.
		float magnitude;
		memcpy(&magnitude, &bits, sizeof(magnitude));
		magnitude += 0.5f;
		memcpy(&result, &magnitude, sizeof(result));
		result -= 126u << 23;
	} else {
		const uint32_t odd = (bits >> 13) & 1;
		result = (bits + 0xc8000fff + odd) >> 13;
	}
	return uint16_t(sign | result);
}

inline uint16_t float_to_half(float p_value) {
#if defined(__FLT16_MANT_DIG__) && (defined(__aarch64__) || defined(__F16C__))
	const _Float16 value = p_value;
	uint16_t bits;
	memcpy(&bits, &value, sizeof(bits));
	return bits;
#else
	return float_to_half_software(p_value);
#endif
}

inline float half_to_float(uint16_t p_value) {
#if defined(__FLT16_MANT_DIG__) && (defined(__aarch64__) || defined(__F16C__))
	_Float16 value;
	memcpy(&value, &p_value, sizeof(value));
	return float(value);
#else
	const float magnitude = ufloat_to_float(p_value & 0x7fff, 10);
	return (p_value & 0x8000) ? -magnitude : magnitude;
#endif
}

inline double clamp_number(double p_value, double p_min, double p_max) {
	return std::isnan(p_value) ? 0.0 : std::clamp(p_value, p_min, p_max);
}

inline double read_component(const uint8_t *p_src, Encoding p_encoding) {
	switch (p_encoding) {
		case Encoding::UNORM8:
			return load<uint8_t>(p_src) / 255.0;
		case Encoding::SNORM8:
			return std::max(-1.0, load<int8_t>(p_src) / 127.0);
		case Encoding::UINT8:
			return load<uint8_t>(p_src);
		case Encoding::SINT8:
			return load<int8_t>(p_src);
		case Encoding::UINT16:
			return load<uint16_t>(p_src);
		case Encoding::SINT16:
			return load<int16_t>(p_src);
		case Encoding::FLOAT16:
			return half_to_float(load<uint16_t>(p_src));
		case Encoding::UINT32:
			return load<uint32_t>(p_src);
		case Encoding::SINT32:
			return load<int32_t>(p_src);
		case Encoding::FLOAT32:
			return load<float>(p_src);
		default:
			return 0;
	}
}

inline void write_component(uint8_t *p_dst, Encoding p_encoding, double p_value) {
	switch (p_encoding) {
		case Encoding::UNORM8:
			store<uint8_t>(p_dst, uint8_t(std::round(clamp_number(p_value, 0, 1) * 255)));
			break;
		case Encoding::SNORM8:
			store<int8_t>(p_dst, int8_t(std::round(clamp_number(p_value, -1, 1) * 127)));
			break;
		case Encoding::UINT8:
			store<uint8_t>(p_dst, uint8_t(clamp_number(p_value, 0, UINT8_MAX)));
			break;
		case Encoding::SINT8:
			store<int8_t>(p_dst, int8_t(clamp_number(p_value, INT8_MIN, INT8_MAX)));
			break;
		case Encoding::UINT16:
			store<uint16_t>(p_dst, uint16_t(clamp_number(p_value, 0, UINT16_MAX)));
			break;
		case Encoding::SINT16:
			store<int16_t>(p_dst, int16_t(clamp_number(p_value, INT16_MIN, INT16_MAX)));
			break;
		case Encoding::FLOAT16:
			store<uint16_t>(p_dst, float_to_half(float(p_value)));
			break;
		case Encoding::UINT32:
			store<uint32_t>(p_dst, uint32_t(clamp_number(p_value, 0, UINT32_MAX)));
			break;
		case Encoding::SINT32:
			store<int32_t>(p_dst, int32_t(clamp_number(p_value, INT32_MIN, INT32_MAX)));
			break;
		case Encoding::FLOAT32:
			store<float>(p_dst, float(p_value));
			break;
		default:
			break;
	}
}

inline void unpack(const uint8_t *p_src, Format p_format, double *r_values) {
	if (component_size(p_format.encoding)) {
		for (uint32_t c = 0; c < p_format.channels; c++) {
			r_values[c] = read_component(p_src + c * component_size(p_format.encoding), p_format.encoding);
		}
		return;
	}
	const uint32_t packed = load<uint32_t>(p_src);
	if (p_format.encoding == Encoding::RG11B10_UFLOAT) {
		r_values[0] = ufloat_to_float(packed & 0x7ff, 6);
		r_values[1] = ufloat_to_float((packed >> 11) & 0x7ff, 6);
		r_values[2] = ufloat_to_float(packed >> 22, 5);
	} else {
		for (uint32_t c = 0; c < 4; c++) {
			const uint32_t mask = c == 3 ? 3 : 1023;
			r_values[c] = (packed >> (c * 10)) & mask;
			if (p_format.encoding == Encoding::RGB10A2_UNORM) {
				r_values[c] /= mask;
			}
		}
	}
}

inline void pack(uint8_t *p_dst, Format p_format, const double *p_values) {
	if (component_size(p_format.encoding)) {
		for (uint32_t c = 0; c < p_format.channels; c++) {
			write_component(p_dst + c * component_size(p_format.encoding), p_format.encoding, p_values[c]);
		}
		return;
	}
	uint32_t packed = 0;
	if (p_format.encoding == Encoding::RG11B10_UFLOAT) {
		packed = float_to_ufloat(float(p_values[0]), 6) |
				(float_to_ufloat(float(p_values[1]), 6) << 11) |
				(float_to_ufloat(float(p_values[2]), 5) << 22);
	} else {
		for (uint32_t c = 0; c < 4; c++) {
			const uint32_t mask = c == 3 ? 3 : 1023;
			const double value = p_format.encoding == Encoding::RGB10A2_UNORM ? std::round(clamp_number(p_values[c], 0, 1) * mask) : clamp_number(p_values[c], 0, mask);
			packed |= uint32_t(value) << (c * 10);
		}
	}
	store<uint32_t>(p_dst, packed);
}

template <typename Src, typename Dst, typename Convert>
inline void convert_components(const uint8_t *p_src, uint32_t p_src_pitch, uint8_t *p_dst, uint32_t p_dst_pitch,
		uint32_t p_components, uint32_t p_height, Convert p_convert) {
	if (uint64_t(p_components) * sizeof(Src) == p_src_pitch && uint64_t(p_components) * sizeof(Dst) == p_dst_pitch &&
			uint64_t(p_components) * p_height <= UINT32_MAX) {
		p_components *= p_height;
		p_height = 1;
	}
	for (uint32_t y = 0; y < p_height; y++) {
		const uint8_t *src = p_src + uint64_t(y) * p_src_pitch;
		uint8_t *dst = p_dst + uint64_t(y) * p_dst_pitch;
		for (uint32_t c = 0; c < p_components; c++) {
			store<Dst>(dst + c * sizeof(Dst), p_convert(load<Src>(src + c * sizeof(Src))));
		}
	}
}

inline bool convert(Format p_src_format, Format p_dst_format,
		const uint8_t *p_src, uint32_t p_src_pitch, uint8_t *p_dst, uint32_t p_dst_pitch,
		uint32_t p_width, uint32_t p_height) {
	const uint32_t src_size = pixel_size(p_src_format);
	const uint32_t dst_size = pixel_size(p_dst_format);
	if (!src_size || !dst_size || uint64_t(p_width) * src_size > p_src_pitch || uint64_t(p_width) * dst_size > p_dst_pitch) {
		return false;
	}
	// Dispatch once per image for existing hot upload paths. The inner loops
	// remain simple and vectorizable, without per-texel format switches or an
	// intermediate double-precision RGBA value.
	if (p_src_format.channels == p_dst_format.channels) {
		const uint32_t components = p_width * p_src_format.channels;
		if (p_src_format.encoding == Encoding::UNORM8 && p_dst_format.encoding == Encoding::FLOAT32) {
			convert_components<uint8_t, float>(p_src, p_src_pitch, p_dst, p_dst_pitch, components, p_height, [](uint8_t v) { return float(v) / 255.0f; });
			return true;
		}
		if (p_src_format.encoding == Encoding::SNORM8 && p_dst_format.encoding == Encoding::FLOAT32) {
			convert_components<int8_t, float>(p_src, p_src_pitch, p_dst, p_dst_pitch, components, p_height, [](int8_t v) { return std::max(-1.0f, float(v) / 127.0f); });
			return true;
		}
		if (p_src_format.encoding == Encoding::UINT8 && p_dst_format.encoding == Encoding::UINT32) {
			convert_components<uint8_t, uint32_t>(p_src, p_src_pitch, p_dst, p_dst_pitch, components, p_height, [](uint8_t v) { return uint32_t(v); });
			return true;
		}
		if (p_src_format.encoding == Encoding::SINT8 && p_dst_format.encoding == Encoding::SINT32) {
			convert_components<int8_t, int32_t>(p_src, p_src_pitch, p_dst, p_dst_pitch, components, p_height, [](int8_t v) { return int32_t(v); });
			return true;
		}
		if (p_src_format.encoding == Encoding::UINT16 && p_dst_format.encoding == Encoding::UINT32) {
			convert_components<uint16_t, uint32_t>(p_src, p_src_pitch, p_dst, p_dst_pitch, components, p_height, [](uint16_t v) { return uint32_t(v); });
			return true;
		}
		if (p_src_format.encoding == Encoding::SINT16 && p_dst_format.encoding == Encoding::SINT32) {
			convert_components<int16_t, int32_t>(p_src, p_src_pitch, p_dst, p_dst_pitch, components, p_height, [](int16_t v) { return int32_t(v); });
			return true;
		}
		if (p_src_format.encoding == Encoding::FLOAT32 && p_dst_format.encoding == Encoding::UNORM8) {
			convert_components<float, uint8_t>(p_src, p_src_pitch, p_dst, p_dst_pitch, components, p_height, [](float v) { return std::isnan(v) ? 0 : uint8_t(std::clamp(v, 0.0f, 1.0f) * 255.0f + 0.5f); });
			return true;
		}
		if (p_src_format.encoding == Encoding::FLOAT32 && p_dst_format.encoding == Encoding::SNORM8) {
			convert_components<float, int8_t>(p_src, p_src_pitch, p_dst, p_dst_pitch, components, p_height, [](float v) { return std::isnan(v) ? 0 : int8_t(std::round(std::clamp(v, -1.0f, 1.0f) * 127.0f)); });
			return true;
		}
		if (p_src_format.encoding == Encoding::UINT32 && p_dst_format.encoding == Encoding::UINT8) {
			convert_components<uint32_t, uint8_t>(p_src, p_src_pitch, p_dst, p_dst_pitch, components, p_height, [](uint32_t v) { return uint8_t(std::min(v, 255u)); });
			return true;
		}
		if (p_src_format.encoding == Encoding::SINT32 && p_dst_format.encoding == Encoding::SINT8) {
			convert_components<int32_t, int8_t>(p_src, p_src_pitch, p_dst, p_dst_pitch, components, p_height, [](int32_t v) { return int8_t(std::clamp(v, -128, 127)); });
			return true;
		}
		if (p_src_format.encoding == Encoding::UINT32 && p_dst_format.encoding == Encoding::UINT16) {
			convert_components<uint32_t, uint16_t>(p_src, p_src_pitch, p_dst, p_dst_pitch, components, p_height, [](uint32_t v) { return uint16_t(std::min(v, 65535u)); });
			return true;
		}
		if (p_src_format.encoding == Encoding::SINT32 && p_dst_format.encoding == Encoding::SINT16) {
			convert_components<int32_t, int16_t>(p_src, p_src_pitch, p_dst, p_dst_pitch, components, p_height, [](int32_t v) { return int16_t(std::clamp(v, -32768, 32767)); });
			return true;
		}
		if (p_src_format.encoding == Encoding::FLOAT32 && p_dst_format.encoding == Encoding::FLOAT16) {
			convert_components<float, uint16_t>(p_src, p_src_pitch, p_dst, p_dst_pitch, components, p_height, float_to_half);
			return true;
		}
		if (p_src_format.encoding == Encoding::FLOAT16 && p_dst_format.encoding == Encoding::FLOAT32) {
			convert_components<uint16_t, float>(p_src, p_src_pitch, p_dst, p_dst_pitch, components, p_height, half_to_float);
			return true;
		}
	}
	for (uint32_t y = 0; y < p_height; y++) {
		for (uint32_t x = 0; x < p_width; x++) {
			double values[4] = { 0, 0, 0, 1 };
			unpack(p_src + uint64_t(y) * p_src_pitch + uint64_t(x) * src_size, p_src_format, values);
			pack(p_dst + uint64_t(y) * p_dst_pitch + uint64_t(x) * dst_size, p_dst_format, values);
		}
	}
	return true;
}

} // namespace WebGPUTextureConversion
