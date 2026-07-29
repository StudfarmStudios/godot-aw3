/**************************************************************************/
/*  display_server_sdl.cpp                                                */
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

#include "display_server_sdl.h"

#include "key_mapping_sdl.h"

#include "core/config/project_settings.h"
#include "core/os/os.h"
#include "core/string/print_string.h"

#ifdef SDL_ENABLED
#include "drivers/sdl/joypad_sdl.h"
#endif

#ifdef GLES3_ENABLED
#include "drivers/gles3/rasterizer_gles3.h"
#if defined(GLAD_ENABLED) && defined(EGL_ENABLED)
#include "platform_egl.h"
#endif
#endif

#if defined(RD_ENABLED)
#include "rendering_context_driver_vulkan_sdl.h"

#include "servers/rendering/renderer_rd/renderer_compositor_rd.h"
#include "servers/rendering/rendering_device.h"
#endif

DisplayServerSDL *DisplayServerSDL::singleton = nullptr;

// The SDL joypad driver (drivers/sdl/joypad_sdl.cpp) drains the event queue
// with SDL_PollEvent and only looks at joystick/gamepad events, so the
// display server extracts everything outside that range first with
// SDL_PeepEvents and then lets the joypad driver poll the rest.
static constexpr Uint32 EVENT_RANGE_1_MIN = SDL_EVENT_FIRST;
static constexpr Uint32 EVENT_RANGE_1_MAX = SDL_EVENT_JOYSTICK_AXIS_MOTION - 1;
static constexpr Uint32 EVENT_RANGE_2_MIN = SDL_EVENT_FINGER_DOWN;
static constexpr Uint32 EVENT_RANGE_2_MAX = SDL_EVENT_LAST;

Vector<String> DisplayServerSDL::get_rendering_drivers_func() {
	Vector<String> drivers;
#ifdef VULKAN_ENABLED
	drivers.push_back("vulkan");
#endif
#ifdef GLES3_ENABLED
	drivers.push_back("opengl3");
	drivers.push_back("opengl3_es");
#endif
	return drivers;
}

DisplayServer *DisplayServerSDL::create_func(const String &p_rendering_driver, DisplayServerEnums::WindowMode p_mode, DisplayServerEnums::VSyncMode p_vsync_mode, uint32_t p_flags, const Vector2i *p_position, const Vector2i &p_resolution, int p_screen, DisplayServerEnums::Context p_context, int64_t p_parent_window, Error &r_error) {
	DisplayServer *ds = memnew(DisplayServerSDL(p_rendering_driver, p_mode, p_vsync_mode, p_flags, p_position, p_resolution, p_screen, p_context, p_parent_window, r_error));
	if (r_error != OK) {
		memdelete(ds);
		ds = nullptr;
		ERR_PRINT("Unable to create the SDL display server.");
	}
	return ds;
}

void DisplayServerSDL::register_sdl_driver() {
	register_create_function("sdl", create_func, get_rendering_drivers_func);
}

void DisplayServerSDL::_dispatch_input_events(const Ref<InputEvent> &p_event) {
	if (singleton) {
		singleton->_dispatch_input_event(p_event);
	}
}

void DisplayServerSDL::_dispatch_input_event(const Ref<InputEvent> &p_event) {
	if (input_event_callback.is_valid()) {
		input_event_callback.call(p_event);
	}
}

void DisplayServerSDL::_send_window_event(DisplayServerEnums::WindowEvent p_event) {
	if (window_event_callback.is_valid()) {
		window_event_callback.call(int(p_event));
	}
}

bool DisplayServerSDL::has_feature(DisplayServerEnums::Feature p_feature) const {
	switch (p_feature) {
		case DisplayServerEnums::FEATURE_MOUSE:
		case DisplayServerEnums::FEATURE_MOUSE_WARP:
		case DisplayServerEnums::FEATURE_CLIPBOARD:
		case DisplayServerEnums::FEATURE_CURSOR_SHAPE:
		case DisplayServerEnums::FEATURE_CUSTOM_CURSOR_SHAPE:
		case DisplayServerEnums::FEATURE_SWAP_BUFFERS:
		case DisplayServerEnums::FEATURE_HIDPI:
		case DisplayServerEnums::FEATURE_ICON:
			return true;
		case DisplayServerEnums::FEATURE_CLIPBOARD_PRIMARY:
			return video_driver_name != "kmsdrm";
#ifdef TOUCH_ENABLED
		case DisplayServerEnums::FEATURE_TOUCHSCREEN: {
			int count = 0;
			SDL_TouchID *devices = SDL_GetTouchDevices(&count);
			if (devices) {
				SDL_free(devices);
			}
			return count > 0;
		}
#endif
		default:
			return false;
	}
}

// Screens.

SDL_DisplayID DisplayServerSDL::_get_display_id(int p_screen) const {
	if (p_screen < 0) {
		// SCREEN_OF_MAIN_WINDOW and the other special values: single window,
		// so they all resolve to the display the window is on.
		SDL_DisplayID id = window ? SDL_GetDisplayForWindow(window) : 0;
		if (id != 0) {
			return id;
		}
		return SDL_GetPrimaryDisplay();
	}

	int count = 0;
	SDL_DisplayID *displays = SDL_GetDisplays(&count);
	SDL_DisplayID id = 0;
	if (displays) {
		if (p_screen < count) {
			id = displays[p_screen];
		}
		SDL_free(displays);
	}
	if (id == 0) {
		id = SDL_GetPrimaryDisplay();
	}
	return id;
}

int DisplayServerSDL::get_screen_count() const {
	int count = 0;
	SDL_DisplayID *displays = SDL_GetDisplays(&count);
	if (displays) {
		SDL_free(displays);
	}
	return count;
}

int DisplayServerSDL::get_primary_screen() const {
	SDL_DisplayID primary = SDL_GetPrimaryDisplay();
	int count = 0;
	SDL_DisplayID *displays = SDL_GetDisplays(&count);
	int index = 0;
	if (displays) {
		for (int i = 0; i < count; i++) {
			if (displays[i] == primary) {
				index = i;
				break;
			}
		}
		SDL_free(displays);
	}
	return index;
}

Point2i DisplayServerSDL::screen_get_position(int p_screen) const {
	SDL_Rect rect = {};
	if (!SDL_GetDisplayBounds(_get_display_id(p_screen), &rect)) {
		return Point2i();
	}
	return Point2i(rect.x, rect.y);
}

Size2i DisplayServerSDL::screen_get_size(int p_screen) const {
	SDL_Rect rect = {};
	if (!SDL_GetDisplayBounds(_get_display_id(p_screen), &rect)) {
		return Size2i();
	}
	return Size2i(rect.w, rect.h);
}

Rect2i DisplayServerSDL::screen_get_usable_rect(int p_screen) const {
	SDL_Rect rect = {};
	if (!SDL_GetDisplayUsableBounds(_get_display_id(p_screen), &rect)) {
		return Rect2i(Point2i(), screen_get_size(p_screen));
	}
	return Rect2i(rect.x, rect.y, rect.w, rect.h);
}

int DisplayServerSDL::screen_get_dpi(int p_screen) const {
	float scale = SDL_GetDisplayContentScale(_get_display_id(p_screen));
	if (scale <= 0.0f) {
		scale = 1.0f;
	}
	return Math::round(96.0f * scale);
}

float DisplayServerSDL::screen_get_scale(int p_screen) const {
	float scale = SDL_GetDisplayContentScale(_get_display_id(p_screen));
	return scale > 0.0f ? scale : 1.0f;
}

float DisplayServerSDL::screen_get_max_scale() const {
	float max_scale = 1.0f;
	int count = 0;
	SDL_DisplayID *displays = SDL_GetDisplays(&count);
	if (displays) {
		for (int i = 0; i < count; i++) {
			float scale = SDL_GetDisplayContentScale(displays[i]);
			max_scale = MAX(max_scale, scale);
		}
		SDL_free(displays);
	}
	return max_scale;
}

float DisplayServerSDL::screen_get_refresh_rate(int p_screen) const {
	const SDL_DisplayMode *mode = SDL_GetDesktopDisplayMode(_get_display_id(p_screen));
	if (mode && mode->refresh_rate > 0.0f) {
		return mode->refresh_rate;
	}
	return SCREEN_REFRESH_RATE_FALLBACK;
}

// Windows.

Vector<DisplayServerEnums::WindowID> DisplayServerSDL::get_window_list() const {
	Vector<DisplayServerEnums::WindowID> list;
	list.push_back(DisplayServerEnums::MAIN_WINDOW_ID);
	return list;
}

void DisplayServerSDL::show_window(DisplayServerEnums::WindowID p_id) {
	if (p_id == DisplayServerEnums::MAIN_WINDOW_ID && window) {
		SDL_ShowWindow(window);
	}
}

void DisplayServerSDL::window_attach_instance_id(ObjectID p_instance, DisplayServerEnums::WindowID p_window) {
	window_attached_instance_id = p_instance;
}

ObjectID DisplayServerSDL::window_get_attached_instance_id(DisplayServerEnums::WindowID p_window) const {
	return window_attached_instance_id;
}

void DisplayServerSDL::window_set_rect_changed_callback(const Callable &p_callable, DisplayServerEnums::WindowID p_window) {
	rect_changed_callback = p_callable;
}

void DisplayServerSDL::window_set_window_event_callback(const Callable &p_callable, DisplayServerEnums::WindowID p_window) {
	window_event_callback = p_callable;
}

void DisplayServerSDL::window_set_input_event_callback(const Callable &p_callable, DisplayServerEnums::WindowID p_window) {
	input_event_callback = p_callable;
}

void DisplayServerSDL::window_set_input_text_callback(const Callable &p_callable, DisplayServerEnums::WindowID p_window) {
	input_text_callback = p_callable;
}

void DisplayServerSDL::window_set_drop_files_callback(const Callable &p_callable, DisplayServerEnums::WindowID p_window) {
	drop_files_callback = p_callable;
}

void DisplayServerSDL::window_set_title(const String &p_title, DisplayServerEnums::WindowID p_window) {
	if (window) {
		SDL_SetWindowTitle(window, p_title.utf8().get_data());
	}
}

int DisplayServerSDL::window_get_current_screen(DisplayServerEnums::WindowID p_window) const {
	if (!window) {
		return 0;
	}
	SDL_DisplayID id = SDL_GetDisplayForWindow(window);
	int count = 0;
	SDL_DisplayID *displays = SDL_GetDisplays(&count);
	int index = 0;
	if (displays) {
		for (int i = 0; i < count; i++) {
			if (displays[i] == id) {
				index = i;
				break;
			}
		}
		SDL_free(displays);
	}
	return index;
}

Point2i DisplayServerSDL::window_get_position(DisplayServerEnums::WindowID p_window) const {
	int x = 0, y = 0;
	if (window) {
		SDL_GetWindowPosition(window, &x, &y);
	}
	return Point2i(x, y);
}

Point2i DisplayServerSDL::window_get_position_with_decorations(DisplayServerEnums::WindowID p_window) const {
	return window_get_position(p_window);
}

void DisplayServerSDL::window_set_position(const Point2i &p_position, DisplayServerEnums::WindowID p_window) {
	if (window) {
		SDL_SetWindowPosition(window, p_position.x, p_position.y);
	}
}

void DisplayServerSDL::window_set_max_size(const Size2i p_size, DisplayServerEnums::WindowID p_window) {
	if (window && p_size != Size2i()) {
		SDL_SetWindowMaximumSize(window, p_size.x, p_size.y);
	}
}

Size2i DisplayServerSDL::window_get_max_size(DisplayServerEnums::WindowID p_window) const {
	int w = 0, h = 0;
	if (window) {
		SDL_GetWindowMaximumSize(window, &w, &h);
	}
	return Size2i(w, h);
}

void DisplayServerSDL::window_set_min_size(const Size2i p_size, DisplayServerEnums::WindowID p_window) {
	if (window && p_size != Size2i()) {
		SDL_SetWindowMinimumSize(window, p_size.x, p_size.y);
	}
}

Size2i DisplayServerSDL::window_get_min_size(DisplayServerEnums::WindowID p_window) const {
	int w = 0, h = 0;
	if (window) {
		SDL_GetWindowMinimumSize(window, &w, &h);
	}
	return Size2i(w, h);
}

void DisplayServerSDL::window_set_size(const Size2i p_size, DisplayServerEnums::WindowID p_window) {
	if (window) {
		SDL_SetWindowSize(window, p_size.x, p_size.y);
	}
}

Size2i DisplayServerSDL::window_get_size(DisplayServerEnums::WindowID p_window) const {
	int w = 0, h = 0;
	if (window) {
		SDL_GetWindowSizeInPixels(window, &w, &h);
	}
	return Size2i(w, h);
}

Size2i DisplayServerSDL::window_get_size_with_decorations(DisplayServerEnums::WindowID p_window) const {
	return window_get_size(p_window);
}

void DisplayServerSDL::window_set_mode(DisplayServerEnums::WindowMode p_mode, DisplayServerEnums::WindowID p_window) {
	if (!window) {
		return;
	}
	switch (p_mode) {
		case DisplayServerEnums::WINDOW_MODE_WINDOWED:
			SDL_SetWindowFullscreen(window, false);
			SDL_RestoreWindow(window);
			break;
		case DisplayServerEnums::WINDOW_MODE_MINIMIZED:
			SDL_MinimizeWindow(window);
			break;
		case DisplayServerEnums::WINDOW_MODE_MAXIMIZED:
			SDL_SetWindowFullscreen(window, false);
			SDL_MaximizeWindow(window);
			break;
		case DisplayServerEnums::WINDOW_MODE_FULLSCREEN:
		case DisplayServerEnums::WINDOW_MODE_EXCLUSIVE_FULLSCREEN:
			SDL_SetWindowFullscreen(window, true);
			break;
	}
	window_mode = p_mode;
}

DisplayServerEnums::WindowMode DisplayServerSDL::window_get_mode(DisplayServerEnums::WindowID p_window) const {
	if (!window) {
		return DisplayServerEnums::WINDOW_MODE_WINDOWED;
	}
	SDL_WindowFlags flags = SDL_GetWindowFlags(window);
	if (flags & SDL_WINDOW_FULLSCREEN) {
		return window_mode == DisplayServerEnums::WINDOW_MODE_EXCLUSIVE_FULLSCREEN
				? DisplayServerEnums::WINDOW_MODE_EXCLUSIVE_FULLSCREEN
				: DisplayServerEnums::WINDOW_MODE_FULLSCREEN;
	}
	if (flags & SDL_WINDOW_MINIMIZED) {
		return DisplayServerEnums::WINDOW_MODE_MINIMIZED;
	}
	if (flags & SDL_WINDOW_MAXIMIZED) {
		return DisplayServerEnums::WINDOW_MODE_MAXIMIZED;
	}
	return DisplayServerEnums::WINDOW_MODE_WINDOWED;
}

static int _vsync_mode_to_interval(DisplayServerEnums::VSyncMode p_mode) {
	switch (p_mode) {
		case DisplayServerEnums::VSYNC_DISABLED:
		case DisplayServerEnums::VSYNC_MAILBOX:
			return 0;
		case DisplayServerEnums::VSYNC_ADAPTIVE:
			return -1;
		case DisplayServerEnums::VSYNC_ENABLED:
		default:
			return 1;
	}
}

void DisplayServerSDL::window_set_vsync_mode(DisplayServerEnums::VSyncMode p_vsync_mode, DisplayServerEnums::WindowID p_window) {
	vsync_mode = p_vsync_mode;
#if defined(RD_ENABLED)
	if (rendering_context) {
		rendering_context->window_set_vsync_mode(DisplayServerEnums::MAIN_WINDOW_ID, p_vsync_mode);
		return;
	}
#endif
	if (gl_context) {
		int interval = _vsync_mode_to_interval(p_vsync_mode);
		if (!SDL_GL_SetSwapInterval(interval) && interval == -1) {
			// Adaptive vsync not supported; fall back to regular vsync.
			SDL_GL_SetSwapInterval(1);
			vsync_mode = DisplayServerEnums::VSYNC_ENABLED;
		}
	}
}

DisplayServerEnums::VSyncMode DisplayServerSDL::window_get_vsync_mode(DisplayServerEnums::WindowID p_window) const {
#if defined(RD_ENABLED)
	if (rendering_context) {
		return rendering_context->window_get_vsync_mode(DisplayServerEnums::MAIN_WINDOW_ID);
	}
#endif
	return vsync_mode;
}

void DisplayServerSDL::window_set_flag(DisplayServerEnums::WindowFlags p_flag, bool p_enabled, DisplayServerEnums::WindowID p_window) {
	if (!window) {
		return;
	}
	switch (p_flag) {
		case DisplayServerEnums::WINDOW_FLAG_RESIZE_DISABLED:
			SDL_SetWindowResizable(window, !p_enabled);
			break;
		case DisplayServerEnums::WINDOW_FLAG_BORDERLESS:
			SDL_SetWindowBordered(window, !p_enabled);
			break;
		case DisplayServerEnums::WINDOW_FLAG_ALWAYS_ON_TOP:
			SDL_SetWindowAlwaysOnTop(window, p_enabled);
			break;
		default:
			break;
	}
	if (p_enabled) {
		window_flags |= (1 << p_flag);
	} else {
		window_flags &= ~(uint32_t)(1 << p_flag);
	}
}

bool DisplayServerSDL::window_get_flag(DisplayServerEnums::WindowFlags p_flag, DisplayServerEnums::WindowID p_window) const {
	return (window_flags & (1 << p_flag)) != 0;
}

void DisplayServerSDL::window_move_to_foreground(DisplayServerEnums::WindowID p_window) {
	if (window) {
		SDL_RaiseWindow(window);
	}
}

bool DisplayServerSDL::window_is_focused(DisplayServerEnums::WindowID p_window) const {
	return window && (SDL_GetWindowFlags(window) & SDL_WINDOW_INPUT_FOCUS);
}

bool DisplayServerSDL::window_can_draw(DisplayServerEnums::WindowID p_window) const {
	return window && !(SDL_GetWindowFlags(window) & SDL_WINDOW_MINIMIZED);
}

bool DisplayServerSDL::can_any_window_draw() const {
	return window_can_draw();
}

int64_t DisplayServerSDL::window_get_native_handle(DisplayServerEnums::HandleType p_handle_type, DisplayServerEnums::WindowID p_window) const {
	switch (p_handle_type) {
		case DisplayServerEnums::WINDOW_HANDLE:
			return (int64_t)(uint64_t)window;
		case DisplayServerEnums::OPENGL_CONTEXT:
			return (int64_t)(uint64_t)gl_context;
		default:
			return 0;
	}
}

// Mouse.

void DisplayServerSDL::_mouse_update_mode() {
	DisplayServerEnums::MouseMode wanted_mouse_mode = mouse_mode_override_enabled
			? mouse_mode_override
			: mouse_mode_base;

	if (wanted_mouse_mode == mouse_mode || !window) {
		return;
	}

	switch (wanted_mouse_mode) {
		case DisplayServerEnums::MOUSE_MODE_VISIBLE:
			SDL_SetWindowRelativeMouseMode(window, false);
			SDL_SetWindowMouseGrab(window, false);
			SDL_ShowCursor();
			break;
		case DisplayServerEnums::MOUSE_MODE_HIDDEN:
			SDL_SetWindowRelativeMouseMode(window, false);
			SDL_SetWindowMouseGrab(window, false);
			SDL_HideCursor();
			break;
		case DisplayServerEnums::MOUSE_MODE_CAPTURED:
			SDL_SetWindowRelativeMouseMode(window, true);
			break;
		case DisplayServerEnums::MOUSE_MODE_CONFINED:
			SDL_SetWindowRelativeMouseMode(window, false);
			SDL_SetWindowMouseGrab(window, true);
			SDL_ShowCursor();
			break;
		case DisplayServerEnums::MOUSE_MODE_CONFINED_HIDDEN:
			SDL_SetWindowRelativeMouseMode(window, false);
			SDL_SetWindowMouseGrab(window, true);
			SDL_HideCursor();
			break;
		default:
			break;
	}

	mouse_mode = wanted_mouse_mode;
}

void DisplayServerSDL::mouse_set_mode(DisplayServerEnums::MouseMode p_mode) {
	ERR_FAIL_INDEX(p_mode, DisplayServerEnums::MOUSE_MODE_MAX);
	if (p_mode == mouse_mode_base) {
		return;
	}
	mouse_mode_base = p_mode;
	_mouse_update_mode();
}

DisplayServerEnums::MouseMode DisplayServerSDL::mouse_get_mode() const {
	return mouse_mode;
}

void DisplayServerSDL::mouse_set_mode_override(DisplayServerEnums::MouseMode p_mode) {
	ERR_FAIL_INDEX(p_mode, DisplayServerEnums::MOUSE_MODE_MAX);
	if (p_mode == mouse_mode_override) {
		return;
	}
	mouse_mode_override = p_mode;
	_mouse_update_mode();
}

DisplayServerEnums::MouseMode DisplayServerSDL::mouse_get_mode_override() const {
	return mouse_mode_override;
}

void DisplayServerSDL::mouse_set_mode_override_enabled(bool p_override_enabled) {
	if (p_override_enabled == mouse_mode_override_enabled) {
		return;
	}
	mouse_mode_override_enabled = p_override_enabled;
	_mouse_update_mode();
}

bool DisplayServerSDL::mouse_is_mode_override_enabled() const {
	return mouse_mode_override_enabled;
}

void DisplayServerSDL::warp_mouse(const Point2i &p_position) {
	if (window) {
		float density = SDL_GetWindowPixelDensity(window);
		if (density <= 0.0f) {
			density = 1.0f;
		}
		SDL_WarpMouseInWindow(window, p_position.x / density, p_position.y / density);
	}
}

Point2i DisplayServerSDL::mouse_get_position() const {
	float x = 0, y = 0;
	SDL_GetMouseState(&x, &y);
	float density = window ? SDL_GetWindowPixelDensity(window) : 1.0f;
	if (density <= 0.0f) {
		density = 1.0f;
	}
	return Point2i(Math::round(x * density), Math::round(y * density));
}

BitField<MouseButtonMask> DisplayServerSDL::mouse_get_button_state() const {
	SDL_MouseButtonFlags state = SDL_GetMouseState(nullptr, nullptr);
	BitField<MouseButtonMask> mask = {};
	if (state & SDL_BUTTON_LMASK) {
		mask.set_flag(MouseButtonMask::LEFT);
	}
	if (state & SDL_BUTTON_MMASK) {
		mask.set_flag(MouseButtonMask::MIDDLE);
	}
	if (state & SDL_BUTTON_RMASK) {
		mask.set_flag(MouseButtonMask::RIGHT);
	}
	if (state & SDL_BUTTON_X1MASK) {
		mask.set_flag(MouseButtonMask::MB_XBUTTON1);
	}
	if (state & SDL_BUTTON_X2MASK) {
		mask.set_flag(MouseButtonMask::MB_XBUTTON2);
	}
	return mask;
}

// Clipboard.

void DisplayServerSDL::clipboard_set(const String &p_text) {
	SDL_SetClipboardText(p_text.utf8().get_data());
}

String DisplayServerSDL::clipboard_get() const {
	char *text = SDL_GetClipboardText();
	String result = String::utf8(text);
	SDL_free(text);
	return result;
}

void DisplayServerSDL::clipboard_set_primary(const String &p_text) {
	SDL_SetPrimarySelectionText(p_text.utf8().get_data());
}

String DisplayServerSDL::clipboard_get_primary() const {
	char *text = SDL_GetPrimarySelectionText();
	String result = String::utf8(text);
	SDL_free(text);
	return result;
}

// Cursor.

static SDL_SystemCursor _cursor_shape_to_sdl(DisplayServerEnums::CursorShape p_shape) {
	switch (p_shape) {
		case DisplayServerEnums::CURSOR_ARROW:
			return SDL_SYSTEM_CURSOR_DEFAULT;
		case DisplayServerEnums::CURSOR_IBEAM:
			return SDL_SYSTEM_CURSOR_TEXT;
		case DisplayServerEnums::CURSOR_POINTING_HAND:
			return SDL_SYSTEM_CURSOR_POINTER;
		case DisplayServerEnums::CURSOR_CROSS:
			return SDL_SYSTEM_CURSOR_CROSSHAIR;
		case DisplayServerEnums::CURSOR_WAIT:
			return SDL_SYSTEM_CURSOR_WAIT;
		case DisplayServerEnums::CURSOR_BUSY:
			return SDL_SYSTEM_CURSOR_PROGRESS;
		case DisplayServerEnums::CURSOR_DRAG:
		case DisplayServerEnums::CURSOR_MOVE:
			return SDL_SYSTEM_CURSOR_MOVE;
		case DisplayServerEnums::CURSOR_CAN_DROP:
			return SDL_SYSTEM_CURSOR_POINTER;
		case DisplayServerEnums::CURSOR_FORBIDDEN:
			return SDL_SYSTEM_CURSOR_NOT_ALLOWED;
		case DisplayServerEnums::CURSOR_VSIZE:
		case DisplayServerEnums::CURSOR_VSPLIT:
			return SDL_SYSTEM_CURSOR_NS_RESIZE;
		case DisplayServerEnums::CURSOR_HSIZE:
		case DisplayServerEnums::CURSOR_HSPLIT:
			return SDL_SYSTEM_CURSOR_EW_RESIZE;
		case DisplayServerEnums::CURSOR_BDIAGSIZE:
			return SDL_SYSTEM_CURSOR_NESW_RESIZE;
		case DisplayServerEnums::CURSOR_FDIAGSIZE:
			return SDL_SYSTEM_CURSOR_NWSE_RESIZE;
		case DisplayServerEnums::CURSOR_HELP:
		default:
			return SDL_SYSTEM_CURSOR_DEFAULT;
	}
}

void DisplayServerSDL::cursor_set_shape(DisplayServerEnums::CursorShape p_shape) {
	ERR_FAIL_INDEX(p_shape, DisplayServerEnums::CURSOR_MAX);
	cursor_shape = p_shape;

	if (custom_cursors[p_shape]) {
		SDL_SetCursor(custom_cursors[p_shape]);
		return;
	}
	if (!cursors[p_shape]) {
		cursors[p_shape] = SDL_CreateSystemCursor(_cursor_shape_to_sdl(p_shape));
	}
	if (cursors[p_shape]) {
		SDL_SetCursor(cursors[p_shape]);
	}
}

DisplayServerEnums::CursorShape DisplayServerSDL::cursor_get_shape() const {
	return cursor_shape;
}

static SDL_Surface *_image_to_sdl_surface(const Ref<Image> &p_image) {
	Ref<Image> image = p_image->duplicate();
	if (image->get_format() != Image::FORMAT_RGBA8) {
		image->convert(Image::FORMAT_RGBA8);
	}
	int w = image->get_width();
	int h = image->get_height();
	SDL_Surface *surface = SDL_CreateSurface(w, h, SDL_PIXELFORMAT_RGBA32);
	if (!surface) {
		return nullptr;
	}
	Vector<uint8_t> data = image->get_data();
	const uint8_t *src = data.ptr();
	uint8_t *dst = (uint8_t *)surface->pixels;
	for (int y = 0; y < h; y++) {
		memcpy(dst + y * surface->pitch, src + y * w * 4, w * 4);
	}
	return surface;
}

void DisplayServerSDL::cursor_set_custom_image(const Ref<Resource> &p_cursor, DisplayServerEnums::CursorShape p_shape, const Vector2 &p_hotspot) {
	ERR_FAIL_INDEX(p_shape, DisplayServerEnums::CURSOR_MAX);

	if (p_cursor.is_valid()) {
		Ref<Image> image = _get_cursor_image_from_resource(p_cursor, p_hotspot);
		ERR_FAIL_COND(image.is_null());

		SDL_Surface *surface = _image_to_sdl_surface(image);
		ERR_FAIL_NULL_MSG(surface, vformat("SDL: Failed to create cursor surface: %s", SDL_GetError()));

		SDL_Cursor *cursor = SDL_CreateColorCursor(surface, (int)p_hotspot.x, (int)p_hotspot.y);
		SDL_DestroySurface(surface);
		ERR_FAIL_NULL_MSG(cursor, vformat("SDL: Failed to create color cursor: %s", SDL_GetError()));

		if (custom_cursors[p_shape]) {
			SDL_DestroyCursor(custom_cursors[p_shape]);
		}
		custom_cursors[p_shape] = cursor;
	} else {
		if (custom_cursors[p_shape]) {
			SDL_DestroyCursor(custom_cursors[p_shape]);
			custom_cursors[p_shape] = nullptr;
		}
	}

	if (p_shape == cursor_shape) {
		cursor_set_shape(cursor_shape);
	}
}

void DisplayServerSDL::set_icon(const Ref<Image> &p_icon) {
	if (!window || p_icon.is_null()) {
		return;
	}
	SDL_Surface *surface = _image_to_sdl_surface(p_icon);
	ERR_FAIL_NULL_MSG(surface, vformat("SDL: Failed to create icon surface: %s", SDL_GetError()));
	SDL_SetWindowIcon(window, surface);
	SDL_DestroySurface(surface);
}

// Events.

static void _set_key_modifier_state(Ref<InputEventWithModifiers> p_event, SDL_Keymod p_mod) {
	p_event->set_shift_pressed(p_mod & SDL_KMOD_SHIFT);
	p_event->set_ctrl_pressed(p_mod & SDL_KMOD_CTRL);
	p_event->set_alt_pressed(p_mod & SDL_KMOD_ALT);
	p_event->set_meta_pressed(p_mod & SDL_KMOD_GUI);
}

void DisplayServerSDL::_handle_key_event(const SDL_KeyboardEvent &p_event) {
	Ref<InputEventKey> k;
	k.instantiate();
	k->set_window_id(DisplayServerEnums::MAIN_WINDOW_ID);
	k->set_pressed(p_event.down);
	k->set_echo(p_event.repeat);

	Key keycode = KeyMappingSDL::to_keycode(p_event.key);
	k->set_keycode(keycode);
	k->set_physical_keycode(KeyMappingSDL::to_physical_keycode(p_event.scancode));
	k->set_key_label(keycode);
	k->set_unicode(KeyMappingSDL::to_unicode(p_event.key, p_event.mod));

	switch (p_event.scancode) {
		case SDL_SCANCODE_LCTRL:
		case SDL_SCANCODE_LSHIFT:
		case SDL_SCANCODE_LALT:
		case SDL_SCANCODE_LGUI:
			k->set_location(KeyLocation::LEFT);
			break;
		case SDL_SCANCODE_RCTRL:
		case SDL_SCANCODE_RSHIFT:
		case SDL_SCANCODE_RALT:
		case SDL_SCANCODE_RGUI:
			k->set_location(KeyLocation::RIGHT);
			break;
		default:
			break;
	}

	_set_key_modifier_state(k, p_event.mod);

	Input::get_singleton()->parse_input_event(k);
}

static MouseButton _sdl_button_to_godot(Uint8 p_button) {
	switch (p_button) {
		case SDL_BUTTON_LEFT:
			return MouseButton::LEFT;
		case SDL_BUTTON_MIDDLE:
			return MouseButton::MIDDLE;
		case SDL_BUTTON_RIGHT:
			return MouseButton::RIGHT;
		case SDL_BUTTON_X1:
			return MouseButton::MB_XBUTTON1;
		case SDL_BUTTON_X2:
			return MouseButton::MB_XBUTTON2;
		default:
			return MouseButton::NONE;
	}
}

void DisplayServerSDL::_handle_mouse_button_event(const SDL_MouseButtonEvent &p_event) {
	MouseButton button = _sdl_button_to_godot(p_event.button);
	if (button == MouseButton::NONE) {
		return;
	}

	float density = window ? SDL_GetWindowPixelDensity(window) : 1.0f;
	if (density <= 0.0f) {
		density = 1.0f;
	}

	Ref<InputEventMouseButton> mb;
	mb.instantiate();
	mb->set_window_id(DisplayServerEnums::MAIN_WINDOW_ID);
	mb->set_button_index(button);
	mb->set_pressed(p_event.down);
	mb->set_double_click(p_event.down && p_event.clicks == 2);
	mb->set_position(Vector2(p_event.x, p_event.y) * density);
	mb->set_global_position(mb->get_position());
	mb->set_button_mask(mouse_get_button_state());
	_set_key_modifier_state(mb, SDL_GetModState());

	Input::get_singleton()->parse_input_event(mb);
}

int DisplayServerSDL::_get_touch_index(Sint64 p_finger_id, bool p_pressed) {
	if (touch_ids.has(p_finger_id)) {
		int index = touch_ids[p_finger_id];
		if (!p_pressed) {
			touch_ids.erase(p_finger_id);
		}
		return index;
	}
	if (!p_pressed) {
		return -1;
	}
	// Allocate the lowest free index.
	int index = 0;
	while (true) {
		bool used = false;
		for (const KeyValue<Sint64, int> &E : touch_ids) {
			if (E.value == index) {
				used = true;
				break;
			}
		}
		if (!used) {
			break;
		}
		index++;
	}
	touch_ids[p_finger_id] = index;
	return index;
}

void DisplayServerSDL::_resize_window(Size2i p_size) {
#if defined(RD_ENABLED)
	if (rendering_context) {
		rendering_context->window_set_size(DisplayServerEnums::MAIN_WINDOW_ID, p_size.width, p_size.height);
	}
#endif
	if (rect_changed_callback.is_valid()) {
		rect_changed_callback.call(Rect2i(window_get_position(), p_size));
	}
}

void DisplayServerSDL::_handle_sdl_event(const SDL_Event &p_event) {
	switch (p_event.type) {
		case SDL_EVENT_QUIT:
		case SDL_EVENT_WINDOW_CLOSE_REQUESTED: {
			_send_window_event(DisplayServerEnums::WINDOW_EVENT_CLOSE_REQUEST);
		} break;

		case SDL_EVENT_WINDOW_RESIZED:
		case SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED: {
			_resize_window(window_get_size());
		} break;

		case SDL_EVENT_WINDOW_FOCUS_GAINED: {
			_send_window_event(DisplayServerEnums::WINDOW_EVENT_FOCUS_IN);
		} break;

		case SDL_EVENT_WINDOW_FOCUS_LOST: {
			Input::get_singleton()->release_pressed_events();
			_send_window_event(DisplayServerEnums::WINDOW_EVENT_FOCUS_OUT);
		} break;

		case SDL_EVENT_WINDOW_MOUSE_ENTER: {
			_send_window_event(DisplayServerEnums::WINDOW_EVENT_MOUSE_ENTER);
		} break;

		case SDL_EVENT_WINDOW_MOUSE_LEAVE: {
			_send_window_event(DisplayServerEnums::WINDOW_EVENT_MOUSE_EXIT);
		} break;

		case SDL_EVENT_KEY_DOWN:
		case SDL_EVENT_KEY_UP: {
			_handle_key_event(p_event.key);
		} break;

		case SDL_EVENT_MOUSE_MOTION: {
			float density = window ? SDL_GetWindowPixelDensity(window) : 1.0f;
			if (density <= 0.0f) {
				density = 1.0f;
			}
			Ref<InputEventMouseMotion> mm;
			mm.instantiate();
			mm->set_window_id(DisplayServerEnums::MAIN_WINDOW_ID);
			mm->set_position(Vector2(p_event.motion.x, p_event.motion.y) * density);
			mm->set_global_position(mm->get_position());
			mm->set_relative(Vector2(p_event.motion.xrel, p_event.motion.yrel) * density);
			mm->set_relative_screen_position(mm->get_relative());
			mm->set_velocity(Input::get_singleton()->get_last_mouse_velocity());
			mm->set_screen_velocity(mm->get_velocity());
			mm->set_button_mask(mouse_get_button_state());
			_set_key_modifier_state(mm, SDL_GetModState());

			Input::get_singleton()->parse_input_event(mm);
		} break;

		case SDL_EVENT_MOUSE_BUTTON_DOWN:
		case SDL_EVENT_MOUSE_BUTTON_UP: {
			_handle_mouse_button_event(p_event.button);
		} break;

		case SDL_EVENT_MOUSE_WHEEL: {
			float density = window ? SDL_GetWindowPixelDensity(window) : 1.0f;
			if (density <= 0.0f) {
				density = 1.0f;
			}
			Vector2 pos = Vector2(p_event.wheel.mouse_x, p_event.wheel.mouse_y) * density;

			float wheel_values[2] = { p_event.wheel.y, p_event.wheel.x };
			MouseButton wheel_buttons[2][2] = {
				{ MouseButton::WHEEL_UP, MouseButton::WHEEL_DOWN },
				{ MouseButton::WHEEL_RIGHT, MouseButton::WHEEL_LEFT },
			};
			bool flipped = p_event.wheel.direction == SDL_MOUSEWHEEL_FLIPPED;

			for (int axis = 0; axis < 2; axis++) {
				float value = flipped ? -wheel_values[axis] : wheel_values[axis];
				if (value == 0.0f) {
					continue;
				}
				MouseButton button = value > 0 ? wheel_buttons[axis][0] : wheel_buttons[axis][1];

				Ref<InputEventMouseButton> mb;
				mb.instantiate();
				mb->set_window_id(DisplayServerEnums::MAIN_WINDOW_ID);
				mb->set_button_index(button);
				mb->set_factor(Math::abs(value));
				mb->set_position(pos);
				mb->set_global_position(pos);
				mb->set_button_mask(mouse_get_button_state());
				_set_key_modifier_state(mb, SDL_GetModState());

				mb->set_pressed(true);
				Input::get_singleton()->parse_input_event(mb);

				Ref<InputEventMouseButton> mb_up = mb->duplicate();
				mb_up->set_pressed(false);
				Input::get_singleton()->parse_input_event(mb_up);
			}
		} break;

#ifdef TOUCH_ENABLED
		case SDL_EVENT_FINGER_DOWN:
		case SDL_EVENT_FINGER_UP:
		case SDL_EVENT_FINGER_CANCELED: {
			bool pressed = p_event.type == SDL_EVENT_FINGER_DOWN;
			int index = _get_touch_index((Sint64)p_event.tfinger.fingerID, pressed);
			if (index < 0) {
				break;
			}
			Size2i win_size = window_get_size();

			Ref<InputEventScreenTouch> st;
			st.instantiate();
			st->set_window_id(DisplayServerEnums::MAIN_WINDOW_ID);
			st->set_index(index);
			st->set_position(Vector2(p_event.tfinger.x * win_size.width, p_event.tfinger.y * win_size.height));
			st->set_pressed(pressed);
			st->set_canceled(p_event.type == SDL_EVENT_FINGER_CANCELED);

			Input::get_singleton()->parse_input_event(st);
		} break;

		case SDL_EVENT_FINGER_MOTION: {
			int index = _get_touch_index((Sint64)p_event.tfinger.fingerID, true);
			Size2i win_size = window_get_size();

			Ref<InputEventScreenDrag> sd;
			sd.instantiate();
			sd->set_window_id(DisplayServerEnums::MAIN_WINDOW_ID);
			sd->set_index(index);
			sd->set_position(Vector2(p_event.tfinger.x * win_size.width, p_event.tfinger.y * win_size.height));
			sd->set_relative(Vector2(p_event.tfinger.dx * win_size.width, p_event.tfinger.dy * win_size.height));
			sd->set_relative_screen_position(sd->get_relative());
			sd->set_pressure(p_event.tfinger.pressure);

			Input::get_singleton()->parse_input_event(sd);
		} break;
#endif

		case SDL_EVENT_DROP_FILE: {
			if (drop_files_callback.is_valid() && p_event.drop.data) {
				Vector<String> files;
				files.push_back(String::utf8(p_event.drop.data));
				drop_files_callback.call(files);
			}
		} break;

		default:
			break;
	}
}

void DisplayServerSDL::process_events() {
	SDL_PumpEvents();

	SDL_Event events[64];
	int count;
	do {
		count = SDL_PeepEvents(events, 64, SDL_GETEVENT, EVENT_RANGE_1_MIN, EVENT_RANGE_1_MAX);
		for (int i = 0; i < count; i++) {
			_handle_sdl_event(events[i]);
		}
	} while (count == 64);
	do {
		count = SDL_PeepEvents(events, 64, SDL_GETEVENT, EVENT_RANGE_2_MIN, EVENT_RANGE_2_MAX);
		for (int i = 0; i < count; i++) {
			_handle_sdl_event(events[i]);
		}
	} while (count == 64);

#ifdef SDL_ENABLED
	if (joypad_sdl) {
		joypad_sdl->process_events();
	}
#endif

	Input::get_singleton()->flush_buffered_events();
}

// Rendering.

void DisplayServerSDL::release_rendering_thread() {
	if (gl_context) {
		SDL_GL_MakeCurrent(window, nullptr);
	}
}

void DisplayServerSDL::gl_window_make_current(DisplayServerEnums::WindowID p_window_id) {
	if (gl_context) {
		SDL_GL_MakeCurrent(window, gl_context);
	}
}

void DisplayServerSDL::swap_buffers() {
	if (gl_context) {
		SDL_GL_SwapWindow(window);
	}
}

Error DisplayServerSDL::_create_gl_context(const String &p_driver) {
	SDL_GL_ResetAttributes();
	if (p_driver == "opengl3") {
		SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_CORE);
		SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3);
		SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 3);
	} else { // opengl3_es
		SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_ES);
		SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3);
		SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 0);
	}
	SDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER, 1);
	SDL_GL_SetAttribute(SDL_GL_DEPTH_SIZE, 24);
	SDL_GL_SetAttribute(SDL_GL_STENCIL_SIZE, 8);

	gl_context = SDL_GL_CreateContext(window);
	if (!gl_context) {
		return ERR_UNAVAILABLE;
	}
	if (!SDL_GL_MakeCurrent(window, gl_context)) {
		SDL_GL_DestroyContext(gl_context);
		gl_context = nullptr;
		return ERR_UNAVAILABLE;
	}

#if defined(GLAD_ENABLED) && defined(EGL_ENABLED)
	// Load GLAD's EGL pointers so the rasterizer can resolve GL symbols
	// through eglGetProcAddress (upstream this is done by the EGL manager).
	// GLAD's generic GLES2 loader refuses to run without it.
	if (!gladLoaderLoadEGL(EGL_NO_DISPLAY)) {
		print_verbose("SDL: Couldn't load EGL with GLAD; falling back to the generic GL loaders.");
	}
#endif

	return OK;
}

void DisplayServerSDL::_destroy_window_and_sdl() {
	if (gl_context) {
		SDL_GL_DestroyContext(gl_context);
		gl_context = nullptr;
	}
	if (window) {
		SDL_DestroyWindow(window);
		window = nullptr;
	}
}

DisplayServerSDL::DisplayServerSDL(const String &p_rendering_driver, DisplayServerEnums::WindowMode p_mode, DisplayServerEnums::VSyncMode p_vsync_mode, uint32_t p_flags, const Vector2i *p_position, const Vector2i &p_resolution, int p_screen, DisplayServerEnums::Context p_context, int64_t p_parent_window, Error &r_error) {
	singleton = this;
	r_error = ERR_UNAVAILABLE;
	rendering_driver = p_rendering_driver;

	SDL_SetHint(SDL_HINT_NO_SIGNAL_HANDLERS, "1");
	SDL_SetHint(SDL_HINT_VIDEO_ALLOW_SCREENSAVER, "1");

	if (!SDL_InitSubSystem(SDL_INIT_VIDEO | SDL_INIT_EVENTS)) {
		ERR_FAIL_MSG(vformat("SDL: Failed to initialize video subsystem: %s", SDL_GetError()));
	}

	video_driver_name = String::utf8(SDL_GetCurrentVideoDriver());
	print_verbose(vformat("SDL: Using video driver \"%s\".", video_driver_name));

	// Under kmsdrm there is no windowing system; windows are always
	// fullscreen on a display, so honor that from the start.
	bool force_fullscreen = video_driver_name == "kmsdrm";

	SDL_WindowFlags window_sdl_flags = 0;
	if (rendering_driver == "opengl3" || rendering_driver == "opengl3_es") {
		window_sdl_flags |= SDL_WINDOW_OPENGL;
	}
#ifdef VULKAN_ENABLED
	if (rendering_driver == "vulkan") {
		window_sdl_flags |= SDL_WINDOW_VULKAN;
	}
#endif
	if (!(p_flags & DisplayServerEnums::WINDOW_FLAG_RESIZE_DISABLED_BIT)) {
		window_sdl_flags |= SDL_WINDOW_RESIZABLE;
	}
	if (p_flags & DisplayServerEnums::WINDOW_FLAG_BORDERLESS_BIT) {
		window_sdl_flags |= SDL_WINDOW_BORDERLESS;
	}
	if (p_flags & DisplayServerEnums::WINDOW_FLAG_ALWAYS_ON_TOP_BIT) {
		window_sdl_flags |= SDL_WINDOW_ALWAYS_ON_TOP;
	}
	if (force_fullscreen || p_mode == DisplayServerEnums::WINDOW_MODE_FULLSCREEN || p_mode == DisplayServerEnums::WINDOW_MODE_EXCLUSIVE_FULLSCREEN) {
		window_sdl_flags |= SDL_WINDOW_FULLSCREEN;
	}
	window_flags = p_flags;
	window_mode = p_mode;

	window = SDL_CreateWindow("Godot", p_resolution.width, p_resolution.height, window_sdl_flags);
	if (!window) {
		SDL_QuitSubSystem(SDL_INIT_VIDEO | SDL_INIT_EVENTS);
		ERR_FAIL_MSG(vformat("SDL: Failed to create window: %s", SDL_GetError()));
	}

	if (!force_fullscreen && p_position != nullptr) {
		SDL_SetWindowPosition(window, p_position->x, p_position->y);
	}

	bool driver_found = false;

#ifdef VULKAN_ENABLED
	if (rendering_driver == "vulkan") {
		rendering_context = memnew(RenderingContextDriverVulkanSDL);
		if (rendering_context->initialize() != OK) {
			memdelete(rendering_context);
			rendering_context = nullptr;
			_destroy_window_and_sdl();
			SDL_QuitSubSystem(SDL_INIT_VIDEO | SDL_INIT_EVENTS);
			r_error = ERR_CANT_CREATE;
			ERR_FAIL_MSG("Could not initialize Vulkan. Try the OpenGL ES driver with `--rendering-driver opengl3_es`.");
		}

		RenderingContextDriverVulkanSDL::WindowPlatformData wpd;
		wpd.window = window;
		if (rendering_context->window_create(DisplayServerEnums::MAIN_WINDOW_ID, &wpd) != OK) {
			memdelete(rendering_context);
			rendering_context = nullptr;
			_destroy_window_and_sdl();
			SDL_QuitSubSystem(SDL_INIT_VIDEO | SDL_INIT_EVENTS);
			r_error = ERR_CANT_CREATE;
			ERR_FAIL_MSG("Failed to create a Vulkan window.");
		}

		Size2i win_size = window_get_size();
		rendering_context->window_set_size(DisplayServerEnums::MAIN_WINDOW_ID, win_size.width, win_size.height);
		rendering_context->window_set_vsync_mode(DisplayServerEnums::MAIN_WINDOW_ID, p_vsync_mode);

		rendering_device = memnew(RenderingDevice);
		if (rendering_device->initialize(rendering_context, DisplayServerEnums::MAIN_WINDOW_ID) != OK) {
			memdelete(rendering_device);
			rendering_device = nullptr;
			memdelete(rendering_context);
			rendering_context = nullptr;
			_destroy_window_and_sdl();
			SDL_QuitSubSystem(SDL_INIT_VIDEO | SDL_INIT_EVENTS);
			r_error = ERR_CANT_CREATE;
			ERR_FAIL_MSG("Failed to create a Vulkan rendering device.");
		}
		rendering_device->screen_create(DisplayServerEnums::MAIN_WINDOW_ID);

		RendererCompositorRD::make_current();
		driver_found = true;
	}
#endif

#ifdef GLES3_ENABLED
	if (rendering_driver == "opengl3") {
		if (_create_gl_context("opengl3") == OK) {
			RasterizerGLES3::make_current(true);
			driver_found = true;
		} else {
			bool fallback = GLOBAL_GET("rendering/gl_compatibility/fallback_to_gles");
			if (fallback) {
				WARN_PRINT("Could not create an OpenGL 3.3 context, falling back to OpenGL ES 3.0.");
				rendering_driver = "opengl3_es";
				OS::get_singleton()->set_current_rendering_driver_name(rendering_driver, OS::RENDERING_SOURCE_FALLBACK);
			}
		}
	}

	if (rendering_driver == "opengl3_es" && !driver_found) {
		if (_create_gl_context("opengl3_es") == OK) {
			RasterizerGLES3::make_current(false);
			driver_found = true;
		}
	}
#endif

	if (!driver_found) {
		_destroy_window_and_sdl();
		SDL_QuitSubSystem(SDL_INIT_VIDEO | SDL_INIT_EVENTS);
		r_error = ERR_UNAVAILABLE;
		ERR_FAIL_MSG(vformat("Video driver \"%s\" not available: %s", rendering_driver, String::utf8(SDL_GetError())));
	}

	if (gl_context) {
		window_set_vsync_mode(p_vsync_mode);
	}

#ifdef SDL_ENABLED
	joypad_sdl = memnew(JoypadSDL);
	if (joypad_sdl->initialize() != OK) {
		ERR_PRINT("Couldn't initialize SDL joypad input driver.");
		memdelete(joypad_sdl);
		joypad_sdl = nullptr;
	}
#endif

	Input::get_singleton()->set_event_dispatch_function(_dispatch_input_events);

	cursor_set_shape(DisplayServerEnums::CURSOR_ARROW);

	SDL_ShowWindow(window);
	_resize_window(window_get_size());

	r_error = OK;
}

DisplayServerSDL::~DisplayServerSDL() {
#if defined(RD_ENABLED)
	if (rendering_device) {
		memdelete(rendering_device);
		rendering_device = nullptr;
	}
	if (rendering_context) {
		memdelete(rendering_context);
		rendering_context = nullptr;
	}
#endif

	for (int i = 0; i < DisplayServerEnums::CURSOR_MAX; i++) {
		if (cursors[i]) {
			SDL_DestroyCursor(cursors[i]);
			cursors[i] = nullptr;
		}
		if (custom_cursors[i]) {
			SDL_DestroyCursor(custom_cursors[i]);
			custom_cursors[i] = nullptr;
		}
	}

	_destroy_window_and_sdl();

#ifdef SDL_ENABLED
	if (joypad_sdl) {
		// The joypad driver's destructor calls SDL_Quit().
		memdelete(joypad_sdl);
		joypad_sdl = nullptr;
	} else {
		SDL_Quit();
	}
#else
	SDL_Quit();
#endif

	singleton = nullptr;
}
