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
