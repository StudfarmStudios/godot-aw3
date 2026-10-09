/**************************************************************************/
/*  storage_format_remap.h                                                */
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

#include <string>
#include <string_view>

namespace WebGPUStorageFormats {

// Keep these texel formats in agreement with _promote_storage_format(). Only
// rewrite the format argument of a storage-texture type, never user identifiers
// containing the same text. An empty result means no allocation/change is needed.
inline std::string remap_wgsl(std::string_view p_source, bool p_tier1, bool p_tier2) {
	struct Remap {
		std::string_view from;
		std::string_view to;
		int tier;
	};
	static constexpr Remap formats[] = {
		{ "r8unorm", "r32float", 1 },
		{ "r8snorm", "r32float", 1 },
		{ "r8uint", "r32uint", 1 },
		{ "r8sint", "r32sint", 1 },
		{ "rg8unorm", "rg32float", 1 },
		{ "rg8snorm", "rg32float", 1 },
		{ "rg8uint", "rg32uint", 1 },
		{ "rg8sint", "rg32sint", 1 },
		{ "rgb10a2unorm", "rgba16float", 2 },
		{ "rgb10a2uint", "rgba16uint", 2 },
		{ "rg11b10ufloat", "rgba16float", 2 },
		{ "r16float", "r32float", 0 },
		{ "r16uint", "r32uint", 0 },
		{ "r16sint", "r32sint", 0 },
		{ "rg16float", "rg32float", 0 },
		{ "rg16uint", "rg32uint", 0 },
		{ "rg16sint", "rg32sint", 0 },
		{ "r16unorm", "r32float", 0 },
		{ "r16snorm", "r32float", 0 },
		{ "rg16unorm", "rg32float", 0 },
		{ "rg16snorm", "rg32float", 0 },
		{ "rgba16unorm", "rgba16float", 0 },
		{ "rgba16snorm", "rgba16float", 0 },
	};
	std::string result;
	size_t copied = 0;
	size_t position = 0;
	while ((position = p_source.find("texture_storage_", position)) != std::string_view::npos) {
		// Match an actual type token rather than an identifier containing the
		// type name, and require its template opener immediately after it.
		const size_t type_end = p_source.find_first_not_of("abcdefghijklmnopqrstuvwxyz0123456789_", position);
		const auto type = p_source.substr(position, type_end - position);
		const bool boundary = position == 0 || !((p_source[position - 1] >= 'a' && p_source[position - 1] <= 'z') || (p_source[position - 1] >= 'A' && p_source[position - 1] <= 'Z') || (p_source[position - 1] >= '0' && p_source[position - 1] <= '9') || p_source[position - 1] == '_');
		position += sizeof("texture_storage_") - 1;
		if (!boundary || (type != "texture_storage_1d" && type != "texture_storage_2d" && type != "texture_storage_2d_array" && type != "texture_storage_3d")) {
			continue;
		}
		const size_t open = p_source.find_first_not_of(" \t\r\n", type_end);
		if (open == std::string_view::npos || p_source[open] != '<') {
			continue;
		}
		const size_t start = p_source.find_first_not_of(" \t\r\n", open + 1);
		if (start == std::string_view::npos) {
			break;
		}
		const size_t end = p_source.find_first_of(",> \t\r\n", start);
		if (end == std::string_view::npos) {
			break;
		}
		const auto format = p_source.substr(start, end - start);
		for (const Remap &remap : formats) {
			if (format == remap.from && !(remap.tier == 1 && p_tier1) && !(remap.tier == 2 && p_tier2)) {
				result.append(p_source.substr(copied, start - copied));
				result.append(remap.to);
				copied = end;
				break;
			}
		}
		position = end;
	}
	if (copied) {
		result.append(p_source.substr(copied));
	}
	return result;
}

} // namespace WebGPUStorageFormats
