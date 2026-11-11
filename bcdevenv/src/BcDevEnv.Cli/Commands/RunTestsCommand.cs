using BcDevEnv.Cli.Cli;
using BcDevEnv.Cli.Infra;
using BcDevEnv.Cli.Nav;
using BcDevEnv.Cli.Testing;

namespace BcDevEnv.Cli.Commands;

/// <summary>
/// run-tests: run the Business Central test suite against a running server instance (or convert a
/// test-runner result document produced elsewhere) and emit a JUnit XML report that CI systems
/// understand. Exits non-zero when any test fails (unless --allow-failures), so it can gate a build.
///
/// Two input paths, both funnelling through <see cref="XUnitResultParser"/>:
///   * --from-xml / --results-dir : parse existing xUnit result document(s) (no live server needed).
///   * live (default)             : invoke the toolkit's runner web service over OData v4, either with
///                                  the legacy single RunAll call or the per-codeunit protocol
///                                  (PrepareTests + one RunCodeunit call per codeunit).
///   * live, --executor altool    : PrepareTests selects the tests as above, then the AL tool's
///                                  runtests executes them through the development endpoint (a client
///                                  session, so TestPages work); see <see cref="AlToolTestRunner"/>.
///
/// --disabled-tests applies the repository's DisabledTests entries BEFORE execution (per-codeunit
/// protocol only) and afterwards verifies that every matching test was reported as skipped. A
/// disabled test that still ran, a test the runner disabled without an entry, or a failed runner call
/// fails the command even with --allow-failures.
/// </summary>
public static class RunTestsCommand
{
    private sealed record Collected(TestRunResult Run, IReadOnlyList<string> RunnerErrors);

    public static int Run(ParsedArgs a) => Run(a, new NavTestService());

    /// <summary>Runs the command with a specific runner client (tests inject a fake HTTP handler).</summary>
    public static int Run(ParsedArgs a, NavTestService service) => Run(a, service, null);

    /// <summary>Runs the command with a specific runner client and AL tool executor (tests inject fakes).</summary>
    public static int Run(ParsedArgs a, NavTestService service, AlToolTestRunner? alTool)
    {
        var resultFile = a.Get("result-file") ?? Path.Combine("TestResults", "junit.xml");
        var suiteName = a.GetOr("suite-name", "BusinessCentral");
        var allowFailures = a.Flag("allow-failures");

        var catalog = LoadCatalog(a);
        var collected = CollectResults(a, catalog, service, alTool ?? new AlToolTestRunner());
        var run = collected.Run;

        JUnitResultWriter.WriteFile(run, resultFile, suiteName);

        PrintSummary(run, resultFile);

        var infrastructureErrors = collected.RunnerErrors.ToList();
        if (catalog != null)
            infrastructureErrors.AddRange(ReportDisabledTests(catalog, run));

        if (infrastructureErrors.Count > 0)
        {
            foreach (var error in infrastructureErrors)
                Log.Error(error);
            Log.Error($"{infrastructureErrors.Count} test infrastructure error(s); the run is not trustworthy.");
            return 1;
        }

        if (run.Total == 0)
        {
            Log.Warn("No tests were found in the result set.");
            return a.Flag("allow-empty") ? 0 : 1;
        }

        if (run.AnyFailed)
        {
            if (!allowFailures)
            {
                Log.Error($"{run.Failed} test(s) failed.");
                return 1;
            }
            Log.Warn($"{run.Failed} test(s) failed; --allow-failures was specified.");
            return 0;
        }

        Log.Success("All tests passed.");
        return 0;
    }

    private static DisabledTestCatalog? LoadCatalog(ParsedArgs a)
    {
        var paths = a.GetAll("disabled-tests");
        if (paths.Count == 0) return null;

        var appName = a.Get("app-name");
        var catalog = DisabledTestCatalog.Load(paths, appName);
        var scope = string.IsNullOrWhiteSpace(appName) ? "all apps" : $"app '{appName}' (folder '{DisabledTestCatalog.AppFolderName(appName)}')";
        Log.Info($"Loaded {catalog.Entries.Count} disabled test entr{(catalog.Entries.Count == 1 ? "y" : "ies")} for {scope} " +
                 $"from {catalog.SourceFiles.Count} file(s).");
        return catalog;
    }

    // Returns infrastructure errors; prints the skip report.
    private static IEnumerable<string> ReportDisabledTests(DisabledTestCatalog catalog, TestRunResult run)
    {
        var verification = catalog.Verify(run);
        Console.WriteLine("Disabled tests:");
        Console.WriteLine($"  Entries: {catalog.Entries.Count}   Skipped before execution: {verification.SkippedByCatalog}   " +
                          $"Entries matching no test in this run: {verification.UnmatchedEntries.Count}");
        foreach (var entry in verification.UnmatchedEntries.Take(20))
            Log.Verbose($"  Unmatched: {entry.CodeunitName}:{entry.Method}");
        Console.WriteLine();

        foreach (var executed in verification.ExecutedDisabledTests)
            yield return $"Disabled test '{executed.CodeunitName}:{executed.Method}' was executed ({executed.Outcome}).";
        foreach (var unexpected in verification.UnexpectedlyDisabled)
            yield return $"Test '{unexpected}' was reported as disabled but matches no DisabledTests entry.";
    }

    private static Collected CollectResults(ParsedArgs a, DisabledTestCatalog? catalog, NavTestService service, AlToolTestRunner alTool)
    {
        // Explicit result files / directories take precedence and need no running server.
        var xmlFiles = new List<string>();
        xmlFiles.AddRange(a.GetAll("from-xml"));

        var resultsDir = a.Get("results-dir");
        if (resultsDir != null)
        {
            if (!Directory.Exists(resultsDir))
                throw new BcDevEnvException($"Results directory not found: '{resultsDir}'.");
            xmlFiles.AddRange(Directory.GetFiles(resultsDir, "*.xml", SearchOption.AllDirectories));
        }

        if (xmlFiles.Count > 0)
            return new Collected(MergeFromFiles(xmlFiles), Array.Empty<string>());

        // Otherwise run live against a running NST via the toolkit's OData runner (and the AL tool).
        return RunLive(a, catalog, service, alTool);
    }

    private static TestRunResult MergeFromFiles(IEnumerable<string> files)
    {
        var merged = new TestRunResult();
        var distinct = files.Select(Path.GetFullPath).Distinct(StringComparer.OrdinalIgnoreCase).ToList();
        foreach (var file in distinct)
        {
            if (!File.Exists(file))
                throw new BcDevEnvException($"Result file not found: '{file}'.");
            Log.Info($"Reading test results from '{file}'.");
            var parsed = XUnitResultParser.Parse(File.ReadAllText(file));
            merged.Codeunits.AddRange(parsed.Codeunits);
        }
        return merged;
    }

    private static Collected RunLive(ParsedArgs a, DisabledTestCatalog? catalog, NavTestService service, AlToolTestRunner alTool)
    {
        var odataUrl = a.Get("odata-url") ?? BuildODataUrl(a);
        var executor = ParseExecutor(a.Get("executor"));
        var perCodeunit = executor == AlToolExecutor || UsePerCodeunitProtocol(a);

        if (executor == AlToolExecutor && a.Get("protocol")?.Equals("run-all", StringComparison.OrdinalIgnoreCase) == true)
            throw new BcDevEnvException("--executor altool needs the per-codeunit protocol (PrepareTests selects the tests); remove --protocol run-all.");
        if (catalog != null && !perCodeunit)
            throw new BcDevEnvException(
                "--disabled-tests needs the per-codeunit protocol (it excludes tests before execution); remove --protocol run-all.");

        var options = new NavTestService.RunOptions
        {
            ODataBaseUrl = odataUrl,
            ServiceName = a.GetOr("service-name", "BcDevEnvTestRunner"),
            RunAction = a.GetOr("run-action", "RunAll"),
            Company = a.Get("company"),
            ExtensionId = a.Get("extension"),
            TestCodeunitFilter = a.Get("test-codeunit"),
            TestSuite = a.GetOr("test-suite", "DEFAULT"),
            Authentication = a.GetOr("auth", "Windows"),
            UserName = a.Get("user"),
            Password = a.Get("password"),
            TimeoutMinutes = int.TryParse(a.Get("timeout-minutes"), out var t) ? t : 30,
            TestType = ParseTestType(a.Get("test-type")),
            RequiredTestIsolation = ParseRequiredTestIsolation(a.Get("required-test-isolation")),
            TestRunnerCodeunitId = ParseOptionalInt(a.Get("test-runner-codeunit-id"), "test-runner-codeunit-id"),
            DisabledTestsJson = catalog?.ToRunnerJson(),
        };

        Log.Info($"Running BC tests against '{options.ODataBaseUrl}' (service '{options.ServiceName}', " +
                 $"protocol {(perCodeunit ? "per-codeunit" : "run-all")}).");

        if (!perCodeunit)
            return new Collected(XUnitResultParser.Parse(service.Run(options)), Array.Empty<string>());

        if (executor == AlToolExecutor)
        {
            var alToolOptions = BuildAlToolOptions(a, options);
            Log.Info($"Executor: altool ({alToolOptions.AlToolPath}; development endpoint {alToolOptions.Server}:{alToolOptions.Port}/" +
                     $"{alToolOptions.ServerInstance}, {alToolOptions.Authentication} authentication). The BcDevEnvTestRunner selects the tests.");
            try
            {
                var prepared = service.Prepare(options);
                var alToolRun = alTool.Run(prepared, alToolOptions);
                LogStateResetSummary(service, options, alToolRun.StateResetsPassed);
                return new Collected(alToolRun.Result, alToolRun.RunnerErrors);
            }
            finally
            {
                EndTestRun(service, options);
            }
        }

        Log.Info($"Executor: odata ({options.ServiceName} RunCodeunit, one call per codeunit).");
        try
        {
            var perCodeunitRun = service.RunPerCodeunit(options);
            return new Collected(perCodeunitRun.Result, perCodeunitRun.RunnerErrors);
        }
        finally
        {
            EndTestRun(service, options);
        }
    }

    // PrepareTests starts a test run during which every client session that opens a company gets ApplicationArea('')
    // (the login hook of the BcDevEnv Test Runner app); ending it keeps that from reaching sessions after the run, such
    // as interactive web client sessions. Best effort, it runs in a finally block: a failure (or an older app without
    // EndTestRun) is a warning and never replaces the run's outcome.
    private static void EndTestRun(NavTestService service, NavTestService.RunOptions options)
    {
        try
        {
            Log.Verbose($"Test run: {service.EndTestRun(options)}.");
        }
        catch (Exception ex)
        {
            Log.Warn($"Could not end the test run ({NavTestService.EndTestRunAction}); until a later run ends, every client session that " +
                     $"opens a company gets an empty application area. {ex.Message}");
        }
    }

    // What the passed state resets committed (the "Application Area Setup" restores); informational, a missing
    // GetStateResetSummary action (an older BcDevEnv Test Runner app) is only a warning.
    private static void LogStateResetSummary(NavTestService service, NavTestService.RunOptions options, int resetsPassed)
    {
        if (resetsPassed == 0) return;
        NavTestService.StateResetSummary summary;
        try
        {
            summary = service.GetStateResetSummary(options);
        }
        catch (BcDevEnvException ex)
        {
            Log.Warn($"State reset: could not read the state reset summary ({NavTestService.GetStateResetSummaryAction}); " +
                     $"is the current BcDevEnv Test Runner app installed? {ex.Message}");
            return;
        }
        var (info, warning) = AlToolTestRunner.StateResetSummaryMessages(summary, resetsPassed);
        Log.Info(info);
        if (warning != null) Log.Warn(warning);
        if (AlToolTestRunner.LoginApplicationAreaWarning(summary, resetsPassed) is { } loginWarning) Log.Warn(loginWarning);
    }

    public const string ODataExecutor = "odata";
    public const string AlToolExecutor = "altool";

    /// <summary>--executor: odata (default; the runner's RunCodeunit) or altool (the AL tool's runtests).</summary>
    public static string ParseExecutor(string? value)
    {
        if (string.IsNullOrWhiteSpace(value)) return ODataExecutor;
        var trimmed = value.Trim();
        if (trimmed.Equals(ODataExecutor, StringComparison.OrdinalIgnoreCase)) return ODataExecutor;
        if (trimmed.Equals(AlToolExecutor, StringComparison.OrdinalIgnoreCase)) return AlToolExecutor;
        throw new BcDevEnvException($"Unknown --executor '{value}'. Use odata or altool.");
    }

    /// <summary>AL tool options from the command line (the connection defaults to the run's server instance).</summary>
    public static AlToolTestRunner.Options BuildAlToolOptions(ParsedArgs a, NavTestService.RunOptions run)
    {
        var alTool = a.Get("altool");
        if (string.IsNullOrWhiteSpace(alTool))
            throw new BcDevEnvException("--executor altool needs --altool <path to altool.dll or altool.exe>.");
        if (!File.Exists(alTool))
            throw new BcDevEnvException($"The AL tool was not found at '{alTool}'.");

        return new AlToolTestRunner.Options
        {
            AlToolPath = alTool,
            DotnetPath = a.Get("dotnet"),
            Company = run.Company,
            Server = a.GetOr("dev-server", "http://localhost"),
            ServerInstance = a.Get("server-instance") ?? Environment.GetEnvironmentVariable("BCDEVENV_INSTANCE") ?? "BC",
            Port = ParsePositiveInt(a.Get("dev-port"), "dev-port", 7049),
            Authentication = run.Authentication,
            UserName = run.UserName,
            Password = run.Password,
            BatchSize = ParseBatchSize(a.Get("altool-batch-size")),
            Timeout = TimeSpan.FromMinutes(ParsePositiveInt(a.Get("app-timeout-minutes"), "app-timeout-minutes", AlToolTestRunner.DefaultTimeoutMinutes)),
            PermissionsMock = ParsePermissionsMock(a.Get("permissions-mock")),
            StateProbe = ParseStateProbe(a.Get("state-probe")),
        };
    }

    /// <summary>--state-probe: off (default) or on (diagnostic: log the state a test codeunit starts with, after the first reset of every batch).</summary>
    public static bool ParseStateProbe(string? value)
    {
        if (string.IsNullOrWhiteSpace(value)) return false;
        var trimmed = value.Trim();
        if (trimmed.Equals("on", StringComparison.OrdinalIgnoreCase)) return true;
        if (trimmed.Equals("off", StringComparison.OrdinalIgnoreCase)) return false;
        throw new BcDevEnvException($"Invalid --state-probe '{value}'. Use on or off.");
    }

    /// <summary>
    /// --permissions-mock: on (default; started before every codeunit, with the D365 Full Access base unless its
    /// TestPermissions is Disabled) or off (stopped).
    /// </summary>
    public static bool ParsePermissionsMock(string? value)
    {
        if (string.IsNullOrWhiteSpace(value)) return true;
        var trimmed = value.Trim();
        if (trimmed.Equals("on", StringComparison.OrdinalIgnoreCase)) return true;
        if (trimmed.Equals("off", StringComparison.OrdinalIgnoreCase)) return false;
        throw new BcDevEnvException($"Invalid --permissions-mock '{value}'. Use on or off.");
    }

    /// <summary>--altool-batch-size: 1 to the number of state reset methods (one runs before every codeunit of a batch).</summary>
    public static int ParseBatchSize(string? value)
    {
        var size = ParsePositiveInt(value, "altool-batch-size", AlToolTestRunner.DefaultBatchSize);
        if (size > AlToolTestRunner.MaxBatchSize)
            throw new BcDevEnvException($"Invalid --altool-batch-size '{value}'. Expected 1 to {AlToolTestRunner.MaxBatchSize} " +
                                        "(the BcDevEnv Test Runner has one state reset method per codeunit of a batch).");
        return size;
    }

    private static int ParsePositiveInt(string? value, string optionName, int defaultValue)
    {
        if (string.IsNullOrWhiteSpace(value)) return defaultValue;
        if (int.TryParse(value, out var parsed) && parsed > 0) return parsed;
        throw new BcDevEnvException($"Invalid --{optionName} '{value}'. Expected a positive integer.");
    }

    /// <summary>Explicit --protocol wins; otherwise any per-codeunit-only option selects it.</summary>
    public static bool UsePerCodeunitProtocol(ParsedArgs a)
    {
        var protocol = a.Get("protocol");
        if (protocol != null)
        {
            if (protocol.Equals("per-codeunit", StringComparison.OrdinalIgnoreCase)) return true;
            if (protocol.Equals("run-all", StringComparison.OrdinalIgnoreCase)) return false;
            throw new BcDevEnvException($"Unknown --protocol '{protocol}'. Use per-codeunit or run-all.");
        }
        return a.Has("disabled-tests") || a.Has("test-type") || a.Has("required-test-isolation") ||
               a.Has("test-runner-codeunit-id");
    }

    /// <summary>Maps --test-type (name or CodeUnit Metadata ordinal) to the TestType option value.</summary>
    public static int ParseTestType(string? value) => ParseOption(value, "test-type",
        new[] { "None", "UnitTest", "IntegrationTest", "Uncategorized", "AITest" });

    /// <summary>Maps --required-test-isolation (name or ordinal) to the RequiredTestIsolation option value.</summary>
    public static int ParseRequiredTestIsolation(string? value) => ParseOption(value, "required-test-isolation",
        new[] { "None", "Disabled", "Codeunit", "Function" });

    private static int ParseOption(string? value, string optionName, string[] members)
    {
        if (string.IsNullOrWhiteSpace(value)) return 0;
        var index = Array.FindIndex(members, m => m.Equals(value.Trim(), StringComparison.OrdinalIgnoreCase));
        if (index >= 0) return index;
        if (int.TryParse(value, out var ordinal) && ordinal >= 0 && ordinal < members.Length) return ordinal;
        throw new BcDevEnvException($"Invalid --{optionName} '{value}'. Use one of: {string.Join(", ", members)}.");
    }

    private static int ParseOptionalInt(string? value, string optionName)
    {
        if (string.IsNullOrWhiteSpace(value)) return 0;
        if (int.TryParse(value, out var parsed) && parsed >= 0) return parsed;
        throw new BcDevEnvException($"Invalid --{optionName} '{value}'. Expected a non-negative integer.");
    }

    private static string BuildODataUrl(ParsedArgs a)
    {
        var server = a.GetOr("server", "localhost");
        var port = a.GetOr("odata-port", "7048");
        var instance = a.Get("server-instance")
                       ?? Environment.GetEnvironmentVariable("BCDEVENV_INSTANCE")
                       ?? "BC";
        return $"http://{server}:{port}/{instance}/ODataV4";
    }

    private static void PrintSummary(TestRunResult run, string resultFile)
    {
        Console.WriteLine();
        Console.WriteLine("Test summary:");
        foreach (var cu in run.Codeunits)
            Console.WriteLine($"  {cu.Name,-48} {cu.Passed,4} passed  {cu.Failed,4} failed  {cu.Skipped,4} skipped");
        Console.WriteLine();
        Console.WriteLine($"  Total: {run.Total}   Passed: {run.Passed}   Failed: {run.Failed}   Skipped: {run.Skipped}   ({run.DurationSeconds:0.0}s)");
        var disabled = run.Codeunits.Sum(c => c.Methods.Count(m =>
            m.Outcome == TestOutcome.Skipped && m.Message == TestSkipReasons.DisabledByDisabledTests));
        if (disabled > 0)
            Console.WriteLine($"  Skipped because of DisabledTests: {disabled}");
        Console.WriteLine($"  JUnit report: {Path.GetFullPath(resultFile)}");
        Console.WriteLine();
    }
}
