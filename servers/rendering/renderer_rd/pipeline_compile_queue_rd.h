/**************************************************************************/
/*  pipeline_compile_queue_rd.h                                           */
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

#include "core/templates/local_vector.h"

// Pipeline compilations waiting to run on the thread that owns the device.
//
// Drivers that can only be called from one thread (WebGPU in the browser, where
// the JavaScript objects backing the device live in that thread's context)
// cannot hand pipeline compilation to WorkerThreadPool. Doing it inline instead
// is what the renderer is written to avoid: it asks for a specialized pipeline
// *without* waiting, expects nothing back, and draws with the ubershader until
// the real one is ready. Compiling inline turns that into a stall of however
// long the driver takes - a few hundred milliseconds for a scene shader.
//
// So the work is queued here and a bounded slice of it runs each frame, on the
// same thread, while the ubershader covers the gap. A caller that genuinely
// cannot proceed without a given pipeline can still force it with compile_now().
class PipelineCompileQueueRD {
public:
	// One queued compilation. Owned by the queue once pushed.
	class Task {
	public:
		virtual void compile() = 0;
		virtual uint32_t key_hash() const = 0;
		virtual const void *owner() const = 0;
		virtual ~Task() {}
	};

	static void push(Task *p_task);

	// Run a specific queued compilation now, if it is still queued. Returns true
	// if it was found and run.
	static bool compile_now(uint32_t p_key_hash);

	// Run queued compilations until the budget is spent. Always runs at least one
	// so the queue cannot stall completely, however slow a single compile is.
	static void process(double p_budget_msec);

	// Drop anything queued for an owner that is going away.
	static void remove_owner(const void *p_owner);

	static uint32_t pending_count();

private:
	static LocalVector<Task *> queue;
};
