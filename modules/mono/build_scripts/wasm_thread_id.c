/* Linked into threaded web builds on a .NET 10 runtime pack in place of the
 * pack's SystemNative_TryGetUInt32OSThreadId (via -Wl,--wrap).
 *
 * System.Threading.Lock identifies its owner by this ID. The .NET 10 browser
 * packs compile System.Native without -pthread, so it returns 1 on every
 * thread, also in the multithreaded pack. Every thread then counts as the
 * owner, and any number of threads hold a Lock at once. .NET 9 returned -1
 * here, which makes Lock fall back to the managed thread ID. */
#include <pthread.h>
#include <stdint.h>

uint32_t __wrap_SystemNative_TryGetUInt32OSThreadId(void) {
	return (uint32_t)(uintptr_t)pthread_self();
}
