/**************************************************************************/
/*  logical_copy_cli.cpp                                                  */
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

// Focused harness: call the production preprocessing pass, not a test reimplementation.
#include "drivers/webgpu/spirv_preprocess.h"

#include <cstdio>
#include <cstring>
#include <fstream>
#include <iterator>
#include <vector>

int main(int argc, char **argv) {
	if (argc != 3) {
		std::fprintf(stderr, "Usage: logical_copy_cli input.spv output.spv\n");
		return 2;
	}
	std::ifstream input(argv[1], std::ios::binary);
	if (!input) {
		return 2;
	}
	std::vector<uint8_t> bytes((std::istreambuf_iterator<char>(input)), {});
	Vector<uint8_t> module;
	module.resize(bytes.size());
	if (!bytes.empty()) {
		memcpy(module.ptrw(), bytes.data(), bytes.size());
	}
	module = spirv_preprocess::rewrite_copy_logical(module);
	std::ofstream output(argv[2], std::ios::binary);
	output.write(reinterpret_cast<const char *>(module.ptr()), module.size());
	if (!output) {
		return 2;
	}
	auto unsupported = spirv_preprocess::find_untranslatable_construct(module);
	if (!unsupported.empty()) {
		std::fprintf(stderr, "%s\n", unsupported.c_str());
	}
	return 0;
}
