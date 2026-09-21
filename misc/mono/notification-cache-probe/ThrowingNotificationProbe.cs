using Godot;
using System;

public partial class ThrowingNotificationProbe : Node
{
    public const int ThrowingNotification = 9002;
    public static int Calls;
    public static int FirstNotification = -1;

    public override void _Notification(int what)
    {
        if (FirstNotification == -1)
            FirstNotification = what;

        if (what != ThrowingNotification)
            return;

        Calls++;
        if (Calls == 1)
            throw new InvalidOperationException("expected first-notification probe exception");
    }
}
