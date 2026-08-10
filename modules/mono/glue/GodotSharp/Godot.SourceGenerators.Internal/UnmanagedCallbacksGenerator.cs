using System.Text;
using System.Linq;
using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.Text;
using Microsoft.CodeAnalysis.CSharp;
using Microsoft.CodeAnalysis.CSharp.Syntax;

namespace Godot.SourceGenerators.Internal;

[Generator]
public class UnmanagedCallbacksGenerator : ISourceGenerator
{
    public void Initialize(GeneratorInitializationContext context)
    {
        context.RegisterForPostInitialization(ctx => { GenerateAttribute(ctx); });
    }

    public void Execute(GeneratorExecutionContext context)
    {
        INamedTypeSymbol[] unmanagedCallbacksClasses = context
            .Compilation.SyntaxTrees
            .SelectMany(tree =>
                tree.GetRoot().DescendantNodes()
                    .OfType<ClassDeclarationSyntax>()
                    .SelectUnmanagedCallbacksClasses(context.Compilation)
                    // Report and skip non-partial classes
                    .Where(x =>
                    {
                        if (x.cds.IsPartial())
                        {
                            if (x.cds.IsNested() && !x.cds.AreAllOuterTypesPartial(out var typeMissingPartial))
                            {
                                Common.ReportNonPartialUnmanagedCallbacksOuterClass(context, typeMissingPartial!);
                                return false;
                            }

                            return true;
                        }

                        Common.ReportNonPartialUnmanagedCallbacksClass(context, x.cds, x.symbol);
                        return false;
                    })
                    .Select(x => x.symbol)
            )
            .Distinct<INamedTypeSymbol>(SymbolEqualityComparer.Default)
            .ToArray();

        foreach (var symbol in unmanagedCallbacksClasses)
        {
            var attr = symbol.GetGenerateUnmanagedCallbacksAttribute();
            if (attr == null || attr.ConstructorArguments.Length != 1)
            {
                // TODO: Report error or throw exception, this is an invalid case and should never be reached
                System.Diagnostics.Debug.Fail("FAILED!");
                continue;
            }

            var funcStructType = (INamedTypeSymbol?)attr.ConstructorArguments[0].Value;
            if (funcStructType == null)
            {
                // TODO: Report error or throw exception, this is an invalid case and should never be reached
                System.Diagnostics.Debug.Fail("FAILED!");
                continue;
            }

            var data = new CallbacksData(symbol, funcStructType);
            GenerateInteropMethodImplementations(context, data);
            GenerateUnmanagedCallbacksStruct(context, data);
        }
    }

    private void GenerateAttribute(GeneratorPostInitializationContext context)
    {
        string source = @"using System;

namespace Godot.SourceGenerators.Internal
{
internal class GenerateUnmanagedCallbacksAttribute : Attribute
{
    public Type FuncStructType { get; }

    public GenerateUnmanagedCallbacksAttribute(Type funcStructType)
    {
        FuncStructType = funcStructType;
    }
}
}";

        context.AddSource("GenerateUnmanagedCallbacksAttribute.generated",
            SourceText.From(source, Encoding.UTF8));
    }

    private void GenerateInteropMethodImplementations(GeneratorExecutionContext context, CallbacksData data)
    {
        var symbol = data.NativeTypeSymbol;

        INamespaceSymbol namespaceSymbol = symbol.ContainingNamespace;
        string classNs = namespaceSymbol != null && !namespaceSymbol.IsGlobalNamespace ?
            namespaceSymbol.FullQualifiedNameOmitGlobal() :
            string.Empty;
        bool hasNamespace = classNs.Length != 0;
        bool isInnerClass = symbol.ContainingType != null;

        var source = new StringBuilder();
        var methodSource = new StringBuilder();
        var methodCallArguments = new StringBuilder();
        var methodSourceAfterCall = new StringBuilder();

        source.Append(
            @"using System;
using System.Diagnostics.CodeAnalysis;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using Godot.Bridge;
using Godot.NativeInterop;

#pragma warning disable CA1707 // Disable warning: Identifiers should not contain underscores

");

        if (hasNamespace)
        {
            source.Append("namespace ");
            source.Append(classNs);
            source.Append("\n{\n");
        }

        if (isInnerClass)
        {
            var containingType = symbol.ContainingType;
            AppendPartialContainingTypeDeclarations(containingType);

            void AppendPartialContainingTypeDeclarations(INamedTypeSymbol? containingType)
            {
                if (containingType == null)
                    return;

                AppendPartialContainingTypeDeclarations(containingType.ContainingType);

                source.Append("partial ");
                source.Append(containingType.GetDeclarationKeyword());
                source.Append(" ");
                source.Append(containingType.ToDisplayString(SymbolDisplayFormat.MinimallyQualifiedFormat));
                source.Append("\n{\n");
            }
        }

        source.Append("[System.Runtime.CompilerServices.SkipLocalsInit]\n");
        source.Append($"unsafe partial class {symbol.Name}\n");
        source.Append("{\n");
        source.Append($"    private static {data.FuncStructSymbol.FullQualifiedNameIncludeGlobal()} _unmanagedCallbacks;\n\n");

        foreach (var callback in data.Methods)
        {
            methodSource.Clear();
            methodCallArguments.Clear();
            methodSourceAfterCall.Clear();

            // On WebAssembly the engine, the Mono runtime and this managed code
            // are one binary, so a callback can also be reached as a plain
            // P/Invoke — and that is worth far more than tidiness: Mono's AOT
            // compiler refuses to compile the marshalling wrapper for a calli
            // through an unmanaged function pointer ("Skip (disabled)", one per
            // signature), so every call through _unmanagedCallbacks runs on the
            // interpreter, while a P/Invoke wrapper is compiled ahead of time
            // like any other method.
            //
            // The module name has to be listed in $(_WasmPInvokeModules) so the
            // symbol lands in the generated pinvoke table, which is what the
            // runtime's dl fallback resolves against. It deliberately is not
            // "__Internal": Mono answers that name with dlopen(self), which a
            // statically linked wasm build cannot provide.
            //
            // OperatingSystem.IsBrowser() is a compile-time constant per
            // runtime, so exactly one of the two branches survives and no
            // platform pays for the other.
            bool canPInvoke = CanCallDirectly(callback);
            if (canPInvoke)
            {
                source.Append($"    [global::System.Runtime.InteropServices.DllImport(\"godot\", EntryPoint = \"{callback.Name}\")]\n");
                source.Append($"    private static extern {callback.ReturnType.FullQualifiedNameIncludeGlobal()} {callback.Name}__pinvoke(");
                AppendUnmanagedParameterList(source, callback);
                source.Append(");\n\n");
            }

            source.Append("    [global::System.Runtime.CompilerServices.MethodImpl(global::System.Runtime.CompilerServices.MethodImplOptions.AggressiveInlining)]\n");
            source.Append($"    {SyntaxFacts.GetText(callback.DeclaredAccessibility)} ");

            if (callback.IsStatic)
                source.Append("static ");

            source.Append("partial ");
            source.Append(callback.ReturnType.FullQualifiedNameIncludeGlobal());
            source.Append(' ');
            source.Append(callback.Name);
            source.Append('(');

            for (int i = 0; i < callback.Parameters.Length; i++)
            {
                var parameter = callback.Parameters[i];

                AppendRefKind(source, parameter.RefKind, parameter.ScopedKind);
                source.Append(' ');
                source.Append(parameter.Type.FullQualifiedNameIncludeGlobal());
                source.Append(' ');
                source.Append(parameter.Name);

                if (parameter.RefKind == RefKind.Out)
                {
                    // Only assign default if the parameter won't be passed by-ref or copied later.
                    if (IsGodotInteropStruct(parameter.Type))
                        methodSource.Append($"        {parameter.Name} = default;\n");
                }

                if (IsByRefParameter(parameter))
                {
                    if (IsGodotInteropStruct(parameter.Type))
                    {
                        methodSource.Append("        ");
                        AppendCustomUnsafeAsPointer(methodSource, parameter, out string varName);
                        methodCallArguments.Append(varName);
                    }
                    else if (parameter.Type.IsValueType)
                    {
                        methodSource.Append("        ");
                        AppendCopyToStackAndGetPointer(methodSource, parameter, out string varName);
                        methodCallArguments.Append($"&{varName}");

                        if (parameter.RefKind is RefKind.Out or RefKind.Ref)
                        {
                            methodSourceAfterCall.Append($"        {parameter.Name} = {varName};\n");
                        }
                    }
                    else
                    {
                        // If it's a by-ref param and we can't get the pointer
                        // just pass it by-ref and let it be pinned.
                        AppendRefKind(methodCallArguments, parameter.RefKind, parameter.ScopedKind)
                            .Append(' ')
                            .Append(parameter.Name);
                    }
                }
                else
                {
                    methodCallArguments.Append(parameter.Name);
                }

                if (i < callback.Parameters.Length - 1)
                {
                    source.Append(", ");
                    methodCallArguments.Append(", ");
                }
            }

            source.Append(")\n");
            source.Append("    {\n");

            source.Append(methodSource);

            string indirectCall = $"_unmanagedCallbacks.{callback.Name}({methodCallArguments})";
            string directCall = $"{callback.Name}__pinvoke({methodCallArguments})";

            if (callback.ReturnsVoid)
            {
                if (canPInvoke)
                {
                    source.Append("        if (global::System.OperatingSystem.IsBrowser())\n");
                    source.Append($"            {directCall};\n");
                    source.Append("        else\n");
                    source.Append($"            {indirectCall};\n");
                }
                else
                {
                    source.Append($"        {indirectCall};\n");
                }
            }
            else
            {
                source.Append("        ");
                source.Append(methodSourceAfterCall.Length != 0
                    ? $"{callback.ReturnType.FullQualifiedNameIncludeGlobal()} ret = "
                    : "return ");
                source.Append(canPInvoke
                    ? $"global::System.OperatingSystem.IsBrowser() ? {directCall} : {indirectCall}"
                    : indirectCall);
                source.Append(";\n");
            }

            if (methodSourceAfterCall.Length != 0)
            {
                source.Append(methodSourceAfterCall);

                if (!callback.ReturnsVoid)
                    source.Append("        return ret;\n");
            }

            source.Append("    }\n\n");
        }

        source.Append("}\n");

        if (isInnerClass)
        {
            var containingType = symbol.ContainingType;

            while (containingType != null)
            {
                source.Append("}\n"); // outer class

                containingType = containingType.ContainingType;
            }
        }

        if (hasNamespace)
            source.Append("\n}");

        source.Append("\n\n#pragma warning restore CA1707\n");

        context.AddSource($"{data.NativeTypeSymbol.FullQualifiedNameOmitGlobal().SanitizeQualifiedNameForUniqueHint()}.generated",
            SourceText.From(source.ToString(), Encoding.UTF8));
    }

    private void GenerateUnmanagedCallbacksStruct(GeneratorExecutionContext context, CallbacksData data)
    {
        var symbol = data.FuncStructSymbol;

        INamespaceSymbol namespaceSymbol = symbol.ContainingNamespace;
        string classNs = namespaceSymbol != null && !namespaceSymbol.IsGlobalNamespace ?
            namespaceSymbol.FullQualifiedNameOmitGlobal() :
            string.Empty;
        bool hasNamespace = classNs.Length != 0;
        bool isInnerClass = symbol.ContainingType != null;

        var source = new StringBuilder();

        source.Append(
            @"using System.Runtime.InteropServices;
using Godot.NativeInterop;

#pragma warning disable CA1707 // Disable warning: Identifiers should not contain underscores

");
        if (hasNamespace)
        {
            source.Append("namespace ");
            source.Append(classNs);
            source.Append("\n{\n");
        }

        if (isInnerClass)
        {
            var containingType = symbol.ContainingType;
            AppendPartialContainingTypeDeclarations(containingType);

            void AppendPartialContainingTypeDeclarations(INamedTypeSymbol? containingType)
            {
                if (containingType == null)
                    return;

                AppendPartialContainingTypeDeclarations(containingType.ContainingType);

                source.Append("partial ");
                source.Append(containingType.GetDeclarationKeyword());
                source.Append(" ");
                source.Append(containingType.ToDisplayString(SymbolDisplayFormat.MinimallyQualifiedFormat));
                source.Append("\n{\n");
            }
        }

        source.Append("[StructLayout(LayoutKind.Sequential)]\n");
        source.Append($"unsafe partial struct {symbol.Name}\n{{\n");

        foreach (var callback in data.Methods)
        {
            source.Append("    ");
            source.Append(callback.DeclaredAccessibility == Accessibility.Public ? "public " : "internal ");

            source.Append("delegate* unmanaged<");

            foreach (var parameter in callback.Parameters)
            {
                if (IsByRefParameter(parameter))
                {
                    if (IsGodotInteropStruct(parameter.Type) || parameter.Type.IsValueType)
                    {
                        AppendPointerType(source, parameter.Type);
                    }
                    else
                    {
                        // If it's a by-ref param and we can't get the pointer
                        // just pass it by-ref and let it be pinned.
                        AppendRefKind(source, parameter.RefKind, parameter.ScopedKind)
                            .Append(' ')
                            .Append(parameter.Type.FullQualifiedNameIncludeGlobal());
                    }
                }
                else
                {
                    source.Append(parameter.Type.FullQualifiedNameIncludeGlobal());
                }

                source.Append(", ");
            }

            source.Append(callback.ReturnType.FullQualifiedNameIncludeGlobal());
            source.Append($"> {callback.Name};\n");
        }

        source.Append("}\n");

        if (isInnerClass)
        {
            var containingType = symbol.ContainingType;

            while (containingType != null)
            {
                source.Append("}\n"); // outer class

                containingType = containingType.ContainingType;
            }
        }

        if (hasNamespace)
            source.Append("}\n");

        source.Append("\n#pragma warning restore CA1707\n");

        context.AddSource($"{symbol.FullQualifiedNameOmitGlobal().SanitizeQualifiedNameForUniqueHint()}.generated",
            SourceText.From(source.ToString(), Encoding.UTF8));
    }

    /// <summary>
    /// Can this callback also be declared as a plain P/Invoke? Only if every
    /// parameter and the return type reach native code as-is: anything the
    /// interop marshaller would have to convert (bool, char, string, a class)
    /// would not match the calling convention the callbacks struct uses, so
    /// those keep the function-pointer path on every platform.
    /// </summary>
    private static bool CanCallDirectly(IMethodSymbol callback)
    {
        if (!callback.ReturnsVoid && !IsDirectlyPassable(callback.ReturnType))
            return false;

        // Returning one of the interop structs by value is a shape the wasm
        // SDK's P/Invoke table generator rejects ("WASM0001: Unsupported
        // parameter type"), and a rejected entry is worse than no P/Invoke at
        // all: the symbol is missing from the table, the first call throws, and
        // logging that exception calls back in here and recurses until the
        // stack is gone. Leave those on the function-pointer path.
        if (!callback.ReturnsVoid && IsGodotInteropStruct(callback.ReturnType))
            return false;

        foreach (var parameter in callback.Parameters)
        {
            // By-ref parameters we cannot turn into a pointer are passed by-ref
            // and pinned, which is marshalling again.
            if (IsByRefParameter(parameter) &&
                !IsGodotInteropStruct(parameter.Type) && !parameter.Type.IsValueType)
                return false;

            if (!IsDirectlyPassable(parameter.Type))
                return false;
        }

        return true;
    }

    private static bool IsDirectlyPassable(ITypeSymbol type) =>
        type.IsUnmanagedType &&
        type.SpecialType is not (SpecialType.System_Boolean or SpecialType.System_Char);

    /// <summary>
    /// The parameter list of the unmanaged signature — the same shape
    /// <see cref="GenerateUnmanagedCallbacksStruct"/> gives the
    /// <c>delegate* unmanaged</c> field, so both calls take the same arguments.
    /// </summary>
    private static void AppendUnmanagedParameterList(StringBuilder source, IMethodSymbol callback)
    {
        for (int i = 0; i < callback.Parameters.Length; i++)
        {
            var parameter = callback.Parameters[i];

            if (IsByRefParameter(parameter))
                AppendPointerType(source, parameter.Type);
            else
                source.Append(parameter.Type.FullQualifiedNameIncludeGlobal());

            source.Append(' ');
            source.Append(parameter.Name);

            if (i < callback.Parameters.Length - 1)
                source.Append(", ");
        }
    }

    private static bool IsGodotInteropStruct(ITypeSymbol type) =>
        _godotInteropStructs.Contains(type.FullQualifiedNameOmitGlobal());

    private static bool IsByRefParameter(IParameterSymbol parameter) =>
        parameter.RefKind is RefKind.In or RefKind.Out or RefKind.Ref;

    private static StringBuilder AppendRefKind(StringBuilder source, RefKind refKind, ScopedKind scopedKind)
    {
        return (refKind, scopedKind) switch
        {
            (RefKind.Out, _) => source.Append("out"),
            (RefKind.In, ScopedKind.ScopedRef) => source.Append("scoped in"),
            (RefKind.In, _) => source.Append("in"),
            (RefKind.Ref, ScopedKind.ScopedRef) => source.Append("scoped ref"),
            (RefKind.Ref, _) => source.Append("ref"),
            _ => source,
        };
    }

    private static void AppendPointerType(StringBuilder source, ITypeSymbol type)
    {
        source.Append(type.FullQualifiedNameIncludeGlobal());
        source.Append('*');
    }

    private static void AppendCustomUnsafeAsPointer(StringBuilder source, IParameterSymbol parameter,
        out string varName)
    {
        varName = $"{parameter.Name}_ptr";

        AppendPointerType(source, parameter.Type);
        source.Append(' ');
        source.Append(varName);
        source.Append(" = ");

        source.Append('(');
        AppendPointerType(source, parameter.Type);
        source.Append(')');

        if (parameter.RefKind == RefKind.In)
            source.Append("CustomUnsafe.ReadOnlyRefAsPointer(in ");
        else
            source.Append("CustomUnsafe.AsPointer(ref ");

        source.Append(parameter.Name);

        source.Append(");\n");
    }

    private static void AppendCopyToStackAndGetPointer(StringBuilder source, IParameterSymbol parameter,
        out string varName)
    {
        varName = $"{parameter.Name}_copy";

        source.Append(parameter.Type.FullQualifiedNameIncludeGlobal());
        source.Append(' ');
        source.Append(varName);
        if (parameter.RefKind is RefKind.In or RefKind.Ref)
        {
            source.Append(" = ");
            source.Append(parameter.Name);
        }

        source.Append(";\n");
    }

    private static readonly string[] _godotInteropStructs =
    {
        "Godot.NativeInterop.godot_ref",
        "Godot.NativeInterop.godot_variant_call_error",
        "Godot.NativeInterop.godot_variant",
        "Godot.NativeInterop.godot_string",
        "Godot.NativeInterop.godot_string_name",
        "Godot.NativeInterop.godot_node_path",
        "Godot.NativeInterop.godot_signal",
        "Godot.NativeInterop.godot_callable",
        "Godot.NativeInterop.godot_array",
        "Godot.NativeInterop.godot_dictionary",
        "Godot.NativeInterop.godot_packed_byte_array",
        "Godot.NativeInterop.godot_packed_int32_array",
        "Godot.NativeInterop.godot_packed_int64_array",
        "Godot.NativeInterop.godot_packed_float32_array",
        "Godot.NativeInterop.godot_packed_float64_array",
        "Godot.NativeInterop.godot_packed_string_array",
        "Godot.NativeInterop.godot_packed_vector2_array",
        "Godot.NativeInterop.godot_packed_vector3_array",
        "Godot.NativeInterop.godot_packed_vector4_array",
        "Godot.NativeInterop.godot_packed_color_array",
    };
}
