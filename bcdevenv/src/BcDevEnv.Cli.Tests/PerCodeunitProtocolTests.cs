using System.Net;
using System.Text;
using System.Text.Json;
using System.Xml.Linq;
using BcDevEnv.Cli.Cli;
using BcDevEnv.Cli.Commands;
using BcDevEnv.Cli.Infra;
using BcDevEnv.Cli.Nav;
using BcDevEnv.Cli.Testing;
using Xunit;

namespace BcDevEnv.Cli.Tests;

/// <summary>Scripted stand-in for the BcDevEnvTestRunner OData actions.</summary>
internal sealed class FakeRunnerHandler : HttpMessageHandler
{
    private readonly Func<string, JsonElement, HttpResponseMessage> _respond;

    public FakeRunnerHandler(Func<string, JsonElement, HttpResponseMessage> respond) => _respond = respond;

    public List<(string Action, string Url, JsonElement Body)> Requests { get; } = new();

    public HttpResponseMessage Respond(string action, JsonElement body) => _respond(action, body);

    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        var url = request.RequestUri!.ToString();
        var path = request.RequestUri.AbsolutePath;
        var action = path[(path.LastIndexOf('_') + 1)..];
        var body = JsonDocument.Parse(request.Content!.ReadAsStringAsync(cancellationToken).Result).RootElement.Clone();
        Requests.Add((action, url, body));
        return Task.FromResult(_respond(action, body));
    }

    public static HttpResponseMessage Value(string text) => new(HttpStatusCode.OK)
    {
        Content = new StringContent(JsonSerializer.Serialize(new Dictionary<string, string> { ["value"] = text }), Encoding.UTF8, "application/json"),
    };

    public static HttpResponseMessage Error(HttpStatusCode status, string body) => new(status) { Content = new StringContent(body) };

    public static string Plan(params (int LineNo, int Id, string Name, bool Run, int Functions, int Disabled)[] codeunits) =>
        JsonSerializer.Serialize(new
        {
            testSuite = "DEFAULT",
            testRunnerId = 130450,
            functions = codeunits.Sum(c => c.Functions),
            disabledFunctions = codeunits.Sum(c => c.Disabled),
            codeunits = codeunits.Select(c => new
            {
                lineNo = c.LineNo, codeunitId = c.Id, name = c.Name, run = c.Run, functions = c.Functions, disabledFunctions = c.Disabled,
            }),
        });

    public static string XUnit(int id, string name, params (string Method, string Result, string? Reason)[] tests)
    {
        var sb = new StringBuilder();
        sb.Append("""<?xml version="1.0" encoding="utf-8"?><assemblies><assembly name="DEFAULT">""");
        sb.Append($"""<collection name="Codeunit {id} {name}" codeunitId="{id}" codeunitName="{name}" appName="My Test App" extensionId="11111111-1111-1111-1111-111111111111">""");
        foreach (var t in tests)
        {
            sb.Append($"""<test name="{name}:{t.Method}" method="{t.Method}" result="{t.Result}" time="0.5" """);
            if (t.Result == "Failure")
                sb.Append($"><failure><message>{t.Reason}</message><stack-trace></stack-trace></failure></test>");
            else if (t.Reason != null)
                sb.Append($"><reason>{t.Reason}</reason></test>");
            else
                sb.Append("/>");
        }
        sb.Append("</collection></assembly></assemblies>");
        return sb.ToString();
    }
}

public class PerCodeunitProtocolTests
{
    private const string Disabled = TestSkipReasons.DisabledByDisabledTests;
    private const string NotExecuted = TestSkipReasons.NotExecutedPrefix + " (the codeunit most likely failed before or during OnRun).";

    private static NavTestService.RunOptions Options(string? disabledJson = null) => new()
    {
        ODataBaseUrl = "http://localhost:7048/BC/ODataV4",
        Company = "Empty Company",
        ExtensionId = "11111111-1111-1111-1111-111111111111",
        TestType = 1,
        RequiredTestIsolation = 1,
        TestRunnerCodeunitId = 130451,
        DisabledTestsJson = disabledJson,
    };

    [Fact]
    public void Prepare_payload_sends_every_parameter_as_text()
    {
        using var doc = JsonDocument.Parse(NavTestService.BuildPreparePayload(Options("[]")));
        var root = doc.RootElement;

        Assert.Equal(7, root.EnumerateObject().Count());
        Assert.All(root.EnumerateObject(), p => Assert.Equal(JsonValueKind.String, p.Value.ValueKind));
        Assert.Equal("1", root.GetProperty("testType").GetString());
        Assert.Equal("1", root.GetProperty("requiredTestIsolation").GetString());
        Assert.Equal("130451", root.GetProperty("testRunnerCodeunitId").GetString());
        Assert.Equal("[]", root.GetProperty("disabledTestsJson").GetString());
        Assert.Equal("", root.GetProperty("testCodeunitFilter").GetString());
    }

    [Fact]
    public void Codeunit_payload_and_action_urls()
    {
        Assert.Equal("""{"testSuite":"DEFAULT","codeunitLineNo":"20000"}""", NavTestService.BuildCodeunitPayload(Options(), 20000));
        Assert.Equal("http://localhost:7048/BC/ODataV4/BcDevEnvTestRunner_PrepareTests?company=Empty%20Company",
            NavTestService.BuildActionUrl(Options(), NavTestService.PrepareAction));
    }

    [Fact]
    public void ParsePlan_reads_the_runner_suite_description()
    {
        var plan = NavTestService.ParsePlan(FakeRunnerHandler.Plan((10000, 50001, "Alpha Tests", true, 3, 1)));

        Assert.Equal(130450, plan.TestRunnerId);
        var cu = Assert.Single(plan.Codeunits);
        Assert.Equal(new NavTestService.PlannedCodeunit { LineNo = 10000, CodeunitId = 50001, Name = "Alpha Tests", Run = true, Functions = 3, DisabledFunctions = 1 }, cu);
        Assert.Throws<BcDevEnvException>(() => NavTestService.ParsePlan("<html/>"));
    }

    [Fact]
    public void ParsePlan_reads_the_TestPermissions_of_each_codeunit()
    {
        var plan = NavTestService.ParsePlan("""
            {"testSuite":"DEFAULT","testRunnerId":130450,"functions":3,"disabledFunctions":0,"codeunits":[
              {"lineNo":10000,"codeunitId":50001,"name":"A","run":true,"functions":1,"disabledFunctions":0,"testPermissions":"NonRestrictive","testPermissionsMixed":true},
              {"lineNo":20000,"codeunitId":50002,"name":"B","run":true,"functions":1,"disabledFunctions":0,"testPermissions":"Disabled","testPermissionsMixed":false},
              {"lineNo":30000,"codeunitId":50003,"name":"C","run":true,"functions":1,"disabledFunctions":0}]}
            """);

        Assert.Equal(new (string?, bool)[] { ("NonRestrictive", true), ("Disabled", false), (null, false) },
            plan.Codeunits.Select(c => (c.TestPermissions, c.TestPermissionsMixed)));
    }

    [Fact]
    public void Runs_enabled_codeunits_and_only_reads_results_of_fully_disabled_ones()
    {
        var handler = new FakeRunnerHandler((action, body) => (action, body.GetProperty("codeunitLineNo").GetString()) switch
        {
            ("RunCodeunit", "10000") => FakeRunnerHandler.Value(FakeRunnerHandler.XUnit(50001, "Alpha Tests",
                ("Works", "Success", null), ("Off", "Skipped", Disabled))),
            ("GetCodeunitResults", "20000") => FakeRunnerHandler.Value(FakeRunnerHandler.XUnit(50002, "Beta Tests",
                ("All1", "Skipped", Disabled), ("All2", "Skipped", Disabled))),
            _ => throw new InvalidOperationException($"Unexpected {action}"),
        });
        var prepareHandler = WithPrepare(handler, FakeRunnerHandler.Plan(
            (10000, 50001, "Alpha Tests", true, 2, 1), (20000, 50002, "Beta Tests", false, 2, 2)));

        var run = new NavTestService(prepareHandler).RunPerCodeunit(Options("[]"));

        Assert.Empty(run.RunnerErrors);
        Assert.Equal(new[] { "PrepareTests", "RunCodeunit", "GetCodeunitResults" }, prepareHandler.Requests.Select(r => r.Action));
        Assert.Equal(4, run.Result.Total);
        Assert.Equal(1, run.Result.Passed);
        Assert.Equal(3, run.Result.Skipped);
        Assert.Equal("Alpha Tests", run.Result.Codeunits[0].CodeunitName);
        Assert.Equal(Disabled, run.Result.Codeunits[1].Methods[0].Message);
    }

    [Fact]
    public void Failed_codeunit_call_is_recovered_and_reported_as_runner_error()
    {
        var handler = WithPrepare(new FakeRunnerHandler((action, _) => action switch
        {
            "RunCodeunit" => FakeRunnerHandler.Error(HttpStatusCode.InternalServerError, "The server crashed"),
            "GetCodeunitResults" => FakeRunnerHandler.Value(FakeRunnerHandler.XUnit(50001, "Alpha Tests",
                ("First", "Success", null), ("Second", "Failure", NotExecuted))),
            _ => throw new InvalidOperationException(action),
        }), FakeRunnerHandler.Plan((10000, 50001, "Alpha Tests", true, 2, 0)));

        var run = new NavTestService(handler).RunPerCodeunit(Options());

        Assert.Contains("runner call failed", Assert.Single(run.RunnerErrors));
        Assert.Equal(1, run.Result.Passed);
        var failed = run.Result.Codeunits.Single().Methods.Single(m => m.Outcome == TestOutcome.Failed);
        Assert.Contains("Runner call failed", failed.Message);
        Assert.Contains("The server crashed", failed.Message);
    }

    [Fact]
    public void Unrecoverable_codeunit_becomes_a_failed_runner_error_test()
    {
        var handler = WithPrepare(new FakeRunnerHandler((_, _) => FakeRunnerHandler.Error(HttpStatusCode.BadGateway, "down")),
            FakeRunnerHandler.Plan((10000, 50001, "Alpha Tests", true, 1, 0)));

        var run = new NavTestService(handler).RunPerCodeunit(Options());

        var method = Assert.Single(run.Result.Codeunits.Single().Methods);
        Assert.Equal("RunnerError", method.Name);
        Assert.Equal(TestOutcome.Failed, method.Outcome);
        Assert.NotEmpty(run.RunnerErrors);
    }

    [Fact]
    public void Result_count_mismatch_is_a_runner_error()
    {
        var handler = WithPrepare(new FakeRunnerHandler((_, _) => FakeRunnerHandler.Value(
                FakeRunnerHandler.XUnit(50001, "Alpha Tests", ("Only", "Success", null)))),
            FakeRunnerHandler.Plan((10000, 50001, "Alpha Tests", true, 2, 0)));

        var run = new NavTestService(handler).RunPerCodeunit(Options());

        Assert.Contains(run.RunnerErrors, e => e.Contains("prepared 2 test method(s) but reported 1"));
    }

    [Fact]
    public void Command_excludes_disabled_tests_and_passes_with_skips()
    {
        using var dir = new TempDir();
        dir.Write("DisabledTests/My_Test_App/My_Test_App.DisabledTest.json",
            """[{"codeunitId":50001,"codeunitName":"Alpha Tests","method":"Off","bug":"1"}]""");
        var handler = WithPrepare(new FakeRunnerHandler((_, _) => FakeRunnerHandler.Value(FakeRunnerHandler.XUnit(50001, "Alpha Tests",
                ("Works", "Success", null), ("Off", "Skipped", Disabled)))),
            FakeRunnerHandler.Plan((10000, 50001, "Alpha Tests", true, 2, 1)));
        var output = Path.Combine(dir.Path, "junit.xml");

        var exit = RunCommand(handler, "--disabled-tests", Path.Combine(dir.Path, "DisabledTests"), "--app-name", "My Test App",
            "--test-type", "UnitTest", "--required-test-isolation", "Disabled", "--test-runner-codeunit-id", "130451",
            "--result-file", output);

        Assert.Equal(0, exit);
        var prepare = handler.Requests.First().Body;
        Assert.Equal("1", prepare.GetProperty("testType").GetString());
        Assert.Equal("1", prepare.GetProperty("requiredTestIsolation").GetString());
        using (var sent = JsonDocument.Parse(prepare.GetProperty("disabledTestsJson").GetString()!))
            Assert.Equal("Off", sent.RootElement[0].GetProperty("methods")[0].GetString());
        var skipped = XDocument.Load(output).Descendants("skipped").Single();
        Assert.Equal(Disabled, skipped.Attribute("message")!.Value);
    }

    [Fact]
    public void Command_fails_when_a_disabled_test_ran_even_with_allow_failures()
    {
        using var dir = new TempDir();
        var file = dir.Write("d.json", """[{"codeunitName":"Alpha Tests","method":"Off"}]""");
        var handler = WithPrepare(new FakeRunnerHandler((_, _) => FakeRunnerHandler.Value(FakeRunnerHandler.XUnit(50001, "Alpha Tests",
                ("Off", "Success", null)))),
            FakeRunnerHandler.Plan((10000, 50001, "Alpha Tests", true, 1, 0)));

        Assert.Equal(1, RunCommand(handler, "--disabled-tests", file, "--allow-failures", "--result-file", Path.Combine(dir.Path, "j.xml")));
    }

    [Fact]
    public void Command_fails_on_runner_errors_even_with_allow_failures()
    {
        using var dir = new TempDir();
        var handler = WithPrepare(new FakeRunnerHandler((action, _) => action == "RunCodeunit"
                ? FakeRunnerHandler.Error(HttpStatusCode.InternalServerError, "x")
                : FakeRunnerHandler.Value(FakeRunnerHandler.XUnit(50001, "Alpha Tests", ("A", "Success", null)))),
            FakeRunnerHandler.Plan((10000, 50001, "Alpha Tests", true, 1, 0)));

        Assert.Equal(1, RunCommand(handler, "--protocol", "per-codeunit", "--allow-failures", "--result-file", Path.Combine(dir.Path, "j.xml")));
        Assert.True(File.Exists(Path.Combine(dir.Path, "j.xml")));
    }

    [Fact]
    public void Command_keeps_strict_failure_propagation()
    {
        using var dir = new TempDir();
        var handler = WithPrepare(new FakeRunnerHandler((_, _) => FakeRunnerHandler.Value(FakeRunnerHandler.XUnit(50001, "Alpha Tests",
                ("A", "Failure", "boom")))),
            FakeRunnerHandler.Plan((10000, 50001, "Alpha Tests", true, 1, 0)));

        Assert.Equal(1, RunCommand(handler, "--test-type", "1", "--result-file", Path.Combine(dir.Path, "j.xml")));
    }

    [Fact]
    public void Disabled_tests_require_the_per_codeunit_protocol()
    {
        using var dir = new TempDir();
        var file = dir.Write("d.json", "[]");
        Assert.Throws<BcDevEnvException>(() =>
            RunCommand(new FakeRunnerHandler((_, _) => throw new InvalidOperationException()), "--disabled-tests", file, "--protocol", "run-all"));
    }

    [Theory]
    [InlineData(new string[0], false)]
    [InlineData(new[] { "--test-type", "UnitTest" }, true)]
    [InlineData(new[] { "--disabled-tests", "x" }, true)]
    [InlineData(new[] { "--disabled-tests", "x", "--protocol", "RUN-ALL" }, false)]
    [InlineData(new[] { "--protocol", "per-codeunit" }, true)]
    public void Protocol_selection(string[] args, bool perCodeunit)
    {
        Assert.Equal(perCodeunit, RunTestsCommand.UsePerCodeunitProtocol(ParsedArgs.Parse(args, new HashSet<string>())));
    }

    [Theory]
    [InlineData(null, 0)]
    [InlineData("UnitTest", 1)]
    [InlineData("integrationtest", 2)]
    [InlineData("3", 3)]
    [InlineData("AITest", 4)]
    public void TestType_names_and_ordinals(string? value, int expected) => Assert.Equal(expected, RunTestsCommand.ParseTestType(value));

    [Theory]
    [InlineData("None", 0)]
    [InlineData("Disabled", 1)]
    [InlineData("codeunit", 2)]
    [InlineData("3", 3)]
    public void RequiredTestIsolation_names_and_ordinals(string value, int expected) =>
        Assert.Equal(expected, RunTestsCommand.ParseRequiredTestIsolation(value));

    [Theory]
    [InlineData("Smoke")]
    [InlineData("9")]
    [InlineData("-1")]
    public void Invalid_option_values_are_rejected(string value)
    {
        Assert.Throws<BcDevEnvException>(() => RunTestsCommand.ParseTestType(value));
        Assert.Throws<BcDevEnvException>(() => RunTestsCommand.ParseRequiredTestIsolation(value));
    }

    private static int RunCommand(FakeRunnerHandler handler, params string[] args)
    {
        var all = new List<string> { "--odata-url", "http://localhost:7048/BC/ODataV4", "--company", "Empty Company" };
        all.AddRange(args);
        return RunTestsCommand.Run(ParsedArgs.Parse(all, new HashSet<string> { "allow-failures", "allow-empty" }), new NavTestService(handler));
    }

    // Answers PrepareTests with the given plan and delegates everything else.
    private static FakeRunnerHandler WithPrepare(FakeRunnerHandler inner, string planJson) =>
        new((action, body) => action == NavTestService.PrepareAction
            ? FakeRunnerHandler.Value(planJson)
            : inner.Respond(action, body));
}
