using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using Godot.NativeInterop;

#nullable enable

namespace Godot
{
    internal static class DisposablesTracker
    {
        [UnmanagedCallersOnly]
        internal static void OnGodotShuttingDown()
        {
            try
            {
                OnGodotShuttingDownImpl();
            }
            catch (Exception e)
            {
                ExceptionUtils.LogException(e);
            }
        }

        private static void OnGodotShuttingDownImpl()
        {
            bool isStdoutVerbose;

            try
            {
                isStdoutVerbose = OS.IsStdOutVerbose();
            }
            catch (ObjectDisposedException)
            {
                // OS singleton already disposed. Maybe OnUnloading was called twice.
                isStdoutVerbose = false;
            }

            if (isStdoutVerbose)
                GD.Print("Unloading: Disposing tracked instances...");

            // Dispose Godot Objects first, and only then dispose other disposables
            // like StringName, NodePath, Godot.Collections.Array/Dictionary, etc.
            // The Godot Object Dispose() method may need any of the later instances.

            foreach (GodotObject self in GodotObjectInstances.LiveTargets<GodotObject>())
                self.Dispose();

            foreach (IDisposable self in OtherInstances.LiveTargets<IDisposable>())
                self.Dispose();

            if (isStdoutVerbose)
                GD.Print("Unloading: Finished disposing tracked instances.");
        }

        // Every wrapper handed out is tracked so shutdown can dispose what is still alive.
        // The table holds a weak GC handle per wrapper in plain integer arrays, so tracking
        // costs no managed object beyond the handle. It used to be a ConcurrentDictionary
        // keyed by a WeakReference: two more objects per wrapper (the WeakReference with a
        // finalizer of its own, and the dictionary's node), and every add and remove wrote
        // a reference into a bucket array big enough for the large-object space, whose
        // dirty cards every young collection then had to scan. On the web build, where the
        // collector stops the game, those were a large part of each collection's pause.
        private static readonly WeakHandleTable GodotObjectInstances = new();
        private static readonly WeakHandleTable OtherInstances = new();

        public static long RegisterGodotObject(GodotObject godotObject)
            => GodotObjectInstances.Add(godotObject);

        public static long RegisterDisposable(IDisposable disposable)
            => OtherInstances.Add(disposable);

        public static void UnregisterGodotObject(GodotObject godotObject, long token)
        {
            if (!GodotObjectInstances.Remove(token))
                throw new ArgumentException("Godot Object not registered.", nameof(token));
        }

        public static void UnregisterDisposable(long token)
        {
            if (!OtherInstances.Remove(token))
                throw new ArgumentException("Disposable not registered.", nameof(token));
        }

        /// <summary>
        /// Weak GC handles in slots. A token is the slot plus one in its low half and the
        /// slot's generation in its high half, so a token kept past its removal can never
        /// release the handle of whatever was registered in the slot since.
        /// </summary>
        private sealed class WeakHandleTable
        {
            private readonly object _lock = new();
            private IntPtr[] _handles = new IntPtr[1024];
            private int[] _generations = new int[1024];
            private int[] _nextFree = new int[1024];
            private int _freeHead = -1;
            private int _used;

            public long Add(object target)
            {
                IntPtr handle = GCHandle.ToIntPtr(GCHandle.Alloc(target, GCHandleType.Weak));
                lock (_lock)
                {
                    int slot;
                    if (_freeHead >= 0)
                    {
                        slot = _freeHead;
                        _freeHead = _nextFree[slot];
                    }
                    else
                    {
                        if (_used == _handles.Length)
                        {
                            int size = _used * 2;
                            Array.Resize(ref _handles, size);
                            Array.Resize(ref _generations, size);
                            Array.Resize(ref _nextFree, size);
                        }
                        slot = _used++;
                    }
                    _handles[slot] = handle;
                    return ((long)_generations[slot] << 32) | (uint)(slot + 1);
                }
            }

            public bool Remove(long token)
            {
                int slot = (int)(uint)token - 1;
                int generation = (int)(token >> 32);
                IntPtr handle;
                lock (_lock)
                {
                    if (slot < 0 || slot >= _used || _generations[slot] != generation)
                        return false;
                    handle = _handles[slot];
                    if (handle == IntPtr.Zero)
                        return false;
                    _handles[slot] = IntPtr.Zero;
                    _generations[slot] = generation + 1;
                    _nextFree[slot] = _freeHead;
                    _freeHead = slot;
                }
                GCHandle.FromIntPtr(handle).Free();
                return true;
            }

            /// <summary>The registered objects still alive, strongly held, for shutdown.</summary>
            public List<T> LiveTargets<T>() where T : class
            {
                var live = new List<T>();
                lock (_lock)
                {
                    for (int i = 0; i < _used; i++)
                    {
                        IntPtr handle = _handles[i];
                        if (handle != IntPtr.Zero && GCHandle.FromIntPtr(handle).Target is T target)
                            live.Add(target);
                    }
                }
                return live;
            }
        }
    }
}
