using BcDevEnv.Cli.Testing;
using Xunit;

namespace BcDevEnv.Cli.Tests;

public class TestOutcomeParserTests
{
    [Theory]
    [InlineData("Success", TestOutcome.Passed)]
    [InlineData("Passed", TestOutcome.Passed)]
    [InlineData("PASS", TestOutcome.Passed)]
    [InlineData("2", TestOutcome.Passed)]
    [InlineData("Failure", TestOutcome.Failed)]
    [InlineData("Failed", TestOutcome.Failed)]
    [InlineData("1", TestOutcome.Failed)]
    [InlineData("Skipped", TestOutcome.Skipped)]
    [InlineData("Inconclusive", TestOutcome.Skipped)]
    [InlineData("0", TestOutcome.Skipped)]
    public void Maps_known_values(string input, TestOutcome expected)
    {
        Assert.Equal(expected, TestOutcomeParser.FromBc(input));
    }

    [Fact]
    public void Empty_is_skipped()
    {
        Assert.Equal(TestOutcome.Skipped, TestOutcomeParser.FromBc(""));
        Assert.Equal(TestOutcome.Skipped, TestOutcomeParser.FromBc(null));
    }

    [Fact]
    public void Unknown_defaults_to_failed()
    {
        // Never let an unrecognised label silently count as a pass.
        Assert.Equal(TestOutcome.Failed, TestOutcomeParser.FromBc("weird-value"));
    }
}
