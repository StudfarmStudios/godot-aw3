/**************************************************************************/
/*  rendering_context_driver_vulkan_sdl.cpp                               */
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

#ifdef VULKAN_ENABLED

#include "rendering_context_driver_vulkan_sdl.h"

#include "core/variant/variant.h"

#include <SDL3/SDL_vulkan.h>
#include <drivers/vulkan/godot_vulkan.h>

#include <cstring>

const char *RenderingContextDriverVulkanSDL::_get_platform_surface_extension() const {
	// SDL reports [VK_KHR_surface, <platform surface extension>]; which
	// platform extension depends on the active video driver (x11, wayland,
	// or VK_KHR_display under kmsdrm).
	Uint32 count = 0;
	const char *const *extensions = SDL_Vulkan_GetInstanceExtensions(&count);
	ERR_FAIL_NULL_V_MSG(extensions, nullptr, vformat("SDL: Failed to query Vulkan instance extensions: %s", SDL_GetError()));
	for (Uint32 i = 0; i < count; i++) {
		if (strcmp(extensions[i], VK_KHR_SURFACE_EXTENSION_NAME) != 0) {
			return extensions[i];
		}
	}
	return nullptr;
}

RenderingContextDriver::SurfaceID RenderingContextDriverVulkanSDL::surface_create(const void *p_platform_data) {
	const WindowPlatformData *wpd = (const WindowPlatformData *)(p_platform_data);

	VkSurfaceKHR vk_surface = VK_NULL_HANDLE;
	if (!SDL_Vulkan_CreateSurface(wpd->window, instance_get(), get_allocation_callbacks(VK_OBJECT_TYPE_SURFACE_KHR), &vk_surface)) {
		ERR_FAIL_V_MSG(SurfaceID(), vformat("SDL: Failed to create Vulkan surface: %s", SDL_GetError()));
	}

	Surface *surface = memnew(Surface);
	surface->vk_surface = vk_surface;
	return SurfaceID(surface);
}

RenderingContextDriverVulkanSDL::RenderingContextDriverVulkanSDL() {
	SDL_Vulkan_LoadLibrary(nullptr);
}

RenderingContextDriverVulkanSDL::~RenderingContextDriverVulkanSDL() {
	SDL_Vulkan_UnloadLibrary();
}

#endif // VULKAN_ENABLED
