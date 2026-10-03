/**************************************************************************/
/*  probe.c                                                               */
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

// Force the proxy caller to retire its stack before the target finishes.
#include <emscripten/proxying.h>
#include <emscripten/threading.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

static em_proxying_queue *queue;
static pthread_t target;
static atomic_int forced, unlocked, stack_reused, finished, running = 1;
static atomic_int calls;
static atomic_uintptr_t context, condition;

static void wait_for(atomic_int *flag) {
	while (!atomic_load(flag)) {
		emscripten_futex_wait(flag, 0, 100);
	}
}

static void publish(atomic_int *flag) {
	atomic_store(flag, 1);
	emscripten_futex_wake(flag, 1);
}

// Test-only hooks inserted into a copy of the SDK source by build.py.
void aw3_probe_before_lock(void) {
	if (atomic_load(&forced)) {
		wait_for(&unlocked);
	}
}

void aw3_probe_after_unlock(void *ctx, void *cond) {
	if (atomic_load(&forced)) {
		atomic_store(&context, (uintptr_t)ctx);
		atomic_store(&condition, (uintptr_t)cond);
		publish(&unlocked);
		wait_for(&stack_reused);
	}
}

static void count_call(void *unused) {
	atomic_fetch_add(&calls, 1);
}

static void *serve(void *unused) {
	while (atomic_load(&running)) {
		emscripten_proxy_execute_queue(queue);
		if (atomic_load(&stack_reused)) {
			publish(&finished);
		}
	}
	return NULL;
}

__attribute__((noinline)) static void reuse_stack(void) {
	volatile unsigned char bytes[32768];
	uintptr_t ctx = atomic_load(&context);
	if (ctx < (uintptr_t)bytes || ctx + 128 >= (uintptr_t)(bytes + sizeof(bytes))) {
		fprintf(stderr, "PROXY_CONTEXT_FAIL context was not inside reused stack\n");
		abort();
	}
	for (unsigned i = 0; i < sizeof(bytes); i++) {
		bytes[i] = 0xa5;
	}
	// New stack contents happen to resemble a private, unlocked condition
	// variable whose former waiter link is now unrelated (unaligned) data.
	// All these writes are to the live bytes array, after the proxy returned.
	size_t cond_offset = atomic_load(&condition) - (uintptr_t)bytes;
	for (unsigned i = 0; i < sizeof(int); i++) {
		bytes[cond_offset + offsetof(pthread_cond_t, __u.__p[0]) + i] = 0;
		bytes[cond_offset + offsetof(pthread_cond_t, __u.__vi[8]) + i] = 0;
	}
	publish(&stack_reused);
	wait_for(&finished);
	// Keep the new stack object live while the target finishes its old context.
	if (bytes[0] != 0xa5 || bytes[sizeof(bytes) - 1] != 0xa5) {
		abort();
	}
}

static void *stress(void *unused) {
	for (int i = 0; i < 10000; i++) {
		if (!emscripten_proxy_sync(queue, target, count_call, NULL)) {
			abort();
		}
	}
	return NULL;
}

int main(void) {
	queue = em_proxying_queue_create();
	if (!queue || pthread_create(&target, NULL, serve, NULL)) {
		abort();
	}
	atomic_store(&forced, 1);
	if (!emscripten_proxy_sync(queue, target, count_call, NULL)) {
		abort();
	}
	reuse_stack();
	atomic_store(&forced, 0);
	pthread_t callers[4];
	for (int i = 0; i < 4; i++) {
		if (pthread_create(&callers[i], NULL, stress, NULL)) {
			abort();
		}
	}
	for (int i = 0; i < 4; i++) {
		pthread_join(callers[i], NULL);
	}
	atomic_store(&running, 0);
	pthread_join(target, NULL);
	em_proxying_queue_destroy(queue);
	if (atomic_load(&calls) != 40001) {
		abort();
	}
	printf("PROXY_CONTEXT_PASS forced_stack_reuse=1 sync_calls=%d\n", atomic_load(&calls));
	return 0;
}
