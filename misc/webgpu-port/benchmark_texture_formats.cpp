/**************************************************************************/
/*  benchmark_texture_formats.cpp                                         */
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

// Copyright (c) 2014-present Godot Engine contributors.
// SPDX-License-Identifier: MIT

#include "core/math/math_funcs.h"
#include "drivers/webgpu/texture_format_conversion.h"

#include <chrono>
#include <cstdio>
#include <vector>

using namespace WebGPUTextureConversion;
constexpr uint32_t WIDTH = 1024, HEIGHT = 1024;
volatile uint32_t checksum = 0;

// The two previously supported conversions, taken from the driver at c0d51825.
// Narrow integer/packed conversion is not used as a baseline: it was incorrect.
__attribute__((noinline)) void baseline_unorm(const uint8_t *src, uint8_t *dst) {
	for (uint32_t i = 0; i < WIDTH * HEIGHT; i++) {
		store<float>(dst + i * 4, float(src[i]) / 255.0f);
	}
}
__attribute__((noinline)) void baseline_half(const uint8_t *src, uint8_t *dst) {
	for (uint32_t i = 0; i < WIDTH * HEIGHT; i++) {
		store<uint16_t>(dst + i * 2, Math::make_half_float(load<float>(src + i * 4)));
	}
}
__attribute__((noinline)) void new_unorm(const uint8_t *src, uint8_t *dst) {
	convert({ Encoding::UNORM8, 1 }, { Encoding::FLOAT32, 1 }, src, WIDTH, dst, WIDTH * 4, WIDTH, HEIGHT);
}
__attribute__((noinline)) void new_half(const uint8_t *src, uint8_t *dst) {
	convert({ Encoding::FLOAT32, 1 }, { Encoding::FLOAT16, 1 }, src, WIDTH * 4, dst, WIDTH * 2, WIDTH, HEIGHT);
}

__attribute__((noinline)) void new_half_software(const uint8_t *src, uint8_t *dst) {
	convert_components<float, uint16_t>(src, WIDTH * 4, dst, WIDTH * 2, WIDTH, HEIGHT, float_to_half_software);
}

using Convert = void (*)(const uint8_t *, uint8_t *);
static double measure(Convert convert_fn, uint8_t *src, uint8_t *dst) {
	constexpr uint32_t ITERATIONS = 100;
	for (uint32_t i = 0; i < 5; i++) {
		convert_fn(src, dst);
	}
	const auto start = std::chrono::steady_clock::now();
	for (uint32_t i = 0; i < ITERATIONS; i++) {
		src[0] = i; // Prevent hoisting the identical input across iterations.
		convert_fn(src, dst);
		checksum = checksum + dst[(i * 4093) % (WIDTH * HEIGHT)];
	}
	return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count() / ITERATIONS;
}

int main() {
	std::vector<uint8_t> src(WIDTH * HEIGHT * 4), dst(WIDTH * HEIGHT * 4);
	for (uint32_t i = 0; i < WIDTH * HEIGHT; i++) {
		store<float>(src.data() + i * 4, float(i % 8192) / 8192.0f);
	}
	puts("format,round,baseline_ms,new_ms,ratio");
	for (uint32_t round = 0; round < 5; round++) {
		for (uint32_t format = 0; format < 3; format++) {
			const Convert baseline = format ? baseline_half : baseline_unorm;
			const Convert current = format == 2 ? new_half_software : (format ? new_half : new_unorm);
			// Alternate order to reduce thermal/order bias. This is a CPU helper
			// benchmark, not an end-to-end browser or GPU performance claim.
			double old_ms, new_ms;
			if (round % 2) {
				new_ms = measure(current, src.data(), dst.data());
				old_ms = measure(baseline, src.data(), dst.data());
			} else {
				old_ms = measure(baseline, src.data(), dst.data());
				new_ms = measure(current, src.data(), dst.data());
			}
			printf("%s,%u,%.5f,%.5f,%.3f\n", format == 2 ? "f32-to-f16-software" : (format ? "f32-to-f16" : "r8-to-f32"), round, old_ms, new_ms, new_ms / old_ms);
		}
	}
	return checksum == UINT32_MAX ? 1 : 0;
}
