/**************************************************************************/
/*  patch_webgpu.js                                                       */
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

// Emscripten's WebGPU bridge passes a WGPUStringView length to UTF8ToString
// without its `ignoreNul` argument. For bounded views this makes every error
// message and label scan for a terminator even though the C API supplied the
// exact byte count. WGPU_STRLEN is SIZE_MAX; wasm32 represents it as the
// uint32 sentinel below and retains the bridge's null-terminated behavior.
(function () {
	if (typeof WebGPU === 'undefined' || typeof UTF8ToString !== 'function') {
		return;
	}

	const WGPU_STRLEN = 0xffffffff;
	const readStringView = function (stringViewPtr) {
		const ptr = HEAPU32[stringViewPtr >> 2];
		const length = HEAPU32[(stringViewPtr + 4) >> 2];
		return UTF8ToString(ptr, length, length !== WGPU_STRLEN);
	};

	WebGPU.makeStringFromStringView = readStringView;
	WebGPU.makeStringFromOptionalStringView = function (stringViewPtr) {
		const ptr = HEAPU32[stringViewPtr >> 2];
		const length = HEAPU32[(stringViewPtr + 4) >> 2];
		if (!ptr) {
			if (length === 0) {
				return "";
			}
			return undefined;
		}
		return UTF8ToString(ptr, length, length !== WGPU_STRLEN);
	};
})();
