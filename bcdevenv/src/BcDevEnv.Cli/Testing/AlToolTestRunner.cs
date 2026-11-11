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
/// <para>The server's development test runner raises none of the Test Runner's per-test events and runs every
/// test codeunit in a new session, so session state (application area, work date, last error) starts fresh in
/// every codeunit. While the run is active (PrepareTests until EndTestRun), the BcDevEnv Test Runner app clears
/// the application area that such a session gets at login (ApplicationArea(''), as the Test Runner does before
/// every test method); the CLI ends the run after the AL tool. A state reset codeunit of the BcDevEnv Test Runner
/// app runs before every test codeunit of
/// every batch for the state that outlives a session: it restores "Application Area Setup" to the baseline of
/// PrepareTests and commits it (the reset codeunits have RequiredTestIsolation = Disabled), and it sets up the
/// permissions mock: <see cref="ResetMockStoppedCodeunitId"/> without the permissions mock; with it,
/// <see cref="ResetMockStartedCodeunitId"/> for codeunits whose TestPermissions is Disabled (or unknown) and
/// <see cref="ResetFullAccessCodeunitId"/> (the D365 Full Access base of codeunit 130302, as the Test Runner
/// sets it for such methods) for all others. Its results are not test results; a reset that fails or is not
/// reported is an infrastructure error. <see cref="StateResetSummaryMessages"/> compares the passed resets with
/// the committed ones that the BcDevEnv Test Runner counted.</para>
///
/// <para>Diagnostic only: with <see cref="Options.StateProbe"/>, the state probe codeunit
/// (<see cref="StateProbeCodeunitId"/>) runs once per batch, right after the first state reset. It always
/// fails; its message (the state a test codeunit starts with) is logged as "State probe: ..."
/// and is neither a test result nor an infrastructure error.</para>
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
        /// The state reset before every test codeunit starts the permissions mock (true): without assignments for
        /// codeunits whose TestPermissions is Disabled (<see cref="ResetMockStartedCodeunitId"/>), with the D365 Full
        /// Access base for all others (<see cref="ResetFullAccessCodeunitId"/>); or it stops it (false,
        /// <see cref="ResetMockStoppedCodeunitId"/>).
        /// </summary>
        public bool PermissionsMock { get; init; } = true;

        /// <summary>Diagnostic: run the state probe (<see cref="StateProbeCodeunitId"/>) after the first state reset of every batch.</summary>
        public bool StateProbe { get; init; }
    }

    /// <summary>
    /// Merged results (every prepared codeunit, in plan order), infrastructure errors and the state probe
    /// messages (one per batch that reported its probe; empty unless <see cref="Options.StateProbe"/>).
    /// </summary>
    public sealed record AlToolRun(TestRunResult Result, IReadOnlyList<string> RunnerErrors, IReadOnlyList<string> StateProbes)
    {
        /// <summary>
        /// State resets that the AL tool reported as passed, one per test codeunit at most. Each should have committed
        /// its changes (compare <see cref="NavTestService.StateResetSummary.Resets"/>).
        /// </summary>
        public int StateResetsPassed { get; init; }
    }

    /// <summary>One entry of the <c>--testgroups</c> file; an empty method list runs every method.</summary>
    public sealed record TestGroup(int CodeunitId, IReadOnlyList<string> TestMethods);

    public const int DefaultBatchSize = 20;
    public const int DefaultTimeoutMinutes = 240;

    /// <summary>BcDevEnv Test Runner codeunit "BcDevEnv Reset Mock Started" (state reset, permissions mock started).</summary>
    public const int ResetMockStartedCodeunitId = 50103;

    /// <summary>BcDevEnv Test Runner codeunit "BcDevEnv Reset Mock Stopped" (state reset, permissions mock stopped).</summary>
    public const int ResetMockStoppedCodeunitId = 50104;

    /// <summary>
    /// BcDevEnv Test Runner codeunit "BcDevEnv Reset Full Access" (state reset, permissions mock started with the
    /// D365 Full Access base of codeunit 130302 "Set State Test Run"), for codeunits whose TestPermissions is not Disabled.
    /// </summary>
    public const int ResetFullAccessCodeunitId = 50106;

    /// <summary>
    /// The state reset codeunits have the identical test methods ResetTestState01..ResetTestState50: the server
    /// rejects a test method that occurs twice in one runtests call ("Test case name ... is not unique"), so the
    /// n-th reset of a batch runs method n (of whichever reset codeunit it uses). This count is therefore also the
    /// maximum batch size.
    /// </summary>
    public const int ResetMethodCount = 50;

    /// <summary>The most codeunits per AL tool process (one state reset method each).</summary>
    public const int MaxBatchSize = ResetMethodCount;

    /// <summary>Name prefix of the state reset test methods (followed by the two-digit position).</summary>
    public const string ResetMethodPrefix = "ResetTestState";

    /// <summary>BcDevEnv Test Runner codeunit "BcDevEnv State Probe" (diagnostic; its test method always fails with the session state).</summary>
    public const int StateProbeCodeunitId = 50105;

    /// <summary>The test method of the state probe codeunit.</summary>
    public const string StateProbeMethodName = "ProbeState";

    /// <summary>Prefix of the logged state probe messages.</summary>
    public const string StateProbeLogPrefix = "State probe: ";

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
        var probes = new List<string>();
        foreach (var reset in suite.Codeunits.Where(c => IsStateResetCodeunit(c.Codeunit.CodeunitId)))
            Log.Warn($"Codeunit {reset.Codeunit.CodeunitId} {reset.Codeunit.Name} is a BcDevEnv state reset codeunit, not a test; it is left out.");
        foreach (var probe in suite.Codeunits.Where(c => IsStateProbeCodeunit(c.Codeunit.CodeunitId)))
            Log.Warn($"Codeunit {probe.Codeunit.CodeunitId} {probe.Codeunit.Name} is the BcDevEnv state probe, not a test; it is left out.");
        var states = suite.Codeunits.Where(c => !IsStateResetCodeunit(c.Codeunit.CodeunitId) && !IsStateProbeCodeunit(c.Codeunit.CodeunitId))
                                    .Select(c => new CodeunitState(c, options.PermissionsMock)).ToList();
        var runnable = states.Where(s => s.Prepared.TemplateAvailable && s.Prepared.Codeunit.Run && s.Group != null).ToList();
        var batchSize = Math.Clamp(options.BatchSize, 1, MaxBatchSize);
        var batches = runnable.Select((s, i) => (s, i)).GroupBy(x => x.i / batchSize, x => x.s).Select(g => g.ToList()).ToList();
        var deadline = _utcNow() + options.Timeout;

        Log.Info($"AL tool: {runnable.Count} codeunit(s) to run in {batches.Count} batch(es) of up to {batchSize} " +
                 $"(timeout {options.Timeout.TotalMinutes:0} min); {states.Count - runnable.Count} codeunit(s) not run (fully disabled or not prepared).");
        LogStateResetPlan(runnable, options);
        if (options.StateProbe)
            Log.Info($"AL tool: diagnostic state probe codeunit {StateProbeCodeunitId} runs after the first state reset of every batch; " +
                     $"its message is logged as \"{StateProbeLogPrefix.TrimEnd()} ...\" and is not a test result.");

        var workDirectory = options.WorkDirectory ?? Path.Combine(Path.GetTempPath(), "bcdevenv-altool-" + Guid.NewGuid().ToString("N"));
        var ownWorkDirectory = options.WorkDirectory == null;
        var resetsPassed = 0;
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
                RunBatch(batch, options, remaining, Path.Combine(workDirectory, $"testgroups-{b + 1:D3}.json"), label, errors, probes, ref resetsPassed);
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
        return new AlToolRun(result, errors, probes) { StateResetsPassed = resetsPassed };
    }

    /// <summary>The test groups for the given codeunits (codeunits without an enabled method are left out).</summary>
    public static IReadOnlyList<TestGroup> BuildTestGroups(IEnumerable<NavTestService.PreparedCodeunit> codeunits) =>
        codeunits.Where(c => c.TemplateAvailable && c.Codeunit.Run)
                 .Select(BuildTestGroup).OfType<TestGroup>().ToList();

    // The state reset plan of the run, and warnings for codeunits whose permission base is uncertain.
    private static void LogStateResetPlan(IReadOnlyList<CodeunitState> runnable, Options options)
    {
        if (!options.PermissionsMock)
        {
            Log.Info($"AL tool: state reset codeunit {ResetMockStoppedCodeunitId} runs before every test codeunit " +
                     "(permissions mock stopped); its results are not reported.");
            return;
        }

        var fullAccess = runnable.Count(s => s.ResetCodeunitId == ResetFullAccessCodeunitId);
        Log.Info($"AL tool: state reset codeunit {ResetMockStartedCodeunitId} (TestPermissions Disabled) or {ResetFullAccessCodeunitId} " +
                 "(otherwise) runs before every test codeunit (permissions mock started; " +
                 $"{fullAccess} codeunit(s) with the D365 Full Access base, {runnable.Count - fullAccess} without assignments); " +
                 "its results are not reported.");
        foreach (var warning in StateResetWarnings(runnable.Select(s => s.Prepared.Codeunit), options.PermissionsMock))
            Log.Warn(warning);
    }

    /// <summary>
    /// Warnings for codeunits whose state reset may not match the Test Runner's: no TestPermissions reported (an older
    /// BcDevEnv Test Runner app; the reset starts the permissions mock without assignments) or selected methods with
    /// different values (the reset runs once per codeunit and uses the first selected method's). None without the
    /// permissions mock, which never assigns the D365 Full Access base.
    /// </summary>
    public static IReadOnlyList<string> StateResetWarnings(IEnumerable<NavTestService.PlannedCodeunit> codeunits, bool permissionsMock)
    {
        var warnings = new List<string>();
        if (!permissionsMock) return warnings;
        var list = codeunits.ToList();
        var unknown = list.Where(c => string.IsNullOrWhiteSpace(c.TestPermissions)).ToList();
        if (unknown.Count > 0)
            warnings.Add($"AL tool: the BcDevEnv Test Runner reported no TestPermissions for {unknown.Count} codeunit(s) " +
                         $"({string.Join(", ", unknown.Take(10).Select(c => c.CodeunitId))}{(unknown.Count > 10 ? ", ..." : "")}); " +
                         $"their state reset starts the permissions mock without assignments (codeunit {ResetMockStartedCodeunitId}), " +
                         "not with the D365 Full Access base. Is the current BcDevEnv Test Runner app installed?");
        foreach (var mixed in list.Where(c => c.TestPermissionsMixed && !string.IsNullOrWhiteSpace(c.TestPermissions)))
            warnings.Add($"Codeunit {mixed.CodeunitId} {mixed.Name}: its selected test methods have different TestPermissions; " +
                         "the state reset runs once per codeunit and uses the first selected method's " +
                         $"({mixed.TestPermissions}, codeunit {StateResetCodeunitId(true, mixed.TestPermissions)}).");
        return warnings;
    }

    /// <summary>Serialises test groups as the AL tool's <c>--testgroups</c> JSON.</summary>
    public static string SerializeTestGroups(IEnumerable<TestGroup> groups) => JsonSerializer.Serialize(groups, GroupJson);

    /// <summary>
    /// The log line for what the state resets of a run did (GetStateResetSummary of the BcDevEnv Test Runner) after
    /// <paramref name="resetsPassed"/> passed state resets, and a warning when fewer resets were committed than passed:
    /// the others were rolled back, including their "Application Area Setup" restore. With a runner app that has the
    /// login hook, the line also says in how many client sessions it cleared the login application area.
    /// </summary>
    public static (string Info, string? Warning) StateResetSummaryMessages(NavTestService.StateResetSummary summary, int resetsPassed)
    {
        var committed = $"State reset: {summary.Resets} state reset(s) committed ({resetsPassed} passed)";
        var info = !summary.TablePresent
            ? $"{committed}; there is no \"Application Area Setup\" table to restore."
            : summary.BaselineRows < 0
                ? $"{committed}; \"Application Area Setup\" has no baseline, nothing was restored."
                : $"{committed}; \"Application Area Setup\" (baseline {summary.BaselineRows} row(s)) restored by {summary.Restores} of them: " +
                  $"{summary.Removed} row(s) removed, {summary.Recreated} re-created, {summary.Modified} modified.";
        if (summary.LoginSessions is { } sessions)
            info = $"{info.TrimEnd('.')}; login ApplicationArea cleared in {sessions} session(s) " +
                   $"({summary.LoginSessionsWithArea ?? 0} had one set at login).";
        string? warning = null;
        if (summary.Resets < resetsPassed)
            warning = $"State reset: only {summary.Resets} of {resetsPassed} passed state reset(s) were committed; the others were rolled back, " +
                      "including their \"Application Area Setup\" restore. Is the current BcDevEnv Test Runner app (reset codeunits with " +
                      "RequiredTestIsolation = Disabled) installed?";
        return (info, warning);
    }

    /// <summary>
    /// A warning when the login hook of the BcDevEnv Test Runner (ApplicationArea('') in every client session that opens
    /// a company during the run) cleared the application area in fewer sessions than <paramref name="resetsPassed"/>:
    /// the AL tool runs every state reset in a session of its own, so each passed reset should have been counted.
    /// Null when it was not fewer, or when the runner app has no login hook (<see cref="NavTestService.StateResetSummary.LoginSessions"/> null).
    /// </summary>
    public static string? LoginApplicationAreaWarning(NavTestService.StateResetSummary summary, int resetsPassed)
    {
        if (summary.LoginSessions is not { } sessions || sessions >= resetsPassed)
            return null;
        return $"State reset: the login ApplicationArea was cleared in only {sessions} session(s), fewer than the {resetsPassed} passed " +
               "state reset(s), which each ran in a session of their own; test codeunits may have run with the application area of " +
               "\"Application Area Setup\" (controls outside it are \"not found on the page\").";
    }

    /// <summary>The state reset codeunit for the permissions mock setting (TestPermissions unknown).</summary>
    public static int StateResetCodeunitId(bool permissionsMock) => StateResetCodeunitId(permissionsMock, null);

    /// <summary>
    /// The state reset codeunit for a test codeunit: without the permissions mock <see cref="ResetMockStoppedCodeunitId"/>;
    /// with it, like the Test Runner's codeunit 130453 (130302 for every method whose TestPermissions is not Disabled),
    /// <see cref="ResetMockStartedCodeunitId"/> for Disabled (and for an unknown value: no D365 Full Access base, as
    /// before it was reported) and <see cref="ResetFullAccessCodeunitId"/> for any other value.
    /// </summary>
    public static int StateResetCodeunitId(bool permissionsMock, string? testPermissions)
    {
        if (!permissionsMock) return ResetMockStoppedCodeunitId;
        if (string.IsNullOrWhiteSpace(testPermissions) || string.Equals(testPermissions.Trim(), "Disabled", StringComparison.OrdinalIgnoreCase))
            return ResetMockStartedCodeunitId;
        return ResetFullAccessCodeunitId;
    }

    public static bool IsStateResetCodeunit(int codeunitId) =>
        codeunitId is ResetMockStartedCodeunitId or ResetMockStoppedCodeunitId or ResetFullAccessCodeunitId;

    public static bool IsStateProbeCodeunit(int codeunitId) => codeunitId == StateProbeCodeunitId;

    /// <summary>The state reset method that runs before the <paramref name="position"/>-th codeunit of a batch (1-based).</summary>
    public static string ResetMethodName(int position)
    {
        if (position < 1 || position > ResetMethodCount)
            throw new ArgumentOutOfRangeException(nameof(position), position, $"The state reset codeunits have {ResetMethodCount} methods.");
        return ResetMethodPrefix + position.ToString("D2", CultureInfo.InvariantCulture);
    }

    /// <summary>The position of a state reset method (ResetTestState07 = 7); 0 for any other method name.</summary>
    public static int ResetMethodPosition(string? methodName)
    {
        if (methodName == null || methodName.Length != ResetMethodPrefix.Length + 2 ||
            !methodName.StartsWith(ResetMethodPrefix, StringComparison.OrdinalIgnoreCase) ||
            !int.TryParse(methodName.AsSpan(ResetMethodPrefix.Length), NumberStyles.None, CultureInfo.InvariantCulture, out var position))
            return 0;
        return position is >= 1 and <= ResetMethodCount ? position : 0;
    }

    /// <summary>
    /// The groups with a state reset before each of them ([reset 01, g1, reset 02, g2, ...]). The AL tool runs
    /// the groups in order, each in a new session, and does not merge repeated codeunits; the server rejects a
    /// repeated codeunit/method pair, so every reset selects its own method of the reset codeunit. With
    /// <paramref name="stateProbe"/>, the diagnostic state probe runs once, right after the first reset
    /// ([reset 01, probe, g1, reset 02, g2, ...]).
    /// </summary>
    public static IReadOnlyList<TestGroup> WithStateResets(IEnumerable<TestGroup> groups, int resetCodeunitId, bool stateProbe = false)
    {
        var list = groups.ToList();
        return WithStateResets(list, Enumerable.Repeat(resetCodeunitId, list.Count).ToList(), stateProbe);
    }

    /// <summary>
    /// As <see cref="WithStateResets(IEnumerable{TestGroup}, int, bool)"/>, with the reset codeunit of each group
    /// (<paramref name="resetCodeunitIds"/>[i] before <paramref name="groups"/>[i]). The method positions run across
    /// the reset codeunits ([50103 ResetTestState01, g1, 50106 ResetTestState02, g2, ...]), so no method name repeats.
    /// </summary>
    public static IReadOnlyList<TestGroup> WithStateResets(IReadOnlyList<TestGroup> groups, IReadOnlyList<int> resetCodeunitIds, bool stateProbe = false)
    {
        if (groups.Count > ResetMethodCount)
            throw new ArgumentException($"A batch has at most {ResetMethodCount} codeunits (one state reset method each); got {groups.Count}.", nameof(groups));
        if (resetCodeunitIds.Count != groups.Count)
            throw new ArgumentException($"One state reset codeunit per group is required; got {resetCodeunitIds.Count} for {groups.Count} group(s).", nameof(resetCodeunitIds));
        var invalid = resetCodeunitIds.Where(id => !IsStateResetCodeunit(id)).Distinct().ToList();
        if (invalid.Count > 0)
            throw new ArgumentException($"Not a state reset codeunit: {string.Join(", ", invalid)}.", nameof(resetCodeunitIds));
        var result = new List<TestGroup>(groups.Count * 2 + 1);
        for (var i = 0; i < groups.Count; i++)
        {
            result.Add(new TestGroup(resetCodeunitIds[i], new[] { ResetMethodName(i + 1) }));
            if (i == 0 && stateProbe)
                result.Add(new TestGroup(StateProbeCodeunitId, new[] { StateProbeMethodName }));
            result.Add(groups[i]);
        }
        return result;
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

    private void RunBatch(List<CodeunitState> batch, Options options, TimeSpan timeout, string groupsFile, string label, List<string> errors, List<string> probes,
        ref int resetsPassed)
    {
        var resetIds = batch.Select(s => s.ResetCodeunitId).ToList();
        File.WriteAllText(groupsFile, SerializeTestGroups(WithStateResets(batch.Select(s => s.Group!).ToList(), resetIds, options.StateProbe)));
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
            var resets = new HashSet<int>();
            var passedResets = new HashSet<int>();
            var probed = false;
            var byId = batch.GroupBy(s => s.Prepared.Codeunit.CodeunitId).ToDictionary(g => g.Key, g => g.First());
            foreach (var item in results.EnumerateArray())
            {
                var codeunitId = item.TryGetProperty("codeunitId", out var idElement) && idElement.TryGetInt32(out var id) ? id : 0;
                var methodName = GetString(item, "methodName") ?? "";
                if (IsStateProbeCodeunit(codeunitId))
                {
                    // Diagnostic only: ProbeState always fails with the session state as its message. Other
                    // results of the probe codeunit (OnRun) carry nothing.
                    if (options.StateProbe && string.Equals(methodName, StateProbeMethodName, StringComparison.OrdinalIgnoreCase))
                    {
                        probed = true;
                        var probe = $"{label}: {Abbreviate(SplitOutput(GetString(item, "output")).Message, 4000)}";
                        probes.Add(probe);
                        Log.Info(StateProbeLogPrefix + probe);
                    }
                    continue;
                }
                if (IsStateResetCodeunit(codeunitId))
                {
                    // ResetTestState<n> runs before the n-th codeunit of the batch; it is not a test result. Other
                    // results of the reset codeunit (OnRun) precede the next reset method. A reset counts only from
                    // the reset codeunit chosen for that position.
                    var position = ResetMethodPosition(methodName);
                    if (position > batch.Count) position = 0;
                    var chosen = position > 0 && codeunitId == resetIds[position - 1];
                    if (chosen) resets.Add(position);
                    var next = batch[Math.Min(position > 0 ? position : resets.Count + 1, batch.Count) - 1].Prepared.Codeunit;
                    var status = GetString(item, "status");
                    if (string.Equals(status?.Trim(), "passed", StringComparison.OrdinalIgnoreCase))
                    {
                        if (chosen) passedResets.Add(position);
                    }
                    else
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
            resetsPassed += passedResets.Count;

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
            var withoutReset = Enumerable.Range(1, batch.Count).Where(p => !resets.Contains(p)).Select(p => batch[p - 1].Prepared.Codeunit.CodeunitId).ToList();
            if (withoutReset.Count > 0)
            {
                var methods = batch.Count == 1 ? ResetMethodName(1) : $"{ResetMethodName(1)}..{ResetMethodName(batch.Count)}";
                var error = $"{label}: the AL tool reported {resets.Count} of {batch.Count} state reset(s) " +
                            $"(codeunit {string.Join(" / ", resetIds.Distinct())} {methods}); " +
                            $"codeunit(s) {string.Join(", ", withoutReset)} ran without a clean state. Is the current BcDevEnv Test Runner app installed?";
                Log.Error(error);
                errors.Add(error);
            }
            foreach (var state in batch)
                state.Complete("The AL tool reported no result for this test.");
            if (options.StateProbe && !probed)
                Log.Warn($"{label}: the AL tool reported no result for the state probe (codeunit {StateProbeCodeunitId} {StateProbeMethodName}); " +
                         "the probe is diagnostic only. Is the current BcDevEnv Test Runner app installed?");
            Log.Info($"{label}: {count} result(s) (+{resets.Count} state reset(s){(probed ? " + state probe" : "")}), exit code {capture.ExitCode} ({elapsed.TotalSeconds:0.0}s).");
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
        public CodeunitState(NavTestService.PreparedCodeunit prepared, bool permissionsMock)
        {
            Prepared = prepared;
            Result = prepared.Template;
            Group = prepared.TemplateAvailable && prepared.Codeunit.Run ? BuildTestGroup(prepared) : null;
            ResetCodeunitId = StateResetCodeunitId(permissionsMock, prepared.Codeunit.TestPermissions);
        }

        public NavTestService.PreparedCodeunit Prepared { get; }
        public TestRunResult Result { get; }
        public TestGroup? Group { get; }

        /// <summary>The state reset codeunit that runs before this codeunit.</summary>
        public int ResetCodeunitId { get; }
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
