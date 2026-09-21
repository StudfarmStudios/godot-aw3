using Godot;

public partial class SelfFreeNotificationProbe : Node
{
    public const int SelfFreeNotification = 9001;
    public static int Calls;
    public static int FirstNotification = -1;
    public bool Armed;

    public override void _Notification(int what)
    {
        if (FirstNotification == -1)
            FirstNotification = what;

        if (what == SelfFreeNotification && Armed)
        {
            Calls++;
            Free();
        }
    }
}
