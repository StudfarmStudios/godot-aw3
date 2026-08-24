#pragma warning disable CA1707 // Identifiers should not contain underscores
#pragma warning disable IDE1006 // Naming rule violation
// ReSharper disable InconsistentNaming

using System;
using System.Runtime.CompilerServices;

namespace Godot.NativeInterop
{
    /*
     * By-value wrappers over the out-parameter interop entry points.
     *
     * The native callbacks that produce a Godot interop struct return it
     * through an out-pointer rather than by value, because a by-value
     * struct return is rejected by the wasm SDK's P/Invoke table generator
     * (WASM0001) - and a rejected entry is dropped silently, leaving the
     * callback on the function-pointer path, where Mono's AOT compiler
     * refuses the marshalling wrapper and the call runs on the interpreter.
     *
     * Keeping the by-value shape here means call sites are unchanged and
     * costs nothing: this is ordinary managed IL, not an interop boundary.
     *
     * NOT partial, on purpose - the generator collects partial definitions
     * in order to build the UnmanagedCallbacks struct, which has to stay in
     * step with the array at the bottom of glue/runtime_interop.cpp.
     */
    public static unsafe partial class NativeFuncs
    {
        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        public static delegate* unmanaged<godot_bool, IntPtr> godotsharp_get_class_constructor(
            scoped in godot_string_name p_classname)
        {
            delegate* unmanaged<godot_bool, IntPtr> dest;
            godotsharp_get_class_constructor(p_classname, &dest);
            return dest;
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        internal static godot_variant godotsharp_callable_call(scoped in godot_callable p_callable,
            godot_variant** p_args, int p_arg_count, out godot_variant_call_error p_call_error)
        {
            godot_variant dest;
            godotsharp_callable_call(p_callable, p_args, p_arg_count, out p_call_error, &dest);
            return dest;
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        public static godot_variant godotsharp_method_bind_call(IntPtr p_method_bind, IntPtr p_instance,
            godot_variant** p_args, int p_arg_count, out godot_variant_call_error p_call_error)
        {
            godot_variant dest;
            godotsharp_method_bind_call(p_method_bind, p_instance, p_args, p_arg_count, out p_call_error, &dest);
            return dest;
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        public static godot_node_path godotsharp_variant_as_node_path(scoped in godot_variant p_self)
        {
            godot_node_path dest;
            godotsharp_variant_as_node_path(p_self, &dest);
            return dest;
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        public static godot_callable godotsharp_variant_as_callable(scoped in godot_variant p_self)
        {
            godot_callable dest;
            godotsharp_variant_as_callable(p_self, &dest);
            return dest;
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        public static godot_signal godotsharp_variant_as_signal(scoped in godot_variant p_self)
        {
            godot_signal dest;
            godotsharp_variant_as_signal(p_self, &dest);
            return dest;
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        public static godot_dictionary godotsharp_variant_as_dictionary(scoped in godot_variant p_self)
        {
            godot_dictionary dest;
            godotsharp_variant_as_dictionary(p_self, &dest);
            return dest;
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        public static godot_array godotsharp_variant_as_array(scoped in godot_variant p_self)
        {
            godot_array dest;
            godotsharp_variant_as_array(p_self, &dest);
            return dest;
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        public static godot_packed_byte_array godotsharp_variant_as_packed_byte_array(scoped in godot_variant p_self)
        {
            godot_packed_byte_array dest;
            godotsharp_variant_as_packed_byte_array(p_self, &dest);
            return dest;
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        public static godot_packed_int32_array godotsharp_variant_as_packed_int32_array(scoped in godot_variant p_self)
        {
            godot_packed_int32_array dest;
            godotsharp_variant_as_packed_int32_array(p_self, &dest);
            return dest;
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        public static godot_packed_int64_array godotsharp_variant_as_packed_int64_array(scoped in godot_variant p_self)
        {
            godot_packed_int64_array dest;
            godotsharp_variant_as_packed_int64_array(p_self, &dest);
            return dest;
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        public static godot_packed_float32_array godotsharp_variant_as_packed_float32_array(scoped in godot_variant p_self)
        {
            godot_packed_float32_array dest;
            godotsharp_variant_as_packed_float32_array(p_self, &dest);
            return dest;
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        public static godot_packed_float64_array godotsharp_variant_as_packed_float64_array(scoped in godot_variant p_self)
        {
            godot_packed_float64_array dest;
            godotsharp_variant_as_packed_float64_array(p_self, &dest);
            return dest;
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        public static godot_packed_string_array godotsharp_variant_as_packed_string_array(scoped in godot_variant p_self)
        {
            godot_packed_string_array dest;
            godotsharp_variant_as_packed_string_array(p_self, &dest);
            return dest;
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        public static godot_packed_vector2_array godotsharp_variant_as_packed_vector2_array(scoped in godot_variant p_self)
        {
            godot_packed_vector2_array dest;
            godotsharp_variant_as_packed_vector2_array(p_self, &dest);
            return dest;
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        public static godot_packed_vector3_array godotsharp_variant_as_packed_vector3_array(scoped in godot_variant p_self)
        {
            godot_packed_vector3_array dest;
            godotsharp_variant_as_packed_vector3_array(p_self, &dest);
            return dest;
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        public static godot_packed_vector4_array godotsharp_variant_as_packed_vector4_array(scoped in godot_variant p_self)
        {
            godot_packed_vector4_array dest;
            godotsharp_variant_as_packed_vector4_array(p_self, &dest);
            return dest;
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        public static godot_packed_color_array godotsharp_variant_as_packed_color_array(scoped in godot_variant p_self)
        {
            godot_packed_color_array dest;
            godotsharp_variant_as_packed_color_array(p_self, &dest);
            return dest;
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        public static godot_packed_byte_array godotsharp_packed_byte_array_new_mem_copy(byte* p_src, int p_length)
        {
            godot_packed_byte_array dest;
            godotsharp_packed_byte_array_new_mem_copy(p_src, p_length, &dest);
            return dest;
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        public static godot_packed_int32_array godotsharp_packed_int32_array_new_mem_copy(int* p_src, int p_length)
        {
            godot_packed_int32_array dest;
            godotsharp_packed_int32_array_new_mem_copy(p_src, p_length, &dest);
            return dest;
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        public static godot_packed_int64_array godotsharp_packed_int64_array_new_mem_copy(long* p_src, int p_length)
        {
            godot_packed_int64_array dest;
            godotsharp_packed_int64_array_new_mem_copy(p_src, p_length, &dest);
            return dest;
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        public static godot_packed_float32_array godotsharp_packed_float32_array_new_mem_copy(float* p_src, int p_length)
        {
            godot_packed_float32_array dest;
            godotsharp_packed_float32_array_new_mem_copy(p_src, p_length, &dest);
            return dest;
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        public static godot_packed_float64_array godotsharp_packed_float64_array_new_mem_copy(double* p_src, int p_length)
        {
            godot_packed_float64_array dest;
            godotsharp_packed_float64_array_new_mem_copy(p_src, p_length, &dest);
            return dest;
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        public static godot_packed_vector2_array godotsharp_packed_vector2_array_new_mem_copy(Vector2* p_src, int p_length)
        {
            godot_packed_vector2_array dest;
            godotsharp_packed_vector2_array_new_mem_copy(p_src, p_length, &dest);
            return dest;
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        public static godot_packed_vector3_array godotsharp_packed_vector3_array_new_mem_copy(Vector3* p_src, int p_length)
        {
            godot_packed_vector3_array dest;
            godotsharp_packed_vector3_array_new_mem_copy(p_src, p_length, &dest);
            return dest;
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        public static godot_packed_vector4_array godotsharp_packed_vector4_array_new_mem_copy(Vector4* p_src, int p_length)
        {
            godot_packed_vector4_array dest;
            godotsharp_packed_vector4_array_new_mem_copy(p_src, p_length, &dest);
            return dest;
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        public static godot_packed_color_array godotsharp_packed_color_array_new_mem_copy(Color* p_src, int p_length)
        {
            godot_packed_color_array dest;
            godotsharp_packed_color_array_new_mem_copy(p_src, p_length, &dest);
            return dest;
        }

    }
}
