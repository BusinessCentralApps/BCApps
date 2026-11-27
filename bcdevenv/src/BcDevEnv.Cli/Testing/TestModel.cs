namespace BcDevEnv.Cli.Testing;

/// <summary>Outcome of a single AL test method (or of a whole test codeunit).</summary>
public enum TestOutcome
{
    Passed,
    Failed,
    Skipped,
}

/// <summary>Maps the Business Central test runner's result labels onto <see cref="TestOutcome"/>.</summary>
public static class TestOutcomeParser
{
    /// <summary>
    /// Normalises the many spellings the BC test tool / test runner uses for a result
    /// ("Success", "Passed", "2"; "Failure", "Failed", "1"; "Skipped", "Inconclusive", "0"/"None").
    /// Unknown values are treated as failures so a run never silently passes.
    /// </summary>
    public static TestOutcome FromBc(string? value)
    {
        var v = (value ?? string.Empty).Trim();
        if (v.Length == 0) return TestOutcome.Skipped;

        switch (v.ToLowerInvariant())
        {
            case "success":
            case "passed":
            case "pass":
            case "ok":
            case "2":
                return TestOutcome.Passed;
            case "skipped":
            case "skip":
            case "inconclusive":
            case "none":
            case "notexecuted":
            case "0":
                return TestOutcome.Skipped;
            case "failure":
            case "failed":
            case "fail":
            case "1":
                return TestOutcome.Failed;
            default:
                return TestOutcome.Failed;
        }
    }
}

/// <summary>Result of a single test method inside a test codeunit.</summary>
public sealed class TestMethodResult
{
    public required string Name { get; init; }
    public TestOutcome Outcome { get; init; }
    public double DurationSeconds { get; init; }
    public string? Message { get; init; }
    public string? StackTrace { get; init; }
}

/// <summary>Skip reasons emitted by the BcDevEnvTestRunner AL app.</summary>
public static class TestSkipReasons
{
    /// <summary>The test was excluded before execution by a DisabledTests entry.</summary>
    public const string DisabledByDisabledTests = "Disabled by DisabledTests";

    /// <summary>A selected test the test runner (or the AL tool) reported as skipped.</summary>
    public const string SkippedByTestRunner = "Skipped by the test runner";

    /// <summary>Start of the failure message for a selected test that never produced a result.</summary>
    public const string NotExecutedPrefix = "The test was selected but not executed";
}

/// <summary>Result of a single AL test codeunit (a JUnit "testsuite").</summary>
public sealed class TestCodeunitResult
{
    public required string Name { get; init; }
    public int? CodeunitId { get; init; }

    /// <summary>Plain AL codeunit name (without the "Codeunit &lt;id&gt;" prefix) when the runner reports it.</summary>
    public string? CodeunitName { get; init; }
    public string? AppName { get; init; }
    public string? ExtensionId { get; init; }
    public List<TestMethodResult> Methods { get; } = new();

    public double DurationSeconds => Methods.Sum(m => m.DurationSeconds);
    public int Total => Methods.Count;
    public int Failed => Methods.Count(m => m.Outcome == TestOutcome.Failed);
    public int Skipped => Methods.Count(m => m.Outcome == TestOutcome.Skipped);
    public int Passed => Methods.Count(m => m.Outcome == TestOutcome.Passed);
}

/// <summary>A complete test run across one or more codeunits.</summary>
public sealed class TestRunResult
{
    public List<TestCodeunitResult> Codeunits { get; } = new();
    public DateTime StartedUtc { get; init; } = DateTime.UtcNow;

    public int Total => Codeunits.Sum(c => c.Total);
    public int Failed => Codeunits.Sum(c => c.Failed);
    public int Skipped => Codeunits.Sum(c => c.Skipped);
    public int Passed => Codeunits.Sum(c => c.Passed);
    public double DurationSeconds => Codeunits.Sum(c => c.DurationSeconds);

    /// <summary>True when at least one test method failed.</summary>
    public bool AnyFailed => Failed > 0;
}
