/**************************************************************************/
/*  shader_baker_export_plugin_platform_webgpu.cpp                        */
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

#include "shader_baker_export_plugin_platform_webgpu.h"

#include "core/io/compression.h"
#include "core/io/dir_access.h"
#include "core/io/file_access.h"
#include "core/io/json.h"
#include "core/io/marshalls.h"
#include "core/os/os.h"
#include "drivers/webgpu/generated/wgsl_cache_identity.gen.h"
#include "drivers/webgpu/rendering_shader_container_webgpu.h"
#include "drivers/webgpu/spirv_preprocess.h"
#include "editor/editor_node.h"

namespace {

static uint64_t source_hash(const Vector<uint8_t> &p_spirv) {
	return (uint64_t(hash_murmur3_buffer(p_spirv.ptr(), p_spirv.size(), 0x9E3779B9U)) << 32) |
			hash_murmur3_buffer(p_spirv.ptr(), p_spirv.size());
}

// Drain both nonblocking pipes, with total output and wall-clock limits. The
// matching CLI isolates every Tint translation in a child with its own timeout.
static bool run_tint(const String &p_cli, const List<String> &p_arguments, uint64_t p_timeout_usec, String &r_output) {
	Dictionary process = OS::get_singleton()->execute_with_pipe(p_cli, p_arguments, false);
	if (process.is_empty()) {
		return false;
	}
	const ProcessID pid = process["pid"];
	Ref<FileAccess> pipes[2] = { process["stdio"], process["stderr"] };
	Vector<uint8_t> outputs[2];
	const uint64_t start = OS::get_singleton()->get_ticks_usec();
	bool success = true;
	while (true) {
		const bool running_before_read = OS::get_singleton()->is_process_running(pid);
		uint64_t received = 0;
		for (int i = 0; i < 2; i++) {
			const uint64_t available = pipes[i]->get_length();
			if (available == 0) {
				continue;
			}
			if (available > 64 * 1024 * 1024 || uint64_t(outputs[i].size()) + available > 64 * 1024 * 1024) {
				success = false;
				break;
			}
			const int old_size = outputs[i].size();
			outputs[i].resize(old_size + available);
			const uint64_t read = pipes[i]->get_buffer(outputs[i].ptrw() + old_size, available);
			if (read > available) {
				success = false;
				break;
			}
			outputs[i].resize(old_size + read);
			received += read;
		}
		if (!success || OS::get_singleton()->get_ticks_usec() - start > p_timeout_usec) {
			OS::get_singleton()->kill(pid);
			success = false;
			break;
		}
		if (received == 0 && !running_before_read) {
			break;
		}
		OS::get_singleton()->delay_usec(1000);
	}
	for (Ref<FileAccess> &pipe : pipes) {
		pipe->close();
	}
	r_output = String::utf8(reinterpret_cast<const char *>(outputs[0].ptr()), outputs[0].size());
	return success && OS::get_singleton()->get_process_exit_code(pid) == 0;
}

static void append_u32(Vector<uint8_t> &r_bytes, uint32_t p_value) {
	const int offset = r_bytes.size();
	r_bytes.resize(offset + 4);
	encode_uint32(p_value, r_bytes.ptrw() + offset);
}

static bool append_cache_record(Vector<uint8_t> &r_cache, uint64_t p_hash, const Vector<uint8_t> &p_source, const String &p_wgsl) {
	const CharString wgsl = p_wgsl.utf8();
	if (wgsl.is_empty() || wgsl.length() > 16 * 1024 * 1024) {
		return false;
	}
	HashSet<uint32_t> reachable;
	HashMap<uint32_t, spirv_preprocess::ImageBindingInfo> images;
	// Match the runtime's pre-specialization metadata contract. Aliased
	// anisotropic samplers must not regain stage visibility from a seed.
	const Vector<uint8_t> analysis_source = spirv_preprocess::alias_anisotropic_samplers(p_source);
	spirv_preprocess::reachable_binding_keys(analysis_source, &reachable);
	spirv_preprocess::binding_image_info(analysis_source, &images);
	if (reachable.size() > 65536 || images.size() > 65536) {
		return false;
	}
	Vector<uint8_t> payload;
	append_u32(payload, wgsl.length());
	payload.resize(4 + wgsl.length());
	memcpy(payload.ptrw() + 4, wgsl.ptr(), wgsl.length());
	append_u32(payload, 1); // Analysis v1: keep runtime/harvest wire layout.
	Vector<uint32_t> keys;
	for (uint32_t key : reachable) {
		keys.push_back(key);
	}
	keys.sort();
	append_u32(payload, keys.size());
	for (uint32_t key : keys) {
		append_u32(payload, key);
	}
	keys.clear();
	for (const KeyValue<uint32_t, spirv_preprocess::ImageBindingInfo> &entry : images) {
		keys.push_back(entry.key);
	}
	keys.sort();
	append_u32(payload, keys.size());
	for (uint32_t key : keys) {
		const spirv_preprocess::ImageBindingInfo &info = images[key];
		append_u32(payload, key);
		append_u32(payload, info.dim);
		append_u32(payload, info.depth);
		append_u32(payload, info.arrayed);
		append_u32(payload, info.multisampled);
	}
	Vector<uint8_t> compressed;
	compressed.resize(Compression::get_max_compressed_buffer_size(payload.size(), Compression::MODE_ZSTD));
	const int compressed_size = Compression::compress(compressed.ptrw(), payload.ptr(), payload.size(), Compression::MODE_ZSTD);
	if (compressed_size <= 0 || uint64_t(r_cache.size()) + 20 + compressed_size > 256 * 1024 * 1024) {
		return false;
	}
	const int offset = r_cache.size();
	r_cache.resize(offset + 20 + compressed_size);
	encode_uint64(p_hash, r_cache.ptrw() + offset);
	encode_uint32(compressed_size, r_cache.ptrw() + offset + 8);
	encode_uint32(payload.size(), r_cache.ptrw() + offset + 12);
	encode_uint32(hash_murmur3_buffer(compressed.ptr(), compressed_size), r_cache.ptrw() + offset + 16);
	memcpy(r_cache.ptrw() + offset + 20, compressed.ptr(), compressed_size);
	return true;
}

} // namespace

RenderingShaderContainerFormat *ShaderBakerExportPluginPlatformWebGPU::create_shader_container_format(const Ref<EditorExportPlatform> &p_platform, const Ref<EditorExportPreset> &p_preset) {
	// Until an explicit target profile rebuilds every capability-dependent
	// define, a Vulkan/Metal editor cannot safely bake browser shader sources.
	// Native Dawn already uses the same WebGPU source-generation decisions.
	ERR_FAIL_COND_V_MSG(OS::get_singleton()->get_current_rendering_driver_name() != "webgpu", nullptr,
			"WebGPU shader baking currently requires starting the native editor with --rendering-driver webgpu.");
	source_modules.clear();
	source_bytes = 0;
	source_limit_reached = false;
	tint_cli = p_preset->get("shader_baker/tint_cli");
	if (tint_cli.is_empty()) {
		tint_cli = OS::get_singleton()->get_executable_path().get_base_dir().path_join("tint_convert_cli");
	}
	return memnew(RenderingShaderContainerFormatWebGPU);
}

bool ShaderBakerExportPluginPlatformWebGPU::matches_driver(const String &p_driver) {
	return p_driver == "webgpu";
}

void ShaderBakerExportPluginPlatformWebGPU::collect_spirv(const Vector<uint8_t> &p_spirv) {
	const uint64_t hash = source_hash(p_spirv);
	MutexLock lock(source_mutex);
	if (source_modules.has(hash)) {
		return;
	}
	if (source_modules.size() >= 16384 || source_bytes + p_spirv.size() > 256 * 1024 * 1024) {
		source_limit_reached = true;
		return;
	}
	source_modules.insert(hash, p_spirv);
	source_bytes += p_spirv.size();
}

HashMap<String, PackedByteArray> ShaderBakerExportPluginPlatformWebGPU::create_extra_files() {
	HashMap<String, PackedByteArray> files;
	String output;
	List<String> arguments;
	arguments.push_back("--fingerprint");
	if (!FileAccess::exists(tint_cli) || !run_tint(tint_cli, arguments, 10000000, output) || output.strip_edges() != WEBGPU_TRANSLATOR_FINGERPRINT) {
		WARN_PRINT("WebGPU WGSL baking skipped: shader_baker/tint_cli must point to a CLI built with this editor's translator/profile identity. Compact SPIR-V remains available.");
		source_modules.clear();
		return files;
	}
	Error error;
	Ref<DirAccess> workspace = DirAccess::create_temp("godot-webgpu-bake", false, &error);
	if (workspace.is_null()) {
		WARN_PRINT("WebGPU WGSL baking skipped: cannot create a temporary directory. Compact SPIR-V remains available.");
		source_modules.clear();
		return files;
	}
	Vector<uint64_t> hashes;
	for (const KeyValue<uint64_t, Vector<uint8_t>> &entry : source_modules) {
		hashes.push_back(entry.key);
	}
	hashes.sort();
	PackedByteArray cache;
	cache.resize(40);
	encode_uint32(0x43534757, cache.ptrw()); // WGSC.
	encode_uint32(4, cache.ptrw() + 4);
	memcpy(cache.ptrw() + 8, WEBGPU_TRANSLATOR_FINGERPRINT_BYTES, 32);
	uint32_t translated = 0;
	uint32_t failed = 0;
	EditorProgress progress("baking_webgpu_wgsl", "Baking WebGPU shaders", hashes.size(), true);
	for (int first = 0; first < hashes.size(); first += 32) {
		if (progress.step("Translating SPIR-V to WGSL...", first)) {
			failed += hashes.size() - first;
			break;
		}
		arguments.clear();
		arguments.push_back("--batch");
		HashMap<String, uint64_t> paths;
		for (int index = first; index < MIN(first + 32, hashes.size()); index++) {
			const String path = workspace->get_current_dir().path_join(itos(index) + ".spv");
			Ref<FileAccess> file = FileAccess::open(path, FileAccess::WRITE);
			if (file.is_null() || !file->store_buffer(source_modules[hashes[index]])) {
				failed++;
				continue;
			}
			file.unref();
			paths.insert(path, hashes[index]);
			arguments.push_back(path);
		}
		if (paths.is_empty()) {
			continue;
		}
		JSON json;
		Dictionary results;
		if (run_tint(tint_cli, arguments, 180000000, output) && json.parse(output) == OK && json.get_data().get_type() == Variant::DICTIONARY) {
			results = json.get_data();
		}
		for (const KeyValue<String, uint64_t> &entry : paths) {
			Variant value = results.get(entry.key, Variant());
			if (value.get_type() == Variant::STRING && append_cache_record(cache, entry.value, source_modules[entry.value], value)) {
				translated++;
			} else {
				failed++;
				if (failed <= 5) {
					const String detail = value.get_type() == Variant::DICTIONARY ? String(Dictionary(value).get("error", "invalid result")) : "missing or malformed batch result";
					print_verbose(vformat("[WebGPU shader baker] WGSL translation failed for source hash %s: %s", String::num_uint64(entry.value, 16), detail.left(2000)));
				}
			}
			workspace->remove(entry.key);
		}
	}
	if (translated > 0) {
		files.insert("wgsl_seed.bin", cache);
	}
	print_line(vformat("[WebGPU shader baker] WGSL seed: %d translated, %d failed, %d source modules; translator/profile %s", translated, failed, hashes.size(), WEBGPU_TRANSLATOR_FINGERPRINT));
	if (failed > 0 || source_limit_reached) {
		WARN_PRINT("WebGPU WGSL seed is partial; remaining shaders will use compact SPIR-V and deferred runtime translation.");
	}
	source_modules.clear();
	return files;
}
