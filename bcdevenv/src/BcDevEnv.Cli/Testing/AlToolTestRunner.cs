using System.Globalization;
using System.Text.Json;
using BcDevEnv.Cli.Infra;
using BcDevEnv.Cli.Nav;

namespace BcDevEnv.Cli.Testing;

/// <summary>
/// Executes a suite prepared by the BcDevEnvTestRunner (<see cref="NavTestService.Prepare"/>) with the
/// AL tool's <c>runtests</c> command. The AL tool connects to the server's development endpoint
/// (TestRunnerHub) and runs the tests in a client session, so tests that open TestPages work; the
/// OData runner runs them in a web-service session where they cannot.
///
/// <para>Selection stays with the BcDevEnvTestRunner: PrepareTests applies the test type, the
/// RequiredTestIsolation pass and the DisabledTests entries, and each codeunit's result template
/// (GetCodeunitResults before execution) lists its methods. Only codeunits with an enabled method
/// are passed to the AL tool: with an empty method list when none of their methods is disabled,
/// otherwise with the explicit list of enabled methods, so disabled methods never run. The AL tool
/// outcomes are merged into the templates: disabled methods stay "Disabled by DisabledTests" skips
/// and a selected method without an outcome stays a "selected but not executed" failure.</para>
///
/// <para>Codeunits are run in batches (one AL tool process per batch) under a per-app deadline. A
/// process that cannot start, times out, or does not print a parseable JSON result with data is an
/// infrastructure error; failed tests alone are not (the AL tool exits 1 for them).</para>
///
/// <para>The server's development test runner raises none of the Test Runner's per-test events, so a
/// state reset codeunit of the BcDevEnv Test Runner app (<see cref="ResetMockStartedCodeunitId"/> or
/// <see cref="ResetMockStoppedCodeunitId"/>) is run before every test codeunit of every batch. Its
/// results are not test results; a reset that fails or is not reported is an infrastructure error.</para>
/// </summary>
public sealed class AlToolTestRunner
{
    /// <summary>Runs a process with a timeout (tests inject a fake).</summary>
    public delegate ProcessCapture ProcessExecutor(string fileName, IReadOnlyList<string> arguments, TimeSpan timeout,
        IReadOnlyDictionary<string, string>? environment);

    /// <summary>AL tool location, development endpoint connection, batching and timeout.</summary>
    public sealed record Options
    {
        /// <summary>altool.dll (run with <see cref="DotnetPath"/>) or an altool executable.</summary>
        public required string AlToolPath { get; init; }

        /// <summary>dotnet host for altool.dll; null = <see cref="DefaultDotnetPath"/>.</summary>
        public string? DotnetPath { get; init; }

        public string? Company { get; init; }
        public string Server { get; init; } = "http://localhost";
        public string ServerInstance { get; init; } = "BC";

        /// <summary>Development endpoint port (DeveloperServicesPort).</summary>
        public int Port { get; init; } = 7049;

        /// <summary>Windows or UserPassword (credentials passed in BC_SERVER_USERNAME / BC_SERVER_PASSWORD).</summary>
        public string Authentication { get; init; } = "Windows";
        public string? UserName { get; init; }
        public string? Password { get; init; }

        /// <summary>Codeunits per AL tool process.</summary>
        public int BatchSize { get; init; } = DefaultBatchSize;

        /// <summary>Deadline for all batches of one run (one app and pass in the pipeline).</summary>
        public TimeSpan Timeout { get; init; } = TimeSpan.FromMinutes(DefaultTimeoutMinutes);

        /// <summary>Folder for the test group files; null = a temporary folder.</summary>
        public string? WorkDirectory { get; init; }

        /// <summary>
        /// The state reset before every test codeunit starts the permissions mock without assignments
        /// (true, <see cref="ResetMockStartedCodeunitId"/>) or stops it (false, <see cref="ResetMockStoppedCodeunitId"/>).
        /// </summary>
        public bool PermissionsMock { get; init; } = true;
    }

    /// <summary>Merged results (every prepared codeunit, in plan order) and infrastructure errors.</summary>
    public sealed record AlToolRun(TestRunResult Result, IReadOnlyList<string> RunnerErrors);

    /// <summary>One entry of the <c>--testgroups</c> file; an empty method list runs every method.</summary>
    public sealed record TestGroup(int CodeunitId, IReadOnlyList<string> TestMethods);

    public const int DefaultBatchSize = 20;
    public const int DefaultTimeoutMinutes = 240;

    /// <summary>BcDevEnv Test Runner codeunit "BcDevEnv Reset Mock Started" (state reset, permissions mock started).</summary>
    public const int ResetMockStartedCodeunitId = 50103;

    /// <summary>BcDevEnv Test Runner codeunit "BcDevEnv Reset Mock Stopped" (state reset, permissions mock stopped).</summary>
    public const int ResetMockStoppedCodeunitId = 50104;

    /// <summary>The test method of the state reset codeunits.</summary>
    public const string ResetMethodName = "ResetTestState";

    private const string CallstackMarker = "AL Callstack:";

    private static readonly JsonSerializerOptions GroupJson = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };

    private readonly ProcessExecutor _execute;
    private readonly Func<DateTime> _utcNow;

    public AlToolTestRunner(ProcessExecutor? execute = null, Func<DateTime>? utcNow = null)
    {
        _execute = execute ?? ((file, args, timeout, env) => ProcessRunner.Capture(file, args, timeout, env));
        _utcNow = utcNow ?? (() => DateTime.UtcNow);
    }

    /// <summary>The dotnet host installed by the container image, else dotnet on the PATH.</summary>
    public static string DefaultDotnetPath()
    {
        var installed = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "dotnet", "dotnet.exe");
        return OperatingSystem.IsWindows() && File.Exists(installed) ? installed : "dotnet";
    }

    /// <summary>Runs the enabled methods of the prepared suite and merges the outcomes into its templates.</summary>
    public AlToolRun Run(NavTestService.PreparedSuite suite, Options options)
    {
        var errors = new List<string>(suite.RunnerErrors);
        var resetId = StateResetCodeunitId(options.PermissionsMock);
        foreach (var reset in suite.Codeunits.Where(c => IsStateResetCodeunit(c.Codeunit.CodeunitId)))
            Log.Warn($"Codeunit {reset.Codeunit.CodeunitId} {reset.Codeunit.Name} is a BcDevEnv state reset codeunit, not a test; it is left out.");
        var states = suite.Codeunits.Where(c => !IsStateResetCodeunit(c.Codeunit.CodeunitId)).Select(c => new CodeunitState(c)).ToList();
        var runnable = states.Where(s => s.Prepared.TemplateAvailable && s.Prepared.Codeunit.Run && s.Group != null).ToList();
        var batchSize = Math.Max(1, options.BatchSize);
        var batches = runnable.Select((s, i) => (s, i)).GroupBy(x => x.i / batchSize, x => x.s).Select(g => g.ToList()).ToList();
        var deadline = _utcNow() + options.Timeout;

        Log.Info($"AL tool: {runnable.Count} codeunit(s) to run in {batches.Count} batch(es) of up to {batchSize} " +
                 $"(timeout {options.Timeout.TotalMinutes:0} min); {states.Count - runnable.Count} codeunit(s) not run (fully disabled or not prepared).");
        Log.Info($"AL tool: state reset codeunit {resetId} runs before every test codeunit " +
                 $"(permissions mock {(options.PermissionsMock ? "started without assignments" : "stopped")}); its results are not reported.");

        var workDirectory = options.WorkDirectory ?? Path.Combine(Path.GetTempPath(), "bcdevenv-altool-" + Guid.NewGuid().ToString("N"));
        var ownWorkDirectory = options.WorkDirectory == null;
        Directory.CreateDirectory(workDirectory);
        try
        {
            for (var b = 0; b < batches.Count; b++)
            {
                var batch = batches[b];
                var label = $"AL tool batch {b + 1}/{batches.Count} (codeunit(s) {string.Join(", ", batch.Select(s => s.Prepared.Codeunit.CodeunitId))})";
                var remaining = deadline - _utcNow();
                if (remaining <= TimeSpan.Zero)
                {
                    var error = $"{label}: not run, the {options.Timeout.TotalMinutes:0}-minute timeout was reached.";
                    Fail(batch, error, errors);
                    continue;
                }
                RunBatch(batch, options, remaining, Path.Combine(workDirectory, $"testgroups-{b + 1:D3}.json"), label, errors);
            }
        }
        finally
        {
            if (ownWorkDirectory)
            {
                try { Directory.Delete(workDirectory, recursive: true); }
                catch (IOException) { /* best effort */ }
                catch (UnauthorizedAccessException) { /* best effort */ }
            }
        }

        var result = new TestRunResult();
        var index = 0;
        foreach (var state in states)
        {
            index++;
            result.Codeunits.AddRange(state.Result.Codeunits);
            var codeunit = state.Prepared.Codeunit;
            var status = !state.Prepared.TemplateAvailable ? " (not prepared)" : codeunit.Run ? "" : " (disabled)";
            Log.Info($"[{index}/{states.Count}] Codeunit {codeunit.CodeunitId} {codeunit.Name}{status}: {state.Result.Passed} passed, " +
                     $"{state.Result.Failed} failed, {state.Result.Skipped} skipped ({state.Result.DurationSeconds:0.0}s)");
        }
        return new AlToolRun(result, errors);
    }

    /// <summary>The test groups for the given codeunits (codeunits without an enabled method are left out).</summary>
    public static IReadOnlyList<TestGroup> BuildTestGroups(IEnumerable<NavTestService.PreparedCodeunit> codeunits) =>
        codeunits.Where(c => c.TemplateAvailable && c.Codeunit.Run)
                 .Select(BuildTestGroup).OfType<TestGroup>().ToList();

    /// <summary>Serialises test groups as the AL tool's <c>--testgroups</c> JSON.</summary>
    public static string SerializeTestGroups(IEnumerable<TestGroup> groups) => JsonSerializer.Serialize(groups, GroupJson);

    /// <summary>The state reset codeunit for the permissions mock setting.</summary>
    public static int StateResetCodeunitId(bool permissionsMock) =>
        permissionsMock ? ResetMockStartedCodeunitId : ResetMockStoppedCodeunitId;

    public static bool IsStateResetCodeunit(int codeunitId) =>
        codeunitId is ResetMockStartedCodeunitId or ResetMockStoppedCodeunitId;

    /// <summary>
    /// The groups with the state reset codeunit before each of them ([reset, g1, reset, g2, ...]). The AL
    /// tool runs the groups in order, in one session, and does not merge repeated codeunits.
    /// </summary>
    public static IReadOnlyList<TestGroup> WithStateResets(IEnumerable<TestGroup> groups, int resetCodeunitId)
    {
        var reset = new TestGroup(resetCodeunitId, Array.Empty<string>());
        return groups.SelectMany(g => new[] { reset, g }).ToList();
    }

    // Empty method list = all methods (no method of the codeunit is disabled); otherwise the enabled
    // methods only. Null when no method is enabled (nothing to run).
    private static TestGroup? BuildTestGroup(NavTestService.PreparedCodeunit codeunit)
    {
        var methods = codeunit.Template.Codeunits.SelectMany(c => c.Methods).ToList();
        var enabled = methods.Where(m => !IsDisabled(m)).Select(m => m.Name).Distinct(StringComparer.OrdinalIgnoreCase).ToList();
        if (enabled.Count == 0) return null;
        return new TestGroup(codeunit.Codeunit.CodeunitId, enabled.Count == methods.Count ? Array.Empty<string>() : enabled);
    }

    private static bool IsDisabled(TestMethodResult m) =>
        m.Outcome == TestOutcome.Skipped && string.Equals(m.Message, TestSkipReasons.DisabledByDisabledTests, StringComparison.Ordinal);

    private static bool IsNotExecuted(TestMethodResult m) =>
        m.Outcome == TestOutcome.Failed && m.Message?.StartsWith(TestSkipReasons.NotExecutedPrefix, StringComparison.Ordinal) == true;

    private void RunBatch(List<CodeunitState> batch, Options options, TimeSpan timeout, string groupsFile, string label, List<string> errors)
    {
        var resetId = StateResetCodeunitId(options.PermissionsMock);
        File.WriteAllText(groupsFile, SerializeTestGroups(WithStateResets(batch.Select(s => s.Group!), resetId)));
        var (fileName, arguments) = BuildCommand(options, groupsFile);
        Dictionary<string, string>? environment = null;
        if (string.Equals(options.Authentication, "UserPassword", StringComparison.OrdinalIgnoreCase))
            environment = new Dictionary<string, string>
            {
                ["BC_SERVER_USERNAME"] = options.UserName ?? "",
                ["BC_SERVER_PASSWORD"] = options.Password ?? "",
            };

        var started = _utcNow();
        ProcessCapture capture;
        try
        {
            capture = _execute(fileName, arguments, timeout, environment);
        }
        catch (BcDevEnvException ex)
        {
            Fail(batch, $"{label}: {ex.Message}", errors);
            return;
        }
        var elapsed = _utcNow() - started;

        if (capture.TimedOut)
        {
            LogOutput(capture);
            Fail(batch, $"{label}: the AL tool did not finish within the remaining {timeout.TotalMinutes:0.#} minute(s) of the " +
                        $"{options.Timeout.TotalMinutes:0}-minute timeout and was stopped.", errors);
            return;
        }

        JsonDocument document;
        try
        {
            document = ParseOutput(capture.StdOut);
        }
        catch (BcDevEnvException ex)
        {
            LogOutput(capture);
            Fail(batch, $"{label}: {ex.Message} (exit code {capture.ExitCode})", errors);
            return;
        }

        using (document)
        {
            var root = document.RootElement;
            var message = GetString(root, "message");
            var code = root.TryGetProperty("errorDetails", out var details) && details.ValueKind == JsonValueKind.Object
                ? GetString(details, "code") : null;
            if (!root.TryGetProperty("data", out var data) || data.ValueKind != JsonValueKind.Object ||
                !data.TryGetProperty("results", out var results) || results.ValueKind != JsonValueKind.Array)
            {
                LogOutput(capture);
                Fail(batch, $"{label}: the AL tool reported no test data (exit code {capture.ExitCode}" +
                            $"{(code != null ? ", " + code : "")}): {FirstLine(message)}", errors);
                return;
            }

            var count = 0;
            var resets = 0;
            var byId = batch.GroupBy(s => s.Prepared.Codeunit.CodeunitId).ToDictionary(g => g.Key, g => g.First());
            foreach (var item in results.EnumerateArray())
            {
                var codeunitId = item.TryGetProperty("codeunitId", out var idElement) && idElement.TryGetInt32(out var id) ? id : 0;
                var methodName = GetString(item, "methodName") ?? "";
                if (IsStateResetCodeunit(codeunitId))
                {
                    // The k-th reset runs before the k-th codeunit of the batch; it is not a test result.
                    var next = batch[Math.Min(resets, batch.Count - 1)].Prepared.Codeunit;
                    if (methodName.Equals(ResetMethodName, StringComparison.OrdinalIgnoreCase)) resets++;
                    var status = GetString(item, "status");
                    if (!string.Equals(status?.Trim(), "passed", StringComparison.OrdinalIgnoreCase))
                    {
                        var error = $"{label}: the state reset before codeunit {next.CodeunitId} {next.Name} failed " +
                                    $"(codeunit {codeunitId} '{methodName}' {status ?? "without status"}): " +
                                    $"{Abbreviate(SplitOutput(GetString(item, "output")).Message, 500)} The codeunit ran without a clean state.";
                        Log.Error(error);
                        errors.Add(error);
                    }
                    continue;
                }
                count++;
                if (!byId.TryGetValue(codeunitId, out var state))
                {
                    errors.Add($"{label}: the AL tool reported '{methodName}' of codeunit {codeunitId}, which was not requested.");
                    continue;
                }
                state.Merge(methodName, GetString(item, "status"), GetString(item, "output"),
                    item.TryGetProperty("durationMs", out var ms) && ms.TryGetDouble(out var d) ? d / 1000d : 0d);
            }

            if (count == 0)
            {
                LogOutput(capture);
                Fail(batch, $"{label}: the AL tool reported no test results (exit code {capture.ExitCode}): {FirstLine(message)}", errors);
                return;
            }

            var missing = batch.Sum(s => s.CountNotExecuted());
            if (capture.ExitCode != 0 && code != "TestRunFailed")
            {
                // Not just failed tests (TestRunFailed): the run itself went wrong.
                var problem = $"{label}: the AL tool exited with {capture.ExitCode}{(code != null ? " (" + code + ")" : "")}: {FirstLine(message)}";
                if (missing > 0)
                {
                    LogOutput(capture);
                    Fail(batch, $"{problem} {missing} selected test(s) have no result.", errors);
                    return;
                }
                Log.Warn(problem);
            }
            if (resets < batch.Count)
            {
                var error = $"{label}: the AL tool reported {resets} of {batch.Count} state reset(s) (codeunit {resetId} {ResetMethodName}); " +
                            "the codeunits without one ran without a clean state. Is the current BcDevEnv Test Runner app installed?";
                Log.Error(error);
                errors.Add(error);
            }
            foreach (var state in batch)
                state.Complete("The AL tool reported no result for this test.");
            Log.Info($"{label}: {count} result(s) (+{resets} state reset(s)), exit code {capture.ExitCode} ({elapsed.TotalSeconds:0.0}s).");
        }
    }

    /// <summary>The AL tool command for one test groups file.</summary>
    public static (string FileName, IReadOnlyList<string> Arguments) BuildCommand(Options options, string groupsFile)
    {
        var arguments = new List<string>();
        string fileName;
        if (options.AlToolPath.EndsWith(".dll", StringComparison.OrdinalIgnoreCase))
        {
            fileName = string.IsNullOrWhiteSpace(options.DotnetPath) ? DefaultDotnetPath() : options.DotnetPath!;
            arguments.Add(options.AlToolPath);
        }
        else
        {
            fileName = options.AlToolPath;
        }
        arguments.AddRange(new[]
        {
            "runtests",
            "--testgroups", groupsFile,
            "--server", options.Server,
            "--serverinstance", options.ServerInstance,
            "--port", options.Port.ToString(CultureInfo.InvariantCulture),
            "--authentication", options.Authentication,
        });
        if (!string.IsNullOrWhiteSpace(options.Company))
            arguments.AddRange(new[] { "--company", options.Company! });
        return (fileName, arguments);
    }

    /// <summary>Parses the AL tool's JSON result (stdout; anything before the first '{' is ignored).</summary>
    public static JsonDocument ParseOutput(string stdout)
    {
        var start = stdout.IndexOf('{');
        var end = stdout.LastIndexOf('}');
        if (start < 0 || end < start)
            throw new BcDevEnvException($"The AL tool printed no JSON result: {Abbreviate(stdout)}");
        try
        {
            return JsonDocument.Parse(stdout[start..(end + 1)]);
        }
        catch (JsonException ex)
        {
            throw new BcDevEnvException($"Could not parse the AL tool result: {ex.Message} {Abbreviate(stdout)}", ex);
        }
    }

    /// <summary>Splits an AL tool failure output into the error message and the AL call stack.</summary>
    public static (string Message, string? StackTrace) SplitOutput(string? output)
    {
        var text = output ?? "";
        var marker = text.IndexOf(CallstackMarker, StringComparison.Ordinal);
        if (marker < 0) return (text.Trim(), null);
        var stack = text[(marker + CallstackMarker.Length)..].Trim();
        return (text[..marker].Trim(), stack.Length == 0 ? null : stack);
    }

    private static void Fail(List<CodeunitState> batch, string error, List<string> errors)
    {
        Log.Error(error);
        errors.Add(error);
        foreach (var state in batch) state.Complete(error);
    }

    private static void LogOutput(ProcessCapture capture)
    {
        if (!string.IsNullOrWhiteSpace(capture.StdOut)) Log.Warn($"AL tool output: {Abbreviate(capture.StdOut, 4000)}");
        if (!string.IsNullOrWhiteSpace(capture.StdErr)) Log.Warn($"AL tool error output: {Abbreviate(capture.StdErr, 4000)}");
    }

    private static string? GetString(JsonElement element, string name) =>
        element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;

    private static string FirstLine(string? text)
    {
        var lines = (text ?? "").Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        return lines.FirstOrDefault(l => !l.StartsWith("=====", StringComparison.Ordinal)) ?? "";
    }

    private static string Abbreviate(string text, int max = 1000)
    {
        var trimmed = text.Trim();
        return trimmed.Length <= max ? trimmed : trimmed[..max] + "...";
    }

    // The template of one prepared codeunit and the outcomes merged into it.
    private sealed class CodeunitState
    {
        public CodeunitState(NavTestService.PreparedCodeunit prepared)
        {
            Prepared = prepared;
            Result = prepared.Template;
            Group = prepared.TemplateAvailable && prepared.Codeunit.Run ? BuildTestGroup(prepared) : null;
        }

        public NavTestService.PreparedCodeunit Prepared { get; }
        public TestRunResult Result { get; }
        public TestGroup? Group { get; }
        private readonly HashSet<TestMethodResult> _reported = new();
        private string? _onRunFailure;

        public void Merge(string methodName, string? status, string? output, double seconds)
        {
            var codeunit = Result.Codeunits.FirstOrDefault(c => c.CodeunitId == Prepared.Codeunit.CodeunitId)
                           ?? Result.Codeunits.FirstOrDefault();
            if (codeunit == null) return;

            var index = FindMethod(codeunit, methodName);
            if (index < 0 && methodName.Equals("OnRun", StringComparison.OrdinalIgnoreCase))
            {
                if (ToOutcome(status) == TestOutcome.Failed)
                    _onRunFailure = SplitOutput(output).Message;
                return;
            }

            var reported = ToResult(index >= 0 ? codeunit.Methods[index] : null, methodName, status, output, seconds);
            if (index < 0)
            {
                Log.Warn($"Codeunit {Prepared.Codeunit.CodeunitId} {Prepared.Codeunit.Name}: the AL tool reported '{methodName}', " +
                         "which is not in the prepared suite; it is added to the results.");
                codeunit.Methods.Add(reported);
                _reported.Add(reported);
                return;
            }

            var existing = codeunit.Methods[index];
            if (_reported.Contains(existing))
            {
                // Several results for one method (e.g. data-driven): a failure wins, durations add up.
                var winner = reported.Outcome == TestOutcome.Failed && existing.Outcome != TestOutcome.Failed ? reported : existing;
                reported = new TestMethodResult
                {
                    Name = existing.Name,
                    Outcome = winner.Outcome,
                    Message = winner.Message,
                    StackTrace = winner.StackTrace,
                    DurationSeconds = existing.DurationSeconds + reported.DurationSeconds,
                };
            }
            codeunit.Methods[index] = reported;
            _reported.Add(reported);
        }

        // Selected methods that did not get an outcome keep their "not executed" failure; add why
        // (a failed OnRun explains it best).
        public void Complete(string reason)
        {
            if (_onRunFailure != null) reason = $"OnRun failed: {_onRunFailure}";
            foreach (var codeunit in Result.Codeunits)
                for (var i = 0; i < codeunit.Methods.Count; i++)
                {
                    var m = codeunit.Methods[i];
                    if (_reported.Contains(m) || !IsNotExecuted(m)) continue;
                    codeunit.Methods[i] = new TestMethodResult
                    {
                        Name = m.Name,
                        Outcome = m.Outcome,
                        DurationSeconds = m.DurationSeconds,
                        Message = $"{m.Message} {reason}",
                        StackTrace = m.StackTrace,
                    };
                    _reported.Add(codeunit.Methods[i]);
                }
        }

        public int CountNotExecuted() =>
            Result.Codeunits.Sum(c => c.Methods.Count(m => !_reported.Contains(m) && IsNotExecuted(m)));

        private static int FindMethod(TestCodeunitResult codeunit, string methodName)
        {
            var index = codeunit.Methods.FindIndex(m => m.Name.Equals(methodName, StringComparison.OrdinalIgnoreCase));
            if (index >= 0) return index;
            var baseName = BaseName(methodName);
            return baseName.Equals(methodName, StringComparison.Ordinal)
                ? -1
                : codeunit.Methods.FindIndex(m => m.Name.Equals(baseName, StringComparison.OrdinalIgnoreCase));
        }

        // "Method(1)" / "Method [row 2]" -> "Method" (data-driven variants).
        private static string BaseName(string methodName)
        {
            var trimmed = methodName.TrimEnd();
            foreach (var (open, close) in new[] { ('(', ')'), ('[', ']') })
            {
                if (!trimmed.EndsWith(close)) continue;
                var at = trimmed.LastIndexOf(open);
                if (at > 0) return trimmed[..at].TrimEnd();
            }
            return trimmed;
        }

        private static TestOutcome ToOutcome(string? status) => (status ?? "").Trim().ToLowerInvariant() switch
        {
            "passed" => TestOutcome.Passed,
            "skipped" => TestOutcome.Skipped,
            _ => TestOutcome.Failed,
        };

        private static TestMethodResult ToResult(TestMethodResult? template, string methodName, string? status, string? output, double seconds)
        {
            var name = template?.Name ?? methodName;
            var outcome = ToOutcome(status);
            switch (outcome)
            {
                case TestOutcome.Passed:
                    return new TestMethodResult { Name = name, Outcome = outcome, DurationSeconds = seconds };
                case TestOutcome.Skipped:
                    // A disabled method the AL tool also skipped keeps its DisabledTests reason.
                    return template != null && IsDisabled(template)
                        ? template
                        : new TestMethodResult { Name = name, Outcome = outcome, DurationSeconds = seconds, Message = TestSkipReasons.SkippedByTestRunner };
                default:
                    var (message, stack) = SplitOutput(output);
                    var known = (status ?? "").Trim().Equals("failed", StringComparison.OrdinalIgnoreCase);
                    if (!known) message = $"The AL tool reported status '{status}'. {message}".Trim();
                    if (message.Length == 0) message = "The AL tool reported the test as failed without a message.";
                    return new TestMethodResult { Name = name, Outcome = TestOutcome.Failed, DurationSeconds = seconds, Message = message, StackTrace = stack };
            }
        }
    }
}
