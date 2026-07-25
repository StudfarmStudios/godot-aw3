/* Force-included when building the web runtime with AOT-compiled assemblies.
 * runtime.c calls register_aot_modules(), which is defined in the generated
 * driver-gen.c, but the runtime pack ships no declaration for it. */
#pragma once

void register_aot_modules(void);
