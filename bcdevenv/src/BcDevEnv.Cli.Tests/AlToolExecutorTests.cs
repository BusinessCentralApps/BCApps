using System.Text.Json;
using System.Text.Json.Nodes;
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
/// gets the test groups without the injected state resets; with <c>autoResets</c> (default) the fake
/// reports a passed OnRun and ResetTestState for every injected reset, like the AL tool would.
/// </summary>
internal sealed class FakeAlTool
{
    private readonly Func<int, IReadOnlyList<AlToolTestRunner.TestGroup>, ProcessCapture> _respond;
    private readonly bool _autoResets;

    public FakeAlTool(Func<int, IReadOnlyList<AlToolTestRunner.TestGroup>, ProcessCapture> respond, bool autoResets = true)
    {
        _respond = respond;
        _autoResets = autoResets;
    }

    public List<(string FileName, IReadOnlyList<string> Arguments, TimeSpan Timeout, IReadOnlyDictionary<string, string>? Environment,
        IReadOnlyList<AlToolTestRunner.TestGroup> Groups, string GroupsJson, IReadOnlyList<AlToolTestRunner.TestGroup> AllGroups)> Calls { get; } = new();

    public ProcessCapture Execute(string fileName, IReadOnlyList<string> arguments, TimeSpan timeout, IReadOnlyDictionary<string, string>? environment)
    {
        var file = arguments[arguments.ToList().IndexOf("--testgroups") + 1];
        var json = File.ReadAllText(file);
        var all = JsonSerializer.Deserialize<List<AlToolTestRunner.TestGroup>>(json, new JsonSerializerOptions { PropertyNameCaseInsensitive = true })!;
        var groups = all.Where(g => !AlToolTestRunner.IsStateResetCodeunit(g.CodeunitId)).ToList();
        Calls.Add((fileName, arguments, timeout, environment, groups, json, all));
        var capture = _respond(Calls.Count, groups);
        return _autoResets ? WithResetResults(capture, all.Where(g => AlToolTestRunner.IsStateResetCodeunit(g.CodeunitId))) : capture;
    }

    // Adds passed reset results in front of the reported results (when there is a result array).
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
        foreach (var reset in resets)
            foreach (var method in new[] { "OnRun", AlToolTestRunner.ResetMethodName })
                results.Insert(index++, new JsonObject
                {
                    ["codeunitId"] = reset.CodeunitId, ["methodName"] = method, ["status"] = "passed", ["output"] = "", ["durationMs"] = 5,
                });
        return capture with { StdOut = capture.StdOut[..start] + root.ToJsonString() + capture.StdOut[(end + 1)..] };
    }

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
        Assert.All(tool.Calls.SelectMany(c => c.AllGroups).Where(g => g.CodeunitId == reset), g => Assert.Empty(g.TestMethods));
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
            (reset, AlToolTestRunner.ResetMethodName, "passed", null),
            (50001, "A", "passed", null),
            (reset, "OnRun", "passed", null),
            (reset, AlToolTestRunner.ResetMethodName, "failed", "Codeunit 130301 failed.\r\nAL Callstack:\r\n\"Reset State Before Test Run\"\r\n"),
            (50002, "B", "passed", null)), autoResets: false);
        var suite = Suite(Prepared(50001, "Alpha", true, Pending("A")), Prepared(50002, "Beta", true, Pending("B")));

        var run = new AlToolTestRunner(tool.Execute).Run(suite, Options());

        var error = Assert.Single(run.RunnerErrors);
        Assert.Contains("the state reset before codeunit 50002 Beta failed", error);
        Assert.Contains($"codeunit {reset} 'ResetTestState' failed", error);
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
            (reset, AlToolTestRunner.ResetMethodName, "passed", null),
            (50001, "A", "passed", null),
            (50002, "B", "passed", null)), autoResets: false);
        var suite = Suite(Prepared(50001, "Alpha", true, Pending("A")), Prepared(50002, "Beta", true, Pending("B")));

        var run = new AlToolTestRunner(tool.Execute).Run(suite, Options());

        Assert.Contains($"reported 1 of 2 state reset(s) (codeunit {reset} ResetTestState)", Assert.Single(run.RunnerErrors));
        Assert.Equal(2, run.Result.Passed);
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
    public void A_prepared_state_reset_codeunit_is_left_out()
    {
        var tool = new FakeAlTool((_, groups) => FakeAlTool.Results(groups.Select(g => (g.CodeunitId, "T", "passed", (string?)null)).ToArray()));
        var suite = Suite(
            Prepared(AlToolTestRunner.ResetMockStoppedCodeunitId, "BcDevEnv Reset Mock Stopped", true, Pending(AlToolTestRunner.ResetMethodName)),
            Prepared(50001, "Alpha", true, Pending("T")));

        var run = new AlToolTestRunner(tool.Execute).Run(suite, Options());

        Assert.Empty(run.RunnerErrors);
        Assert.Equal(new[] { AlToolTestRunner.ResetMockStartedCodeunitId, 50001 }, Assert.Single(tool.Calls).AllGroups.Select(g => g.CodeunitId));
        Assert.Equal(50001, Assert.Single(run.Result.Codeunits).CodeunitId);
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
        Assert.Equal(new[] { "PrepareTests", "GetCodeunitResults" }, runner.Requests.Select(r => r.Action));
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
    public void Command_with_altool_executor_fails_on_a_failed_state_reset_even_with_allow_failures()
    {
        using var dir = new TempDir();
        var alTool = dir.Write("altool.dll", "");
        var plan = FakeRunnerHandler.Plan((10000, 50001, "Alpha Tests", true, 1, 0));
        var template = FakeRunnerHandler.XUnit(50001, "Alpha Tests", Pending("A"));
        var tool = new FakeAlTool((_, _) => FakeAlTool.Results(
            (AlToolTestRunner.ResetMockStartedCodeunitId, AlToolTestRunner.ResetMethodName, "failed", "boom"),
            (50001, "A", "passed", null)), autoResets: false);
        var output = Path.Combine(dir.Path, "j.xml");

        Assert.Equal(1, RunCommand(WithPrepare(plan, template), tool, "--executor", "altool", "--altool", alTool,
            "--allow-failures", "--result-file", output));
        Assert.Single(XDocument.Load(output).Descendants("testcase"));
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
        Assert.Throws<BcDevEnvException>(() => RunCommand(unused, tool, "--executor", "vstest"));
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
    }

    private static int RunCommand(FakeRunnerHandler handler, FakeAlTool tool, params string[] args)
    {
        var all = new List<string> { "--odata-url", "http://localhost:7048/BC/ODataV4", "--company", "Empty Company" };
        all.AddRange(args);
        return RunTestsCommand.Run(ParsedArgs.Parse(all, new HashSet<string> { "allow-failures", "allow-empty" }),
            new NavTestService(handler), new AlToolTestRunner(tool.Execute));
    }

    // PrepareTests returns the plan, GetCodeunitResults the template; RunCodeunit must not be called.
    private static FakeRunnerHandler WithPrepare(string planJson, string templateXml) =>
        new((action, _) => action switch
        {
            NavTestService.PrepareAction => FakeRunnerHandler.Value(planJson),
            "GetCodeunitResults" => FakeRunnerHandler.Value(templateXml),
            _ => throw new InvalidOperationException($"Unexpected {action}"),
        });
}
