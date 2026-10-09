/**************************************************************************/
/*  metadata_probe.cpp                                                    */
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

// Standalone metadata oracle using the actual production SPIR-V preprocessing.
#include "drivers/webgpu/spirv_preprocess.h"

#include <algorithm>
#include <fstream>
#include <iostream>
#include <iterator>
#include <vector>

static void print_keys(const HashSet<uint32_t> &keys) {
	std::vector<uint32_t> sorted;
	for (uint32_t key : keys) {
		sorted.push_back(key);
	}
	std::sort(sorted.begin(), sorted.end());
	std::cout << "[";
	for (size_t i = 0; i < sorted.size(); i++) {
		if (i) {
			std::cout << ",";
		}
		std::cout << sorted[i];
	}
	std::cout << "]";
}

int main(int argc, char **argv) {
	for (int argument = 1; argument < argc; argument++) {
		std::ifstream file(argv[argument], std::ios::binary);
		std::vector<uint8_t> data((std::istreambuf_iterator<char>(file)), std::istreambuf_iterator<char>());
		if (data.size() < 20 || data.size() % 4) {
			return 1;
		}
		Vector<uint8_t> source;
		source.resize(data.size());
		std::copy(data.begin(), data.end(), source.ptrw());
		HashSet<uint32_t> raw, normalized;
		spirv_preprocess::reachable_binding_keys(source, &raw);
		const Vector<uint8_t> adjusted = spirv_preprocess::alias_anisotropic_samplers(source);
		spirv_preprocess::reachable_binding_keys(adjusted, &normalized);
		HashMap<uint32_t, spirv_preprocess::ImageBindingInfo> images;
		spirv_preprocess::binding_image_info(adjusted, &images);
		std::cout << "{\"raw\":";
		print_keys(raw);
		std::cout << ",\"normalized\":";
		print_keys(normalized);
		std::cout << ",\"images\":[";
		bool comma = false;
		for (const auto &entry : images) {
			if (comma) {
				std::cout << ",";
			}
			comma = true;
			const auto &info = entry.value;
			std::cout << "[" << entry.key << "," << info.dim << "," << info.depth << "," << info.arrayed << "," << info.multisampled << "]";
		}
		std::cout << "]}" << std::endl;
	}
}
