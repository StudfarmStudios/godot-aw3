/**************************************************************************/
/*  display_server_sdl.h                                                  */
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

#include "core/input/input.h"
#include "core/templates/hash_map.h"
#include "servers/display/display_server.h"

#include <SDL3/SDL.h>

class JoypadSDL;
class RenderingContextDriverVulkanSDL;
class RenderingDevice;

// Single-window display server on top of SDL3. SDL picks the best available
// video driver at runtime (wayland, x11, kmsdrm, ...), which makes this port
// work on devices that only expose KMS/DRM.
class DisplayServerSDL : public DisplayServer {
	GDSOFTCLASS(DisplayServerSDL, DisplayServer);

	static DisplayServerSDL *singleton;

	SDL_Window *window = nullptr;
	String video_driver_name;
	String rendering_driver;

	SDL_GLContext gl_context = nullptr;

#if defined(RD_ENABLED)
	RenderingContextDriverVulkanSDL *rendering_context = nullptr;
	RenderingDevice *rendering_device = nullptr;
#endif

#ifdef SDL_ENABLED
	JoypadSDL *joypad_sdl = nullptr;
#endif

	DisplayServerEnums::VSyncMode vsync_mode = DisplayServerEnums::VSYNC_ENABLED;
	DisplayServerEnums::WindowMode window_mode = DisplayServerEnums::WINDOW_MODE_WINDOWED;
	uint32_t window_flags = 0;

	Callable rect_changed_callback;
	Callable window_event_callback;
	Callable input_event_callback;
	Callable input_text_callback;
	Callable drop_files_callback;

	ObjectID window_attached_instance_id;

	DisplayServerEnums::MouseMode mouse_mode = DisplayServerEnums::MOUSE_MODE_VISIBLE;
	DisplayServerEnums::MouseMode mouse_mode_base = DisplayServerEnums::MOUSE_MODE_VISIBLE;
	DisplayServerEnums::MouseMode mouse_mode_override = DisplayServerEnums::MOUSE_MODE_VISIBLE;
	bool mouse_mode_override_enabled = false;
	void _mouse_update_mode();

	DisplayServerEnums::CursorShape cursor_shape = DisplayServerEnums::CURSOR_ARROW;
	SDL_Cursor *cursors[DisplayServerEnums::CURSOR_MAX] = {};
	SDL_Cursor *custom_cursors[DisplayServerEnums::CURSOR_MAX] = {};

	HashMap<Sint64, int> touch_ids;

	static void _dispatch_input_events(const Ref<InputEvent> &p_event);
	void _dispatch_input_event(const Ref<InputEvent> &p_event);

	void _send_window_event(DisplayServerEnums::WindowEvent p_event);
	void _handle_sdl_event(const SDL_Event &p_event);
	void _handle_key_event(const SDL_KeyboardEvent &p_event);
	void _handle_mouse_button_event(const SDL_MouseButtonEvent &p_event);
	void _resize_window(Size2i p_size);
	int _get_touch_index(Sint64 p_finger_id, bool p_pressed);

	SDL_DisplayID _get_display_id(int p_screen) const;

	Error _create_gl_context(const String &p_driver);
	void _destroy_window_and_sdl();

	friend class DisplayServer;

	static Vector<String> get_rendering_drivers_func();
	static DisplayServer *create_func(const String &p_rendering_driver, DisplayServerEnums::WindowMode p_mode, DisplayServerEnums::VSyncMode p_vsync_mode, uint32_t p_flags, const Vector2i *p_position, const Vector2i &p_resolution, int p_screen, DisplayServerEnums::Context p_context, int64_t p_parent_window, Error &r_error);

public:
	static DisplayServerSDL *get_singleton_sdl() { return singleton; }
	String get_video_driver_name() const { return video_driver_name; }

	static void register_sdl_driver();

	bool has_feature(DisplayServerEnums::Feature p_feature) const override;
	String get_name() const override { return "SDL"; }

	// Screens.
	int get_screen_count() const override;
	int get_primary_screen() const override;
	Point2i screen_get_position(int p_screen = DisplayServerEnums::SCREEN_OF_MAIN_WINDOW) const override;
	Size2i screen_get_size(int p_screen = DisplayServerEnums::SCREEN_OF_MAIN_WINDOW) const override;
	Rect2i screen_get_usable_rect(int p_screen = DisplayServerEnums::SCREEN_OF_MAIN_WINDOW) const override;
	int screen_get_dpi(int p_screen = DisplayServerEnums::SCREEN_OF_MAIN_WINDOW) const override;
	float screen_get_scale(int p_screen = DisplayServerEnums::SCREEN_OF_MAIN_WINDOW) const override;
	float screen_get_max_scale() const override;
	float screen_get_refresh_rate(int p_screen = DisplayServerEnums::SCREEN_OF_MAIN_WINDOW) const override;
	void screen_set_orientation(DisplayServerEnums::ScreenOrientation p_orientation, int p_screen = DisplayServerEnums::SCREEN_OF_MAIN_WINDOW) override {}
	void screen_set_keep_on(bool p_enable) override {}

	// Windows.
	Vector<DisplayServerEnums::WindowID> get_window_list() const override;

	DisplayServerEnums::WindowID create_sub_window(DisplayServerEnums::WindowMode p_mode, DisplayServerEnums::VSyncMode p_vsync_mode, uint32_t p_flags, const Rect2i &p_rect = Rect2i(), bool p_exclusive = false, DisplayServerEnums::WindowID p_transient_parent = DisplayServerEnums::INVALID_WINDOW_ID) override { return DisplayServerEnums::INVALID_WINDOW_ID; }
	void show_window(DisplayServerEnums::WindowID p_id) override;
	void delete_sub_window(DisplayServerEnums::WindowID p_id) override {}

	DisplayServerEnums::WindowID get_window_at_screen_position(const Point2i &p_position) const override { return DisplayServerEnums::MAIN_WINDOW_ID; }

	void window_attach_instance_id(ObjectID p_instance, DisplayServerEnums::WindowID p_window = DisplayServerEnums::MAIN_WINDOW_ID) override;
	ObjectID window_get_attached_instance_id(DisplayServerEnums::WindowID p_window = DisplayServerEnums::MAIN_WINDOW_ID) const override;

	void window_set_rect_changed_callback(const Callable &p_callable, DisplayServerEnums::WindowID p_window = DisplayServerEnums::MAIN_WINDOW_ID) override;
	void window_set_window_event_callback(const Callable &p_callable, DisplayServerEnums::WindowID p_window = DisplayServerEnums::MAIN_WINDOW_ID) override;
	void window_set_input_event_callback(const Callable &p_callable, DisplayServerEnums::WindowID p_window = DisplayServerEnums::MAIN_WINDOW_ID) override;
	void window_set_input_text_callback(const Callable &p_callable, DisplayServerEnums::WindowID p_window = DisplayServerEnums::MAIN_WINDOW_ID) override;
	void window_set_drop_files_callback(const Callable &p_callable, DisplayServerEnums::WindowID p_window = DisplayServerEnums::MAIN_WINDOW_ID) override;

	void window_set_title(const String &p_title, DisplayServerEnums::WindowID p_window = DisplayServerEnums::MAIN_WINDOW_ID) override;
	void window_set_mouse_passthrough(const Vector<Vector2> &p_region, DisplayServerEnums::WindowID p_window = DisplayServerEnums::MAIN_WINDOW_ID) override {}

	int window_get_current_screen(DisplayServerEnums::WindowID p_window = DisplayServerEnums::MAIN_WINDOW_ID) const override;
	void window_set_current_screen(int p_screen, DisplayServerEnums::WindowID p_window = DisplayServerEnums::MAIN_WINDOW_ID) override {}

	Point2i window_get_position(DisplayServerEnums::WindowID p_window = DisplayServerEnums::MAIN_WINDOW_ID) const override;
	Point2i window_get_position_with_decorations(DisplayServerEnums::WindowID p_window = DisplayServerEnums::MAIN_WINDOW_ID) const override;
	void window_set_position(const Point2i &p_position, DisplayServerEnums::WindowID p_window = DisplayServerEnums::MAIN_WINDOW_ID) override;

	void window_set_transient(DisplayServerEnums::WindowID p_window, DisplayServerEnums::WindowID p_parent) override {}

	void window_set_max_size(const Size2i p_size, DisplayServerEnums::WindowID p_window = DisplayServerEnums::MAIN_WINDOW_ID) override;
	Size2i window_get_max_size(DisplayServerEnums::WindowID p_window = DisplayServerEnums::MAIN_WINDOW_ID) const override;

	void window_set_min_size(const Size2i p_size, DisplayServerEnums::WindowID p_window = DisplayServerEnums::MAIN_WINDOW_ID) override;
	Size2i window_get_min_size(DisplayServerEnums::WindowID p_window = DisplayServerEnums::MAIN_WINDOW_ID) const override;

	void window_set_size(const Size2i p_size, DisplayServerEnums::WindowID p_window = DisplayServerEnums::MAIN_WINDOW_ID) override;
	Size2i window_get_size(DisplayServerEnums::WindowID p_window = DisplayServerEnums::MAIN_WINDOW_ID) const override;
	Size2i window_get_size_with_decorations(DisplayServerEnums::WindowID p_window = DisplayServerEnums::MAIN_WINDOW_ID) const override;

	void window_set_mode(DisplayServerEnums::WindowMode p_mode, DisplayServerEnums::WindowID p_window = DisplayServerEnums::MAIN_WINDOW_ID) override;
	DisplayServerEnums::WindowMode window_get_mode(DisplayServerEnums::WindowID p_window = DisplayServerEnums::MAIN_WINDOW_ID) const override;

	void window_set_vsync_mode(DisplayServerEnums::VSyncMode p_vsync_mode, DisplayServerEnums::WindowID p_window = DisplayServerEnums::MAIN_WINDOW_ID) override;
	DisplayServerEnums::VSyncMode window_get_vsync_mode(DisplayServerEnums::WindowID p_window) const override;

	bool window_is_maximize_allowed(DisplayServerEnums::WindowID p_window = DisplayServerEnums::MAIN_WINDOW_ID) const override { return false; }

	void window_set_flag(DisplayServerEnums::WindowFlags p_flag, bool p_enabled, DisplayServerEnums::WindowID p_window = DisplayServerEnums::MAIN_WINDOW_ID) override;
	bool window_get_flag(DisplayServerEnums::WindowFlags p_flag, DisplayServerEnums::WindowID p_window = DisplayServerEnums::MAIN_WINDOW_ID) const override;

	void window_request_attention(DisplayServerEnums::WindowID p_window = DisplayServerEnums::MAIN_WINDOW_ID) override {}
	void window_set_taskbar_progress_value(float p_value, DisplayServerEnums::WindowID p_window = DisplayServerEnums::MAIN_WINDOW_ID) override {}
	void window_set_taskbar_progress_state(DisplayServerEnums::ProgressState p_state, DisplayServerEnums::WindowID p_window = DisplayServerEnums::MAIN_WINDOW_ID) override {}
	void window_move_to_foreground(DisplayServerEnums::WindowID p_window = DisplayServerEnums::MAIN_WINDOW_ID) override;
	bool window_is_focused(DisplayServerEnums::WindowID p_window = DisplayServerEnums::MAIN_WINDOW_ID) const override;

	bool window_can_draw(DisplayServerEnums::WindowID p_window = DisplayServerEnums::MAIN_WINDOW_ID) const override;
	bool can_any_window_draw() const override;

	void window_set_ime_active(const bool p_active, DisplayServerEnums::WindowID p_window = DisplayServerEnums::MAIN_WINDOW_ID) override {}
	void window_set_ime_position(const Point2i &p_pos, DisplayServerEnums::WindowID p_window = DisplayServerEnums::MAIN_WINDOW_ID) override {}

	int64_t window_get_native_handle(DisplayServerEnums::HandleType p_handle_type, DisplayServerEnums::WindowID p_window = DisplayServerEnums::MAIN_WINDOW_ID) const override;

	void process_events() override;

	void set_native_icon(const String &p_filename) override {}
	void set_icon(const Ref<Image> &p_icon) override;

	void help_set_search_callbacks(const Callable &p_search_callback = Callable(), const Callable &p_action_callback = Callable()) override {}

	// TTS is not supported on this platform.
	bool tts_is_speaking() const override { return false; }
	bool tts_is_paused() const override { return false; }
	TypedArray<Dictionary> tts_get_voices() const override { return TypedArray<Dictionary>(); }
	void tts_speak(const String &p_text, const String &p_voice, int p_volume = 50, float p_pitch = 1.0f, float p_rate = 1.0f, int64_t p_utterance_id = 0, bool p_interrupt = false) override {}
	void tts_pause() override {}
	void tts_resume() override {}
	void tts_stop() override {}

	// Mouse.
	void mouse_set_mode(DisplayServerEnums::MouseMode p_mode) override;
	DisplayServerEnums::MouseMode mouse_get_mode() const override;
	void mouse_set_mode_override(DisplayServerEnums::MouseMode p_mode) override;
	DisplayServerEnums::MouseMode mouse_get_mode_override() const override;
	void mouse_set_mode_override_enabled(bool p_override_enabled) override;
	bool mouse_is_mode_override_enabled() const override;

	void warp_mouse(const Point2i &p_position) override;
	Point2i mouse_get_position() const override;
	BitField<MouseButtonMask> mouse_get_button_state() const override;

	// Clipboard.
	void clipboard_set(const String &p_text) override;
	String clipboard_get() const override;
	void clipboard_set_primary(const String &p_text) override;
	String clipboard_get_primary() const override;

	void virtual_keyboard_show(const String &p_existing_text, const Rect2 &p_screen_rect = Rect2(), DisplayServerEnums::VirtualKeyboardType p_type = DisplayServerEnums::KEYBOARD_TYPE_DEFAULT, int p_max_length = -1, int p_cursor_start = -1, int p_cursor_end = -1) override {}
	void virtual_keyboard_hide() override {}

	// Cursor.
	void cursor_set_shape(DisplayServerEnums::CursorShape p_shape) override;
	DisplayServerEnums::CursorShape cursor_get_shape() const override;
	void cursor_set_custom_image(const Ref<Resource> &p_cursor, DisplayServerEnums::CursorShape p_shape = DisplayServerEnums::CURSOR_ARROW, const Vector2 &p_hotspot = Vector2()) override;

	Error dialog_show(String p_title, String p_description, Vector<String> p_buttons, const Callable &p_callback) override { return ERR_UNAVAILABLE; }
	Error dialog_input_text(String p_title, String p_description, String p_partial, const Callable &p_callback) override { return ERR_UNAVAILABLE; }
	Error file_dialog_show(const String &p_title, const String &p_current_directory, const String &p_filename, bool p_show_hidden, DisplayServerEnums::FileDialogMode p_mode, const Vector<String> &p_filters, const Callable &p_callback, DisplayServerEnums::WindowID p_window_id) override { return ERR_UNAVAILABLE; }
	Error file_dialog_with_options_show(const String &p_title, const String &p_current_directory, const String &p_root, const String &p_filename, bool p_show_hidden, DisplayServerEnums::FileDialogMode p_mode, const Vector<String> &p_filters, const TypedArray<Dictionary> &p_options, const Callable &p_callback, DisplayServerEnums::WindowID p_window_id) override { return ERR_UNAVAILABLE; }

	// Rendering.
	void release_rendering_thread() override;
	void gl_window_make_current(DisplayServerEnums::WindowID p_window_id) override;
	void swap_buffers() override;

	DisplayServerEnums::IndicatorID create_status_indicator(const Ref<Texture2D> &p_icon, const String &p_tooltip, const Callable &p_callback) override { return DisplayServerEnums::INVALID_INDICATOR_ID; }
	void status_indicator_set_icon(DisplayServerEnums::IndicatorID p_id, const Ref<Texture2D> &p_icon) override {}
	void status_indicator_set_tooltip(DisplayServerEnums::IndicatorID p_id, const String &p_tooltip) override {}
	void status_indicator_set_callback(DisplayServerEnums::IndicatorID p_id, const Callable &p_callback) override {}
	void delete_status_indicator(DisplayServerEnums::IndicatorID p_id) override {}

	DisplayServerSDL(const String &p_rendering_driver, DisplayServerEnums::WindowMode p_mode, DisplayServerEnums::VSyncMode p_vsync_mode, uint32_t p_flags, const Vector2i *p_position, const Vector2i &p_resolution, int p_screen, DisplayServerEnums::Context p_context, int64_t p_parent_window, Error &r_error);
	~DisplayServerSDL();
};
