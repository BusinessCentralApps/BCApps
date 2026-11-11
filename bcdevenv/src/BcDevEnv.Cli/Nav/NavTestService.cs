using System.Net.Http.Headers;
using System.Text;
using BcDevEnv.Cli.Infra;
using BcDevEnv.Cli.Testing;

namespace BcDevEnv.Cli.Nav;

/// <summary>
/// Runs the Business Central test suite against a <b>running</b> server instance by invoking a
/// test-runner web service over the NST's OData v4 client-services endpoint and returning the xUnit
/// result document. This keeps bcdevenv dependency-light: it uses only <see cref="HttpClient"/> from
/// the BCL (no client-automation DLL, no extra NuGet package), consistent with the tool's
/// "drive BC directly" design.
///
/// <para>The runner endpoint is a codeunit published as a web service by the test toolkit the
/// environment has installed (via <c>install-app</c>). Like <c>build-image</c>/<c>start</c>, the live
/// path is only meaningful against a real running NST and is not exercised by the hermetic unit
/// tests; the URL-shaping and result handling <b>are</b> tested. Where a live NST is not reachable,
/// <c>run-tests --from-xml</c> / <c>--results-dir</c> convert result documents produced elsewhere.
/// Every path funnels through <see cref="Testing.XUnitResultParser"/>.</para>
/// </summary>
public sealed class NavTestService
{
    /// <summary>Connection + selection options for a live test run.</summary>
    public sealed record RunOptions
    {
        /// <summary>OData base, e.g. <c>http://localhost:7048/BC/ODataV4</c>.</summary>
        public required string ODataBaseUrl { get; init; }

        /// <summary>Published web-service (codeunit) name exposing the runner action.</summary>
        public string ServiceName { get; init; } = "BcDevEnvTestRunner";

        /// <summary>Unbound action that runs the suite and returns xUnit XML.</summary>
        public string RunAction { get; init; } = "RunAll";

        public string? Company { get; init; }
        public string? ExtensionId { get; init; }
        public string? TestCodeunitFilter { get; init; }
        public string? TestSuite { get; init; } = "DEFAULT";

        // Authentication (Windows uses the caller's identity; UserPassword sends Basic auth).
        public string Authentication { get; init; } = "Windows";
        public string? UserName { get; init; }
        public string? Password { get; init; }

        /// <summary>HTTP timeout for EACH runner call (per codeunit in the per-codeunit protocol).</summary>
        public int TimeoutMinutes { get; init; } = 30;

        // Per-codeunit protocol selection (see the BcDevEnvTestRunner AL codeunit).
        /// <summary>CodeUnit Metadata TestType: 0 = no categorization filter, 1 = UnitTest, 2 = IntegrationTest, 3 = Uncategorized.</summary>
        public int TestType { get; init; }

        /// <summary>RequiredTestIsolation: 0 = None|Codeunit, 1 = Disabled, 2 = Codeunit, 3 = Function (only with TestType &gt; 0).</summary>
        public int RequiredTestIsolation { get; init; }

        /// <summary>Test runner codeunit for the suite (e.g. 130450 / 130451); 0 = suite default.</summary>
        public int TestRunnerCodeunitId { get; init; }

        /// <summary>Runner payload from <see cref="Testing.DisabledTestCatalog.ToRunnerJson"/>; null/empty = none.</summary>
        public string? DisabledTestsJson { get; init; }
    }

    /// <summary>One codeunit line of a prepared suite, as returned by PrepareTests.</summary>
    public sealed record PlannedCodeunit
    {
        public int LineNo { get; init; }
        public int CodeunitId { get; init; }
        public string Name { get; init; } = "";
        public bool Run { get; init; }
        public int Functions { get; init; }
        public int DisabledFunctions { get; init; }

        /// <summary>
        /// TestPermissions (Disabled, Restrictive, NonRestrictive) of the codeunit's first selected method, as the
        /// Test Runner receives it; null when the BcDevEnv Test Runner app does not report it (older versions).
        /// </summary>
        public string? TestPermissions { get; init; }

        /// <summary>The selected methods have different TestPermissions (<see cref="TestPermissions"/> is the first one's).</summary>
        public bool TestPermissionsMixed { get; init; }
    }

    /// <summary>The suite PrepareTests built (disabled tests already applied).</summary>
    public sealed record TestSuitePlan
    {
        public string TestSuite { get; init; } = "";
        public int TestRunnerId { get; init; }
        public int Functions { get; init; }
        public int DisabledFunctions { get; init; }
        public List<PlannedCodeunit> Codeunits { get; init; } = new();
    }

    /// <summary>Result of a per-codeunit run: the plan, the merged results, and infrastructure errors.</summary>
    public sealed record PerCodeunitRun(TestSuitePlan Plan, TestRunResult Result, IReadOnlyList<string> RunnerErrors);

    /// <summary>
    /// A prepared codeunit line with its result template, read with GetCodeunitResults before anything
    /// runs: disabled methods are already "Disabled by DisabledTests" skips and every selected method
    /// is a "selected but not executed" failure until an executor reports its outcome.
    /// <see cref="TemplateAvailable"/> is false when the template could not be read; the template is
    /// then a single RunnerError failure and the codeunit must not be run.
    /// </summary>
    public sealed record PreparedCodeunit(PlannedCodeunit Codeunit, TestRunResult Template, bool TemplateAvailable);

    /// <summary>A suite prepared for an external executor (see <see cref="Prepare"/>).</summary>
    public sealed record PreparedSuite(TestSuitePlan Plan, IReadOnlyList<PreparedCodeunit> Codeunits, IReadOnlyList<string> RunnerErrors);

    public const string PrepareAction = "PrepareTests";
    public const string RunCodeunitAction = "RunCodeunit";
    public const string GetCodeunitResultsAction = "GetCodeunitResults";
    public const string GetStateResetSummaryAction = "GetStateResetSummary";
    public const string EndTestRunAction = "EndTestRun";

    /// <summary>
    /// What the AL tool executor's state resets did since the last PrepareTests (GetStateResetSummary):
    /// <see cref="Resets"/> committed resets, <see cref="Restores"/> of them changed "Application Area Setup"
    /// (rows <see cref="Removed"/>, <see cref="Recreated"/>, <see cref="Modified"/>) back to its baseline of
    /// <see cref="BaselineRows"/> rows (-1: no baseline; <see cref="TablePresent"/> false: no such table).
    /// <see cref="LoginSessions"/> client sessions got ApplicationArea('') at login, <see cref="LoginSessionsWithArea"/>
    /// of them had an application area set at login (both null for a runner app without the login hook).
    /// </summary>
    public sealed record StateResetSummary
    {
        public bool TablePresent { get; init; }
        public int BaselineRows { get; init; } = -1;
        public int Resets { get; init; }
        public int Restores { get; init; }
        public int Removed { get; init; }
        public int Recreated { get; init; }
        public int Modified { get; init; }
        public int? LoginSessions { get; init; }
        public int? LoginSessionsWithArea { get; init; }
    }

    private readonly HttpMessageHandler? _handler;

    /// <summary>Default constructor uses a real HTTP stack. Tests inject a handler.</summary>
    public NavTestService(HttpMessageHandler? handler = null) => _handler = handler;

    /// <summary>
    /// Builds the OData v4 URL that invokes the runner action. A codeunit published as a web service
    /// exposes its procedures as OData v4 UNBOUND actions named <c>{ServiceName}_{Procedure}</c>,
    /// invoked at the service root; the company is selected with a <c>?company=</c> query option
    /// (a <c>Company('x')/</c> path segment is for bound resources and 404s here).
    /// </summary>
    public static string BuildRunnerUrl(RunOptions o) => BuildActionUrl(o, o.RunAction);

    /// <summary>URL of an arbitrary runner action (<c>{base}/{ServiceName}_{action}[?company=]</c>).</summary>
    public static string BuildActionUrl(RunOptions o, string action)
    {
        var baseUrl = o.ODataBaseUrl.TrimEnd('/');
        var url = $"{baseUrl}/{o.ServiceName}_{action}";
        if (!string.IsNullOrWhiteSpace(o.Company))
            url += $"?company={Uri.EscapeDataString(o.Company!)}";
        return url;
    }

    /// <summary>
    /// Invokes the runner and returns the raw xUnit XML body. Best-effort; only meaningful against a
    /// live NST. Throws <see cref="BcDevEnvException"/> with an actionable message on any transport
    /// or protocol failure.
    /// </summary>
    public string Run(RunOptions options)
    {
        using var client = CreateClient(options);
        return Post(client, BuildRunnerUrl(options), BuildRunAllPayload(options), options);
    }

    /// <summary>
    /// Per-codeunit protocol: PrepareTests builds the suite once (test type / isolation / runner
    /// selection and the disabled tests are applied before anything runs), then each codeunit line
    /// is run in its own call. Fully disabled codeunits are not run; their skip records are fetched
    /// with GetCodeunitResults. A failed call only loses that codeunit: its committed per-test
    /// results are recovered and the error is recorded so the caller can fail the run.
    /// </summary>
    public PerCodeunitRun RunPerCodeunit(RunOptions options)
    {
        using var client = CreateClient(options);

        var plan = PrepareSuite(client, options);

        var result = new TestRunResult();
        var errors = new List<string>();
        var index = 0;
        foreach (var codeunit in plan.Codeunits)
        {
            index++;
            var label = $"[{index}/{plan.Codeunits.Count}] Codeunit {codeunit.CodeunitId} {codeunit.Name}";
            var payload = BuildCodeunitPayload(options, codeunit.LineNo);
            TestRunResult codeunitResult;
            if (!codeunit.Run)
            {
                codeunitResult = XUnitResultParser.Parse(
                    Post(client, BuildActionUrl(options, GetCodeunitResultsAction), payload, options));
            }
            else
            {
                try
                {
                    codeunitResult = XUnitResultParser.Parse(
                        Post(client, BuildActionUrl(options, RunCodeunitAction), payload, options));
                }
                catch (BcDevEnvException ex)
                {
                    var error = $"{label}: runner call failed: {ex.Message}";
                    Log.Error(error);
                    errors.Add(error);
                    codeunitResult = RecoverCodeunitResults(client, options, codeunit, ex.Message);
                }
            }

            result.Codeunits.AddRange(codeunitResult.Codeunits);
            var status = codeunit.Run ? "" : " (disabled)";
            Log.Info($"{label}{status}: {codeunitResult.Passed} passed, {codeunitResult.Failed} failed, " +
                     $"{codeunitResult.Skipped} skipped ({codeunitResult.DurationSeconds:0.0}s)");
        }

        if (result.Total != plan.Functions)
        {
            var error = $"The runner prepared {plan.Functions} test method(s) but reported {result.Total} result(s).";
            Log.Error(error);
            errors.Add(error);
        }

        return new PerCodeunitRun(plan, result, errors);
    }

    /// <summary>
    /// Prepares the suite for an external executor (the AL tool): PrepareTests applies the test type /
    /// isolation selection and the disabled tests exactly as for <see cref="RunPerCodeunit"/>, then the
    /// result template of every codeunit line is read with GetCodeunitResults. Nothing is executed.
    /// </summary>
    public PreparedSuite Prepare(RunOptions options)
    {
        using var client = CreateClient(options);
        var plan = PrepareSuite(client, options);

        var codeunits = new List<PreparedCodeunit>();
        var errors = new List<string>();
        foreach (var codeunit in plan.Codeunits)
        {
            try
            {
                var template = XUnitResultParser.Parse(Post(client, BuildActionUrl(options, GetCodeunitResultsAction),
                    BuildCodeunitPayload(options, codeunit.LineNo), options));
                codeunits.Add(new PreparedCodeunit(codeunit, template, true));
            }
            catch (BcDevEnvException ex)
            {
                var error = $"Codeunit {codeunit.CodeunitId} {codeunit.Name}: could not read its prepared test methods: {ex.Message}";
                Log.Error(error);
                errors.Add(error);
                codeunits.Add(new PreparedCodeunit(codeunit,
                    RunnerErrorResult(codeunit, $"Reading the prepared test methods failed: {ex.Message}"), false));
            }
        }

        var templateMethods = codeunits.Where(c => c.TemplateAvailable).Sum(c => c.Template.Total);
        if (errors.Count == 0 && templateMethods != plan.Functions)
        {
            var error = $"The runner prepared {plan.Functions} test method(s) but listed {templateMethods}.";
            Log.Error(error);
            errors.Add(error);
        }
        return new PreparedSuite(plan, codeunits, errors);
    }

    private TestSuitePlan PrepareSuite(HttpClient client, RunOptions options)
    {
        var plan = ParsePlan(Post(client, BuildActionUrl(options, PrepareAction), BuildPreparePayload(options), options));
        Log.Info($"Prepared test suite '{plan.TestSuite}' (runner {plan.TestRunnerId}): {plan.Codeunits.Count} codeunit(s), " +
                 $"{plan.Functions} test method(s), {plan.DisabledFunctions} disabled before execution.");
        return plan;
    }

    /// <summary>
    /// Reads what the AL tool executor's state resets did since the last PrepareTests (GetStateResetSummary of the
    /// BcDevEnv Test Runner). Throws <see cref="BcDevEnvException"/> when the action fails or is missing (an older app).
    /// </summary>
    public StateResetSummary GetStateResetSummary(RunOptions options)
    {
        using var client = CreateClient(options);
        return ParseStateResetSummary(Post(client, BuildActionUrl(options, GetStateResetSummaryAction), "{}", options));
    }

    /// <summary>
    /// Ends the test run that PrepareTests started (EndTestRun of the BcDevEnv Test Runner): client sessions that
    /// open a company keep the application area they get at login again. Returns the runner's status ('ended' or
    /// 'not active'). Throws <see cref="BcDevEnvException"/> when the action fails or is missing (an older app).
    /// </summary>
    public string EndTestRun(RunOptions options)
    {
        using var client = CreateClient(options);
        return Post(client, BuildActionUrl(options, EndTestRunAction), "{}", options);
    }

    /// <summary>Parses the JSON returned by GetStateResetSummary.</summary>
    public static StateResetSummary ParseStateResetSummary(string json)
    {
        try
        {
            return System.Text.Json.JsonSerializer.Deserialize<StateResetSummary>(json,
                       new System.Text.Json.JsonSerializerOptions { PropertyNameCaseInsensitive = true })
                   ?? throw new BcDevEnvException("GetStateResetSummary returned no summary.");
        }
        catch (System.Text.Json.JsonException ex)
        {
            throw new BcDevEnvException($"Could not parse the GetStateResetSummary response: {ex.Message}\n{json}", ex);
        }
    }

    /// <summary>A one-method failed result standing for a codeunit whose results are unavailable.</summary>
    public static TestRunResult RunnerErrorResult(PlannedCodeunit codeunit, string message)
    {
        var result = new TestRunResult();
        var cu = new TestCodeunitResult
        {
            Name = $"Codeunit {codeunit.CodeunitId} {codeunit.Name}",
            CodeunitId = codeunit.CodeunitId,
            CodeunitName = codeunit.Name,
        };
        cu.Methods.Add(new TestMethodResult { Name = "RunnerError", Outcome = TestOutcome.Failed, Message = message });
        result.Codeunits.Add(cu);
        return result;
    }

    /// <summary>Parses the JSON suite description returned by PrepareTests.</summary>
    public static TestSuitePlan ParsePlan(string json)
    {
        try
        {
            return System.Text.Json.JsonSerializer.Deserialize<TestSuitePlan>(json,
                       new System.Text.Json.JsonSerializerOptions { PropertyNameCaseInsensitive = true })
                   ?? throw new BcDevEnvException("PrepareTests returned an empty suite description.");
        }
        catch (System.Text.Json.JsonException ex)
        {
            throw new BcDevEnvException($"Could not parse the PrepareTests response: {ex.Message}\n{json}", ex);
        }
    }

    // After a failed RunCodeunit call, read what the server committed for that codeunit. Methods that
    // never produced a result are already failures ("selected but not executed"); attach the
    // transport error to them. When even that fails, report the whole codeunit as one failure.
    private TestRunResult RecoverCodeunitResults(HttpClient client, RunOptions options, PlannedCodeunit codeunit, string runError)
    {
        try
        {
            var recovered = XUnitResultParser.Parse(Post(client, BuildActionUrl(options, GetCodeunitResultsAction),
                BuildCodeunitPayload(options, codeunit.LineNo), options));
            foreach (var cu in recovered.Codeunits)
            {
                for (var i = 0; i < cu.Methods.Count; i++)
                {
                    var m = cu.Methods[i];
                    if (m.Outcome != TestOutcome.Failed ||
                        m.Message?.StartsWith(TestSkipReasons.NotExecutedPrefix, StringComparison.Ordinal) != true) continue;
                    cu.Methods[i] = new TestMethodResult
                    {
                        Name = m.Name,
                        Outcome = m.Outcome,
                        DurationSeconds = m.DurationSeconds,
                        Message = $"{m.Message} Runner call failed: {runError}".Trim(),
                        StackTrace = m.StackTrace,
                    };
                }
            }
            return recovered;
        }
        catch (BcDevEnvException ex)
        {
            Log.Error($"Could not recover results for codeunit {codeunit.CodeunitId}: {ex.Message}");
            return RunnerErrorResult(codeunit, $"Runner call failed: {runError} Result recovery failed: {ex.Message}");
        }
    }

    private string Post(HttpClient client, string url, string payload, RunOptions options)
    {
        Log.Verbose($"POST {url}");
        using var content = new StringContent(payload, Encoding.UTF8, "application/json");

        HttpResponseMessage response;
        try
        {
            response = client.PostAsync(url, content).GetAwaiter().GetResult();
        }
        catch (Exception ex)
        {
            throw new BcDevEnvException(
                $"Could not reach the test runner at '{url}'. Ensure the environment is running and the " +
                $"test toolkit exposes the '{options.ServiceName}' web service. ({ex.Message})", ex);
        }

        using (response)
        {
            var body = response.Content.ReadAsStringAsync().GetAwaiter().GetResult();
            if (!response.IsSuccessStatusCode)
                throw new BcDevEnvException(
                    $"Test runner returned HTTP {(int)response.StatusCode} ({response.ReasonPhrase}) for '{url}'. Body:\n{body}");
            return ExtractXml(body);
        }
    }

    private HttpClient CreateClient(RunOptions options)
    {
        var client = _handler != null ? new HttpClient(_handler, disposeHandler: false) : NewClient(options);
        client.Timeout = TimeSpan.FromMinutes(Math.Max(1, options.TimeoutMinutes));
        return client;
    }

    /// <summary>
    /// The runner action returns either xUnit XML directly, or a JSON envelope wrapping it in a
    /// "value" property (the OData action-result shape). This normalises both to the XML string.
    /// </summary>
    public static string ExtractXml(string body)
    {
        var trimmed = (body ?? string.Empty).TrimStart('\uFEFF', ' ', '\t', '\r', '\n');
        if (trimmed.StartsWith("<", StringComparison.Ordinal))
            return trimmed;

        // OData wraps a text-returning action as {"@odata.context":"...","value":"<assemblies>..."}.
        try
        {
            using var doc = System.Text.Json.JsonDocument.Parse(trimmed);
            if (doc.RootElement.TryGetProperty("value", out var value) &&
                value.ValueKind == System.Text.Json.JsonValueKind.String)
                return value.GetString() ?? string.Empty;
        }
        catch (System.Text.Json.JsonException)
        {
            // Not JSON; fall through and let the parser report a clear error.
        }
        return trimmed;
    }

    /// <summary>Payload of the legacy RunAll action.</summary>
    public static string BuildRunAllPayload(RunOptions o)
    {
        // A BC codeunit OData action requires ALL of its declared parameters, so always include the
        // three (empty strings when unset); the runner treats empty extensionId/filter as "run all".
        return "{" +
               $"\"testSuite\":{J(o.TestSuite)}," +
               $"\"extensionId\":{J(o.ExtensionId)}," +
               $"\"testCodeunitFilter\":{J(o.TestCodeunitFilter)}" +
               "}";
    }

    /// <summary>Payload of PrepareTests (all parameters are Text on the AL side).</summary>
    public static string BuildPreparePayload(RunOptions o)
    {
        return "{" +
               $"\"testSuite\":{J(o.TestSuite)}," +
               $"\"extensionId\":{J(o.ExtensionId)}," +
               $"\"testCodeunitFilter\":{J(o.TestCodeunitFilter)}," +
               $"\"testType\":{J(o.TestType.ToString(System.Globalization.CultureInfo.InvariantCulture))}," +
               $"\"requiredTestIsolation\":{J(o.RequiredTestIsolation.ToString(System.Globalization.CultureInfo.InvariantCulture))}," +
               $"\"testRunnerCodeunitId\":{J(o.TestRunnerCodeunitId.ToString(System.Globalization.CultureInfo.InvariantCulture))}," +
               $"\"disabledTestsJson\":{J(o.DisabledTestsJson)}" +
               "}";
    }

    /// <summary>Payload of RunCodeunit / GetCodeunitResults.</summary>
    public static string BuildCodeunitPayload(RunOptions o, int codeunitLineNo)
    {
        return "{" +
               $"\"testSuite\":{J(o.TestSuite)}," +
               $"\"codeunitLineNo\":{J(codeunitLineNo.ToString(System.Globalization.CultureInfo.InvariantCulture))}" +
               "}";
    }

    private static string J(string? s) => System.Text.Json.JsonSerializer.Serialize(s ?? string.Empty);

    private HttpClient NewClient(RunOptions o)
    {
        var handler = new HttpClientHandler();
        if (string.Equals(o.Authentication, "Windows", StringComparison.OrdinalIgnoreCase))
            handler.UseDefaultCredentials = true;

        var client = new HttpClient(handler, disposeHandler: true);
        if (string.Equals(o.Authentication, "UserPassword", StringComparison.OrdinalIgnoreCase) &&
            !string.IsNullOrEmpty(o.UserName))
        {
            var token = Convert.ToBase64String(Encoding.UTF8.GetBytes($"{o.UserName}:{o.Password}"));
            client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Basic", token);
        }
        client.DefaultRequestHeaders.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        client.DefaultRequestHeaders.Accept.Add(new MediaTypeWithQualityHeaderValue("application/xml"));
        return client;
    }
}
