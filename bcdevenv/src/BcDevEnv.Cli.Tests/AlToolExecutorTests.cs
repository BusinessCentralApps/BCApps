using System.Net;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using System.Xml.Linq;
using BcDevEnv.Cli.Cli;
using BcDevEnv.Cli.Commands;
using BcDevEnv.Cli.Infra;
using BcDevEnv.Cli.Nav;
using BcDevEnv.Cli.Testing;
using Xunit;

namespace BcDevEnv.Cli.Tests;

/// <summary>
/// Scripted stand-in for AL tool processes; records every call and its test groups file. The responder
/// gets the test groups without the injected state resets and state probe; with <c>autoResets</c> (default)
/// the fake reports a passed OnRun and the requested ResetTestState&lt;nn&gt; method for every injected reset
/// (and a failed ProbeState with <see cref="ProbeMessage"/> for an injected probe), like the AL tool would,
/// and, like the server, fails a test case that repeats a codeunit/method pair of the run.
/// </summary>
internal sealed class FakeAlTool
{
    public const string ProbeMessage = "BcDevEnv state probe (diagnostic, not a test): ApplicationArea='#Basic,#Suite'; SessionId=51";

    private readonly Func<int, IReadOnlyList<AlToolTestRunner.TestGroup>, ProcessCapture> _respond;
    private readonly bool _autoResets;

    public FakeAlTool(Func<int, IReadOnlyList<AlToolTestRunner.TestGroup>, ProcessCapture> respond, bool autoResets = true)
    {
        _respond = respond;
        _autoResets = autoResets;
    }

    public List<(string FileName, IReadOnlyList<string> Arguments, TimeSpan Timeout, IReadOnlyDictionary<string, string>? Environment,
        IReadOnlyList<AlToolTestRunner.TestGroup> Groups, string GroupsJson, IReadOnlyList<AlToolTestRunner.TestGroup> AllGroups)> Calls { get; } = new();

    private static bool IsInjected(AlToolTestRunner.TestGroup g) =>
        AlToolTestRunner.IsStateResetCodeunit(g.CodeunitId) || AlToolTestRunner.IsStateProbeCodeunit(g.CodeunitId);

    public ProcessCapture Execute(string fileName, IReadOnlyList<string> arguments, TimeSpan timeout, IReadOnlyDictionary<string, string>? environment)
    {
        var file = arguments[arguments.ToList().IndexOf("--testgroups") + 1];
        var json = File.ReadAllText(file);
        var all = JsonSerializer.Deserialize<List<AlToolTestRunner.TestGroup>>(json, new JsonSerializerOptions { PropertyNameCaseInsensitive = true })!;
        var groups = all.Where(g => !IsInjected(g)).ToList();
        Calls.Add((fileName, arguments, timeout, environment, groups, json, all));
        var capture = _respond(Calls.Count, groups);
        return _autoResets ? WithResetResults(capture, all.Where(IsInjected)) : capture;
    }

    // Adds the reset and probe results in front of the reported results (when there is a result array). An empty
    // method list runs every reset method; a codeunit/method pair that occurred before fails as on the server.
    private static ProcessCapture WithResetResults(ProcessCapture capture, IEnumerable<AlToolTestRunner.TestGroup> resets)
    {
        var start = capture.StdOut.IndexOf('{');
        var end = capture.StdOut.LastIndexOf('}');
        if (start < 0 || end < start) return capture;
        JsonNode? root;
        try { root = JsonNode.Parse(capture.StdOut[start..(end + 1)]); }
        catch (JsonException) { return capture; }
        if (root?["data"]?["results"] is not JsonArray results) return capture;
        var index = 0;
        var seen = new HashSet<(int, string)>();
        foreach (var reset in resets)
        {
            var probe = AlToolTestRunner.IsStateProbeCodeunit(reset.CodeunitId);
            var methods = reset.TestMethods.Count > 0
                ? reset.TestMethods
                : probe
                    ? new[] { AlToolTestRunner.StateProbeMethodName }
                    : Enumerable.Range(1, AlToolTestRunner.ResetMethodCount).Select(AlToolTestRunner.ResetMethodName).ToList();
            foreach (var method in methods.Prepend("OnRun"))
            {
                var unique = seen.Add((reset.CodeunitId, method.ToUpperInvariant())) || method == "OnRun";
                var probed = unique && probe && method != "OnRun";
                results.Insert(index++, new JsonObject
                {
                    ["codeunitId"] = reset.CodeunitId, ["methodName"] = method, ["status"] = unique && !probed ? "passed" : "failed",
                    ["output"] = probed
                        ? ProbeMessage + "\r\nAL Callstack: \"BcDevEnv State Probe\"(CodeUnit 50105).ProbeState line 40"
                        : unique ? "" : $"Test case name '{method}' is not unique. ITestDataSource.ListTestCases() must return a distinct identifier for every test case.",
                    ["durationMs"] = 5,
                });
            }
        }
        return capture with { StdOut = capture.StdOut[..start] + root.ToJsonString() + capture.StdOut[(end + 1)..] };
    }

    /// <summary>
    /// Codeunit/method pairs that a test groups list selects more than once (an empty method list selects
    /// every method of the codeunit); the server rejects such a run.
    /// </summary>
    public static IReadOnlyList<string> RepeatedTestCases(IEnumerable<AlToolTestRunner.TestGroup> groups) =>
        groups.GroupBy(g => g.CodeunitId).SelectMany(c =>
            c.Count() > 1 && c.Any(g => g.TestMethods.Count == 0)
                ? new[] { $"{c.Key}/*" }
                : c.SelectMany(g => g.TestMethods).GroupBy(m => m, StringComparer.OrdinalIgnoreCase).Where(m => m.Count() > 1).Select(m => $"{c.Key}/{m.Key}"))
        .ToList();

    public static ProcessCapture Output(int exitCode, string stdout, string stderr = "") => new(exitCode, stdout, stderr, false);

    public static string Json(params (int Codeunit, string Method, string Status, string? Output)[] results)
    {
        var failed = results.Count(r => r.Status == "failed");
        return JsonSerializer.Serialize(new
        {
            succeeded = failed == 0,
            message = failed == 0 ? "All tests passed." : $"{failed} test(s) failed.",
            data = new
            {
                success = failed == 0,
                passed = results.Count(r => r.Status == "passed"),
                failed,
                skipped = results.Count(r => r.Status == "skipped"),
                total = results.Length,
                results = results.Select(r => new { codeunitId = r.Codeunit, methodName = r.Method, status = r.Status, output = r.Output ?? "", durationMs = 250 }),
            },
            nextSteps = Array.Empty<string>(),
            warnings = Array.Empty<string>(),
            errorDetails = failed == 0 ? null : new { code = "TestRunFailed" },
        });
    }

    // Exit code as the AL tool sets it: 1 when any test failed.
    public static ProcessCapture Results(params (int Codeunit, string Method, string Status, string? Output)[] results) =>
        Output(results.Any(r => r.Status == "failed") ? 1 : 0, "Running tests...\n" + Json(results));
}

public class AlToolExecutorTests
{
    private const string Disabled = TestSkipReasons.DisabledByDisabledTests;
    private const string NotExecuted = TestSkipReasons.NotExecutedPrefix + " (the codeunit most likely failed before or during OnRun).";

    private static NavTestService.PreparedCodeunit Prepared(int id, string name, bool run, params (string Method, string Result, string? Reason)[] tests) =>
        new(new NavTestService.PlannedCodeunit
            {
                LineNo = id * 10, CodeunitId = id, Name = name, Run = run, Functions = tests.Length,
                DisabledFunctions = tests.Count(t => t.Reason == Disabled),
            },
            XUnitResultParser.Parse(FakeRunnerHandler.XUnit(id, name, tests)), true);

    private static NavTestService.PreparedCodeunit WithTestPermissions(NavTestService.PreparedCodeunit prepared, string? value) =>
        prepared with { Codeunit = prepared.Codeunit with { TestPermissions = value } };

    private static NavTestService.PreparedSuite Suite(params NavTestService.PreparedCodeunit[] codeunits) =>
        new(new NavTestService.TestSuitePlan
            {
                TestSuite = "DEFAULT", TestRunnerId = 130450, Functions = codeunits.Sum(c => c.Codeunit.Functions),
                DisabledFunctions = codeunits.Sum(c => c.Codeunit.DisabledFunctions), Codeunits = codeunits.Select(c => c.Codeunit).ToList(),
            },
            codeunits, Array.Empty<string>());

    private static (string, string, string?) Pending(string method) => (method, "Failure", NotExecuted);
    private static (string, string, string?) Off(string method) => (method, "Skipped", Disabled);

    private static AlToolTestRunner.Options Options(int batchSize = 20, int timeoutMinutes = 240) => new()
    {
        AlToolPath = @"C:\altool\altool.dll",
        DotnetPath = @"C:\Program Files\dotnet\dotnet.exe",
        Company = "CRONUS",
        BatchSize = batchSize,
        Timeout = TimeSpan.FromMinutes(timeoutMinutes),
    };

    private static TestMethodResult Method(AlToolTestRunner.AlToolRun run, int codeunitId, string name) =>
        run.Result.Codeunits.Single(c => c.CodeunitId == codeunitId).Methods.Single(m => m.Name == name);

    [Fact]
    public void Test_groups_run_all_methods_or_only_the_enabled_ones()
    {
        var groups = AlToolTestRunner.BuildTestGroups(new[]
        {
            Prepared(50001, "All Enabled", true, Pending("A"), Pending("B")),
            Prepared(50002, "Partly Disabled", true, Pending("A"), Off("B"), Pending("C")),
            Prepared(50003, "Fully Disabled", false, Off("A")),
            Prepared(50004, "Run But Nothing Enabled", true, Off("A")),
        });

        Assert.Equal(2, groups.Count);
        Assert.Equal(50001, groups[0].CodeunitId);
        Assert.Empty(groups[0].TestMethods);
        Assert.Equal(new[] { "A", "C" }, groups[1].TestMethods);
        Assert.Equal("""[{"codeunitId":50001,"testMethods":[]},{"codeunitId":50002,"testMethods":["A","C"]}]""",
            AlToolTestRunner.SerializeTestGroups(groups));
    }

    [Fact]
    public void Command_runs_altool_dll_through_dotnet_against_the_development_endpoint()
    {
        var (file, args) = AlToolTestRunner.BuildCommand(Options(), @"C:\tmp\groups.json");

        Assert.Equal(@"C:\Program Files\dotnet\dotnet.exe", file);
        Assert.Equal(new[]
        {
            @"C:\altool\altool.dll", "runtests", "--testgroups", @"C:\tmp\groups.json", "--server", "http://localhost",
            "--serverinstance", "BC", "--port", "7049", "--authentication", "Windows", "--company", "CRONUS",
        }, args);

        var (exe, exeArgs) = AlToolTestRunner.BuildCommand(Options() with { AlToolPath = @"C:\altool\altool.exe", Company = null }, "g.json");
        Assert.Equal(@"C:\altool\altool.exe", exe);
        Assert.Equal("runtests", exeArgs[0]);
        Assert.DoesNotContain("--company", exeArgs);
    }

    [Fact]
    public void Output_is_parsed_after_leading_text_and_split_into_message_and_stack()
    {
        using (var doc = AlToolTestRunner.ParseOutput("Connecting...\r\n{\"succeeded\":true}\r\n"))
            Assert.True(doc.RootElement.GetProperty("succeeded").GetBoolean());
        Assert.Throws<BcDevEnvException>(() => AlToolTestRunner.ParseOutput("Unhandled exception: boom"));
        Assert.Throws<BcDevEnvException>(() => AlToolTestRunner.ParseOutput("{ not json }"));

        var (message, stack) = AlToolTestRunner.SplitOutput("Assert.AreEqual failed.\r\nAL Callstack:\r\n\"My Tests\"(CodeUnit 50001).Works line 3\r\n\r\n");
        Assert.Equal("Assert.AreEqual failed.", message);
        Assert.Equal("\"My Tests\"(CodeUnit 50001).Works line 3", stack);
        Assert.Equal(("plain", (string?)null), AlToolTestRunner.SplitOutput("plain"));
    }

    [Fact]
    public void Outcomes_are_merged_into_the_templates_and_disabled_methods_stay_skipped()
    {
        var tool = new FakeAlTool((_, _) => FakeAlTool.Results(
            (50001, "OnRun", "passed", null),
            (50001, "Works", "passed", null),
            (50001, "Breaks", "failed", "Expected 1\r\nAL Callstack:\r\nstack line\r\n"),
            (50001, "Ignored", "skipped", null)));
        var suite = Suite(Prepared(50001, "Alpha Tests", true, Pending("Works"), Pending("Breaks"), Pending("Ignored"), Off("Off")));

        var run = new AlToolTestRunner(tool.Execute).Run(suite, Options());

        Assert.Empty(run.RunnerErrors);
        var groups = Assert.Single(tool.Calls).Groups;
        Assert.Equal(new[] { "Works", "Breaks", "Ignored" }, Assert.Single(groups).TestMethods);
        Assert.Equal(4, run.Result.Total);
        Assert.Equal(TestOutcome.Passed, Method(run, 50001, "Works").Outcome);
        Assert.Equal(0.25, Method(run, 50001, "Works").DurationSeconds);
        var breaks = Method(run, 50001, "Breaks");
        Assert.Equal(TestOutcome.Failed, breaks.Outcome);
        Assert.Equal("Expected 1", breaks.Message);
        Assert.Equal("stack line", breaks.StackTrace);
        Assert.Equal(TestSkipReasons.SkippedByTestRunner, Method(run, 50001, "Ignored").Message);
        Assert.Equal(Disabled, Method(run, 50001, "Off").Message);
        Assert.Equal("My Test App", run.Result.Codeunits.Single().AppName);
    }

    [Fact]
    public void Fully_disabled_codeunits_are_not_run_and_codeunits_are_batched()
    {
        var tool = new FakeAlTool((_, groups) => FakeAlTool.Results(groups.Select(g => (g.CodeunitId, "T", "passed", (string?)null)).ToArray()));
        var suite = Suite(
            Prepared(50001, "A", true, Pending("T")),
            Prepared(50002, "B", false, Off("T")),
            Prepared(50003, "C", true, Pending("T")),
            Prepared(50004, "D", true, Pending("T")));

        var run = new AlToolTestRunner(tool.Execute).Run(suite, Options(batchSize: 2));

        Assert.Empty(run.RunnerErrors);
        Assert.Equal(new[] { new[] { 50001, 50003 }, new[] { 50004 } }, tool.Calls.Select(c => c.Groups.Select(g => g.CodeunitId).ToArray()));
        Assert.Equal(new[] { 50001, 50002, 50003, 50004 }, run.Result.Codeunits.Select(c => c.CodeunitId!.Value));
        Assert.Equal(3, run.Result.Passed);
        Assert.Equal(Disabled, Method(run, 50002, "T").Message);
    }

    [Theory]
    [InlineData(true, AlToolTestRunner.ResetMockStartedCodeunitId)]
    [InlineData(false, AlToolTestRunner.ResetMockStoppedCodeunitId)]
    public void The_state_reset_runs_before_every_codeunit_of_every_batch(bool permissionsMock, int reset)
    {
        var tool = new FakeAlTool((_, groups) => FakeAlTool.Results(groups.Select(g => (g.CodeunitId, "T", "passed", (string?)null)).ToArray()));
        var suite = Suite(
            Prepared(50001, "A", true, Pending("T")),
            Prepared(50002, "B", false, Off("T")),
            Prepared(50003, "C", true, Pending("T"), Off("U")),
            Prepared(50004, "D", true, Pending("T")));

        var run = new AlToolTestRunner(tool.Execute).Run(suite, Options(batchSize: 2) with { PermissionsMock = permissionsMock });

        Assert.Empty(run.RunnerErrors);
        Assert.Equal(new[] { new[] { reset, 50001, reset, 50003 }, new[] { reset, 50004 } },
            tool.Calls.Select(c => c.AllGroups.Select(g => g.CodeunitId).ToArray()));
        Assert.Equal(new[] { new[] { "ResetTestState01", "ResetTestState02" }, new[] { "ResetTestState01" } },
            tool.Calls.Select(c => c.AllGroups.Where(g => g.CodeunitId == reset).Select(g => Assert.Single(g.TestMethods)).ToArray()));
        Assert.All(tool.Calls, c => Assert.Empty(FakeAlTool.RepeatedTestCases(c.AllGroups)));
        Assert.Equal(new[] { "T" }, tool.Calls[0].AllGroups[3].TestMethods);
        Assert.Equal(new[] { 50001, 50002, 50003, 50004 }, run.Result.Codeunits.Select(c => c.CodeunitId!.Value));
        Assert.Equal(5, run.Result.Total);
        Assert.Equal(3, run.Result.Passed);
        Assert.Empty(AlToolTestRunner.WithStateResets(Array.Empty<AlToolTestRunner.TestGroup>(), reset));
    }

    [Fact]
    public void A_failed_state_reset_is_an_infrastructure_error_and_the_results_still_merge()
    {
        const int reset = AlToolTestRunner.ResetMockStartedCodeunitId;
        var tool = new FakeAlTool((_, _) => FakeAlTool.Results(
            (reset, "OnRun", "passed", null),
            (reset, "ResetTestState01", "passed", null),
            (50001, "A", "passed", null),
            (reset, "OnRun", "passed", null),
            (reset, "ResetTestState02", "failed", "Codeunit 130301 failed.\r\nAL Callstack:\r\n\"Reset State Before Test Run\"\r\n"),
            (50002, "B", "passed", null)), autoResets: false);
        var suite = Suite(Prepared(50001, "Alpha", true, Pending("A")), Prepared(50002, "Beta", true, Pending("B")));

        var run = new AlToolTestRunner(tool.Execute).Run(suite, Options());

        var error = Assert.Single(run.RunnerErrors);
        Assert.Contains("the state reset before codeunit 50002 Beta failed", error);
        Assert.Contains($"codeunit {reset} 'ResetTestState02' failed", error);
        Assert.Contains("Codeunit 130301 failed.", error);
        Assert.DoesNotContain("Reset State Before Test Run", error);
        Assert.Equal(2, run.Result.Total);
        Assert.Equal(2, run.Result.Passed);
    }

    [Fact]
    public void A_missing_state_reset_is_an_infrastructure_error()
    {
        const int reset = AlToolTestRunner.ResetMockStartedCodeunitId;
        var tool = new FakeAlTool((_, _) => FakeAlTool.Results(
            (reset, "ResetTestState02", "passed", null),
            (50001, "A", "passed", null),
            (50002, "B", "passed", null)), autoResets: false);
        var suite = Suite(Prepared(50001, "Alpha", true, Pending("A")), Prepared(50002, "Beta", true, Pending("B")));

        var run = new AlToolTestRunner(tool.Execute).Run(suite, Options());

        var error = Assert.Single(run.RunnerErrors);
        Assert.Contains($"reported 1 of 2 state reset(s) (codeunit {reset} ResetTestState01..ResetTestState02); codeunit(s) 50001 ran without", error);
        Assert.Equal(2, run.Result.Passed);
    }

    [Fact]
    public void A_state_reset_method_of_an_old_test_runner_app_does_not_count()
    {
        const int reset = AlToolTestRunner.ResetMockStartedCodeunitId;
        var tool = new FakeAlTool((_, _) => FakeAlTool.Results(
            (reset, "ResetTestState", "passed", null),
            (50001, "A", "passed", null)), autoResets: false);

        var run = new AlToolTestRunner(tool.Execute).Run(Suite(Prepared(50001, "Alpha", true, Pending("A"))), Options());

        Assert.Contains($"reported 0 of 1 state reset(s) (codeunit {reset} ResetTestState01)", Assert.Single(run.RunnerErrors));
        Assert.Equal(1, run.Result.Passed);
    }

    [Theory]
    [InlineData(false, "Restrictive", AlToolTestRunner.ResetMockStoppedCodeunitId)]
    [InlineData(false, "Disabled", AlToolTestRunner.ResetMockStoppedCodeunitId)]
    [InlineData(false, null, AlToolTestRunner.ResetMockStoppedCodeunitId)]
    [InlineData(true, null, AlToolTestRunner.ResetMockStartedCodeunitId)]
    [InlineData(true, " ", AlToolTestRunner.ResetMockStartedCodeunitId)]
    [InlineData(true, "Disabled", AlToolTestRunner.ResetMockStartedCodeunitId)]
    [InlineData(true, " disabled ", AlToolTestRunner.ResetMockStartedCodeunitId)]
    [InlineData(true, "Restrictive", AlToolTestRunner.ResetFullAccessCodeunitId)]
    [InlineData(true, "NonRestrictive", AlToolTestRunner.ResetFullAccessCodeunitId)]
    public void The_state_reset_codeunit_follows_the_permissions_mock_and_the_TestPermissions(bool permissionsMock, string? testPermissions, int expected) =>
        Assert.Equal(expected, AlToolTestRunner.StateResetCodeunitId(permissionsMock, testPermissions));

    [Fact]
    public void Codeunits_whose_TestPermissions_is_not_Disabled_get_the_D365_Full_Access_reset()
    {
        const int started = AlToolTestRunner.ResetMockStartedCodeunitId;
        const int full = AlToolTestRunner.ResetFullAccessCodeunitId;
        var tool = new FakeAlTool((_, groups) => FakeAlTool.Results(groups.Select(g => (g.CodeunitId, "T", "passed", (string?)null)).ToArray()));
        var suite = Suite(
            WithTestPermissions(Prepared(50001, "A", true, Pending("T")), "Disabled"),
            WithTestPermissions(Prepared(50002, "B", true, Pending("T")), "Restrictive"),
            WithTestPermissions(Prepared(50003, "C", true, Pending("T")), "NonRestrictive"),
            Prepared(50004, "D", true, Pending("T")),
            WithTestPermissions(Prepared(50005, "E", true, Pending("T")), "Restrictive"));

        var run = new AlToolTestRunner(tool.Execute).Run(suite, Options(batchSize: 4));

        Assert.Empty(run.RunnerErrors);
        Assert.Equal(new[] { new[] { started, 50001, full, 50002, full, 50003, started, 50004 }, new[] { full, 50005 } },
            tool.Calls.Select(c => c.AllGroups.Select(g => g.CodeunitId).ToArray()));
        Assert.Equal(new[] { new[] { "ResetTestState01", "ResetTestState02", "ResetTestState03", "ResetTestState04" }, new[] { "ResetTestState01" } },
            tool.Calls.Select(c => c.AllGroups.Where(g => AlToolTestRunner.IsStateResetCodeunit(g.CodeunitId)).Select(g => Assert.Single(g.TestMethods)).ToArray()));
        Assert.All(tool.Calls, c => Assert.Empty(FakeAlTool.RepeatedTestCases(c.AllGroups)));
        Assert.Equal(new[] { 50001, 50002, 50003, 50004, 50005 }, run.Result.Codeunits.Select(c => c.CodeunitId!.Value));
        Assert.Equal(5, run.Result.Total);
        Assert.Equal(5, run.Result.Passed);

        var stopped = new FakeAlTool((_, groups) => FakeAlTool.Results(groups.Select(g => (g.CodeunitId, "T", "passed", (string?)null)).ToArray()));
        Assert.Empty(new AlToolTestRunner(stopped.Execute).Run(suite, Options(batchSize: 4) with { PermissionsMock = false }).RunnerErrors);
        Assert.All(stopped.Calls.SelectMany(c => c.AllGroups.Where((_, i) => i % 2 == 0)),
            g => Assert.Equal(AlToolTestRunner.ResetMockStoppedCodeunitId, g.CodeunitId));
    }

    [Fact]
    public void A_full_batch_with_alternating_TestPermissions_selects_every_codeunit_method_pair_once()
    {
        var tool = new FakeAlTool((_, groups) => FakeAlTool.Results(groups.Select(g => (g.CodeunitId, "T", "passed", (string?)null)).ToArray()));
        var suite = Suite(Enumerable.Range(0, AlToolTestRunner.MaxBatchSize)
            .Select(i => WithTestPermissions(Prepared(60000 + i, $"C{i}", true, Pending("T")), i % 2 == 0 ? "Disabled" : "Restrictive")).ToArray());

        var run = new AlToolTestRunner(tool.Execute).Run(suite, Options(batchSize: AlToolTestRunner.MaxBatchSize));

        Assert.Empty(run.RunnerErrors);
        var resets = Assert.Single(tool.Calls).AllGroups.Where((_, i) => i % 2 == 0).ToList();
        Assert.Empty(FakeAlTool.RepeatedTestCases(tool.Calls[0].AllGroups));
        Assert.Equal(Enumerable.Range(1, AlToolTestRunner.MaxBatchSize).Select(AlToolTestRunner.ResetMethodName), resets.Select(g => Assert.Single(g.TestMethods)));
        Assert.Equal(Enumerable.Range(0, AlToolTestRunner.MaxBatchSize)
                .Select(i => i % 2 == 0 ? AlToolTestRunner.ResetMockStartedCodeunitId : AlToolTestRunner.ResetFullAccessCodeunitId),
            resets.Select(g => g.CodeunitId));
        Assert.Equal(AlToolTestRunner.MaxBatchSize, run.Result.Passed);
    }

    [Fact]
    public void A_failed_D365_Full_Access_reset_is_an_infrastructure_error()
    {
        const int started = AlToolTestRunner.ResetMockStartedCodeunitId;
        const int full = AlToolTestRunner.ResetFullAccessCodeunitId;
        var tool = new FakeAlTool((_, _) => FakeAlTool.Results(
            (started, "ResetTestState01", "passed", null),
            (50001, "A", "passed", null),
            (full, "ResetTestState02", "failed", "Codeunit 130302 failed.\r\nAL Callstack:\r\n\"Set State Test Run\"\r\n"),
            (50002, "B", "passed", null)), autoResets: false);
        var suite = Suite(
            WithTestPermissions(Prepared(50001, "Alpha", true, Pending("A")), "Disabled"),
            WithTestPermissions(Prepared(50002, "Beta", true, Pending("B")), "Restrictive"));

        var run = new AlToolTestRunner(tool.Execute).Run(suite, Options());

        var error = Assert.Single(run.RunnerErrors);
        Assert.Contains($"the state reset before codeunit 50002 Beta failed (codeunit {full} 'ResetTestState02' failed): Codeunit 130302 failed.", error);
        Assert.Equal(2, run.Result.Passed);
    }

    [Fact]
    public void A_state_reset_from_another_reset_codeunit_than_its_position_uses_does_not_count()
    {
        const int started = AlToolTestRunner.ResetMockStartedCodeunitId;
        const int full = AlToolTestRunner.ResetFullAccessCodeunitId;
        var tool = new FakeAlTool((_, _) => FakeAlTool.Results(
            (full, "ResetTestState01", "passed", null),
            (50001, "A", "passed", null),
            (full, "ResetTestState02", "passed", null),
            (50002, "B", "passed", null)), autoResets: false);
        var suite = Suite(
            WithTestPermissions(Prepared(50001, "Alpha", true, Pending("A")), "Disabled"),
            WithTestPermissions(Prepared(50002, "Beta", true, Pending("B")), "NonRestrictive"));

        var run = new AlToolTestRunner(tool.Execute).Run(suite, Options());

        Assert.Contains($"reported 1 of 2 state reset(s) (codeunit {started} / {full} ResetTestState01..ResetTestState02); codeunit(s) 50001 ran without",
            Assert.Single(run.RunnerErrors));
        Assert.Equal(2, run.Result.Passed);
    }

    [Fact]
    public void State_reset_warnings_name_codeunits_without_or_with_mixed_TestPermissions()
    {
        NavTestService.PlannedCodeunit Planned(int id, string? value, bool mixed = false) =>
            new() { CodeunitId = id, Name = $"C{id}", Run = true, TestPermissions = value, TestPermissionsMixed = mixed };
        var codeunits = new[]
        {
            Planned(50001, "Restrictive"), Planned(50002, null), Planned(50003, "Disabled", mixed: true),
            Planned(50004, "NonRestrictive", mixed: true), Planned(50005, ""), Planned(50006, "Disabled"),
        };

        Assert.Empty(AlToolTestRunner.StateResetWarnings(codeunits, permissionsMock: false));
        var warnings = AlToolTestRunner.StateResetWarnings(codeunits, permissionsMock: true);

        Assert.Equal(3, warnings.Count);
        Assert.Contains("reported no TestPermissions for 2 codeunit(s) (50002, 50005)", warnings[0]);
        Assert.Contains($"without assignments (codeunit {AlToolTestRunner.ResetMockStartedCodeunitId})", warnings[0]);
        Assert.StartsWith("Codeunit 50003 C50003: its selected test methods have different TestPermissions", warnings[1]);
        Assert.EndsWith($"(Disabled, codeunit {AlToolTestRunner.ResetMockStartedCodeunitId}).", warnings[1]);
        Assert.EndsWith($"(NonRestrictive, codeunit {AlToolTestRunner.ResetFullAccessCodeunitId}).", warnings[2]);
        Assert.Empty(AlToolTestRunner.StateResetWarnings(new[] { Planned(50001, "Restrictive"), Planned(50006, "Disabled") }, permissionsMock: true));
        Assert.Contains("for 12 codeunit(s) (1, 2, 3, 4, 5, 6, 7, 8, 9, 10, ...)",
            Assert.Single(AlToolTestRunner.StateResetWarnings(Enumerable.Range(1, 12).Select(i => Planned(i, null)), permissionsMock: true)));
    }

    [Fact]
    public void State_resets_need_one_reset_codeunit_per_group()
    {
        var groups = new[] { new AlToolTestRunner.TestGroup(50001, Array.Empty<string>()), new AlToolTestRunner.TestGroup(50002, Array.Empty<string>()) };

        Assert.Equal(new[] { AlToolTestRunner.ResetFullAccessCodeunitId, 50001, AlToolTestRunner.ResetMockStartedCodeunitId, 50002 },
            AlToolTestRunner.WithStateResets(groups, new[] { AlToolTestRunner.ResetFullAccessCodeunitId, AlToolTestRunner.ResetMockStartedCodeunitId })
                .Select(g => g.CodeunitId));
        Assert.Throws<ArgumentException>(() => AlToolTestRunner.WithStateResets(groups, new[] { AlToolTestRunner.ResetFullAccessCodeunitId }));
        Assert.Throws<ArgumentException>(() => AlToolTestRunner.WithStateResets(groups, new[] { AlToolTestRunner.ResetFullAccessCodeunitId, 50001 }));
    }

    [Theory]
    [InlineData(20)]
    [InlineData(AlToolTestRunner.MaxBatchSize)]
    public void A_full_batch_selects_every_codeunit_method_pair_once(int codeunits)
    {
        var tool = new FakeAlTool((_, groups) => FakeAlTool.Results(groups.Select(g => (g.CodeunitId, "T", "passed", (string?)null)).ToArray()));
        var suite = Suite(Enumerable.Range(0, codeunits).Select(i => Prepared(60000 + i, $"C{i}", true, Pending("T"))).ToArray());

        var run = new AlToolTestRunner(tool.Execute).Run(suite, Options(batchSize: codeunits));

        Assert.Empty(run.RunnerErrors);
        var call = Assert.Single(tool.Calls);
        Assert.Empty(FakeAlTool.RepeatedTestCases(call.AllGroups));
        Assert.Equal(2 * codeunits, call.AllGroups.Count);
        Assert.Equal(Enumerable.Range(1, codeunits).Select(AlToolTestRunner.ResetMethodName),
            call.AllGroups.Where((_, i) => i % 2 == 0).Select(g => Assert.Single(g.TestMethods)));
        Assert.Equal(codeunits, run.Result.Passed);
        Assert.Equal(codeunits, run.Result.Total);
    }

    [Fact]
    public void A_repeated_state_reset_method_is_reported_like_the_server_does()
    {
        // The defect this guards against: the same reset method before every codeunit of a batch.
        var groups = new[]
        {
            new AlToolTestRunner.TestGroup(AlToolTestRunner.ResetMockStartedCodeunitId, new[] { "ResetTestState" }), new AlToolTestRunner.TestGroup(50001, Array.Empty<string>()),
            new AlToolTestRunner.TestGroup(AlToolTestRunner.ResetMockStartedCodeunitId, new[] { "ResetTestState" }), new AlToolTestRunner.TestGroup(50002, Array.Empty<string>()),
        };

        Assert.Equal(new[] { $"{AlToolTestRunner.ResetMockStartedCodeunitId}/ResetTestState" }, FakeAlTool.RepeatedTestCases(groups));
    }

    [Fact]
    public void State_reset_methods_are_numbered_per_position_and_limit_the_batch_size()
    {
        Assert.Equal("ResetTestState01", AlToolTestRunner.ResetMethodName(1));
        Assert.Equal("ResetTestState50", AlToolTestRunner.ResetMethodName(AlToolTestRunner.ResetMethodCount));
        Assert.Throws<ArgumentOutOfRangeException>(() => AlToolTestRunner.ResetMethodName(0));
        Assert.Throws<ArgumentOutOfRangeException>(() => AlToolTestRunner.ResetMethodName(AlToolTestRunner.ResetMethodCount + 1));
        Assert.Equal(7, AlToolTestRunner.ResetMethodPosition("resetteststate07"));
        Assert.Equal(0, AlToolTestRunner.ResetMethodPosition("ResetTestState"));
        Assert.Equal(0, AlToolTestRunner.ResetMethodPosition("ResetTestState00"));
        Assert.Equal(0, AlToolTestRunner.ResetMethodPosition("ResetTestState51"));
        Assert.Equal(0, AlToolTestRunner.ResetMethodPosition("OnRun"));
        Assert.True(AlToolTestRunner.DefaultBatchSize <= AlToolTestRunner.MaxBatchSize);

        var groups = Enumerable.Range(1, AlToolTestRunner.ResetMethodCount + 1).Select(i => new AlToolTestRunner.TestGroup(i, Array.Empty<string>()));
        Assert.Throws<ArgumentException>(() => AlToolTestRunner.WithStateResets(groups, AlToolTestRunner.ResetMockStartedCodeunitId));
    }

    [Theory]
    [InlineData("BcDevEnvResetMockStarted.Codeunit.al", AlToolTestRunner.ResetMockStartedCodeunitId, "TestStateReset.Reset(true);")]
    [InlineData("BcDevEnvResetMockStopped.Codeunit.al", AlToolTestRunner.ResetMockStoppedCodeunitId, "TestStateReset.Reset(false);")]
    [InlineData("BcDevEnvResetFullAccess.Codeunit.al", AlToolTestRunner.ResetFullAccessCodeunitId, "TestStateReset.Reset(true, true);")]
    public void The_state_reset_codeunits_have_one_test_method_per_batch_position(string file, int codeunitId, string reset)
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir != null && !File.Exists(Path.Combine(dir.FullName, "testrunner", "src", file))) dir = dir.Parent;
        Assert.NotNull(dir);
        var source = File.ReadAllText(Path.Combine(dir!.FullName, "testrunner", "src", file));

        Assert.Matches($@"codeunit {codeunitId} ""[^""]+""", source);
        Assert.Contains("Subtype = Test;", source);
        // The server commits the reset (the "Application Area Setup" restore) only without test isolation.
        Assert.Contains("RequiredTestIsolation = Disabled;", source);
        var methods = Regex.Matches(source, @"\[Test\]\s+procedure (\w+)\(\)").Select(m => m.Groups[1].Value).ToList();
        Assert.Equal(Enumerable.Range(1, AlToolTestRunner.ResetMethodCount).Select(AlToolTestRunner.ResetMethodName), methods);
        Assert.Equal(AlToolTestRunner.ResetMethodCount, Regex.Matches(source, @"procedure \w+\(\)").Count(m => m.Value.Contains(AlToolTestRunner.ResetMethodPrefix)));
        Assert.Contains(reset, source);
    }

    [Fact]
    public void Only_state_reset_results_are_no_test_results()
    {
        var tool = new FakeAlTool((_, _) => FakeAlTool.Results());
        var run = new AlToolTestRunner(tool.Execute).Run(Suite(Prepared(50001, "Alpha", true, Pending("A"))), Options());

        Assert.Contains("reported no test results", Assert.Single(run.RunnerErrors));
        Assert.Equal(1, run.Result.Failed);
    }

    [Fact]
    public void Passed_state_resets_are_counted_once_per_codeunit()
    {
        var tool = new FakeAlTool((_, groups) => FakeAlTool.Results(groups.Select(g => (g.CodeunitId, "T", "passed", (string?)null)).ToArray()));
        var suite = Suite(Prepared(50001, "A", true, Pending("T")), Prepared(50002, "B", true, Pending("T")), Prepared(50003, "C", true, Pending("T")));

        Assert.Equal(3, new AlToolTestRunner(tool.Execute).Run(suite, Options(batchSize: 2) with { StateProbe = true }).StateResetsPassed);

        // OnRun, a reset codeunit that was not chosen for the position and a failed reset do not count.
        const int reset = AlToolTestRunner.ResetMockStartedCodeunitId;
        var partly = new FakeAlTool((_, _) => FakeAlTool.Results(
            (reset, "OnRun", "passed", null),
            (reset, AlToolTestRunner.ResetMethodName(1), "passed", null),
            (50001, "T", "passed", null),
            (AlToolTestRunner.ResetFullAccessCodeunitId, AlToolTestRunner.ResetMethodName(2), "passed", null),
            (50002, "T", "passed", null),
            (reset, AlToolTestRunner.ResetMethodName(3), "failed", "boom"),
            (50003, "T", "passed", null)), autoResets: false);
        var run = new AlToolTestRunner(partly.Execute).Run(suite, Options());

        Assert.Equal(1, run.StateResetsPassed);
        Assert.Equal(2, run.RunnerErrors.Count);
    }

    [Fact]
    public void The_state_reset_summary_is_parsed_from_the_runner_response()
    {
        var summary = NavTestService.ParseStateResetSummary(NavTestService.ExtractXml(
            """{"@odata.context":"x","value":"{\"tablePresent\":true,\"baselineRows\":0,\"resets\":41,\"restores\":2,\"removed\":2,\"recreated\":0,\"modified\":0}"}"""));

        Assert.Equal(new NavTestService.StateResetSummary { TablePresent = true, BaselineRows = 0, Resets = 41, Restores = 2, Removed = 2 }, summary);
        Assert.Null(summary.LoginSessions);
        Assert.Equal(-1, NavTestService.ParseStateResetSummary("{}").BaselineRows);
        var withLogin = NavTestService.ParseStateResetSummary("""{"tablePresent":true,"baselineRows":1,"resets":41,"loginSessions":83,"loginSessionsWithArea":83}""");
        Assert.Equal((83, 83), (withLogin.LoginSessions, withLogin.LoginSessionsWithArea));
        Assert.Throws<BcDevEnvException>(() => NavTestService.ParseStateResetSummary("not json"));
        Assert.Throws<BcDevEnvException>(() => NavTestService.ParseStateResetSummary("null"));
    }

    [Fact]
    public void The_state_reset_summary_reports_the_login_application_area_hook()
    {
        var summary = new NavTestService.StateResetSummary { TablePresent = true, BaselineRows = 1, Resets = 41, LoginSessions = 83, LoginSessionsWithArea = 83 };

        var (info, warning) = AlToolTestRunner.StateResetSummaryMessages(summary, 41);
        Assert.Equal("State reset: 41 state reset(s) committed (41 passed); \"Application Area Setup\" (baseline 1 row(s)) restored by 0 of them: " +
                     "0 row(s) removed, 0 re-created, 0 modified; login ApplicationArea cleared in 83 session(s) (83 had one set at login).", info);
        Assert.Null(warning);
        Assert.Null(AlToolTestRunner.LoginApplicationAreaWarning(summary, 2));
        Assert.EndsWith("; there is no \"Application Area Setup\" table to restore; login ApplicationArea cleared in 2 session(s) (0 had one set at login).",
            AlToolTestRunner.StateResetSummaryMessages(new NavTestService.StateResetSummary { Resets = 1, LoginSessions = 2 }, 1).Info);

        // Every AL tool invocation logs in once, however many resets and test codeunits it runs (W1: 8 sessions for
        // 8 batches with 159 resets), so the hook should have counted at least one session per invocation.
        Assert.Null(AlToolTestRunner.LoginApplicationAreaWarning(summary with { Resets = 159, LoginSessions = 8, LoginSessionsWithArea = 0 }, 8));
        Assert.Contains("cleared in only 7 session(s), fewer than the 8 AL tool invocation(s) that reported results",
            AlToolTestRunner.LoginApplicationAreaWarning(summary with { LoginSessions = 7, LoginSessionsWithArea = 0 }, 8));
        Assert.Contains("cleared in only 0 session(s), fewer than the 1 AL tool invocation(s)",
            AlToolTestRunner.LoginApplicationAreaWarning(summary with { LoginSessions = 0, LoginSessionsWithArea = 0 }, 1));
        // A runner app without the login hook reports no sessions: neither a count nor a warning.
        Assert.Null(AlToolTestRunner.LoginApplicationAreaWarning(summary with { LoginSessions = null }, 41));
        Assert.DoesNotContain("login", AlToolTestRunner.StateResetSummaryMessages(summary with { LoginSessions = null }, 41).Info);
    }

    [Fact]
    public void Only_al_tool_invocations_that_reported_results_are_counted_as_logins()
    {
        var tool = new FakeAlTool((call, groups) => call == 2
            ? FakeAlTool.Output(1, "Unable to connect to the server.")
            : FakeAlTool.Results(groups.Select(g => (g.CodeunitId, "T", "passed", (string?)null)).ToArray()));
        var suite = Suite(
            Prepared(50001, "A", true, Pending("T")), Prepared(50002, "B", true, Pending("T")),
            Prepared(50003, "C", true, Pending("T")), Prepared(50004, "D", true, Pending("T")),
            Prepared(50005, "E", true, Pending("T")));

        var run = new AlToolTestRunner(tool.Execute).Run(suite, Options(batchSize: 2));

        Assert.Equal(3, tool.Calls.Count);
        Assert.Equal(2, run.Invocations);
        Assert.Equal(3, run.StateResetsPassed);
        Assert.Single(run.RunnerErrors);
    }

    [Fact]
    public void The_state_reset_summary_warns_when_passed_resets_were_not_committed()
    {
        var restored = new NavTestService.StateResetSummary { TablePresent = true, BaselineRows = 0, Resets = 41, Restores = 2, Removed = 2 };

        var (info, warning) = AlToolTestRunner.StateResetSummaryMessages(restored, 41);
        Assert.Equal("State reset: 41 state reset(s) committed (41 passed); \"Application Area Setup\" (baseline 0 row(s)) restored by 2 of them: " +
                     "2 row(s) removed, 0 re-created, 0 modified.", info);
        Assert.Null(warning);

        // A reset that failed after its restore was committed counts as committed, not as passed.
        Assert.Null(AlToolTestRunner.StateResetSummaryMessages(restored, 40).Warning);

        // Resets that passed but whose changes the server rolled back.
        var (_, rolledBack) = AlToolTestRunner.StateResetSummaryMessages(restored with { Resets = 0, Restores = 0, Removed = 0 }, 41);
        Assert.Contains("only 0 of 41 passed state reset(s) were committed", rolledBack);

        var (noTable, none) = AlToolTestRunner.StateResetSummaryMessages(new NavTestService.StateResetSummary { Resets = 3 }, 3);
        Assert.Equal("State reset: 3 state reset(s) committed (3 passed); there is no \"Application Area Setup\" table to restore.", noTable);
        Assert.Null(none);
    }

    [Fact]
    public void A_prepared_state_reset_codeunit_is_left_out()
    {
        var tool = new FakeAlTool((_, groups) => FakeAlTool.Results(groups.Select(g => (g.CodeunitId, "T", "passed", (string?)null)).ToArray()));
        var suite = Suite(
            Prepared(AlToolTestRunner.ResetMockStoppedCodeunitId, "BcDevEnv Reset Mock Stopped", true, Pending(AlToolTestRunner.ResetMethodName(1))),
            WithTestPermissions(Prepared(AlToolTestRunner.ResetFullAccessCodeunitId, "BcDevEnv Reset Full Access", true, Pending(AlToolTestRunner.ResetMethodName(1))), "Restrictive"),
            Prepared(50001, "Alpha", true, Pending("T")));

        var run = new AlToolTestRunner(tool.Execute).Run(suite, Options());

        Assert.Empty(run.RunnerErrors);
        Assert.Equal(new[] { AlToolTestRunner.ResetMockStartedCodeunitId, 50001 }, Assert.Single(tool.Calls).AllGroups.Select(g => g.CodeunitId));
        Assert.Equal(50001, Assert.Single(run.Result.Codeunits).CodeunitId);
    }

    [Fact]
    public void The_state_probe_runs_once_per_batch_before_the_first_reset_and_is_no_test_result()
    {
        const int reset = AlToolTestRunner.ResetMockStartedCodeunitId;
        const int probe = AlToolTestRunner.StateProbeCodeunitId;
        var tool = new FakeAlTool((_, groups) => FakeAlTool.Results(groups.Select(g => (g.CodeunitId, "T", "passed", (string?)null)).ToArray()));
        var suite = Suite(
            Prepared(50001, "A", true, Pending("T")),
            Prepared(50002, "B", true, Pending("T")),
            Prepared(50003, "C", true, Pending("T")));

        var run = new AlToolTestRunner(tool.Execute).Run(suite, Options(batchSize: 2) with { StateProbe = true });

        Assert.Empty(run.RunnerErrors);
        // First, so that the batch's first reset clears its error before any test codeunit runs.
        Assert.Equal(new[] { new[] { probe, reset, 50001, reset, 50002 }, new[] { probe, reset, 50003 } },
            tool.Calls.Select(c => c.AllGroups.Select(g => g.CodeunitId).ToArray()));
        Assert.All(tool.Calls, c => Assert.Equal(new[] { AlToolTestRunner.StateProbeMethodName }, c.AllGroups[0].TestMethods));
        Assert.All(tool.Calls, c => Assert.Empty(FakeAlTool.RepeatedTestCases(c.AllGroups)));
        Assert.Equal(new[] { 50001, 50002, 50003 }, run.Result.Codeunits.Select(c => c.CodeunitId!.Value));
        Assert.Equal(3, run.Result.Total);
        Assert.Equal(3, run.Result.Passed);
        Assert.Equal(new[]
            {
                $"AL tool batch 1/2 (codeunit(s) 50001, 50002): {FakeAlTool.ProbeMessage}",
                $"AL tool batch 2/2 (codeunit(s) 50003): {FakeAlTool.ProbeMessage}",
            }, run.StateProbes);
        Assert.DoesNotContain(run.StateProbes, p => p.Contains("AL Callstack"));
    }

    [Fact]
    public void The_state_probe_is_off_by_default_and_a_missing_probe_is_no_infrastructure_error()
    {
        var tool = new FakeAlTool((_, groups) => FakeAlTool.Results(groups.Select(g => (g.CodeunitId, "T", "passed", (string?)null)).ToArray()));
        var suite = Suite(Prepared(50001, "A", true, Pending("T")), Prepared(50002, "B", true, Pending("T")));

        var off = new AlToolTestRunner(tool.Execute).Run(suite, Options());

        Assert.Empty(off.RunnerErrors);
        Assert.Empty(off.StateProbes);
        Assert.DoesNotContain(Assert.Single(tool.Calls).AllGroups, g => AlToolTestRunner.IsStateProbeCodeunit(g.CodeunitId));
        Assert.Equal(new[] { AlToolTestRunner.ResetMockStartedCodeunitId, 50001, AlToolTestRunner.ResetMockStartedCodeunitId, 50002 },
            AlToolTestRunner.WithStateResets(tool.Calls[0].Groups, AlToolTestRunner.ResetMockStartedCodeunitId).Select(g => g.CodeunitId));

        // An old BcDevEnv Test Runner app without the probe: the resets still run, the probe result is just missing.
        const int reset = AlToolTestRunner.ResetMockStartedCodeunitId;
        var old = new FakeAlTool((_, _) => FakeAlTool.Results(
            (reset, AlToolTestRunner.ResetMethodName(1), "passed", null),
            (50001, "T", "passed", null),
            (reset, AlToolTestRunner.ResetMethodName(2), "passed", null),
            (50002, "T", "passed", null)), autoResets: false);
        var missing = new AlToolTestRunner(old.Execute).Run(suite, Options() with { StateProbe = true });

        Assert.Empty(missing.RunnerErrors);
        Assert.Empty(missing.StateProbes);
        Assert.Equal(2, missing.Result.Passed);
    }

    [Fact]
    public void A_prepared_state_probe_codeunit_is_left_out()
    {
        var tool = new FakeAlTool((_, groups) => FakeAlTool.Results(groups.Select(g => (g.CodeunitId, "T", "passed", (string?)null)).ToArray()));
        var suite = Suite(
            Prepared(AlToolTestRunner.StateProbeCodeunitId, "BcDevEnv State Probe", true, Pending(AlToolTestRunner.StateProbeMethodName)),
            Prepared(50001, "Alpha", true, Pending("T")));

        var run = new AlToolTestRunner(tool.Execute).Run(suite, Options());

        Assert.Empty(run.RunnerErrors);
        Assert.Equal(new[] { AlToolTestRunner.ResetMockStartedCodeunitId, 50001 }, Assert.Single(tool.Calls).AllGroups.Select(g => g.CodeunitId));
        Assert.Equal(50001, Assert.Single(run.Result.Codeunits).CodeunitId);
    }

    [Fact]
    public void The_state_probe_codeunit_has_one_test_method()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir != null && !File.Exists(Path.Combine(dir.FullName, "testrunner", "src", "BcDevEnvStateProbe.Codeunit.al"))) dir = dir.Parent;
        Assert.NotNull(dir);
        var source = File.ReadAllText(Path.Combine(dir!.FullName, "testrunner", "src", "BcDevEnvStateProbe.Codeunit.al"));

        Assert.Matches($@"codeunit {AlToolTestRunner.StateProbeCodeunitId} ""BcDevEnv State Probe""", source);
        Assert.Contains("Subtype = Test;", source);
        Assert.Equal(new[] { AlToolTestRunner.StateProbeMethodName },
            Regex.Matches(source, @"\[Test\]\s+procedure (\w+)\(\)").Select(m => m.Groups[1].Value));
    }

    [Fact]
    public void The_login_hook_clears_only_the_session_application_area_while_a_run_is_active()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir != null && !File.Exists(Path.Combine(dir.FullName, "testrunner", "src", "BcDevEnvLoginAppArea.Codeunit.al"))) dir = dir.Parent;
        Assert.NotNull(dir);
        var source = File.ReadAllText(Path.Combine(dir!.FullName, "testrunner", "src", "BcDevEnvLoginAppArea.Codeunit.al"));
        var runner = File.ReadAllText(Path.Combine(dir.FullName, "testrunner", "src", "BcDevEnvTestRunner.Codeunit.al"));

        Assert.Matches(@"codeunit 50109 ""BcDevEnv Login App Area""", source);
        // After the Base Application's login (OnCompanyOpen) has set the application area, in the test session itself.
        var subscriber = Regex.Match(source,
            @"\[EventSubscriber\(ObjectType::Codeunit, Codeunit::""Company Triggers"", OnCompanyOpenCompleted, '', false, false\)\]\s+" +
            @"local procedure \w+\(\)\s+begin(?<body>.*?)\r?\n    end;", RegexOptions.Singleline);
        Assert.True(subscriber.Success);
        var body = subscriber.Groups["body"].Value;
        var clear = body.IndexOf("ApplicationArea('');", StringComparison.Ordinal);
        Assert.InRange(body.IndexOf("if not GuiAllowed() then", StringComparison.Ordinal), 0, clear);
        Assert.InRange(body.IndexOf("if not IsRunActive() then", StringComparison.Ordinal), 0, clear);
        // Session only: "Application Area Setup" keeps its rows (tests that read it keep the standard semantics).
        var code = Regex.Replace(source, @"//[^\r\n]*", "");
        Assert.DoesNotMatch(@"Record ""Application Area Setup""|9178|RecordRef", code);

        // PrepareTests starts the run, EndTestRun (which the CLI calls) ends it.
        Assert.Contains("LoginAppArea.StartRun();", runner);
        Assert.Contains("if LoginAppArea.EndRun() then", AlProcedure(runner, $@"procedure {NavTestService.EndTestRunAction}\(\): Text"));
    }

    [Fact]
    public void Test_initialize_clears_the_last_error_and_restarts_a_stopped_permissions_mock_with_the_recorded_base_while_a_run_is_active()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir != null && !File.Exists(Path.Combine(dir.FullName, "testrunner", "src", "BcDevEnvMockRestart.Codeunit.al"))) dir = dir.Parent;
        Assert.NotNull(dir);
        string Read(string file) => File.ReadAllText(Path.Combine(dir!.FullName, "testrunner", "src", file));
        var restart = Read("BcDevEnvMockRestart.Codeunit.al");
        var reset = Read("BcDevEnvTestStateReset.Codeunit.al");
        var runner = Read("BcDevEnvTestRunner.Codeunit.al");
        var login = Read("BcDevEnvLoginAppArea.Codeunit.al");

        // Compiled only when both Application Test Library and Permissions Mock are installed: everything but the
        // header comment is inside both guards.
        var code = Regex.Replace(restart, @"(?m)^\s*//[^\r\n]*\r?\n", "").Trim();
        Assert.Matches(@"^#if BCDEVENV_APPTESTLIB\r?\n#if BCDEVENV_PERMISSIONSMOCK\r?\n", code);
        Assert.Matches(@"\r?\n#endif\r?\n#endif$", code);
        Assert.Matches(@"codeunit 50110 ""BcDevEnv Mock Restart""", code);

        var subscriber = Regex.Match(code,
            @"\[EventSubscriber\(ObjectType::Codeunit, Codeunit::""Library - Test Initialize"", OnTestInitialize, '', false, false\)\]\s+" +
            @"local procedure \w+\(CallerCodeunitID: Integer\)(?<body>.*?)\r?\n    end;", RegexOptions.Singleline);
        Assert.True(subscriber.Success);
        var body = subscriber.Groups["body"].Value;
        var restartCall = body.IndexOf("TestStateReset.RestartStoppedPermissionsMock();", StringComparison.Ordinal);
        var startedExit = body.IndexOf("if PermissionsMock.IsStarted() then", StringComparison.Ordinal);
        var runActiveExit = body.IndexOf("if not LoginAppArea.IsRunActive() then", StringComparison.Ordinal);
        var clearLastError = body.IndexOf("ClearLastError();", StringComparison.Ordinal);
        Assert.InRange(startedExit, 0, restartCall);
        Assert.InRange(runActiveExit, 0, restartCall);
        // The last error is cleared in every initializing method of a run, also when the mock is started.
        Assert.InRange(clearLastError, runActiveExit, startedExit);
        // A started mock keeps the assignments the test made before its Initialize.
        Assert.DoesNotMatch(@"ClearAssignments|\.Set\(|\.Assign\(|\.Stop\(\)|\.Start\(\)", code);
        Assert.Matches(@"\r?\n    procedure IsRunActive\(\): Boolean", login);

        // The restart acts only on a stopped mock, with the base that the reset recorded (and committed) for the codeunit.
        var restartProcedure = AlProcedure(reset, @"procedure RestartStoppedPermissionsMock\(\): Boolean");
        Assert.Matches(@"^\s+var\s+PermissionsMock: Codeunit ""Permissions Mock"";\s+Base: Text;\s+begin\s+if PermissionsMock\.IsStarted\(\) then\s+exit\(false\);\s+if not IsolatedStorage\.Get\(", restartProcedure);
        var restartAt = reset.IndexOf("procedure RestartStoppedPermissionsMock", StringComparison.Ordinal);
        var guardAt = reset.LastIndexOf("#if BCDEVENV_PERMISSIONSMOCK", restartAt, StringComparison.Ordinal);
        Assert.InRange(guardAt, 0, restartAt);
        Assert.DoesNotContain("#endif", reset[guardAt..restartAt]);
        var resetProcedure = AlProcedure(reset, @"procedure Reset\(StartPermissionsMock: Boolean; FullAccessBase: Boolean\)");
        Assert.InRange(resetProcedure.IndexOf("SetPermissionsMockBase(StartPermissionsMock, FullAccessBase);", StringComparison.Ordinal), 0, resetProcedure.IndexOf("Commit();", StringComparison.Ordinal));
        // The reset clears the last error last, so no earlier test codeunit (or the state probe) leaves one for the next.
        var resetCode = Regex.Replace(resetProcedure, @"(?m)^\s*//[^\r\n]*\r?\n", "").TrimEnd();
        Assert.EndsWith("RunIfPresent(132553);\r\n        ClearLastError();", resetCode.ReplaceLineEndings("\r\n"));

        // No base outside a run: PrepareTests (before its commit) and EndTestRun forget it.
        var prepare = AlProcedure(runner, @"procedure PrepareTests\([^)]*\): Text");
        Assert.InRange(prepare.IndexOf("TestStateReset.ClearPermissionsMockBase();", StringComparison.Ordinal), 0, prepare.IndexOf("Commit();", StringComparison.Ordinal));
        Assert.Contains("TestStateReset.ClearPermissionsMockBase();", AlProcedure(runner, $@"procedure {NavTestService.EndTestRunAction}\(\): Text"));
    }

    // The body (from the line after the signature to the procedure's "end;") of an AL procedure at the top level of an object.
    private static string AlProcedure(string source, string signaturePattern)
    {
        var match = Regex.Match(source, signaturePattern + @"[^\r\n]*\r?\n(?<body>.*?)\r?\n    end;", RegexOptions.Singleline);
        Assert.True(match.Success, $"No AL procedure matches '{signaturePattern}'.");
        return match.Groups["body"].Value;
    }

    [Fact]
    public void A_selected_test_without_result_stays_a_not_executed_failure_with_the_onrun_error()
    {
        var tool = new FakeAlTool((_, _) => FakeAlTool.Results(
            (50001, "OnRun", "failed", "Setup failed: no number series\r\nAL Callstack:\r\nx\r\n"),
            (50002, "Other", "passed", null)));
        var suite = Suite(Prepared(50001, "Alpha", true, Pending("Never")), Prepared(50002, "Beta", true, Pending("Other"), Pending("Lost")));

        var run = new AlToolTestRunner(tool.Execute).Run(suite, Options());

        Assert.Empty(run.RunnerErrors);
        var never = Method(run, 50001, "Never");
        Assert.Equal(TestOutcome.Failed, never.Outcome);
        Assert.StartsWith(TestSkipReasons.NotExecutedPrefix, never.Message);
        Assert.EndsWith("OnRun failed: Setup failed: no number series", never.Message);
        Assert.EndsWith(" The AL tool reported no result for this test.", Method(run, 50002, "Lost").Message);
    }

    [Fact]
    public void Data_driven_and_unknown_results_are_merged_by_name()
    {
        var tool = new FakeAlTool((_, _) => FakeAlTool.Results(
            (50001, "rowtest(1)", "passed", null),
            (50001, "RowTest(2)", "failed", "row 2 broke"),
            (50001, "Surprise", "passed", null)));
        var suite = Suite(Prepared(50001, "Alpha", true, Pending("RowTest")));

        var run = new AlToolTestRunner(tool.Execute).Run(suite, Options());

        var row = Method(run, 50001, "RowTest");
        Assert.Equal(TestOutcome.Failed, row.Outcome);
        Assert.Equal("row 2 broke", row.Message);
        Assert.Equal(0.5, row.DurationSeconds);
        Assert.Equal(TestOutcome.Passed, Method(run, 50001, "Surprise").Outcome);
        Assert.Empty(run.RunnerErrors);
    }

    [Fact]
    public void An_unknown_status_is_a_failure()
    {
        var tool = new FakeAlTool((_, _) => FakeAlTool.Results((50001, "T", "inconclusive", "hm")));
        var run = new AlToolTestRunner(tool.Execute).Run(Suite(Prepared(50001, "Alpha", true, Pending("T"))), Options());

        var t = Method(run, 50001, "T");
        Assert.Equal(TestOutcome.Failed, t.Outcome);
        Assert.Equal("The AL tool reported status 'inconclusive'. hm", t.Message);
    }

    public static TheoryData<string, ProcessCapture, string, int> InfrastructureFailures => new()
    {
        { "no json", FakeAlTool.Output(1, "Unhandled exception. System.Net.Http.HttpRequestException: refused"), "printed no JSON result", 2 },
        { "null data", FakeAlTool.Output(1, """{"succeeded":false,"message":"Could not connect to the server.","data":null,"errorDetails":{"code":"ConnectionFailed"}}"""), "reported no test data", 2 },
        { "no results", FakeAlTool.Output(0, FakeAlTool.Json()), "reported no test results", 2 },
        { "abnormal exit", FakeAlTool.Output(3, """{"succeeded":false,"message":"Session lost","data":{"results":[{"codeunitId":50001,"methodName":"A","status":"passed"}]},"errorDetails":{"code":"SessionLost"}}"""), "exited with 3 (SessionLost): Session lost 1 selected test(s) have no result.", 1 },
        { "timeout", new ProcessCapture(-1, "", "", true), "did not finish within the remaining", 2 },
        { "unexpected codeunit", FakeAlTool.Results((50001, "A", "passed", null), (50001, "B", "passed", null), (99999, "X", "passed", null)), "codeunit 99999, which was not requested", 0 },
    };

    [Theory]
    [MemberData(nameof(InfrastructureFailures))]
    public void Infrastructure_failures_are_runner_errors(string _, ProcessCapture capture, string expected, int failed)
    {
        var tool = new FakeAlTool((_, _) => capture);
        var run = new AlToolTestRunner(tool.Execute).Run(Suite(Prepared(50001, "Alpha", true, Pending("A"), Pending("B"))), Options());

        Assert.Contains(run.RunnerErrors, e => e.Contains(expected));
        Assert.Equal(failed, run.Result.Failed);
    }

    [Fact]
    public void A_process_that_cannot_start_is_a_runner_error()
    {
        var run = new AlToolTestRunner((_, _, _, _) => throw new BcDevEnvException("Failed to start 'dotnet': not found"))
            .Run(Suite(Prepared(50001, "Alpha", true, Pending("A"))), Options());

        Assert.Contains("Failed to start 'dotnet'", Assert.Single(run.RunnerErrors));
        Assert.Contains("Failed to start 'dotnet'", Method(run, 50001, "A").Message);
    }

    [Fact]
    public void Abnormal_exit_with_all_results_is_only_a_warning()
    {
        var tool = new FakeAlTool((_, _) => FakeAlTool.Output(2,
            """{"succeeded":false,"message":"Cleanup failed","data":{"results":[{"codeunitId":50001,"methodName":"A","status":"passed"}]}}"""));
        var run = new AlToolTestRunner(tool.Execute).Run(Suite(Prepared(50001, "Alpha", true, Pending("A"))), Options());

        Assert.Empty(run.RunnerErrors);
        Assert.Equal(1, run.Result.Passed);
    }

    [Fact]
    public void Remaining_batches_fail_once_the_app_timeout_is_used_up()
    {
        var now = new DateTime(2025, 1, 1, 0, 0, 0, DateTimeKind.Utc);
        var tool = new FakeAlTool((_, groups) =>
        {
            now = now.AddMinutes(11);
            return FakeAlTool.Results(groups.Select(g => (g.CodeunitId, "T", "passed", (string?)null)).ToArray());
        });
        var suite = Suite(Prepared(50001, "A", true, Pending("T")), Prepared(50002, "B", true, Pending("T")));

        var run = new AlToolTestRunner(tool.Execute, () => now).Run(suite, Options(batchSize: 1, timeoutMinutes: 10));

        Assert.Single(tool.Calls);
        Assert.Equal(TimeSpan.FromMinutes(10), tool.Calls[0].Timeout);
        Assert.Contains("not run, the 10-minute timeout was reached", Assert.Single(run.RunnerErrors));
        Assert.Equal(TestOutcome.Passed, Method(run, 50001, "T").Outcome);
        Assert.Equal(TestOutcome.Failed, Method(run, 50002, "T").Outcome);
    }

    [Fact]
    public void UserPassword_credentials_are_passed_in_the_environment()
    {
        var tool = new FakeAlTool((_, _) => FakeAlTool.Results((50001, "A", "passed", null)));
        new AlToolTestRunner(tool.Execute).Run(Suite(Prepared(50001, "Alpha", true, Pending("A"))),
            Options() with { Authentication = "UserPassword", UserName = "admin", Password = "secret" });

        var call = Assert.Single(tool.Calls);
        Assert.Equal("admin", call.Environment!["BC_SERVER_USERNAME"]);
        Assert.Equal("secret", call.Environment["BC_SERVER_PASSWORD"]);
        Assert.DoesNotContain("secret", call.Arguments);
    }

    [Fact]
    public void Codeunits_without_a_template_are_not_run()
    {
        var broken = new NavTestService.PreparedCodeunit(
            new NavTestService.PlannedCodeunit { LineNo = 10, CodeunitId = 50001, Name = "Alpha", Run = true, Functions = 1 },
            NavTestService.RunnerErrorResult(new NavTestService.PlannedCodeunit { CodeunitId = 50001, Name = "Alpha" }, "read failed"), false);
        var suite = Suite(broken) with { RunnerErrors = new[] { "Codeunit 50001 Alpha: could not read its prepared test methods" } };
        var tool = new FakeAlTool((_, _) => throw new InvalidOperationException("must not run"));

        var run = new AlToolTestRunner(tool.Execute).Run(suite, Options());

        Assert.Empty(tool.Calls);
        Assert.Single(run.RunnerErrors);
        Assert.Equal("RunnerError", run.Result.Codeunits.Single().Methods.Single().Name);
    }

    [Fact]
    public void Prepare_reads_every_template_without_running_anything()
    {
        var handler = new FakeRunnerHandler((action, body) => (action, body.TryGetProperty("codeunitLineNo", out var l) ? l.GetString() : null) switch
        {
            ("PrepareTests", _) => FakeRunnerHandler.Value(FakeRunnerHandler.Plan((10000, 50001, "Alpha", true, 2, 1), (20000, 50002, "Beta", false, 1, 1))),
            ("GetCodeunitResults", "10000") => FakeRunnerHandler.Value(FakeRunnerHandler.XUnit(50001, "Alpha", Pending("A"), Off("B"))),
            ("GetCodeunitResults", "20000") => FakeRunnerHandler.Value(FakeRunnerHandler.XUnit(50002, "Beta", Off("C"))),
            _ => throw new InvalidOperationException(action),
        });

        var suite = new NavTestService(handler).Prepare(new NavTestService.RunOptions { ODataBaseUrl = "http://localhost:7048/BC/ODataV4", TestType = 1 });

        Assert.Empty(suite.RunnerErrors);
        Assert.DoesNotContain(handler.Requests, r => r.Action == "RunCodeunit");
        Assert.All(suite.Codeunits, c => Assert.True(c.TemplateAvailable));
        Assert.Equal(3, suite.Codeunits.Sum(c => c.Template.Total));
    }

    [Fact]
    public void Prepare_reports_a_template_count_mismatch()
    {
        var handler = new FakeRunnerHandler((action, _) => action == "PrepareTests"
            ? FakeRunnerHandler.Value(FakeRunnerHandler.Plan((10000, 50001, "Alpha", true, 2, 0)))
            : FakeRunnerHandler.Value(FakeRunnerHandler.XUnit(50001, "Alpha", Pending("A"))));

        var suite = new NavTestService(handler).Prepare(new NavTestService.RunOptions { ODataBaseUrl = "http://localhost:7048/BC/ODataV4" });

        Assert.Contains("prepared 2 test method(s) but listed 1", Assert.Single(suite.RunnerErrors));
    }

    [Fact]
    public void Command_with_altool_executor_excludes_disabled_tests_and_writes_junit()
    {
        using var dir = new TempDir();
        dir.Write("DisabledTests/My_Test_App/My_Test_App.DisabledTest.json",
            """[{"codeunitId":50001,"codeunitName":"Alpha Tests","method":"Off","bug":"1"}]""");
        var alTool = dir.Write("altool/altool.dll", "");
        var runner = WithPrepare(FakeRunnerHandler.Plan((10000, 50001, "Alpha Tests", true, 2, 1)),
            FakeRunnerHandler.XUnit(50001, "Alpha Tests", Pending("Works"), Off("Off")));
        var tool = new FakeAlTool((_, _) => FakeAlTool.Results((50001, "Works", "passed", null)));
        var output = Path.Combine(dir.Path, "junit.xml");

        var exit = RunCommand(runner, tool, "--executor", "altool", "--altool", alTool, "--dotnet", "my-dotnet", "--dev-port", "17049",
            "--disabled-tests", Path.Combine(dir.Path, "DisabledTests"), "--app-name", "My Test App",
            "--test-type", "UnitTest", "--required-test-isolation", "Disabled", "--result-file", output);

        Assert.Equal(0, exit);
        Assert.Equal(new[] { "PrepareTests", "GetCodeunitResults", "GetStateResetSummary", "EndTestRun" }, runner.Requests.Select(r => r.Action));
        var call = Assert.Single(tool.Calls);
        Assert.Equal("my-dotnet", call.FileName);
        Assert.Equal("17049", call.Arguments[call.Arguments.ToList().IndexOf("--port") + 1]);
        Assert.Equal("Empty Company", call.Arguments[call.Arguments.ToList().IndexOf("--company") + 1]);
        Assert.Equal(new[] { "Works" }, Assert.Single(call.Groups).TestMethods);
        Assert.Equal(new[] { AlToolTestRunner.ResetMockStartedCodeunitId, 50001 }, call.AllGroups.Select(g => g.CodeunitId));
        var junit = XDocument.Load(output);
        Assert.Equal(Disabled, junit.Descendants("skipped").Single().Attribute("message")!.Value);
        Assert.Single(junit.Descendants("testcase"), t => t.Element("skipped") == null && t.Element("failure") == null);
        Assert.Equal(2, junit.Descendants("testcase").Count());
        Assert.DoesNotContain("ResetTestState", junit.ToString());
    }

    [Fact]
    public void Command_with_altool_executor_selects_the_state_reset_by_the_permissions_mock_switch()
    {
        using var dir = new TempDir();
        var alTool = dir.Write("altool.dll", "");
        var plan = FakeRunnerHandler.Plan((10000, 50001, "Alpha Tests", true, 1, 0));
        var template = FakeRunnerHandler.XUnit(50001, "Alpha Tests", Pending("A"));
        var tool = new FakeAlTool((_, _) => FakeAlTool.Results((50001, "A", "passed", null)));

        Assert.Equal(0, RunCommand(WithPrepare(plan, template), tool, "--executor", "altool", "--altool", alTool,
            "--permissions-mock", "OFF", "--result-file", Path.Combine(dir.Path, "a.xml")));
        Assert.Equal(0, RunCommand(WithPrepare(plan, template), tool, "--executor", "altool", "--altool", alTool,
            "--permissions-mock", "on", "--result-file", Path.Combine(dir.Path, "b.xml")));

        Assert.Equal(new[] { AlToolTestRunner.ResetMockStoppedCodeunitId, AlToolTestRunner.ResetMockStartedCodeunitId },
            tool.Calls.Select(c => c.AllGroups[0].CodeunitId));
    }

    [Fact]
    public void Command_with_altool_executor_selects_the_state_reset_by_the_prepared_TestPermissions()
    {
        using var dir = new TempDir();
        var alTool = dir.Write("altool.dll", "");
        var plan = JsonNode.Parse(FakeRunnerHandler.Plan((10000, 50001, "Alpha Tests", true, 1, 0)))!;
        plan["codeunits"]![0]!["testPermissions"] = "Restrictive";
        plan["codeunits"]![0]!["testPermissionsMixed"] = false;
        var template = FakeRunnerHandler.XUnit(50001, "Alpha Tests", Pending("A"));
        var tool = new FakeAlTool((_, _) => FakeAlTool.Results((50001, "A", "passed", null)));
        var output = Path.Combine(dir.Path, "on.xml");

        Assert.Equal(0, RunCommand(WithPrepare(plan.ToJsonString(), template), tool, "--executor", "altool", "--altool", alTool, "--result-file", output));
        Assert.Equal(0, RunCommand(WithPrepare(plan.ToJsonString(), template), tool, "--executor", "altool", "--altool", alTool,
            "--permissions-mock", "off", "--result-file", Path.Combine(dir.Path, "off.xml")));

        Assert.Equal(new[] { new[] { AlToolTestRunner.ResetFullAccessCodeunitId, 50001 }, new[] { AlToolTestRunner.ResetMockStoppedCodeunitId, 50001 } },
            tool.Calls.Select(c => c.AllGroups.Select(g => g.CodeunitId).ToArray()));
        var junit = XDocument.Load(output);
        Assert.Single(junit.Descendants("testcase"));
        Assert.DoesNotContain("ResetTestState", junit.ToString());
    }

    [Fact]
    public void Command_with_altool_executor_runs_the_state_probe_only_when_switched_on()
    {
        using var dir = new TempDir();
        var alTool = dir.Write("altool.dll", "");
        var plan = FakeRunnerHandler.Plan((10000, 50001, "Alpha Tests", true, 1, 0));
        var template = FakeRunnerHandler.XUnit(50001, "Alpha Tests", Pending("A"));
        var tool = new FakeAlTool((_, _) => FakeAlTool.Results((50001, "A", "passed", null)));
        var probed = Path.Combine(dir.Path, "on.xml");

        Assert.Equal(0, RunCommand(WithPrepare(plan, template), tool, "--executor", "altool", "--altool", alTool,
            "--state-probe", "ON", "--result-file", probed));
        Assert.Equal(0, RunCommand(WithPrepare(plan, template), tool, "--executor", "altool", "--altool", alTool,
            "--result-file", Path.Combine(dir.Path, "default.xml")));

        Assert.Equal(new[] { new[] { AlToolTestRunner.StateProbeCodeunitId, AlToolTestRunner.ResetMockStartedCodeunitId, 50001 },
                             new[] { AlToolTestRunner.ResetMockStartedCodeunitId, 50001 } },
            tool.Calls.Select(c => c.AllGroups.Select(g => g.CodeunitId).ToArray()));
        var junit = XDocument.Load(probed);
        Assert.Single(junit.Descendants("testcase"));
        Assert.Empty(junit.Descendants("failure"));
        Assert.DoesNotContain(AlToolTestRunner.StateProbeMethodName, junit.ToString());
    }

    [Fact]
    public void Command_with_altool_executor_fails_on_a_failed_state_reset_even_with_allow_failures()
    {
        using var dir = new TempDir();
        var alTool = dir.Write("altool.dll", "");
        var plan = FakeRunnerHandler.Plan((10000, 50001, "Alpha Tests", true, 1, 0));
        var template = FakeRunnerHandler.XUnit(50001, "Alpha Tests", Pending("A"));
        var tool = new FakeAlTool((_, _) => FakeAlTool.Results(
            (AlToolTestRunner.ResetMockStartedCodeunitId, AlToolTestRunner.ResetMethodName(1), "failed", "boom"),
            (50001, "A", "passed", null)), autoResets: false);
        var output = Path.Combine(dir.Path, "j.xml");
        var runner = WithPrepare(plan, template);

        Assert.Equal(1, RunCommand(runner, tool, "--executor", "altool", "--altool", alTool,
            "--allow-failures", "--result-file", output));
        Assert.Single(XDocument.Load(output).Descendants("testcase"));
        Assert.DoesNotContain(runner.Requests, r => r.Action == NavTestService.GetStateResetSummaryAction);
        Assert.Equal(NavTestService.EndTestRunAction, runner.Requests.Last().Action);
    }

    [Fact]
    public void Command_with_altool_executor_reads_the_state_reset_summary_and_a_missing_one_is_only_a_warning()
    {
        using var dir = new TempDir();
        var alTool = dir.Write("altool.dll", "");
        var plan = FakeRunnerHandler.Plan((10000, 50001, "Alpha Tests", true, 1, 0));
        var template = FakeRunnerHandler.XUnit(50001, "Alpha Tests", Pending("A"));
        var tool = new FakeAlTool((_, _) => FakeAlTool.Results((50001, "A", "passed", null)));
        var current = WithPrepare(plan, template,
            """{"tablePresent":true,"baselineRows":0,"resets":1,"restores":1,"removed":1,"recreated":0,"modified":0,"loginSessions":2,"loginSessionsWithArea":2}""");
        var old = WithPrepare(plan, template);

        Assert.Equal(0, RunCommand(current, tool, "--executor", "altool", "--altool", alTool, "--result-file", Path.Combine(dir.Path, "a.xml")));
        // An older app has neither GetStateResetSummary nor EndTestRun: both are only warnings.
        Assert.Equal(0, RunCommand(old, tool, "--executor", "altool", "--altool", alTool, "--result-file", Path.Combine(dir.Path, "b.xml")));

        Assert.Equal(new[] { NavTestService.PrepareAction, NavTestService.GetCodeunitResultsAction, NavTestService.GetStateResetSummaryAction,
                             NavTestService.EndTestRunAction },
            current.Requests.Select(r => r.Action));
        Assert.Equal(new[] { NavTestService.GetStateResetSummaryAction, NavTestService.EndTestRunAction }, old.Requests.TakeLast(2).Select(r => r.Action));
        Assert.Single(XDocument.Load(Path.Combine(dir.Path, "b.xml")).Descendants("testcase"));
    }

    [Fact]
    public void Command_ends_the_test_run_also_when_the_run_fails()
    {
        using var dir = new TempDir();
        var alTool = dir.Write("altool.dll", "");
        var plan = FakeRunnerHandler.Plan((10000, 50001, "Alpha Tests", true, 1, 0));
        var template = FakeRunnerHandler.XUnit(50001, "Alpha Tests", Pending("A"));
        var prepareFails = new FakeRunnerHandler((action, _) => action == NavTestService.PrepareAction
            ? FakeRunnerHandler.Error(HttpStatusCode.InternalServerError, "prepare failed")
            : FakeRunnerHandler.Value("ended"));
        var toolCrashes = WithPrepare(plan, template, "{}");
        var crash = new FakeAlTool((_, _) => throw new InvalidOperationException("the AL tool executor broke"));

        Assert.Throws<BcDevEnvException>(() => RunCommand(prepareFails, crash, "--executor", "altool", "--altool", alTool));
        Assert.Equal(new[] { NavTestService.PrepareAction, NavTestService.EndTestRunAction }, prepareFails.Requests.Select(r => r.Action));
        Assert.Equal("the AL tool executor broke",
            Assert.Throws<InvalidOperationException>(() => RunCommand(toolCrashes, crash, "--executor", "altool", "--altool", alTool)).Message);
        Assert.Equal(NavTestService.EndTestRunAction, toolCrashes.Requests.Last().Action);
    }

    [Fact]
    public void Command_with_altool_executor_fails_when_a_disabled_test_ran()
    {
        using var dir = new TempDir();
        var file = dir.Write("d.json", """[{"codeunitName":"Alpha Tests","method":"Off"}]""");
        var alTool = dir.Write("altool.dll", "");
        var runner = WithPrepare(FakeRunnerHandler.Plan((10000, 50001, "Alpha Tests", true, 2, 1)),
            FakeRunnerHandler.XUnit(50001, "Alpha Tests", Pending("Works"), Off("Off")));
        var tool = new FakeAlTool((_, _) => FakeAlTool.Results((50001, "Works", "passed", null), (50001, "Off", "passed", null)));

        Assert.Equal(1, RunCommand(runner, tool, "--executor", "altool", "--altool", alTool, "--disabled-tests", file,
            "--allow-failures", "--result-file", Path.Combine(dir.Path, "j.xml")));
    }

    [Fact]
    public void Command_with_altool_executor_gates_on_failures_and_infrastructure_errors()
    {
        using var dir = new TempDir();
        var alTool = dir.Write("altool.dll", "");
        var plan = FakeRunnerHandler.Plan((10000, 50001, "Alpha Tests", true, 1, 0));
        var template = FakeRunnerHandler.XUnit(50001, "Alpha Tests", Pending("A"));

        var failing = new FakeAlTool((_, _) => FakeAlTool.Results((50001, "A", "failed", "boom")));
        Assert.Equal(1, RunCommand(WithPrepare(plan, template), failing, "--executor", "altool", "--altool", alTool,
            "--result-file", Path.Combine(dir.Path, "a.xml")));
        Assert.Equal(0, RunCommand(WithPrepare(plan, template), failing, "--executor", "altool", "--altool", alTool,
            "--allow-failures", "--result-file", Path.Combine(dir.Path, "b.xml")));

        var broken = new FakeAlTool((_, _) => FakeAlTool.Output(1, "crash"));
        Assert.Equal(1, RunCommand(WithPrepare(plan, template), broken, "--executor", "altool", "--altool", alTool,
            "--allow-failures", "--result-file", Path.Combine(dir.Path, "c.xml")));
        Assert.True(File.Exists(Path.Combine(dir.Path, "c.xml")));
    }

    [Fact]
    public void Command_with_altool_executor_validates_its_options()
    {
        using var dir = new TempDir();
        var alTool = dir.Write("altool.dll", "");
        var unused = new FakeRunnerHandler((_, _) => throw new InvalidOperationException("must not be called"));
        var tool = new FakeAlTool((_, _) => throw new InvalidOperationException("must not run"));

        Assert.Throws<BcDevEnvException>(() => RunCommand(unused, tool, "--executor", "altool"));
        Assert.Throws<BcDevEnvException>(() => RunCommand(unused, tool, "--executor", "altool", "--altool", Path.Combine(dir.Path, "missing.dll")));
        Assert.Throws<BcDevEnvException>(() => RunCommand(unused, tool, "--executor", "altool", "--altool", alTool, "--protocol", "run-all"));
        Assert.Throws<BcDevEnvException>(() => RunCommand(unused, tool, "--executor", "altool", "--altool", alTool, "--dev-port", "0"));
        Assert.Throws<BcDevEnvException>(() => RunCommand(unused, tool, "--executor", "altool", "--altool", alTool, "--permissions-mock", "yes"));
        Assert.Throws<BcDevEnvException>(() => RunCommand(unused, tool, "--executor", "altool", "--altool", alTool, "--state-probe", "yes"));
        Assert.Throws<BcDevEnvException>(() => RunCommand(unused, tool, "--executor", "altool", "--altool", alTool, "--altool-batch-size", "51"));
        Assert.Throws<BcDevEnvException>(() => RunCommand(unused, tool, "--executor", "vstest"));
        Assert.Equal(AlToolTestRunner.MaxBatchSize, RunTestsCommand.ParseBatchSize("50"));
        Assert.Equal(AlToolTestRunner.DefaultBatchSize, RunTestsCommand.ParseBatchSize(null));
    }

    [Theory]
    [InlineData(null, "odata")]
    [InlineData("", "odata")]
    [InlineData("OData", "odata")]
    [InlineData(" ALTOOL ", "altool")]
    public void Executor_names(string? value, string expected) => Assert.Equal(expected, RunTestsCommand.ParseExecutor(value));

    [Fact]
    public void AlTool_options_default_to_the_development_endpoint_of_the_instance()
    {
        using var dir = new TempDir();
        var alTool = dir.Write("altool.dll", "");
        var options = RunTestsCommand.BuildAlToolOptions(
            ParsedArgs.Parse(new[] { "--altool", alTool, "--server-instance", "NAV", "--app-timeout-minutes", "30", "--altool-batch-size", "5" }, new HashSet<string>()),
            new NavTestService.RunOptions { ODataBaseUrl = "http://localhost:7048/NAV/ODataV4", Company = "CRONUS" });

        Assert.Equal("http://localhost", options.Server);
        Assert.Equal("NAV", options.ServerInstance);
        Assert.Equal(7049, options.Port);
        Assert.Equal("CRONUS", options.Company);
        Assert.Equal(5, options.BatchSize);
        Assert.Equal(TimeSpan.FromMinutes(30), options.Timeout);
        Assert.True(options.PermissionsMock);
        Assert.False(options.StateProbe);
    }

    private static int RunCommand(FakeRunnerHandler handler, FakeAlTool tool, params string[] args)
    {
        var all = new List<string> { "--odata-url", "http://localhost:7048/BC/ODataV4", "--company", "Empty Company" };
        all.AddRange(args);
        return RunTestsCommand.Run(ParsedArgs.Parse(all, new HashSet<string> { "allow-failures", "allow-empty" }),
            new NavTestService(handler), new AlToolTestRunner(tool.Execute));
    }

    // PrepareTests returns the plan, GetCodeunitResults the template, GetStateResetSummary the summary and EndTestRun
    // 'ended' (without a summary both a 404, as from an older BcDevEnv Test Runner app); RunCodeunit must not be called.
    private static FakeRunnerHandler WithPrepare(string planJson, string templateXml, string? summaryJson = null) =>
        new((action, _) => action switch
        {
            NavTestService.PrepareAction => FakeRunnerHandler.Value(planJson),
            "GetCodeunitResults" => FakeRunnerHandler.Value(templateXml),
            NavTestService.GetStateResetSummaryAction => summaryJson != null
                ? FakeRunnerHandler.Value(summaryJson)
                : FakeRunnerHandler.Error(HttpStatusCode.NotFound, "No HTTP resource was found that matches the request URI."),
            NavTestService.EndTestRunAction => summaryJson != null
                ? FakeRunnerHandler.Value("ended")
                : FakeRunnerHandler.Error(HttpStatusCode.NotFound, "No HTTP resource was found that matches the request URI."),
            _ => throw new InvalidOperationException($"Unexpected {action}"),
        });
}
