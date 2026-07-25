/**************************************************************************/
/*  pipeline_compile_queue_rd.cpp                                         */
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

#include "pipeline_compile_queue_rd.h"

#include "core/os/os.h"

LocalVector<PipelineCompileQueueRD::Task *> PipelineCompileQueueRD::queue;

void PipelineCompileQueueRD::push(Task *p_task) {
	if (p_task == nullptr) {
		return;
	}
	queue.push_back(p_task);
}

bool PipelineCompileQueueRD::compile_now(uint32_t p_key_hash) {
	for (uint32_t i = 0; i < queue.size(); i++) {
		if (queue[i]->key_hash() != p_key_hash) {
			continue;
		}
		Task *task = queue[i];
		queue.remove_at(i);
		task->compile();
		memdelete(task);
		return true;
	}
	return false;
}

void PipelineCompileQueueRD::process(double p_budget_msec) {
	if (queue.is_empty()) {
		return;
	}

	uint64_t started = OS::get_singleton()->get_ticks_usec();
	uint64_t budget_usec = (uint64_t)(p_budget_msec * 1000.0);
	do {
		Task *task = queue[0];
		queue.remove_at(0);
		task->compile();
		memdelete(task);
	} while (!queue.is_empty() && (OS::get_singleton()->get_ticks_usec() - started) < budget_usec);
}

void PipelineCompileQueueRD::remove_owner(const void *p_owner) {
	uint32_t i = 0;
	while (i < queue.size()) {
		if (queue[i]->owner() == p_owner) {
			memdelete(queue[i]);
			queue.remove_at(i);
		} else {
			i++;
		}
	}
}

uint32_t PipelineCompileQueueRD::pending_count() {
	return queue.size();
}
