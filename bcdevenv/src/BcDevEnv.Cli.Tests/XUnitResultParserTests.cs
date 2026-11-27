using BcDevEnv.Cli.Testing;
using Xunit;

namespace BcDevEnv.Cli.Tests;

public class XUnitResultParserTests
{
    private const string Sample = """
<assemblies>
  <assembly name="MyApp.Tests" test-framework="AL Test Runner" total="3" passed="1" failed="1" skipped="1" time="0.75">
    <collection name="Codeunit 134000 Customer Tests" total="3" passed="1" failed="1" skipped="1" time="0.75">
      <test name="Customer Tests:TestInsert" method="TestInsert" result="Pass" time="0.25" />
      <test name="Customer Tests:TestDelete" method="TestDelete" result="Fail" time="0.40">
        <failure>
          <message>Assert.AreEqual failed. Expected 1 actual 0.</message>
          <stack-trace>"Customer Tests"(CodeUnit 134000).TestDelete line 12</stack-trace>
        </failure>
      </test>
      <test name="Customer Tests:TestSkipped" method="TestSkipped" result="Skip" time="0.10" />
    </collection>
  </assembly>
</assemblies>
""";

    [Fact]
    public void Parses_counts()
    {
        var run = XUnitResultParser.Parse(Sample);
        Assert.Equal(3, run.Total);
        Assert.Equal(1, run.Passed);
        Assert.Equal(1, run.Failed);
        Assert.Equal(1, run.Skipped);
        Assert.True(run.AnyFailed);
    }

    [Fact]
    public void Parses_codeunit_and_id()
    {
        var run = XUnitResultParser.Parse(Sample);
        var cu = Assert.Single(run.Codeunits);
        Assert.Equal("Codeunit 134000 Customer Tests", cu.Name);
        Assert.Equal(134000, cu.CodeunitId);
        Assert.Equal(3, cu.Methods.Count);
    }

    [Fact]
    public void Captures_failure_message_and_stack()
    {
        var run = XUnitResultParser.Parse(Sample);
        var failed = run.Codeunits[0].Methods.Single(m => m.Outcome == TestOutcome.Failed);
        Assert.Equal("TestDelete", failed.Name);
        Assert.Contains("Assert.AreEqual failed", failed.Message);
        Assert.Contains("line 12", failed.StackTrace);
        Assert.Equal(0.40, failed.DurationSeconds, 3);
    }

    [Fact]
    public void Single_assembly_root_is_supported()
    {
        const string singleAssembly = """
<assembly name="X">
  <collection name="Codeunit 1 A">
    <test method="M" result="Pass" time="1" />
  </collection>
</assembly>
""";
        var run = XUnitResultParser.Parse(singleAssembly);
        Assert.Equal(1, run.Total);
        Assert.Equal(1, run.Passed);
    }

    [Fact]
    public void Empty_input_throws()
    {
        Assert.Throws<BcDevEnv.Cli.Infra.BcDevEnvException>(() => XUnitResultParser.Parse(""));
    }

    [Fact]
    public void Invalid_xml_throws()
    {
        Assert.Throws<BcDevEnv.Cli.Infra.BcDevEnvException>(() => XUnitResultParser.Parse("<not-closed"));
    }
}
