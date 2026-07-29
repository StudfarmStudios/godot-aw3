/**************************************************************************/
/*  key_mapping_sdl.cpp                                                   */
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

#include "key_mapping_sdl.h"

#include <cstring>

// SDL keycodes for printable characters are their (lowercase) Unicode code
// point, and Godot `Key` values for printable characters are the uppercase
// Unicode code point, so most of the range maps arithmetically. Everything
// else goes through the switch below.
Key KeyMappingSDL::to_keycode(SDL_Keycode p_keycode) {
	if (p_keycode >= 'a' && p_keycode <= 'z') {
		return (Key)(p_keycode - 32); // Uppercase.
	}
	if (p_keycode >= ' ' && p_keycode <= '~') {
		return (Key)p_keycode; // Printable ASCII, aligned with Godot's Key values.
	}

	switch (p_keycode) {
		case SDLK_ESCAPE:
			return Key::ESCAPE;
		case SDLK_TAB:
			return Key::TAB;
		case SDLK_BACKSPACE:
			return Key::BACKSPACE;
		case SDLK_RETURN:
		case SDLK_RETURN2:
			return Key::ENTER;
		case SDLK_KP_ENTER:
			return Key::KP_ENTER;
		case SDLK_INSERT:
			return Key::INSERT;
		case SDLK_DELETE:
			return Key::KEY_DELETE;
		case SDLK_PAUSE:
			return Key::PAUSE;
		case SDLK_PRINTSCREEN:
			return Key::PRINT;
		case SDLK_SYSREQ:
			return Key::SYSREQ;
		case SDLK_CLEAR:
			return Key::CLEAR;
		case SDLK_HOME:
			return Key::HOME;
		case SDLK_END:
			return Key::END;
		case SDLK_LEFT:
			return Key::LEFT;
		case SDLK_UP:
			return Key::UP;
		case SDLK_RIGHT:
			return Key::RIGHT;
		case SDLK_DOWN:
			return Key::DOWN;
		case SDLK_PAGEUP:
			return Key::PAGEUP;
		case SDLK_PAGEDOWN:
			return Key::PAGEDOWN;
		case SDLK_LSHIFT:
		case SDLK_RSHIFT:
			return Key::SHIFT;
		case SDLK_LCTRL:
		case SDLK_RCTRL:
			return Key::CTRL;
		case SDLK_LGUI:
		case SDLK_RGUI:
			return Key::META;
		case SDLK_LALT:
		case SDLK_RALT:
			return Key::ALT;
		case SDLK_CAPSLOCK:
			return Key::CAPSLOCK;
		case SDLK_NUMLOCKCLEAR:
			return Key::NUMLOCK;
		case SDLK_SCROLLLOCK:
			return Key::SCROLLLOCK;
		case SDLK_F1:
			return Key::F1;
		case SDLK_F2:
			return Key::F2;
		case SDLK_F3:
			return Key::F3;
		case SDLK_F4:
			return Key::F4;
		case SDLK_F5:
			return Key::F5;
		case SDLK_F6:
			return Key::F6;
		case SDLK_F7:
			return Key::F7;
		case SDLK_F8:
			return Key::F8;
		case SDLK_F9:
			return Key::F9;
		case SDLK_F10:
			return Key::F10;
		case SDLK_F11:
			return Key::F11;
		case SDLK_F12:
			return Key::F12;
		case SDLK_F13:
			return Key::F13;
		case SDLK_F14:
			return Key::F14;
		case SDLK_F15:
			return Key::F15;
		case SDLK_KP_MULTIPLY:
			return Key::KP_MULTIPLY;
		case SDLK_KP_DIVIDE:
			return Key::KP_DIVIDE;
		case SDLK_KP_MINUS:
			return Key::KP_SUBTRACT;
		case SDLK_KP_PERIOD:
			return Key::KP_PERIOD;
		case SDLK_KP_PLUS:
			return Key::KP_ADD;
		case SDLK_KP_0:
			return Key::KP_0;
		case SDLK_KP_1:
			return Key::KP_1;
		case SDLK_KP_2:
			return Key::KP_2;
		case SDLK_KP_3:
			return Key::KP_3;
		case SDLK_KP_4:
			return Key::KP_4;
		case SDLK_KP_5:
			return Key::KP_5;
		case SDLK_KP_6:
			return Key::KP_6;
		case SDLK_KP_7:
			return Key::KP_7;
		case SDLK_KP_8:
			return Key::KP_8;
		case SDLK_KP_9:
			return Key::KP_9;
		case SDLK_MENU:
		case SDLK_APPLICATION:
			return Key::MENU;
		case SDLK_HELP:
			return Key::HELP;
		case SDLK_AC_BACK:
			return Key::BACK;
		case SDLK_AC_FORWARD:
			return Key::FORWARD;
		case SDLK_AC_STOP:
			return Key::STOP;
		case SDLK_AC_REFRESH:
			return Key::REFRESH;
		case SDLK_VOLUMEDOWN:
			return Key::VOLUMEDOWN;
		case SDLK_MUTE:
			return Key::VOLUMEMUTE;
		case SDLK_VOLUMEUP:
			return Key::VOLUMEUP;
		case SDLK_MEDIA_PLAY:
			return Key::MEDIAPLAY;
		case SDLK_MEDIA_STOP:
			return Key::MEDIASTOP;
		case SDLK_MEDIA_PREVIOUS_TRACK:
			return Key::MEDIAPREVIOUS;
		case SDLK_MEDIA_NEXT_TRACK:
			return Key::MEDIANEXT;
		case SDLK_AC_HOME:
			return Key::HOMEPAGE;
		case SDLK_AC_SEARCH:
			return Key::SEARCH;
		default:
			return Key::NONE;
	}
}

// SDL scancodes are USB HID usage codes (US layout positions), which is the
// same convention as Godot's physical keycodes.
Key KeyMappingSDL::to_physical_keycode(SDL_Scancode p_scancode) {
	if (p_scancode >= SDL_SCANCODE_A && p_scancode <= SDL_SCANCODE_Z) {
		return (Key)((int)Key::A + (p_scancode - SDL_SCANCODE_A));
	}
	if (p_scancode >= SDL_SCANCODE_1 && p_scancode <= SDL_SCANCODE_9) {
		return (Key)((int)Key::KEY_1 + (p_scancode - SDL_SCANCODE_1));
	}

	switch (p_scancode) {
		case SDL_SCANCODE_0:
			return Key::KEY_0;
		case SDL_SCANCODE_RETURN:
			return Key::ENTER;
		case SDL_SCANCODE_ESCAPE:
			return Key::ESCAPE;
		case SDL_SCANCODE_BACKSPACE:
			return Key::BACKSPACE;
		case SDL_SCANCODE_TAB:
			return Key::TAB;
		case SDL_SCANCODE_SPACE:
			return Key::SPACE;
		case SDL_SCANCODE_MINUS:
			return Key::MINUS;
		case SDL_SCANCODE_EQUALS:
			return Key::EQUAL;
		case SDL_SCANCODE_LEFTBRACKET:
			return Key::BRACKETLEFT;
		case SDL_SCANCODE_RIGHTBRACKET:
			return Key::BRACKETRIGHT;
		case SDL_SCANCODE_BACKSLASH:
		case SDL_SCANCODE_NONUSHASH:
			return Key::BACKSLASH;
		case SDL_SCANCODE_SEMICOLON:
			return Key::SEMICOLON;
		case SDL_SCANCODE_APOSTROPHE:
			return Key::APOSTROPHE;
		case SDL_SCANCODE_GRAVE:
			return Key::QUOTELEFT;
		case SDL_SCANCODE_COMMA:
			return Key::COMMA;
		case SDL_SCANCODE_PERIOD:
			return Key::PERIOD;
		case SDL_SCANCODE_SLASH:
			return Key::SLASH;
		case SDL_SCANCODE_CAPSLOCK:
			return Key::CAPSLOCK;
		case SDL_SCANCODE_F1:
			return Key::F1;
		case SDL_SCANCODE_F2:
			return Key::F2;
		case SDL_SCANCODE_F3:
			return Key::F3;
		case SDL_SCANCODE_F4:
			return Key::F4;
		case SDL_SCANCODE_F5:
			return Key::F5;
		case SDL_SCANCODE_F6:
			return Key::F6;
		case SDL_SCANCODE_F7:
			return Key::F7;
		case SDL_SCANCODE_F8:
			return Key::F8;
		case SDL_SCANCODE_F9:
			return Key::F9;
		case SDL_SCANCODE_F10:
			return Key::F10;
		case SDL_SCANCODE_F11:
			return Key::F11;
		case SDL_SCANCODE_F12:
			return Key::F12;
		case SDL_SCANCODE_PRINTSCREEN:
			return Key::PRINT;
		case SDL_SCANCODE_SCROLLLOCK:
			return Key::SCROLLLOCK;
		case SDL_SCANCODE_PAUSE:
			return Key::PAUSE;
		case SDL_SCANCODE_INSERT:
			return Key::INSERT;
		case SDL_SCANCODE_HOME:
			return Key::HOME;
		case SDL_SCANCODE_PAGEUP:
			return Key::PAGEUP;
		case SDL_SCANCODE_DELETE:
			return Key::KEY_DELETE;
		case SDL_SCANCODE_END:
			return Key::END;
		case SDL_SCANCODE_PAGEDOWN:
			return Key::PAGEDOWN;
		case SDL_SCANCODE_RIGHT:
			return Key::RIGHT;
		case SDL_SCANCODE_LEFT:
			return Key::LEFT;
		case SDL_SCANCODE_DOWN:
			return Key::DOWN;
		case SDL_SCANCODE_UP:
			return Key::UP;
		case SDL_SCANCODE_NUMLOCKCLEAR:
			return Key::NUMLOCK;
		case SDL_SCANCODE_KP_DIVIDE:
			return Key::KP_DIVIDE;
		case SDL_SCANCODE_KP_MULTIPLY:
			return Key::KP_MULTIPLY;
		case SDL_SCANCODE_KP_MINUS:
			return Key::KP_SUBTRACT;
		case SDL_SCANCODE_KP_PLUS:
			return Key::KP_ADD;
		case SDL_SCANCODE_KP_ENTER:
			return Key::KP_ENTER;
		case SDL_SCANCODE_KP_1:
			return Key::KP_1;
		case SDL_SCANCODE_KP_2:
			return Key::KP_2;
		case SDL_SCANCODE_KP_3:
			return Key::KP_3;
		case SDL_SCANCODE_KP_4:
			return Key::KP_4;
		case SDL_SCANCODE_KP_5:
			return Key::KP_5;
		case SDL_SCANCODE_KP_6:
			return Key::KP_6;
		case SDL_SCANCODE_KP_7:
			return Key::KP_7;
		case SDL_SCANCODE_KP_8:
			return Key::KP_8;
		case SDL_SCANCODE_KP_9:
			return Key::KP_9;
		case SDL_SCANCODE_KP_0:
			return Key::KP_0;
		case SDL_SCANCODE_KP_PERIOD:
			return Key::KP_PERIOD;
		case SDL_SCANCODE_NONUSBACKSLASH:
			return Key::SECTION;
		case SDL_SCANCODE_APPLICATION:
			return Key::MENU;
		case SDL_SCANCODE_LCTRL:
		case SDL_SCANCODE_RCTRL:
			return Key::CTRL;
		case SDL_SCANCODE_LSHIFT:
		case SDL_SCANCODE_RSHIFT:
			return Key::SHIFT;
		case SDL_SCANCODE_LALT:
		case SDL_SCANCODE_RALT:
			return Key::ALT;
		case SDL_SCANCODE_LGUI:
		case SDL_SCANCODE_RGUI:
			return Key::META;
		default:
			return Key::NONE;
	}
}

// Best-effort Unicode for InputEventKey. There is no IME under KMS/DRM, and
// SDL text-input events are not routed to the engine, so synthesize the
// character from the keycode; this covers ASCII text entry (chat, IP fields).
char32_t KeyMappingSDL::to_unicode(SDL_Keycode p_keycode, SDL_Keymod p_mod) {
	if (p_keycode < ' ' || p_keycode > 0x10FFFF || (p_keycode & SDLK_SCANCODE_MASK)) {
		return 0;
	}
	char32_t unicode = (char32_t)p_keycode;
	bool shift = (p_mod & SDL_KMOD_SHIFT) != 0;
	bool caps = (p_mod & SDL_KMOD_CAPS) != 0;
	if (unicode >= 'a' && unicode <= 'z' && (shift != caps)) {
		unicode -= 32;
	} else if (shift && unicode >= ' ' && unicode <= '~') {
		// US layout shifted punctuation/digits.
		static const char *base = "1234567890-=[]\\;',./`";
		static const char *shifted = "!@#$%^&*()_+{}|:\"<>?~";
		const char *pos = strchr(base, (int)unicode);
		if (pos) {
			unicode = (char32_t)shifted[pos - base];
		}
	}
	return unicode;
}
