using Godot;

public partial class SelfReplaceNotificationProbe : Node
{
    public const int SelfReplaceNotification = 9003;
    public static int Calls;
    public static int DisposeCalls;
    public static int FirstNotification = -1;
    public static SelfReplaceNotificationProbe Replacement;
    public bool Armed;

    public static void ResetCounts()
    {
        Calls = 0;
        DisposeCalls = 0;
        FirstNotification = -1;
        Replacement = null;
    }

    public override void _Notification(int what)
    {
        if (FirstNotification == -1)
            FirstNotification = what;

        if (what != SelfReplaceNotification || !Armed)
            return;

        Calls++;
        SetScript(default(Variant));

        // Allocate an unrelated C# ScriptInstance while the native caller unwinds.
        // The original native owner remains live with no script, so this case tests
        // the live-owner/nil-script guard rather than same-owner ABA reuse.
        Replacement = new SelfReplaceNotificationProbe();
    }

    protected override void Dispose(bool disposing)
    {
        DisposeCalls++;
        base.Dispose(disposing);
    }
}
