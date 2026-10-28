using System;
using System.Threading.Tasks;
using Xunit;

namespace Godot.SourceGenerators.Tests;

public class DisabledSourceGeneratorsTests
{
    private static Task VerifyScriptPathAttribute(string globalConfig, bool expectGenerated)
    {
        var verifier = CSharpSourceGeneratorVerifier<ScriptPathAttributeGenerator>.MakeVerifier(
            new string[] { "ScriptBoilerplate.cs" },
            expectGenerated ? new string[] { "ScriptBoilerplate_ScriptPath.generated.cs" } : Array.Empty<string>()
        );
        if (expectGenerated)
        {
            verifier.TestState.GeneratedSources.Add(ScriptPathAttributeGeneratorTests.MakeAssemblyScriptTypesGeneratedSource(
                new string[] { "global::ScriptBoilerplate" }));
        }
        verifier.TestState.AnalyzerConfigFiles.Add(("/disabled.globalconfig", $"""
        is_global = true
        {globalConfig}
        """));
        return verifier.RunAsync();
    }

    [Theory]
    // What Godot.NET.Sdk passes for GodotDisabledSourceGenerators=ScriptMethods;ScriptPathAttribute.
    [InlineData("build_property._GodotDisabledSourceGenerators = ScriptMethods,ScriptPathAttribute")]
    [InlineData("build_property._GodotDisabledSourceGenerators = ScriptPathAttribute,ScriptMethods")]
    [InlineData("build_property._GodotDisabledSourceGenerators = ScriptPathAttribute")]
    // Commas, and whitespace around entries, are also accepted in the property itself.
    [InlineData("build_property.GodotDisabledSourceGenerators = ScriptMethods, ScriptPathAttribute")]
    public Task Disabled(string globalConfig) => VerifyScriptPathAttribute(globalConfig, expectGenerated: false);

    [Theory]
    [InlineData("build_property._GodotDisabledSourceGenerators = ScriptMethods,ScriptSignals")]
    [InlineData("build_property._GodotDisabledSourceGenerators =")]
    public Task NotDisabled(string globalConfig) => VerifyScriptPathAttribute(globalConfig, expectGenerated: true);
}
