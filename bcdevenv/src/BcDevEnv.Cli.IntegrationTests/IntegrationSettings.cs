namespace BcDevEnv.Cli.IntegrationTests;

/// <summary>
/// Central switches that gate the integration tests. These tests reach the network (the BC
/// platform index), download large platform artifacts, and - for the end-to-end variant - drive
/// SQL Server and Docker Windows containers. They are therefore OFF unless explicitly enabled, so a
/// plain <c>dotnet test</c> (and the unit-test CI job) stays hermetic and fast.
/// </summary>
public static class IntegrationSettings
{
    /// <summary>Truthy value of an on/off environment flag.</summary>
    private static bool IsTruthy(string? value) =>
        value is not null &&
        (value.Equals("1", StringComparison.OrdinalIgnoreCase) ||
         value.Equals("true", StringComparison.OrdinalIgnoreCase) ||
         value.Equals("yes", StringComparison.OrdinalIgnoreCase));

    /// <summary>
    /// Master switch. Set BCDEVENV_RUN_INTEGRATION=1 to run the network + artifact-download tests
    /// (they resolve the latest platform per major and validate the CLI can consume the artifact).
    /// </summary>
    public static bool Enabled => IsTruthy(Environment.GetEnvironmentVariable("BCDEVENV_RUN_INTEGRATION"));

    public const string DisabledReason =
        "Integration tests are disabled. Set BCDEVENV_RUN_INTEGRATION=1 to run them " +
        "(they hit the BC platform index and download platform artifacts).";

    /// <summary>
    /// Additional switch for the heavy end-to-end path (create-env -> build-image -> start ->
    /// install-app). Requires SQL Server + Docker in Windows-container mode, so it is a separate,
    /// explicit opt-in on top of <see cref="Enabled"/>.
    /// </summary>
    public static bool ContainerTestsEnabled =>
        Enabled && IsTruthy(Environment.GetEnvironmentVariable("BCDEVENV_RUN_CONTAINER_TESTS"));

    public const string ContainerDisabledReason =
        "End-to-end container tests are disabled. Set BCDEVENV_RUN_CONTAINER_TESTS=1 (in addition " +
        "to BCDEVENV_RUN_INTEGRATION=1) on a host with SQL Server and Docker Windows containers.";

    /// <summary>
    /// Major platform versions to test - one test per major, each resolving the latest available
    /// patch from the index. Override with BCDEVENV_MAJORS (comma-separated), which the workflow
    /// sets from the live index so brand-new majors are picked up automatically.
    /// </summary>
    public static IReadOnlyList<int> Majors
    {
        get
        {
            var raw = Environment.GetEnvironmentVariable("BCDEVENV_MAJORS");
            if (!string.IsNullOrWhiteSpace(raw))
            {
                var parsed = raw
                    .Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                    .Select(s => int.TryParse(s, out var n) ? n : (int?)null)
                    .Where(n => n.HasValue)
                    .Select(n => n!.Value)
                    .Distinct()
                    .OrderBy(n => n)
                    .ToList();
                if (parsed.Count > 0) return parsed;
            }
            return new[] { 28, 29, 30 };
        }
    }
}
