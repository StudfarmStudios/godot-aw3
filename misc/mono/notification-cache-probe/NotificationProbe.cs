using Godot;
using System;
using System.Collections.Generic;

public partial class NotificationProbe : Node
{
    private readonly List<string> _failures = new();
    private DerivedNotificationProbe? _derived;
    private PlainProcessProbe? _plain;
    private Timer? _nativeTimer;
    private int _timerTimeouts;
    private int _stage;
    private int _stageFrames;
    private int _completedRounds;

    public override void _Ready()
    {
        BaseNotificationProbe.ResetNotificationCounts();
        DerivedNotificationProbe.ResetCounts();
        PlainProcessProbe.ResetCounts();
        SelfFreeNotificationProbe.Calls = 0;
        SelfFreeNotificationProbe.FirstNotification = -1;
        ThrowingNotificationProbe.Calls = 0;
        ThrowingNotificationProbe.FirstNotification = -1;
        SelfReplaceNotificationProbe.ResetCounts();

        var selfFree = new SelfFreeNotificationProbe();
        selfFree.Armed = true;
        selfFree.Notification(SelfFreeNotificationProbe.SelfFreeNotification);
        Check(SelfFreeNotificationProbe.Calls == 1,
            $"self-free notification count {SelfFreeNotificationProbe.Calls}, expected 1");
        Check(SelfFreeNotificationProbe.FirstNotification == SelfFreeNotificationProbe.SelfFreeNotification,
            $"self-free first managed notification {SelfFreeNotificationProbe.FirstNotification}, expected {SelfFreeNotificationProbe.SelfFreeNotification}");

        var throwing = new ThrowingNotificationProbe();
        throwing.Notification(ThrowingNotificationProbe.ThrowingNotification);
        throwing.Notification(ThrowingNotificationProbe.ThrowingNotification);
        Check(ThrowingNotificationProbe.Calls == 2,
            $"throwing notification count {ThrowingNotificationProbe.Calls}, expected 2");
        Check(ThrowingNotificationProbe.FirstNotification == ThrowingNotificationProbe.ThrowingNotification,
            $"throwing first managed notification {ThrowingNotificationProbe.FirstNotification}, expected {ThrowingNotificationProbe.ThrowingNotification}");
        throwing.Free();

        var selfReplace = new SelfReplaceNotificationProbe();
        ulong selfReplaceId = selfReplace.GetInstanceId();
        selfReplace.Armed = true;
        selfReplace.Notification(SelfReplaceNotificationProbe.SelfReplaceNotification);
        Check(SelfReplaceNotificationProbe.Calls == 1,
            $"self-replace notification count {SelfReplaceNotificationProbe.Calls}, expected 1");
        Check(SelfReplaceNotificationProbe.FirstNotification == SelfReplaceNotificationProbe.SelfReplaceNotification,
            $"self-replace first managed notification {SelfReplaceNotificationProbe.FirstNotification}, expected {SelfReplaceNotificationProbe.SelfReplaceNotification}");
        Check(SelfReplaceNotificationProbe.DisposeCalls == 1,
            $"self-replace dispose count {SelfReplaceNotificationProbe.DisposeCalls}, expected 1");
        GodotObject? scriptlessOwner = GodotObject.InstanceFromId(selfReplaceId);
        Check(scriptlessOwner != null && GodotObject.IsInstanceValid(scriptlessOwner),
            "self-replace native owner did not survive script removal");
        Check(scriptlessOwner != null && scriptlessOwner.GetScript().VariantType == Variant.Type.Nil,
            "self-replace native owner still has a script");
        scriptlessOwner?.Free();
        Check(SelfReplaceNotificationProbe.Replacement != null && GodotObject.IsInstanceValid(SelfReplaceNotificationProbe.Replacement),
            "self-replace callback did not allocate a replacement C# instance");
        SelfReplaceNotificationProbe.Replacement?.Free();
        SelfReplaceNotificationProbe.Replacement = null;
        StartRound();
    }

    public override void _Process(double delta)
    {
        _stageFrames++;
        if (_stageFrames > 600)
        {
            Fail($"timeout in stage {_stage}");
            Finish();
            return;
        }

        if (_stage == 0 &&
            DerivedNotificationProbe.ProcessCalls >= (_completedRounds + 1) * 3 &&
            DerivedNotificationProbe.PhysicsCalls >= (_completedRounds + 1) * 2 &&
            PlainProcessProbe.ProcessCalls >= (_completedRounds + 1) * 3 &&
            PlainProcessProbe.PhysicsCalls >= (_completedRounds + 1) * 2 &&
            _timerTimeouts >= _completedRounds + 1)
        {
            _derived!.QueueFree();
            _plain!.QueueFree();
            _nativeTimer!.QueueFree();
            _stage = 1;
            _stageFrames = 0;
            return;
        }

        if (_stage == 1 && _stageFrames >= 3)
        {
            _completedRounds++;
            CheckRound();
            if (_completedRounds == 1 && _failures.Count == 0)
            {
                // Recreate both managed types. Assembly reload also replaces
                // CSharpInstance objects through this same initialization path.
                StartRound();
            }
            else
            {
                Finish();
            }
        }
    }

    private void StartRound()
    {
        _derived = new DerivedNotificationProbe { Name = $"Derived{_completedRounds}" };
        _plain = new PlainProcessProbe { Name = $"Plain{_completedRounds}" };
        _nativeTimer = new Timer
        {
            Name = $"NativeTimer{_completedRounds}",
            WaitTime = 0.001,
            OneShot = false,
            Autostart = true,
            ProcessCallback = Timer.TimerProcessCallback.Physics,
        };
        _nativeTimer.Timeout += () => _timerTimeouts++;

        AddChild(_derived);
        AddChild(_plain);
        AddChild(_nativeTimer);
        _stage = 0;
        _stageFrames = 0;
    }

    private void CheckRound()
    {
        int rounds = _completedRounds;
        Check(DerivedNotificationProbe.ExitTreeCalls == rounds,
            $"inherited _ExitTree count {DerivedNotificationProbe.ExitTreeCalls}, expected {rounds}");
        Check(DerivedNotificationProbe.DisposeCalls == rounds,
            $"inherited Dispose count {DerivedNotificationProbe.DisposeCalls}, expected {rounds}");
        Check(PlainProcessProbe.ExitTreeCalls == rounds,
            $"plain _ExitTree count {PlainProcessProbe.ExitTreeCalls}, expected {rounds}");
        Check(PlainProcessProbe.DisposeCalls == rounds,
            $"plain Dispose count {PlainProcessProbe.DisposeCalls}, expected {rounds}");
        Check(BaseNotificationProbe.PredeleteNotifications == rounds,
            $"inherited predelete notification count {BaseNotificationProbe.PredeleteNotifications}, expected {rounds}");
        Check(BaseNotificationProbe.ExitTreeNotifications == rounds,
            $"inherited exit-tree notification count {BaseNotificationProbe.ExitTreeNotifications}, expected {rounds}");
        Check(BaseNotificationProbe.ProcessNotifications == DerivedNotificationProbe.ProcessCalls,
            $"inherited process notifications {BaseNotificationProbe.ProcessNotifications} != callbacks {DerivedNotificationProbe.ProcessCalls}");
        Check(BaseNotificationProbe.PhysicsNotifications == DerivedNotificationProbe.PhysicsCalls,
            $"inherited physics notifications {BaseNotificationProbe.PhysicsNotifications} != callbacks {DerivedNotificationProbe.PhysicsCalls}");
        Check(_timerTimeouts >= rounds,
            $"native Timer internal processing did not fire for round {rounds}");
    }

    private void Check(bool condition, string message)
    {
        if (!condition)
            Fail(message);
    }

    private void Fail(string message)
    {
        _failures.Add(message);
        GD.PushError($"[CSHARP_NOTIFY_TEST] {message}");
    }

    private void Finish()
    {
        if (_failures.Count == 0)
        {
            GD.Print($"[CSHARP_NOTIFY_TEST] PASS rounds={_completedRounds} inherited_process={DerivedNotificationProbe.ProcessCalls} inherited_physics={DerivedNotificationProbe.PhysicsCalls} timer={_timerTimeouts} first_ids={SelfFreeNotificationProbe.FirstNotification},{ThrowingNotificationProbe.FirstNotification},{SelfReplaceNotificationProbe.FirstNotification}");
            GetTree().Quit(0);
        }
        else
        {
            GD.PrintErr($"[CSHARP_NOTIFY_TEST] FAIL count={_failures.Count}: {string.Join(" | ", _failures)}");
            GetTree().Quit(2);
        }

        SetProcess(false);
    }
}
