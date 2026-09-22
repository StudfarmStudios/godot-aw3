/**************************************************************************/
/*  rendering_server_default.cpp                                          */
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

#include "rendering_server_default.h"

#if defined(WEB_ENABLED) && defined(WEBGPU_ENABLED)
#include <emscripten/emscripten.h>
#include <emscripten/eventloop.h>
#include <emscripten/html5.h>
#include <emscripten/threading.h>
#include <cstdio>
#include <cstdlib>

// platform/web/js/libs/library_godot_webgpu_worker.js. Deliberately unproxied:
// they act on the JS realm of the Worker that calls them, which here must be
// the render thread. Declared locally rather than through platform/web headers
// to keep the server layer free of the platform include path.
extern "C" void godot_js_webgpu_worker_preinitialize(void (*p_callback)(int p_error));
extern "C" void godot_js_webgpu_worker_cleanup();

RenderingServerDefault *RenderingServerDefault::web_render_self = nullptr;
#endif

#include "core/object/callable_mp.h"
#include "core/os/os.h"
#include "core/profiling/profiling.h"
#include "servers/display/display_server.h"
#include "servers/rendering/renderer_canvas_cull.h"
#include "servers/rendering/renderer_rd/pipeline_compile_queue_rd.h"
#include "servers/rendering/renderer_scene_cull.h"
#include "servers/rendering/rendering_device.h"
#include "servers/rendering/rendering_server_globals.h"

#ifndef XR_DISABLED
#include "servers/xr/xr_server.h"
#endif

// careful, these may run in different threads than the rendering server

int RenderingServerDefault::changes = 0;

/* FREE */

void RenderingServerDefault::_free(RID p_rid) {
	if (unlikely(p_rid.is_null())) {
		return;
	}
	if (RSG::utilities->free(p_rid)) {
		return;
	}
	if (RSG::canvas->free(p_rid)) {
		return;
	}
	if (RSG::viewport->free(p_rid)) {
		return;
	}
	if (RSG::scene->free(p_rid)) {
		return;
	}
}

/* EVENT QUEUING */

void RenderingServerDefault::request_frame_drawn_callback(const Callable &p_callable) {
	frame_drawn_callbacks.push_back(p_callable);
}

void RenderingServerDefault::_draw(bool p_swap_buffers, double frame_step) {
	GodotProfileZoneGroupedFirst(_profile_zone, "rasterizer->begin_frame");
	RSG::rasterizer->begin_frame(frame_step);

	TIMESTAMP_BEGIN()

	uint64_t time_usec = OS::get_singleton()->get_ticks_usec();

	RENDER_TIMESTAMP("Prepare Render Frame");

#ifndef XR_DISABLED
	GodotProfileZoneGrouped(_profile_zone, "xr_server->pre_render");
	XRServer *xr_server = XRServer::get_singleton();
	if (xr_server != nullptr) {
		// Let XR server know we're about to render a frame.
		xr_server->pre_render();
	}
#endif // XR_DISABLED

	GodotProfileZoneGrouped(_profile_zone, "scene->update");
	RSG::scene->update(); //update scenes stuff before updating instances
	GodotProfileZoneGrouped(_profile_zone, "canvas->update");
	RSG::canvas->update();

	frame_setup_time = double(OS::get_singleton()->get_ticks_usec() - time_usec) / 1000.0;

	GodotProfileZoneGrouped(_profile_zone, "particles_storage->update_particles");
	RSG::particles_storage->update_particles(); //need to be done after instances are updated (colliders and particle transforms), and colliders are rendered

	GodotProfileZoneGrouped(_profile_zone, "scene->render_probes");
	RSG::scene->render_probes();

	GodotProfileZoneGrouped(_profile_zone, "viewport->draw_viewports");
	RSG::viewport->draw_viewports(p_swap_buffers);

	GodotProfileZoneGrouped(_profile_zone, "canvas_render->update");
	RSG::canvas_render->update();

	GodotProfileZoneGrouped(_profile_zone, "rasterizer->end_frame");
	RSG::rasterizer->end_frame(p_swap_buffers);

#ifndef XR_DISABLED
	if (xr_server != nullptr) {
		GodotProfileZone("xr_server->end_frame");
		// let our XR server know we're done so we can get our frame timing
		xr_server->end_frame();
	}
#endif // XR_DISABLED

	GodotProfileZoneGrouped(_profile_zone, "update_visibility_notifiers");
	RSG::canvas->update_visibility_notifiers();
	RSG::scene->update_visibility_notifiers();

	GodotProfileZoneGrouped(_profile_zone, "post_draw_steps");
	if (create_thread) {
		callable_mp(this, &RenderingServerDefault::_run_post_draw_steps).call_deferred();
	} else {
		_run_post_draw_steps();
	}

	if (RSG::utilities->get_captured_timestamps_count()) {
		GodotProfileZoneGrouped(_profile_zone, "frame_profile");
		Vector<RenderingServerTypes::FrameProfileArea> new_profile;
		if (RSG::utilities->capturing_timestamps) {
			new_profile.resize(RSG::utilities->get_captured_timestamps_count());
		}

		uint64_t base_cpu = RSG::utilities->get_captured_timestamp_cpu_time(0);
		uint64_t base_gpu = RSG::utilities->get_captured_timestamp_gpu_time(0);
		for (uint32_t i = 0; i < RSG::utilities->get_captured_timestamps_count(); i++) {
			uint64_t time_cpu = RSG::utilities->get_captured_timestamp_cpu_time(i);
			uint64_t time_gpu = RSG::utilities->get_captured_timestamp_gpu_time(i);

			String name = RSG::utilities->get_captured_timestamp_name(i);

			if (name.begins_with("vp_")) {
				RSG::viewport->handle_timestamp(name, time_cpu, time_gpu);
			}

			if (RSG::utilities->capturing_timestamps) {
				new_profile.write[i].gpu_msec = double((time_gpu - base_gpu) / 1000) / 1000.0;
				new_profile.write[i].cpu_msec = double(time_cpu - base_cpu) / 1000.0;
				new_profile.write[i].name = RSG::utilities->get_captured_timestamp_name(i);
			}
		}

		frame_profile = new_profile;
	}

	frame_profile_frame = RSG::utilities->get_captured_timestamps_frame();

	if (print_gpu_profile) {
		GodotProfileZoneGrouped(_profile_zone, "gpu_profile");
		if (print_frame_profile_ticks_from == 0) {
			print_frame_profile_ticks_from = OS::get_singleton()->get_ticks_usec();
		}
		double total_time = 0.0;

		for (int i = 0; i < frame_profile.size() - 1; i++) {
			String name = frame_profile[i].name;
			if (name[0] == '<' || name[0] == '>') {
				continue;
			}

			double time = frame_profile[i + 1].gpu_msec - frame_profile[i].gpu_msec;

			if (print_gpu_profile_task_time.has(name)) {
				print_gpu_profile_task_time[name] += time;
			} else {
				print_gpu_profile_task_time[name] = time;
			}
		}

		if (frame_profile.size()) {
			total_time = frame_profile[frame_profile.size() - 1].gpu_msec;
		}

		uint64_t ticks_elapsed = OS::get_singleton()->get_ticks_usec() - print_frame_profile_ticks_from;
		print_frame_profile_frame_count++;
		if (ticks_elapsed > 1000000) {
			print_line("GPU PROFILE (total " + rtos(total_time) + "ms): ");

			float print_threshold = 0.01;
			for (const KeyValue<String, float> &E : print_gpu_profile_task_time) {
				double time = E.value / double(print_frame_profile_frame_count);
				if (time > print_threshold) {
					print_line("\t-" + E.key + ": " + rtos(time) + "ms");
				}
			}
			print_gpu_profile_task_time.clear();
			print_frame_profile_ticks_from = OS::get_singleton()->get_ticks_usec();
			print_frame_profile_frame_count = 0;
		}
	}

	GodotProfileZoneGrouped(_profile_zone, "memory_info");
	RSG::utilities->update_memory_info();
}

void RenderingServerDefault::_run_post_draw_steps() {
	while (frame_drawn_callbacks.front()) {
		Callable c = frame_drawn_callbacks.front()->get();
		Variant result;
		Callable::CallError ce;
		c.callp(nullptr, 0, result, ce);
		if (ce.error != Callable::CallError::CALL_OK) {
			String err = Variant::get_callable_error_text(c, nullptr, 0, ce);
			ERR_PRINT("Error calling frame drawn function: " + err);
		}

		frame_drawn_callbacks.pop_front();
	}

	emit_signal(SNAME("frame_post_draw"));
}

double RenderingServerDefault::get_frame_setup_time_cpu() const {
	return frame_setup_time;
}

bool RenderingServerDefault::has_changed() const {
	return changes > 0;
}

void RenderingServerDefault::_init() {
	RSG::threaded = create_thread;

	RSG::canvas = memnew(RendererCanvasCull);
	RSG::viewport = memnew(RendererViewport);
	RendererSceneCull *sr = memnew(RendererSceneCull);
	RSG::camera_attributes = memnew(RendererCameraAttributes);
	RSG::scene = sr;
	RSG::rasterizer = RendererCompositor::create();
	RSG::utilities = RSG::rasterizer->get_utilities();
	RSG::rasterizer->initialize();
	RSG::light_storage = RSG::rasterizer->get_light_storage();
	RSG::material_storage = RSG::rasterizer->get_material_storage();
	RSG::mesh_storage = RSG::rasterizer->get_mesh_storage();
	RSG::particles_storage = RSG::rasterizer->get_particles_storage();
	RSG::texture_storage = RSG::rasterizer->get_texture_storage();
	RSG::gi = RSG::rasterizer->get_gi();
	RSG::fog = RSG::rasterizer->get_fog();
	RSG::canvas_render = RSG::rasterizer->get_canvas();
	sr->set_scene_render(RSG::rasterizer->get_scene());
}

void RenderingServerDefault::_finish() {
	if (test_cube.is_valid()) {
		free_rid(test_cube);
	}

	RSG::canvas->finalize();
	memdelete(RSG::canvas);
	RSG::rasterizer->finalize();
	memdelete(RSG::viewport);
	memdelete(RSG::rasterizer);
	memdelete(RSG::scene);
	memdelete(RSG::camera_attributes);
}

void RenderingServerDefault::init() {
	if (create_thread) {
#if defined(WEB_ENABLED) && defined(WEBGPU_ENABLED)
		if (DisplayServer::get_singleton()->has_deferred_rendering()) {
			_web_start_render_thread();
			return;
		}
#endif
		print_verbose("RenderingServerWrapMT: Starting render thread");
		DisplayServer::get_singleton()->release_rendering_thread();
		WorkerThreadPool::TaskID tid = WorkerThreadPool::get_singleton()->add_task(callable_mp(this, &RenderingServerDefault::_thread_loop), true, "Rendering Server pump task", true);
		command_queue.set_pump_task_id(tid);
		command_queue.push(this, &RenderingServerDefault::_assign_mt_ids, tid);
		command_queue.push_and_sync(this, &RenderingServerDefault::_init);
		DEV_ASSERT(server_task_id == tid);
	} else {
		server_thread = Thread::MAIN_ID;
		_init();
	}
}

void RenderingServerDefault::finish() {
	if (create_thread) {
		command_queue.push(this, &RenderingServerDefault::_finish);
		command_queue.push(this, &RenderingServerDefault::_thread_exit);
#if defined(WEB_ENABLED) && defined(WEBGPU_ENABLED)
		if (web_render_thread_started) {
			// _thread_exit finalizes the GPU objects in the render thread's realm
			// and stops its loops; this sync returns once that has run. The thread
			// is neither joined nor exited: the device's JS callbacks can still
			// fire in that Worker afterwards, and one that ran after the thread
			// had exited (its TLS gone) wedged the malloc lock for every thread.
			// A page ends with its process, so the idle thread costs nothing.
			command_queue.sync();
			pthread_detach(web_render_thread);
			web_render_thread_started = false;
		}
#endif
		if (server_task_id != WorkerThreadPool::INVALID_TASK_ID) {
			WorkerThreadPool::get_singleton()->wait_for_task_completion(server_task_id);
			server_task_id = WorkerThreadPool::INVALID_TASK_ID;
		}
		server_thread = Thread::MAIN_ID;
		DisplayServer::get_singleton()->gl_window_make_current(DisplayServerEnums::MAIN_WINDOW_ID);
		if (RenderingDevice *rd = RenderingDevice::get_singleton()) {
			// DisplayServer later destroys the main RD on this caller thread.
			rd->make_current();
		}
	} else {
		_finish();
	}
}

/* STATUS INFORMATION */

uint64_t RenderingServerDefault::get_rendering_info(RSE::RenderingInfo p_info) {
	if (p_info == RSE::RENDERING_INFO_TOTAL_OBJECTS_IN_FRAME) {
		return RSG::viewport->get_total_objects_drawn();
	} else if (p_info == RSE::RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME) {
		return RSG::viewport->get_total_primitives_drawn();
	} else if (p_info == RSE::RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME) {
		return RSG::viewport->get_total_draw_calls_used();
	} else if (p_info == RSE::RENDERING_INFO_PIPELINE_COMPILATIONS_CANVAS) {
		return RSG::canvas_render->get_pipeline_compilations(RSE::PIPELINE_SOURCE_CANVAS);
	} else if (p_info == RSE::RENDERING_INFO_PIPELINE_COMPILATIONS_MESH) {
		return RSG::canvas_render->get_pipeline_compilations(RSE::PIPELINE_SOURCE_MESH) + RSG::scene->get_pipeline_compilations(RSE::PIPELINE_SOURCE_MESH);
	} else if (p_info == RSE::RENDERING_INFO_PIPELINE_COMPILATIONS_SURFACE) {
		return RSG::scene->get_pipeline_compilations(RSE::PIPELINE_SOURCE_SURFACE);
	} else if (p_info == RSE::RENDERING_INFO_PIPELINE_COMPILATIONS_DRAW) {
		return RSG::canvas_render->get_pipeline_compilations(RSE::PIPELINE_SOURCE_DRAW) + RSG::scene->get_pipeline_compilations(RSE::PIPELINE_SOURCE_DRAW);
	} else if (p_info == RSE::RENDERING_INFO_PIPELINE_COMPILATIONS_SPECIALIZATION) {
		return RSG::canvas_render->get_pipeline_compilations(RSE::PIPELINE_SOURCE_SPECIALIZATION) + RSG::scene->get_pipeline_compilations(RSE::PIPELINE_SOURCE_SPECIALIZATION);
	}
	return RSG::utilities->get_rendering_info(p_info);
}

uint32_t RenderingServerDefault::get_pending_pipeline_compilation_count() const {
	uint32_t pending = PipelineCompileQueueRD::pending_count();
	RenderingDevice *rendering_device = RenderingDevice::get_singleton();
	if (rendering_device != nullptr) {
		pending += rendering_device->pipeline_get_pending_async_creation_count();
	}
	return pending;
}

RenderingDeviceEnums::DeviceType RenderingServerDefault::get_video_adapter_type() const {
	return RSG::utilities->get_video_adapter_type();
}

void RenderingServerDefault::set_frame_profiling_enabled(bool p_enable) {
	RSG::utilities->capturing_timestamps = p_enable;
}

uint64_t RenderingServerDefault::get_frame_profile_frame() {
	return frame_profile_frame;
}

Vector<RenderingServerTypes::FrameProfileArea> RenderingServerDefault::get_frame_profile() {
	return frame_profile;
}

/* TESTING */

Color RenderingServerDefault::get_default_clear_color() {
	return RSG::texture_storage->get_default_clear_color();
}

void RenderingServerDefault::set_default_clear_color(const Color &p_color) {
	RSG::texture_storage->set_default_clear_color(p_color);
}

#ifndef DISABLE_DEPRECATED
bool RenderingServerDefault::has_feature(RSE::Features p_feature) const {
	return false;
}
#endif

void RenderingServerDefault::sdfgi_set_debug_probe_select(const Vector3 &p_position, const Vector3 &p_dir) {
	RSG::scene->sdfgi_set_debug_probe_select(p_position, p_dir);
}

void RenderingServerDefault::set_print_gpu_profile(bool p_enable) {
	RSG::utilities->capturing_timestamps = p_enable;
	print_gpu_profile = p_enable;
}

RID RenderingServerDefault::get_test_cube() {
	if (!test_cube.is_valid()) {
		test_cube = _make_test_cube();
	}
	return test_cube;
}

bool RenderingServerDefault::has_os_feature(const String &p_feature) const {
	if (RSG::utilities) {
		return RSG::utilities->has_os_feature(p_feature);
	} else {
		return false;
	}
}

void RenderingServerDefault::set_debug_generate_wireframes(bool p_generate) {
	RSG::utilities->set_debug_generate_wireframes(p_generate);
}

bool RenderingServerDefault::is_low_end() const {
	return RendererCompositor::is_low_end();
}

Size2i RenderingServerDefault::get_maximum_viewport_size() const {
	if (RSG::utilities) {
		return RSG::utilities->get_maximum_viewport_size();
	} else {
		return Size2i();
	}
}

void RenderingServerDefault::_assign_mt_ids(WorkerThreadPool::TaskID p_pump_task_id) {
	server_thread = Thread::get_caller_id();
	server_task_id = p_pump_task_id;

	RenderingDevice *rd = RenderingDevice::get_singleton();
	if (rd) {
		// This is needed because the main RD is created on the main thread.
		rd->make_current();
	}
}

void RenderingServerDefault::_thread_exit() {
	exit = true;
#if defined(WEB_ENABLED) && defined(WEBGPU_ENABLED)
	if (web_render_thread_started) {
		// Still inside the flush finish() is waiting on, so the DisplayServer's
		// GPU objects are gone before the game thread tears anything else down.
		DisplayServer::get_singleton()->deferred_rendering_finalize();
	}
#endif
}

#if defined(WEB_ENABLED) && defined(WEBGPU_ENABLED)
void RenderingServerDefault::_web_start_render_thread() {
	print_verbose("RenderingServerWrapMT: Starting render thread (web pthread)");
	web_render_self = this;

	pthread_attr_t attr;
	pthread_attr_init(&attr);
	// Hand the canvas from this (application) Worker to the render Worker. The
	// surface has to be created in the same realm as the device, and Emscripten
	// re-transfers a canvas the calling thread already owns.
	int canvas_err = emscripten_pthread_attr_settransferredcanvases(&attr, "#canvas");
	if (canvas_err != 0) {
		pthread_attr_destroy(&attr);
		ERR_FAIL_MSG(vformat("Web: cannot mark #canvas for transfer to the render thread (%d).", canvas_err));
	}
	command_queue.set_consumer_notify(&RenderingServerDefault::_web_notify, this);
	int err = pthread_create(&web_render_thread, &attr, &RenderingServerDefault::_web_render_thread_entry, this);
	pthread_attr_destroy(&attr);
	ERR_FAIL_COND_MSG(err != 0, vformat("Web: pthread_create for the render thread failed (%d).", err));
	web_render_thread_started = true;

	// Queued now, run by the render tick once the device exists. push_and_sync
	// blocks this thread until then; it is a pthread, so that is a real wait and
	// the render Worker's event loop keeps running underneath it.
	command_queue.push(this, &RenderingServerDefault::_assign_mt_ids, WorkerThreadPool::INVALID_TASK_ID);
	command_queue.push_and_sync(this, &RenderingServerDefault::_init);
}

void *RenderingServerDefault::_web_render_thread_entry(void *p_self) {
	// Request the device in this Worker's realm. The adapter/device Promises
	// need this thread's event loop, so unwind to it and continue in the
	// callback; nothing after the unwind runs.
	godot_js_webgpu_worker_preinitialize(&RenderingServerDefault::_web_render_device_ready);
	emscripten_unwind_to_js_event_loop();
	return nullptr;
}

void RenderingServerDefault::_web_render_device_ready(int p_error) {
	RenderingServerDefault *self = web_render_self;
	if (p_error != 0) {
		fprintf(stderr, "Web: render thread could not create a WebGPU device.\n");
		emscripten_force_exit(EXIT_FAILURE);
		return;
	}
	Error err = DisplayServer::get_singleton()->deferred_rendering_initialize();
	if (err != OK) {
		fprintf(stderr, "Web: render thread could not initialize rendering (%d).\n", (int)err);
		emscripten_force_exit(EXIT_FAILURE);
		return;
	}
	// This thread runs from its event loop from here on. Two entry points, both
	// tasks on that loop: a wake (Atomics.waitAsync on web_wake, notified by the
	// game thread's pushes) drains queued commands up to the frame marker that
	// draw() queues in front of every _draw, and the animation-frame callback
	// resumes from that marker, so the frame is always drawn there. A standalone
	// test of a twice-transferred OffscreenCanvas showed why: with a GPU-heavy
	// frame, draws issued from ordinary tasks presented at ~5 fps even with an
	// idle animation-frame loop alongside, while draws inside the callback
	// presented every frame. The wake deliberately avoids Emscripten's mailbox,
	// whose notification is a postMessage routed through the browser main
	// thread. The keepalive is what stops Emscripten treating the thread as
	// finished after the unwind above.
	emscripten_runtime_keepalive_push();
	// Only now may queued commands run: _assign_mt_ids and _init were pushed
	// the moment the thread was created, and executing them without a device
	// dies in the renderer's bring-up. Wakes so far were ignored (_web_drain),
	// so take the first drain explicitly before arming the wait.
	self->web_render_ready = true;
	self->_web_drain();
	self->_web_arm_wait();
	emscripten_request_animation_frame_loop(&RenderingServerDefault::_web_render_raf, self);
}

void RenderingServerDefault::_web_notify(void *p_self) {
	// Called by the command queue, under its mutex, on every push. Never blocks.
	RenderingServerDefault *self = static_cast<RenderingServerDefault *>(p_self);
	if (!self->web_render_thread_started) {
		return;
	}
	self->web_wake.fetch_add(1, std::memory_order_release);
	emscripten_atomic_notify(&self->web_wake, 1);
}

void RenderingServerDefault::_web_arm_wait() {
	// Render thread. A push that landed since the last drain makes the wait
	// refuse to register (NOT_EQUAL); drain and try again.
	while (true) {
		uint32_t seen = web_wake.load(std::memory_order_acquire);
		ATOMICS_WAIT_TOKEN_T token = emscripten_atomic_wait_async(&web_wake, seen, &RenderingServerDefault::_web_wake_cb, this, EMSCRIPTEN_WAIT_ASYNC_INFINITY);
		if (EMSCRIPTEN_IS_VALID_WAIT_TOKEN(token)) {
			return;
		}
		_web_drain();
	}
}

void RenderingServerDefault::_web_wake_cb(int32_t *p_addr, uint32_t p_value, ATOMICS_WAIT_RESULT_T p_result, void *p_self) {
	RenderingServerDefault *self = static_cast<RenderingServerDefault *>(p_self);
	self->_web_drain();
	if (!self->exit) {
		self->_web_arm_wait();
	}
}

void RenderingServerDefault::_web_drain() {
	// Render thread, from a wake. Runs queued commands until the queue is empty
	// or the frame marker pauses the flush; a paused flush is left for the
	// animation-frame callback. After exit the thread simply stays idle:
	// nothing re-arms the wait, the animation-frame loop stops, and the
	// keepalive is kept so Emscripten does not retire the thread under the
	// device's remaining callbacks.
	if (!web_render_ready) {
		return;
	}
	if (!command_queue.is_flush_paused()) {
		command_queue.flush_all();
	}
}

void RenderingServerDefault::_web_frame_marker() {
	// Queued by draw() right before _draw; see _web_render_raf.
	command_queue.request_flush_pause();
}

bool RenderingServerDefault::_web_render_raf(double p_time, void *p_self) {
	// Once per animation frame, and the only place a frame is drawn: resumes the
	// flush the frame marker paused, which runs _draw and whatever the game
	// thread queued after it, up to the next marker. With nothing paused it is a
	// plain drain.
	RenderingServerDefault *self = static_cast<RenderingServerDefault *>(p_self);
	if (self->exit) {
		return false;
	}
	if (self->web_render_ready) {
		self->command_queue.flush_all();
	}
	return true;
}
#endif

void RenderingServerDefault::_thread_loop() {
	DisplayServer::get_singleton()->gl_window_make_current(DisplayServerEnums::MAIN_WINDOW_ID); // Move GL to this thread.

	while (!exit) {
		WorkerThreadPool::get_singleton()->yield();
		command_queue.flush_all();
	}

	DisplayServer::get_singleton()->release_rendering_thread();
}

/* INTERPOLATION */

void RenderingServerDefault::set_physics_interpolation_enabled(bool p_enabled) {
	RSG::canvas->set_physics_interpolation_enabled(p_enabled);
	RSG::scene->set_physics_interpolation_enabled(p_enabled);
}

/* EVENT QUEUING */

void RenderingServerDefault::sync() {
	if (create_thread) {
		command_queue.sync();
	} else {
		command_queue.flush_all(); // Flush all pending from other threads.
	}
}

void RenderingServerDefault::draw(bool p_present, double frame_step) {
	ERR_FAIL_COND_MSG(!Thread::is_main_thread(), "Manually triggering the draw function from the RenderingServer can only be done on the main thread. Call this function from the main thread or use call_deferred().");
	// Needs to be done before changes is reset to 0, to not force the editor to redraw.
	RS::get_singleton()->emit_signal(SNAME("frame_pre_draw"));
	changes = 0;
	if (create_thread) {
#if defined(WEB_ENABLED) && defined(WEBGPU_ENABLED)
		if (web_render_thread_started) {
			// The frame must be drawn from the render thread's animation-frame
			// callback; this stops the drain right before it (see _web_render_raf).
			command_queue.push(this, &RenderingServerDefault::_web_frame_marker);
		}
#endif
		command_queue.push(this, &RenderingServerDefault::_draw, p_present, frame_step);
	} else {
		_draw(p_present, frame_step);
	}
}

void RenderingServerDefault::tick() {
	RSG::canvas->tick();
	RSG::scene->tick();
}

void RenderingServerDefault::pre_draw(bool p_will_draw) {
	RSG::scene->pre_draw(p_will_draw);
}

void RenderingServerDefault::_call_on_render_thread(const Callable &p_callable) {
	p_callable.call();
}

RenderingServerDefault::RenderingServerDefault(bool p_create_thread) {
	RenderingServer::init();

	create_thread = p_create_thread;
}

RenderingServerDefault::~RenderingServerDefault() {
}
