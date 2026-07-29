/**************************************************************************/
/*  audio_driver_sdl.h                                                    */
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

#include "core/os/mutex.h"
#include "core/templates/vector.h"
#include "servers/audio/audio_server.h"

struct SDL_AudioStream;

// Output driver on top of SDL3 audio, which picks the best available backend
// at runtime (pipewire, pulseaudio, alsa, ...). Keeps the whole platform on a
// single system dependency.
class AudioDriverSDL : public AudioDriver {
	Mutex mutex;

	SDL_AudioStream *stream = nullptr;

	Vector<int32_t> samples_in;

	int mix_rate = 0;
	unsigned int buffer_frames = 0;
	static const int CHANNELS = 2; // Stereo.

	static void _stream_callback(void *p_userdata, SDL_AudioStream *p_stream, int p_additional_amount, int p_total_amount);

public:
	virtual const char *get_name() const override {
		return "SDL";
	}

	virtual Error init() override;
	virtual void start() override;
	virtual int get_mix_rate() const override;
	virtual SpeakerMode get_speaker_mode() const override;
	virtual float get_latency() override;

	virtual void lock() override;
	virtual void unlock() override;
	virtual void finish() override;
};
