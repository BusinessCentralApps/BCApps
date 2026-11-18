using System.Xml.Linq;
using BcDevEnv.Cli.Cli;
using BcDevEnv.Cli.Commands;
using Xunit;

namespace BcDevEnv.Cli.Tests;

public class RunTestsCommandTests
{
    [Theory]
    [InlineData("Pass", false, 0)]
    [InlineData("Fail", false, 1)]
    [InlineData("Fail", true, 0)]
    public void Writes_report_before_applying_failure_policy(string outcome, bool allowFailures, int expectedExit)
    {
        var directory = Path.Combine(Path.GetTempPath(), $"bcdevenv-tests-{Guid.NewGuid():N}");
        Directory.CreateDirectory(directory);
        try
        {
            var input = Path.Combine(directory, "input.xml");
            var output = Path.Combine(directory, "junit.xml");
            File.WriteAllText(input,
                $"""<assemblies><assembly name="Tests"><collection name="Codeunit 1 Tests"><test method="Example" result="{outcome}" time="1"/></collection></assembly></assemblies>""");
            var arguments = new List<string> { "--from-xml", input, "--result-file", output };
            if (allowFailures) arguments.Add("--allow-failures");
            var parsed = ParsedArgs.Parse(arguments.ToArray(), new HashSet<string> { "allow-failures" });

            Assert.Equal(expectedExit, RunTestsCommand.Run(parsed));
            var report = XDocument.Load(output);
            Assert.Equal("1", report.Root!.Attribute("tests")!.Value);
            Assert.Equal(outcome == "Fail" ? "1" : "0", report.Root.Attribute("failures")!.Value);
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public void Allow_failures_does_not_allow_zero_tests()
    {
        var directory = Path.Combine(Path.GetTempPath(), $"bcdevenv-tests-{Guid.NewGuid():N}");
        Directory.CreateDirectory(directory);
        try
        {
            var input = Path.Combine(directory, "input.xml");
            var output = Path.Combine(directory, "junit.xml");
            File.WriteAllText(input, "<assemblies/>");
            var parsed = ParsedArgs.Parse(
                new[] { "--from-xml", input, "--result-file", output, "--allow-failures" },
                new HashSet<string> { "allow-failures" });

            Assert.Equal(1, RunTestsCommand.Run(parsed));
            Assert.True(File.Exists(output));
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }
}
