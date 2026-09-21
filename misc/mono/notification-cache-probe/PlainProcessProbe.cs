using Godot;

public partial class PlainProcessProbe : Node
{
    public static int ProcessCalls;
    public static int PhysicsCalls;
    public static int ExitTreeCalls;
    public static int DisposeCalls;

    public static void ResetCounts()
    {
        ProcessCalls = 0;
        PhysicsCalls = 0;
        ExitTreeCalls = 0;
        DisposeCalls = 0;
    }

    public override void _Process(double delta) => ProcessCalls++;

    public override void _PhysicsProcess(double delta) => PhysicsCalls++;

    public override void _ExitTree()
    {
        ExitTreeCalls++;
        base._ExitTree();
    }

    protected override void Dispose(bool disposing)
    {
        DisposeCalls++;
        base.Dispose(disposing);
    }
}
