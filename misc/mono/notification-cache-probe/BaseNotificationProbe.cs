using Godot;

public partial class BaseNotificationProbe : Node
{
    public static int ProcessNotifications;
    public static int PhysicsNotifications;
    public static int ExitTreeNotifications;
    public static int PredeleteNotifications;

    public static void ResetNotificationCounts()
    {
        ProcessNotifications = 0;
        PhysicsNotifications = 0;
        ExitTreeNotifications = 0;
        PredeleteNotifications = 0;
    }

    public override void _Notification(int what)
    {
        switch (what)
        {
            case (int)NotificationProcess:
                ProcessNotifications++;
                break;
            case (int)NotificationPhysicsProcess:
                PhysicsNotifications++;
                break;
            case (int)NotificationExitTree:
                ExitTreeNotifications++;
                break;
            case (int)NotificationPredelete:
                PredeleteNotifications++;
                break;
        }

        base._Notification(what);
    }
}
