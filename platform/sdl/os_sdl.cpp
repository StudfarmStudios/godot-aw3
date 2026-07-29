/**************************************************************************/
/*  os_sdl.cpp                                                            */
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

#include "os_sdl.h"

#include "display_server_sdl.h"

#include "core/io/file_access.h"
#include "core/os/main_loop.h"
#include "core/profiling/profiling.h"
#include "main/main.h"
#include "servers/display/display_server.h"

#include <sys/types.h>
#include <unistd.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>

void OS_SDL::initialize() {
	crash_handler.initialize();

	OS_Unix::initialize_core();
}

void OS_SDL::initialize_joypads() {
	// Joypads are driven by the SDL event loop, owned by DisplayServerSDL.
}

String OS_SDL::get_processor_name() const {
	Ref<FileAccess> f = FileAccess::open("/proc/cpuinfo", FileAccess::READ);
	ERR_FAIL_COND_V_MSG(f.is_null(), "", String("Couldn't open `/proc/cpuinfo` to get the CPU model name. Returning an empty string."));

	while (!f->eof_reached()) {
		const String line = f->get_line();
		if (line.contains("model name")) {
			return line.split(":")[1].strip_edges();
		}
	}

	ERR_FAIL_V_MSG("", String("Couldn't get the CPU model name from `/proc/cpuinfo`. Returning an empty string."));
}

void OS_SDL::finalize() {
	if (main_loop) {
		memdelete(main_loop);
	}
	main_loop = nullptr;
}

MainLoop *OS_SDL::get_main_loop() const {
	return main_loop;
}

void OS_SDL::delete_main_loop() {
	if (main_loop) {
		memdelete(main_loop);
	}
	main_loop = nullptr;
}

void OS_SDL::set_main_loop(MainLoop *p_main_loop) {
	main_loop = p_main_loop;
}

String OS_SDL::get_identifier() const {
	// Report the same identifier as the upstream Linux platform so that
	// feature tags, project settings overrides and GDExtension/C# checks
	// behave the same as on a regular Linux export.
	return "linuxbsd";
}

String OS_SDL::get_name() const {
	return "Linux";
}

bool OS_SDL::_check_internal_feature_support(const String &p_feature) {
	if (p_feature == "linux" || p_feature == "sdl") {
		return true;
	}
	if (p_feature == "kmsdrm") {
		DisplayServerSDL *ds = DisplayServerSDL::get_singleton_sdl();
		return ds && ds->get_video_driver_name() == "kmsdrm";
	}
	if (p_feature == "system_fonts") {
		return false;
	}
	if (p_feature == "pc") {
		return true;
	}
	return false;
}

uint64_t OS_SDL::get_embedded_pck_offset() const {
	Ref<FileAccess> f = FileAccess::open(get_executable_path(), FileAccess::READ);
	if (f.is_null()) {
		return 0;
	}

	// Read and check ELF magic number.
	{
		uint32_t magic = f->get_32();
		if (magic != 0x464c457f) { // 0x7F + "ELF"
			return 0;
		}
	}

	// Read program architecture bits from class field.
	int bits = f->get_8() * 32;

	// Get info about the section header table.
	int64_t section_table_pos;
	int64_t section_header_size;
	if (bits == 32) {
		section_header_size = 40;
		f->seek(0x20);
		section_table_pos = f->get_32();
		f->seek(0x30);
	} else { // 64
		section_header_size = 64;
		f->seek(0x28);
		section_table_pos = f->get_64();
		f->seek(0x3c);
	}
	int num_sections = f->get_16();
	int string_section_idx = f->get_16();

	// Load the strings table.
	uint8_t *strings;
	{
		// Jump to the strings section header.
		f->seek(section_table_pos + string_section_idx * section_header_size);

		// Read strings data size and offset.
		int64_t string_data_pos;
		int64_t string_data_size;
		if (bits == 32) {
			f->seek(f->get_position() + 0x10);
			string_data_pos = f->get_32();
			string_data_size = f->get_32();
		} else { // 64
			f->seek(f->get_position() + 0x18);
			string_data_pos = f->get_64();
			string_data_size = f->get_64();
		}

		// Read strings data.
		f->seek(string_data_pos);
		strings = (uint8_t *)memalloc(string_data_size);
		if (!strings) {
			return 0;
		}
		f->get_buffer(strings, string_data_size);
	}

	// Search for the "pck" section.
	int64_t off = 0;
	for (int i = 0; i < num_sections; ++i) {
		int64_t section_header_pos = section_table_pos + i * section_header_size;
		f->seek(section_header_pos);

		uint32_t name_offset = f->get_32();
		if (strcmp((char *)strings + name_offset, "pck") == 0) {
			if (bits == 32) {
				f->seek(section_header_pos + 0x10);
				off = f->get_32();
			} else { // 64
				f->seek(section_header_pos + 0x18);
				off = f->get_64();
			}
			break;
		}
	}
	memfree(strings);

	return off;
}

String OS_SDL::get_config_path() const {
	if (has_environment("XDG_CONFIG_HOME")) {
		if (get_environment("XDG_CONFIG_HOME").is_absolute_path()) {
			return get_environment("XDG_CONFIG_HOME");
		} else {
			WARN_PRINT_ONCE("`XDG_CONFIG_HOME` is a relative path. Ignoring its value and falling back to `$HOME/.config` or `.` per the XDG Base Directory specification.");
			return has_environment("HOME") ? get_environment("HOME").path_join(".config") : ".";
		}
	} else if (has_environment("HOME")) {
		return get_environment("HOME").path_join(".config");
	} else {
		return ".";
	}
}

String OS_SDL::get_data_path() const {
	if (has_environment("XDG_DATA_HOME")) {
		if (get_environment("XDG_DATA_HOME").is_absolute_path()) {
			return get_environment("XDG_DATA_HOME");
		} else {
			WARN_PRINT_ONCE("`XDG_DATA_HOME` is a relative path. Ignoring its value and falling back to `$HOME/.local/share` or `get_config_path()` per the XDG Base Directory specification.");
			return has_environment("HOME") ? get_environment("HOME").path_join(".local/share") : get_config_path();
		}
	} else if (has_environment("HOME")) {
		return get_environment("HOME").path_join(".local/share");
	} else {
		return get_config_path();
	}
}

String OS_SDL::get_cache_path() const {
	if (has_environment("XDG_CACHE_HOME")) {
		if (get_environment("XDG_CACHE_HOME").is_absolute_path()) {
			return get_environment("XDG_CACHE_HOME");
		} else {
			WARN_PRINT_ONCE("`XDG_CACHE_HOME` is a relative path. Ignoring its value and falling back to `$HOME/.cache` or `get_config_path()` per the XDG Base Directory specification.");
			return has_environment("HOME") ? get_environment("HOME").path_join(".cache") : get_config_path();
		}
	} else if (has_environment("HOME")) {
		return get_environment("HOME").path_join(".cache");
	} else {
		return get_config_path();
	}
}

String OS_SDL::get_system_dir(SystemDir p_dir, bool p_shared_storage) const {
	// Embedded/console-style targets rarely have XDG user dirs; fall back to HOME.
	return has_environment("HOME") ? get_environment("HOME") : ".";
}

Error OS_SDL::shell_open(const String &p_uri) {
	// No desktop environment to delegate to on a KMS/DRM console.
	return ERR_UNAVAILABLE;
}

void OS_SDL::disable_crash_handler() {
	crash_handler.disable();
}

bool OS_SDL::is_disable_crash_handler() const {
	return crash_handler.is_disabled();
}

void OS_SDL::run() {
	if (!main_loop) {
		return;
	}

	main_loop->initialize();

	while (true) {
		GodotProfileFrameMark;
		GodotProfileZone("OS_SDL::run");
		DisplayServer::get_singleton()->process_events(); // get rid of pending events
		if (Main::iteration()) {
			break;
		}
	}

	main_loop->finalize();
}

OS_SDL::OS_SDL() {
	main_loop = nullptr;

	AudioDriverManager::add_driver(&driver_sdl);

	DisplayServerSDL::register_sdl_driver();
}
