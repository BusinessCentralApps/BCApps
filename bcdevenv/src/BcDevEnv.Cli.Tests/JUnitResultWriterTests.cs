using System.Xml.Linq;
using BcDevEnv.Cli.Testing;
using Xunit;

namespace BcDevEnv.Cli.Tests;

public class JUnitResultWriterTests
{
    private static TestRunResult SampleRun()
    {
        var run = new TestRunResult();
        var cu = new TestCodeunitResult { Name = "Customer Tests", CodeunitId = 134000 };
        cu.Methods.Add(new TestMethodResult { Name = "TestInsert", Outcome = TestOutcome.Passed, DurationSeconds = 0.25 });
        cu.Methods.Add(new TestMethodResult
        {
            Name = "TestDelete",
            Outcome = TestOutcome.Failed,
            DurationSeconds = 0.40,
            Message = "Assert failed",
            StackTrace = "line 12",
        });
        cu.Methods.Add(new TestMethodResult { Name = "TestSkipped", Outcome = TestOutcome.Skipped, DurationSeconds = 0.10 });
        run.Codeunits.Add(cu);
        return run;
    }

    [Fact]
    public void Root_aggregates_totals()
    {
        var doc = JUnitResultWriter.ToDocument(SampleRun());
        var root = doc.Root!;
        Assert.Equal("testsuites", root.Name.LocalName);
        Assert.Equal("3", root.Attribute("tests")!.Value);
        Assert.Equal("1", root.Attribute("failures")!.Value);
        Assert.Equal("1", root.Attribute("skipped")!.Value);
    }

    [Fact]
    public void Emits_one_testsuite_per_codeunit_with_testcases()
    {
        var doc = JUnitResultWriter.ToDocument(SampleRun());
        var suite = Assert.Single(doc.Root!.Elements("testsuite"));
        Assert.Equal("134000 Customer Tests", suite.Attribute("name")!.Value);
        Assert.Equal(3, suite.Elements("testcase").Count());
        Assert.All(suite.Elements("testcase"), t => Assert.Equal("134000 Customer Tests", t.Attribute("classname")!.Value));
    }

    [Theory]
    [InlineData("Codeunit 139769 Bank Deposit Posting Tests", null, 139769, "139769 Bank Deposit Posting Tests")]
    [InlineData("Codeunit 139769 Bank Deposit Posting Tests", "Bank Deposit Posting Tests", 139769, "139769 Bank Deposit Posting Tests")]
    [InlineData("Codeunit 50000", null, 50000, "50000")]
    [InlineData("Imported suite", null, null, "Imported suite")]
    public void Suite_names_follow_BcContainerHelper_id_and_name(string name, string? codeunitName, int? codeunitId, string expected)
    {
        var cu = new TestCodeunitResult { Name = name, CodeunitName = codeunitName, CodeunitId = codeunitId };
        Assert.Equal(expected, JUnitResultWriter.SuiteName(cu));
    }

    [Fact]
    public void Extension_id_is_written_as_lower_case_guid_without_braces()
    {
        var run = new TestRunResult();
        var cu = new TestCodeunitResult
        {
            Name = "Codeunit 139769 Bank Deposit Posting Tests",
            CodeunitId = 139769,
            AppName = "Bank Deposits Tests",
            ExtensionId = "{798A05DA-1C2B-4D3E-8F90-ABCDEF012345}",
        };
        cu.Methods.Add(new TestMethodResult { Name = "T", Outcome = TestOutcome.Passed });
        run.Codeunits.Add(cu);
        var doc = JUnitResultWriter.ToDocument(run);
        var properties = doc.Descendants("property").ToDictionary(
            p => p.Attribute("name")!.Value, p => p.Attribute("value")!.Value, StringComparer.Ordinal);
        Assert.Equal("798a05da-1c2b-4d3e-8f90-abcdef012345", properties["extensionid"]);
        Assert.Equal("Bank Deposits Tests", properties["appName"]);
        Assert.False(properties.ContainsKey("extensionId"));
    }

    [Fact]
    public void Failed_testcase_has_failure_with_message_and_stack()
    {
        var doc = JUnitResultWriter.ToDocument(SampleRun());
        var failed = doc.Descendants("testcase").Single(t => t.Attribute("name")!.Value == "TestDelete");
        var failure = Assert.Single(failed.Elements("failure"));
        Assert.Equal("Assert failed", failure.Attribute("message")!.Value);
        Assert.Contains("line 12", failure.Value);
    }

    [Fact]
    public void Skipped_testcase_has_skipped_element()
    {
        var doc = JUnitResultWriter.ToDocument(SampleRun());
        var skipped = doc.Descendants("testcase").Single(t => t.Attribute("name")!.Value == "TestSkipped");
        Assert.Equal("Test skipped", Assert.Single(skipped.Elements("skipped")).Attribute("message")!.Value);
    }

    [Fact]
    public void Suites_without_app_metadata_use_the_run_name_for_ALGo_analysis()
    {
        var doc = JUnitResultWriter.ToDocument(SampleRun(), "Imported results");
        var appName = Assert.Single(doc.Descendants("property"));
        Assert.Equal("appName", appName.Attribute("name")!.Value);
        Assert.Equal("Imported results", appName.Attribute("value")!.Value);
    }

    [Fact]
    public void Time_uses_invariant_decimal_point()
    {
        var doc = JUnitResultWriter.ToDocument(SampleRun());
        var suite = doc.Root!.Element("testsuite")!;
        Assert.Equal("0.750", suite.Attribute("time")!.Value);
    }

    [Fact]
    public void WriteFile_creates_parseable_document()
    {
        var path = Path.Combine(Path.GetTempPath(), "bcdevenv-junit-" + Guid.NewGuid().ToString("N"), "junit.xml");
        try
        {
            JUnitResultWriter.WriteFile(SampleRun(), path);
            Assert.True(File.Exists(path));
            var reloaded = XDocument.Load(path);
            Assert.Equal("testsuites", reloaded.Root!.Name.LocalName);
        }
        finally
        {
            var dir = Path.GetDirectoryName(path);
            if (dir != null && Directory.Exists(dir)) Directory.Delete(dir, recursive: true);
        }
    }
}
