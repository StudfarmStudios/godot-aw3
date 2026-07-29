/**************************************************************************/
/*  audio_driver_sdl.cpp                                                  */
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

#include "audio_driver_sdl.h"

#include "core/config/engine.h"
#include "core/string/print_string.h"

#include <SDL3/SDL.h>

Error AudioDriverSDL::init() {
	if (!SDL_InitSubSystem(SDL_INIT_AUDIO)) {
		ERR_FAIL_V_MSG(ERR_CANT_OPEN, vformat("SDL: Failed to initialize audio subsystem: %s", SDL_GetError()));
	}

	mix_rate = _get_configured_mix_rate();

	int latency = Engine::get_singleton()->get_audio_output_latency();
	buffer_frames = Math::closest_power_of_2((uint32_t)(latency * mix_rate / 1000));
	samples_in.resize(buffer_frames * CHANNELS);

	SDL_SetHint(SDL_HINT_AUDIO_DEVICE_SAMPLE_FRAMES, itos(buffer_frames).utf8().get_data());

	print_verbose(vformat("SDL: audio driver \"%s\", mix rate %d Hz, buffer %d frames (%d ms)",
			String::utf8(SDL_GetCurrentAudioDriver()), mix_rate, buffer_frames, buffer_frames * 1000 / mix_rate));

	return OK;
}

void AudioDriverSDL::start() {
	SDL_AudioSpec spec = {};
	spec.format = SDL_AUDIO_S32;
	spec.channels = CHANNELS;
	spec.freq = mix_rate;

	stream = SDL_OpenAudioDeviceStream(SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, &spec, _stream_callback, this);
	if (!stream) {
		ERR_PRINT(vformat("SDL: Failed to open audio device stream: %s", SDL_GetError()));
		return;
	}
	SDL_ResumeAudioStreamDevice(stream);
}

void AudioDriverSDL::_stream_callback(void *p_userdata, SDL_AudioStream *p_stream, int p_additional_amount, int p_total_amount) {
	AudioDriverSDL *ad = static_cast<AudioDriverSDL *>(p_userdata);

	const int frame_bytes = CHANNELS * (int)sizeof(int32_t);
	int frames_needed = p_additional_amount / frame_bytes;

	while (frames_needed > 0) {
		int frames = MIN(frames_needed, (int)ad->buffer_frames);

		ad->lock();
		ad->start_counting_ticks();
		ad->audio_server_process(frames, ad->samples_in.ptrw());
		ad->stop_counting_ticks();
		ad->unlock();

		SDL_PutAudioStreamData(p_stream, ad->samples_in.ptr(), frames * frame_bytes);
		frames_needed -= frames;
	}
}

int AudioDriverSDL::get_mix_rate() const {
	return mix_rate;
}

AudioDriver::SpeakerMode AudioDriverSDL::get_speaker_mode() const {
	return SPEAKER_MODE_STEREO;
}

float AudioDriverSDL::get_latency() {
	if (mix_rate == 0) {
		return 0;
	}
	return (float)buffer_frames / mix_rate;
}

void AudioDriverSDL::lock() {
	mutex.lock();
}

void AudioDriverSDL::unlock() {
	mutex.unlock();
}

void AudioDriverSDL::finish() {
	if (stream) {
		SDL_DestroyAudioStream(stream);
		stream = nullptr;
	}
	SDL_QuitSubSystem(SDL_INIT_AUDIO);
}
