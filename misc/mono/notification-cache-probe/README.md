# C# notification fast-path regression probe

This headless C# project checks the behavior affected by the C# notification
negative cache:

It targets .NET 9 and `Godot.NET.Sdk/4.7.1`. Install those locally and use a
Godot 4.7.1 Mono editor binary from the engine revision being tested. The probe
has no engine experiment flags or external assets.

- a derived C# type inherits `_Notification` from a C# base type;
- `_Process` and `_PhysicsProcess` still run and have matching notification counts;
- a C# type with no `_Notification` override still receives process callbacks;
- `_ExitTree`, predelete notification, and managed `Dispose(bool)` each run once;
- a native `Timer` continues to receive its internal physics notifications;
- both managed types are freed and recreated, exercising cache initialization on
  replacement instances. Assembly reload creates replacement `CSharpInstance`s
  through the same initialization path; the implementation stores no type-global
  result that could survive a reload.
- a custom `_Notification` synchronously frees its own native owner, checking
  that the native fast path does not touch the deleted script instance when the
  managed callback returns.
- a custom `_Notification` throws on its first invocation and is invoked again,
  locking down the managed bridge contract that exceptions leave `CallError` at
  `CALL_OK` and therefore can never be cached as a missing override;
- a custom `_Notification` removes its own C# script and immediately allocates
  an unrelated instance, exercising synchronous disposal and the live-owner
  with nil-script guard. Same-owner allocator ABA is protected by the native
  generation check but is not forced by this fixture.

The free, throwing, and script-removal cases stay off-tree and assert that their
custom IDs are the first managed notifications after instance creation. A pass
reports `first_ids=9001,9002,9003`.

Build once, then run baseline and candidate engine binaries against the same
assembly. Require both exit codes to be zero:

```sh
dotnet build NotificationProbe.csproj
/path/to/baseline-godot --headless --path /absolute/path/to/notification-cache-probe --fixed-fps 60
/path/to/candidate-godot --headless --path /absolute/path/to/notification-cache-probe --fixed-fps 60
```

The first-notification case intentionally logs one
`expected first-notification probe exception`; the process must continue and
finish with `[CSHARP_NOTIFY_TEST] PASS`. Require that exception exactly once per
run; any other managed exception or `[CSHARP_NOTIFY_TEST] FAIL` is a failure.
