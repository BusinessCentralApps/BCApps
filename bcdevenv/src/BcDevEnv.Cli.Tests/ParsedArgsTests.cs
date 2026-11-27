using BcDevEnv.Cli.Cli;
using BcDevEnv.Cli.Infra;
using Xunit;

namespace BcDevEnv.Cli.Tests;

public class ParsedArgsTests
{
    private static readonly HashSet<string> NoSwitches = new(StringComparer.OrdinalIgnoreCase);

    [Fact]
    public void Parses_key_value_with_space()
    {
        var a = ParsedArgs.Parse(new[] { "--platform", "C:\\art" }, NoSwitches);
        Assert.Equal("C:\\art", a.Get("platform"));
    }

    [Fact]
    public void Parses_key_value_with_equals()
    {
        var a = ParsedArgs.Parse(new[] { "--database-name=CRONUS" }, NoSwitches);
        Assert.Equal("CRONUS", a.Get("database-name"));
    }

    [Fact]
    public void Repeated_option_accumulates()
    {
        var a = ParsedArgs.Parse(new[] { "--app-file", "a.app", "--app-file", "b.app" }, NoSwitches);
        Assert.Equal(new[] { "a.app", "b.app" }, a.GetAll("app-file"));
        // Get returns the last value.
        Assert.Equal("b.app", a.Get("app-file"));
    }

    [Fact]
    public void Declared_switch_takes_no_value()
    {
        var switches = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { "detach" };
        var a = ParsedArgs.Parse(new[] { "--detach", "next" }, switches);
        Assert.True(a.Flag("detach"));
        Assert.Contains("next", a.Positional);
    }

    [Fact]
    public void Positional_tokens_collected()
    {
        var a = ParsedArgs.Parse(new[] { "create-env", "--name", "x" }, NoSwitches);
        Assert.Contains("create-env", a.Positional);
    }

    [Fact]
    public void Require_throws_when_missing()
    {
        var a = ParsedArgs.Parse(Array.Empty<string>(), NoSwitches);
        Assert.Throws<BcDevEnvException>(() => a.Require("platform"));
    }

    [Fact]
    public void GetOr_returns_fallback_when_absent()
    {
        var a = ParsedArgs.Parse(Array.Empty<string>(), NoSwitches);
        Assert.Equal("BC", a.GetOr("server-instance", "BC"));
    }

    [Fact]
    public void Bare_flag_like_token_becomes_switch()
    {
        var a = ParsedArgs.Parse(new[] { "--verbose" }, NoSwitches);
        Assert.True(a.Flag("verbose"));
        Assert.Null(a.Get("verbose"));
    }

    [Fact]
    public void Option_names_are_case_insensitive()
    {
        var a = ParsedArgs.Parse(new[] { "--Platform", "p" }, NoSwitches);
        Assert.Equal("p", a.Get("platform"));
    }
}
