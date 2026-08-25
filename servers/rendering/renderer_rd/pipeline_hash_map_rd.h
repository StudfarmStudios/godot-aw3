/**************************************************************************/
/*  pipeline_hash_map_rd.h                                                */
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

#include "core/object/worker_thread_pool.h"
#include "core/os/mutex.h"
#include "core/templates/hash_map.h"
#include "core/templates/local_vector.h"
#include "core/templates/rb_map.h"
#include "core/templates/rb_set.h"
#include "core/templates/rid.h"
#include "core/templates/vector.h"
#include "servers/rendering/renderer_rd/pipeline_compile_queue_rd.h"
#include "servers/rendering/rendering_device.h"
#include "servers/rendering/rendering_server_enums.h"

#define PRINT_PIPELINE_COMPILATION_KEYS 0

template <typename Key, typename CreationClass, typename CreationFunction>
class PipelineHashMapRD {
private:
	CreationClass *creation_object = nullptr;
	CreationFunction creation_function = nullptr;
	Mutex *compilations_mutex = nullptr;
	uint32_t *compilations = nullptr;
	RBMap<uint32_t, RID> hash_map;
	LocalVector<Pair<uint32_t, RID>> compiled_queue;
	Mutex compiled_queue_mutex;
	RBSet<uint32_t> compilation_set;
	HashMap<uint32_t, WorkerThreadPool::TaskID> compilation_tasks;
	Mutex local_mutex;

	bool _add_new_pipelines_to_map() {
		thread_local Vector<uint32_t> hashes_added;
		hashes_added.clear();

		{
			MutexLock lock(compiled_queue_mutex);
			// A pipeline built asynchronously is not usable the moment it is handed
			// over - binding it before the driver has it would draw nothing. Leave
			// those queued and pick them up on a later pass; the ubershader covers
			// the gap in the meantime.
			uint32_t kept = 0;
			for (uint32_t i = 0; i < compiled_queue.size(); i++) {
				const Pair<uint32_t, RID> &pair = compiled_queue[i];
				if (!RD::get_singleton()->pipeline_is_ready(pair.second)) {
					compiled_queue[kept++] = pair;
					continue;
				}
				hash_map[pair.first] = pair.second;
				hashes_added.push_back(pair.first);
			}
			compiled_queue.resize(kept);
		}

		{
			MutexLock local_lock(local_mutex);
			for (uint32_t hash : hashes_added) {
				HashMap<uint32_t, WorkerThreadPool::TaskID>::Iterator task_it = compilation_tasks.find(hash);
				if (task_it != compilation_tasks.end()) {
					compilation_tasks.remove(task_it);
				}
			}
		}

		return !hashes_added.is_empty();
	}

	void _wait_for_all_pipelines() {
		thread_local LocalVector<WorkerThreadPool::TaskID> tasks_to_wait;
		tasks_to_wait.clear();
		{
			MutexLock local_lock(local_mutex);
			for (KeyValue<uint32_t, WorkerThreadPool::TaskID> key_value : compilation_tasks) {
				tasks_to_wait.push_back(key_value.value);
			}
		}

		for (WorkerThreadPool::TaskID task_id : tasks_to_wait) {
			WorkerThreadPool::get_singleton()->wait_for_task_completion(task_id);
		}
	}

	// A compilation waiting its turn on the device's thread.
	class DeferredCompile : public PipelineCompileQueueRD::Task {
		PipelineHashMapRD *map = nullptr;
		Key key;
		uint32_t hash = 0;

	public:
		DeferredCompile(PipelineHashMapRD *p_map, const Key &p_key, uint32_t p_hash) :
				map(p_map), key(p_key), hash(p_hash) {}

		virtual void compile() override {
			// Asynchronous where the driver supports it: the compile then happens off
			// this thread entirely and the pipeline appears once it is ready. Nothing
			// waits on it - the renderer is already drawing with the ubershader.
			RD::get_singleton()->pipeline_set_async_creation(true);
			(map->creation_object->*map->creation_function)(key);
			RD::get_singleton()->pipeline_set_async_creation(false);
		}
		virtual uint32_t key_hash() const override { return hash; }
		virtual const void *owner() const override { return map; }
	};

public:
	void add_compiled_pipeline(uint32_t p_hash, RID p_pipeline) {
		compiled_queue_mutex.lock();
		compiled_queue.push_back({ p_hash, p_pipeline });
		compiled_queue_mutex.unlock();
	}

	// Start compilation of a pipeline ahead of time in the background. Returns true if the compilation was started, false if it wasn't required. Source is only used for collecting statistics.
	void compile_pipeline(const Key &p_key, uint32_t p_key_hash, RSE::PipelineSource p_source, bool p_high_priority) {
		DEV_ASSERT((creation_object != nullptr) && (creation_function != nullptr) && "Creation object and function was not set before attempting to compile a pipeline.");

		MutexLock local_lock(local_mutex);
		if (compilation_set.has(p_key_hash)) {
			// Check if the pipeline was already submitted.
			return;
		}

		// Record the pipeline as submitted, a task can't be started for it again.
		compilation_set.insert(p_key_hash);

		if (compilations_mutex != nullptr) {
			MutexLock compilations_lock(*compilations_mutex);
			compilations[p_source]++;
		}

#if PRINT_PIPELINE_COMPILATION_KEYS
		String source_name = "UNKNOWN";
		switch (p_source) {
			case RSE::PIPELINE_SOURCE_CANVAS:
				source_name = "CANVAS";
				break;
			case RSE::PIPELINE_SOURCE_MESH:
				source_name = "MESH";
				break;
			case RSE::PIPELINE_SOURCE_SURFACE:
				source_name = "SURFACE";
				break;
			case RSE::PIPELINE_SOURCE_DRAW:
				source_name = "DRAW";
				break;
			case RSE::PIPELINE_SOURCE_SPECIALIZATION:
				source_name = "SPECIALIZATION";
				break;
		}

		print_line("HASH:", p_key_hash, "SOURCE:", source_name);
#endif

		if (RD::get_singleton()->gpu_calls_main_thread_only()) {
			// Driver is bound to the device's thread, so there is no background task
			// to hand this to. Compiling here and now would stall the frame, which is
			// exactly what the caller avoids by not asking to wait - it draws with the
			// ubershader meanwhile. Queue it and let a bounded slice run each frame.
			if (p_high_priority) {
				// The caller is about to block on this one anyway.
				(creation_object->*creation_function)(p_key);
			} else {
				PipelineCompileQueueRD::push(memnew(DeferredCompile(this, p_key, p_key_hash)));
			}
			return;
		}

		// Queue a background compilation task.
		WorkerThreadPool::TaskID task_id = WorkerThreadPool::get_singleton()->add_template_task(creation_object, creation_function, p_key, p_high_priority, "PipelineCompilation");
		compilation_tasks.insert(p_key_hash, task_id);
	}

	void wait_for_pipeline(uint32_t p_key_hash) {
		WorkerThreadPool::TaskID task_id_to_wait = WorkerThreadPool::INVALID_TASK_ID;

		{
			MutexLock local_lock(local_mutex);
			if (!compilation_set.has(p_key_hash)) {
				// The pipeline was never submitted, we can't wait for it.
				return;
			}

			if (RD::get_singleton()->gpu_calls_main_thread_only()) {
				// It is sitting in the deferred queue: run it now, since the caller
				// cannot continue without it.
				PipelineCompileQueueRD::compile_now(p_key_hash);
				return;
			}

			HashMap<uint32_t, WorkerThreadPool::TaskID>::Iterator task_it = compilation_tasks.find(p_key_hash);
			if (task_it != compilation_tasks.end()) {
				// Wait for and remove the compilation task if it exists.
				task_id_to_wait = task_it->value;
				compilation_tasks.remove(task_it);
			}
		}

		if (task_id_to_wait != WorkerThreadPool::INVALID_TASK_ID) {
			WorkerThreadPool::get_singleton()->wait_for_task_completion(task_id_to_wait);
		}
	}

	// Retrieve a pipeline. It'll return an empty pipeline if it's not available yet, but it'll be guaranteed to succeed if 'wait for compilation' is true and stall as necessary. Source is just an optional number to aid debugging.
	RID get_pipeline(const Key &p_key, uint32_t p_key_hash, bool p_wait_for_compilation, RSE::PipelineSource p_source) {
		RBMap<uint32_t, RID>::Element *e = hash_map.find(p_key_hash);

		if (e == nullptr) {
			// Check if there's any new pipelines that need to be added and try again. This method triggers a mutex lock.
			if (_add_new_pipelines_to_map()) {
				e = hash_map.find(p_key_hash);
			}
		}

		if (e == nullptr) {
			// Request compilation. The method will ignore the request if it's already being compiled.
			compile_pipeline(p_key, p_key_hash, p_source, p_wait_for_compilation);

			if (p_wait_for_compilation) {
				wait_for_pipeline(p_key_hash);
				_add_new_pipelines_to_map();

				e = hash_map.find(p_key_hash);
				if (e != nullptr) {
					return e->value();
				} else {
					// Pipeline could not be compiled due to an internal error. Store an empty RID so compilation is not attempted again.
					hash_map[p_key_hash] = RID();
					return RID();
				}
			} else {
				return RID();
			}
		} else {
			return e->value();
		}
	}

	// Delete all cached pipelines. Can stall if background compilation is in progress.
	void clear_pipelines() {
		PipelineCompileQueueRD::remove_owner(this);
		_wait_for_all_pipelines();

		// Asynchronous driver pipelines can still be waiting in compiled_queue.
		// They must be freed here too: carrying them across a shader-map reset lets
		// a stale RID re-enter hash_map after its shader has gone away, and leaves
		// RenderingDevice to report invalid frees during renderer teardown.
		thread_local LocalVector<RID> queued_pipelines;
		queued_pipelines.clear();
		{
			MutexLock lock(compiled_queue_mutex);
			for (const Pair<uint32_t, RID> &pair : compiled_queue) {
				queued_pipelines.push_back(pair.second);
			}
			compiled_queue.clear();
		}

		for (KeyValue<uint32_t, RID> entry : hash_map) {
			RD::get_singleton()->free_rid(entry.value);
		}
		for (RID pipeline : queued_pipelines) {
			RD::get_singleton()->free_rid(pipeline);
		}

		hash_map.clear();
		{
			MutexLock local_lock(local_mutex);
			compilation_set.clear();
			compilation_tasks.clear();
		}
	}

	// Set the external pipeline compilations array to increase the counters on every time a pipeline is compiled.
	void set_compilations(uint32_t *p_compilations, Mutex *p_compilations_mutex) {
		compilations = p_compilations;
		compilations_mutex = p_compilations_mutex;
	}

	void set_creation_object_and_function(CreationClass *p_creation_object, CreationFunction p_creation_function) {
		creation_object = p_creation_object;
		creation_function = p_creation_function;
	}

	PipelineHashMapRD() {}

	~PipelineHashMapRD() {
		clear_pipelines();
	}
};
