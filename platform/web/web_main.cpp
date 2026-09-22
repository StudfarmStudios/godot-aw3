/**************************************************************************/
/*  web_main.cpp                                                          */
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

#include "display_server_web.h"
#include "godot_js.h"
#include "os_web.h"

#include "core/config/engine.h"
#include "core/io/resource_loader.h"
#include "core/os/main_loop.h"
#include "core/os/os.h"
#include "core/profiling/profiling.h"
#include "main/main.h"

#ifdef TOOLS_ENABLED
#include "core/io/file_access.h"
#include "editor/web_tools_editor_plugin.h"
#include "scene/main/scene_tree.h"
#include "scene/main/window.h" // SceneTree only forward declares it.
#endif

#include <emscripten/emscripten.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>

static OS_Web *os = nullptr;
#ifndef PROXY_TO_PTHREAD_ENABLED
static uint64_t target_ticks = 0;
#endif

static bool main_started = false;
static bool shutdown_complete = false;

#if defined(PROXY_TO_PTHREAD_ENABLED) && defined(WEBGPU_ENABLED)
static constexpr const char *APPLICATION_WORKER_WEBGPU_MARKER = "--godot-application-worker-webgpu";
static Vector<String> application_worker_args;
static bool application_worker_webgpu_device = false;
#endif

void exit_callback() {
	if (!shutdown_complete) {
		return; // Still waiting.
	}
	if (main_started) {
		Main::cleanup();
		main_started = false;
	}
	int exit_code = OS_Web::get_singleton()->get_exit_code();
	delete os; // We used a normal new, so it needs a normal delete.
	os = nullptr;
#if defined(PROXY_TO_PTHREAD_ENABLED) && defined(WEBGPU_ENABLED)
	if (application_worker_webgpu_device) {
		// RenderingContextDriverWebGPU has released its imported C wrapper by
		// this point. Destroy the raw GPUDevice in its owning Worker realm.
		godot_js_webgpu_worker_cleanup();
		application_worker_webgpu_device = false;
	}
#endif
	godot_cleanup_profiler();
	emscripten_cancel_main_loop(); // We are exiting in this iteration.
	emscripten_force_exit(exit_code); // Exit runtime.
}

void cleanup_after_sync() {
	shutdown_complete = true;
}

void main_loop_callback() {
#ifndef PROXY_TO_PTHREAD_ENABLED
	uint64_t current_ticks = os->get_ticks_usec();
#endif

	bool force_draw = DisplayServerWeb::get_singleton()->check_size_force_redraw();
	if (force_draw) {
		Main::force_redraw();
#ifndef PROXY_TO_PTHREAD_ENABLED
	} else if (current_ticks < target_ticks) {
		return; // Skip frame.
#endif
	}

#ifndef PROXY_TO_PTHREAD_ENABLED
	int max_fps = Engine::get_singleton()->get_max_fps();
	if (max_fps > 0) {
		if (current_ticks - target_ticks > 1000000) {
			// When the window loses focus, we stop getting updates and accumulate delay.
			// For this reason, if the difference is too big, we reset target ticks to the current ticks.
			target_ticks = current_ticks;
		}
		target_ticks += (uint64_t)(1000000 / max_fps);
	}
#endif

	if (os->main_loop_iterate()) {
		emscripten_cancel_main_loop(); // Cancel current loop and set the cleanup one.
		emscripten_set_main_loop(exit_callback, -1, false);
		godot_js_os_finish_async(cleanup_after_sync);
	}
}

void print_web_header() {
	// Emscripten.
	char *emscripten_version_char = godot_js_emscripten_get_version();
	String emscripten_version = vformat("Emscripten %s", emscripten_version_char);
	// `free()` is used here because it's not memory that was allocated by Godot.
	free(emscripten_version_char);

	// Build features.
	String thread_support = OS::get_singleton()->has_feature("threads")
			? "multi-threaded"
			: "single-threaded";
	String extensions_support = OS::get_singleton()->has_feature("web_extensions")
			? "GDExtension support"
			: "no GDExtension support";

	Vector<String> build_configuration = { emscripten_version, thread_support, extensions_support };
	print_line(vformat("Build configuration: %s.", String(", ").join(build_configuration)));
}

static int godot_web_main_after_webgpu(int argc, char *argv[]) {
	godot_init_profiler();

	os = new OS_Web();

#ifdef TOOLS_ENABLED
	WebToolsEditorPlugin::initialize();
#endif

	// We must override main when testing is enabled
	TEST_MAIN_OVERRIDE

	Error err = Main::setup(argv[0], argc - 1, &argv[1]);

	// Proper shutdown in case of setup failure.
	if (err != OK) {
		// Will only exit after sync.
		emscripten_set_main_loop(exit_callback, -1, false);
		godot_js_os_finish_async(cleanup_after_sync);
		if (err == ERR_HELP) { // Returned by --help and --version, so success.
			return EXIT_SUCCESS;
		}
		return EXIT_FAILURE;
	}

	print_web_header();

	main_started = true;

	// Ease up compatibility.
	ResourceLoader::set_abort_on_missing_resources(false);

	int ret = Main::start();
	os->set_exit_code(ret);
	os->get_main_loop()->initialize();
#ifdef TOOLS_ENABLED
	if (Engine::get_singleton()->is_project_manager_hint() && FileAccess::exists("/tmp/preload.zip")) {
		PackedStringArray ps;
		ps.push_back("/tmp/preload.zip");
		SceneTree::get_singleton()->get_root()->emit_signal(SNAME("files_dropped"), ps);
	}
#endif
	emscripten_set_main_loop(main_loop_callback, -1, false);
	// Immediately run the first iteration.
	// We are inside an animation frame, we want to immediately draw on the newly setup canvas.
	main_loop_callback();

	return os->get_exit_code();
}

#if defined(PROXY_TO_PTHREAD_ENABLED) && defined(WEBGPU_ENABLED)
static void application_worker_webgpu_ready(int p_error) {
	if (p_error != 0) {
		fprintf(stderr, "Application-Worker WebGPU initialization failed.\n");
		emscripten_force_exit(EXIT_FAILURE);
		return;
	}

	application_worker_webgpu_device = true;
	Vector<CharString> encoded_args;
	Vector<char *> argv;
	encoded_args.resize(application_worker_args.size());
	argv.resize(application_worker_args.size());
	for (int i = 0; i < application_worker_args.size(); i++) {
		encoded_args.write[i] = application_worker_args[i].utf8();
		argv.write[i] = const_cast<char *>(encoded_args[i].get_data());
	}

	godot_web_main_after_webgpu(argv.size(), argv.ptrw());
	application_worker_args.clear();
}
#endif

/// When calling main, it is assumed FS is setup and synced.
extern EMSCRIPTEN_KEEPALIVE int godot_web_main(int argc, char *argv[]) {
#if defined(PROXY_TO_PTHREAD_ENABLED) && defined(WEBGPU_ENABLED)
	bool worker_webgpu_requested = false;
	application_worker_args.clear();
	for (int i = 0; i < argc; i++) {
		if (i > 0 && strcmp(argv[i], APPLICATION_WORKER_WEBGPU_MARKER) == 0) {
			worker_webgpu_requested = true;
			continue;
		}
		application_worker_args.push_back(String::utf8(argv[i]));
	}
	if (worker_webgpu_requested) {
		godot_js_webgpu_worker_preinitialize(application_worker_webgpu_ready);
		// Let the Worker's event loop run the adapter/device Promises. The
		// callback above resumes normal Godot startup without Asyncify.
		emscripten_exit_with_live_runtime();
		return EXIT_SUCCESS;
	}
	application_worker_args.clear();
#endif

	return godot_web_main_after_webgpu(argc, argv);
}
