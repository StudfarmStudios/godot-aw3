/**************************************************************************/
/*  main.cpp                                                              */
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

// tint_convert_cli — Standalone SPIR-V → WGSL converter for build-time precompilation.
//
// Runs the same 11 preprocessing passes as the Godot WebGPU runtime driver,
// then converts to WGSL via Tint. Produces output identical to what the engine
// generates at runtime, enabling precompilation of ubershader and specialized
// shader variants at build time.
//
// Usage:
//   tint_convert_cli <file.spv>                       # single file → WGSL to stdout
//   tint_convert_cli --batch <file1.spv> <file2.spv>  # batch → JSON to stdout

#include "drivers/webgpu/generated/wgsl_cache_identity.gen.h"
#include "drivers/webgpu/spirv_preprocess.h"
#include "drivers/webgpu/tint_wrapper.h"

#include <fcntl.h>
#include <poll.h>
#include <sys/wait.h>
#include <unistd.h>

#include <cerrno>
#include <chrono>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>

// Read a binary file into a byte vector.
static std::vector<uint8_t> read_file(const char *p_path) {
	std::ifstream f(p_path, std::ios::binary | std::ios::ate);
	if (!f.is_open()) {
		return {};
	}
	auto size = f.tellg();
	if (size <= 0) {
		return {};
	}
	std::vector<uint8_t> buf((size_t)size);
	f.seekg(0);
	f.read(reinterpret_cast<char *>(buf.data()), size);
	return buf;
}

// Run the full SPIR-V preprocessing pipeline + Tint conversion.
// Returns WGSL string on success, empty string on failure (error written to r_error).
static std::string convert_spirv_to_wgsl(const std::vector<uint8_t> &p_spv_bytes, std::string &r_error) {
	if (p_spv_bytes.size() < 20 || (p_spv_bytes.size() % 4) != 0) {
		r_error = "Invalid SPIR-V: too small or not aligned to 4 bytes";
		return {};
	}

	// Wrap in Godot-compatible Vector for the preprocessing API.
	Vector<uint8_t> spv;
	spv.resize((int64_t)p_spv_bytes.size());
	memcpy(spv.ptrw(), p_spv_bytes.data(), p_spv_bytes.size());

	// Preprocessing, shared with the runtime driver so the two cannot drift.
	spv = spirv_preprocess::run_all(spv);

	// Debug aid: AW3_DUMP_PREPROCESSED=<path> writes the module Tint is about to
	// read, so preprocessing output can be disassembled and compared.
	if (const char *dump_path = getenv("AW3_DUMP_PREPROCESSED")) {
		if (FILE *df = fopen(dump_path, "wb")) {
			fwrite(spv.ptr(), 1, (size_t)spv.size(), df);
			fclose(df);
		}
	}

	// The same gate the runtime driver applies. Tint aborts instead of returning an
	// error on these, which in --batch mode would take every other shader with it.
	std::string untranslatable = spirv_preprocess::find_untranslatable_construct(spv);
	if (!untranslatable.empty()) {
		r_error = "shader uses " + untranslatable + ", which cannot be expressed in WGSL";
		return {};
	}

	// Convert to uint32_t words for Tint.
	size_t word_count = (size_t)spv.size() / 4;
	const uint32_t *words = reinterpret_cast<const uint32_t *>(spv.ptr());

	char *error_msg = nullptr;
	char *wgsl = tint_wrapper_spirv_to_wgsl(words, word_count, &error_msg);
	if (!wgsl) {
		r_error = error_msg ? error_msg : "Tint conversion failed (unknown error)";
		free(error_msg);
		return {};
	}

	std::string result(wgsl);
	free(wgsl);
	return result;
}

// Escape a string for JSON output (handles \, ", newlines, tabs).
static std::string json_escape(const std::string &p_str) {
	std::string out;
	out.reserve(p_str.size() + p_str.size() / 8);
	for (char c : p_str) {
		switch (c) {
			case '"':
				out += "\\\"";
				break;
			case '\\':
				out += "\\\\";
				break;
			case '\n':
				out += "\\n";
				break;
			case '\r':
				out += "\\r";
				break;
			case '\t':
				out += "\\t";
				break;
			default:
				if ((unsigned char)c < 0x20) {
					char escaped[7];
					snprintf(escaped, sizeof(escaped), "\\u%04x", (unsigned char)c);
					out += escaped;
				} else {
					out += c;
				}
				break;
		}
	}
	return out;
}

// Convert a single file in a forked child process. Tint can abort() on
// unhandled SPIR-V features (TINT_UNIMPLEMENTED); fork isolation prevents
// one bad shader from killing the entire batch.
//
// Returns WGSL on success, or sets r_error on failure.
static bool write_all(int p_fd, const char *p_data, size_t p_size) {
	while (p_size > 0) {
		const ssize_t written = write(p_fd, p_data, p_size);
		if (written < 0 && errno == EINTR) {
			continue;
		}
		if (written <= 0) {
			return false;
		}
		p_data += written;
		p_size -= (size_t)written;
	}
	return true;
}

static std::string convert_isolated(const std::vector<uint8_t> &p_spv_bytes, std::string &r_error, std::chrono::milliseconds p_timeout = std::chrono::seconds(120)) {
	int pipefd[2];
	if (pipe(pipefd) != 0) {
		r_error = std::string("Cannot isolate Tint: pipe failed: ") + strerror(errno);
		return {};
	}
	fflush(stdout);
	std::cout.flush();
	pid_t pid = fork();
	if (pid < 0) {
		const int error = errno;
		close(pipefd[0]);
		close(pipefd[1]);
		r_error = std::string("Cannot isolate Tint: fork failed: ") + strerror(error);
		return {};
	}
	if (pid == 0) {
		close(pipefd[0]);
		int devnull = open("/dev/null", O_WRONLY);
		if (devnull >= 0) {
			dup2(devnull, STDOUT_FILENO);
			dup2(devnull, STDERR_FILENO);
			close(devnull);
		}
		std::string error;
		std::string wgsl = convert_spirv_to_wgsl(p_spv_bytes, error);
		const char status = wgsl.empty() ? 'E' : 'W';
		const std::string &message = wgsl.empty() ? error : wgsl;
		const bool sent = write_all(pipefd[1], &status, 1) && write_all(pipefd[1], message.data(), message.size());
		close(pipefd[1]);
		_exit(sent ? 0 : 1);
	}

	close(pipefd[1]);
	std::string data;
	const auto deadline = std::chrono::steady_clock::now() + p_timeout;
	bool failed = false;
	while (true) {
		const auto remaining = std::chrono::duration_cast<std::chrono::milliseconds>(deadline - std::chrono::steady_clock::now()).count();
		if (remaining <= 0) {
			r_error = "Tint conversion timed out";
			failed = true;
			break;
		}
		pollfd descriptor = { pipefd[0], POLLIN, 0 };
		const int ready = poll(&descriptor, 1, (int)remaining);
		if (ready < 0 && errno == EINTR) {
			continue;
		}
		if (ready == 0) {
			continue;
		}
		if (ready < 0) {
			r_error = std::string("Tint result poll failed: ") + strerror(errno);
			failed = true;
			break;
		}
		char buffer[4096];
		const ssize_t count = read(pipefd[0], buffer, sizeof(buffer));
		if (count < 0 && errno == EINTR) {
			continue;
		}
		if (count < 0) {
			r_error = std::string("Tint result read failed: ") + strerror(errno);
			failed = true;
			break;
		}
		if (count == 0) {
			break;
		}
		if (data.size() + (size_t)count > 16 * 1024 * 1024 + 1) {
			r_error = "Tint result exceeds the 16 MiB WGSL cache limit";
			failed = true;
			break;
		}
		data.append(buffer, (size_t)count);
	}
	close(pipefd[0]);
	if (failed) {
		kill(pid, SIGKILL);
	}
	int status = 0;
	pid_t waited;
	do {
		waited = waitpid(pid, &status, 0);
	} while (waited < 0 && errno == EINTR);
	if (failed) {
		return {};
	}
	if (waited != pid || !WIFEXITED(status) || WEXITSTATUS(status) != 0 || data.empty()) {
		r_error = "Tint child failed or crashed while converting SPIR-V";
		return {};
	}
	if (data[0] == 'W') {
		return data.substr(1);
	}
	r_error = data[0] == 'E' ? data.substr(1) : "Invalid Tint child response";
	return {};
}

static void print_usage() {
	fprintf(stderr, "Usage:\n");
	fprintf(stderr, "  tint_convert_cli <file.spv>                       Single file → WGSL to stdout\n");
	fprintf(stderr, "  tint_convert_cli --batch <file1.spv> [file2.spv]  Batch → JSON to stdout\n");
}

int main(int argc, char *argv[]) {
	if (argc < 2) {
		print_usage();
		return 1;
	}

	if (strcmp(argv[1], "--fingerprint") == 0) {
		std::cout << WEBGPU_TRANSLATOR_FINGERPRINT << std::endl;
		return 0;
	}

	tint_wrapper_initialize();

	bool batch_mode = (strcmp(argv[1], "--batch") == 0);

	if (batch_mode) {
		if (argc < 3) {
			fprintf(stderr, "Error: --batch requires at least one file argument.\n");
			return 1;
		}

		// Batch mode: output JSON { "path": "wgsl" | {"error": "msg"}, ... }
		std::cout << "{" << std::endl;
		for (int i = 2; i < argc; i++) {
			const char *path = argv[i];
			auto spv_bytes = read_file(path);

			std::cout << "  \"" << json_escape(path) << "\": ";

			if (spv_bytes.empty()) {
				std::cout << "{\"error\": \"Failed to read file\"}";
			} else {
				std::string error;
				std::string wgsl = convert_isolated(spv_bytes, error);
				if (wgsl.empty()) {
					std::cout << "{\"error\": \"" << json_escape(error) << "\"}";
				} else {
					std::cout << "\"" << json_escape(wgsl) << "\"";
				}
			}

			if (i + 1 < argc) {
				std::cout << ",";
			}
			std::cout << std::endl;
		}
		std::cout << "}" << std::endl;
		return 0;

	} else {
		// Single file mode: output WGSL to stdout.
		const char *path = argv[1];
		auto spv_bytes = read_file(path);
		if (spv_bytes.empty()) {
			fprintf(stderr, "Error: Failed to read '%s'\n", path);
			return 1;
		}

		std::string error;
		std::string wgsl = convert_isolated(spv_bytes, error);
		if (wgsl.empty()) {
			fprintf(stderr, "Error: %s\n", error.c_str());
			return 1;
		}

		std::cout << wgsl;
		return 0;
	}
}
