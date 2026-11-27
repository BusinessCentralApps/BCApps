using System.Diagnostics;
using Xunit;
using Xunit.Abstractions;

namespace BcDevEnv.Cli.IntegrationTests;

/// <summary>
/// The core integration scenario: for the latest build of every supported major platform version
/// (resolved from the index), prove the tool can create a container and install an app.
///
/// Two layers, both parameterised per major:
///   1. <see cref="Artifact_supports_creating_a_container_and_installing_an_app"/> runs everywhere
///      the master switch is on (e.g. GitHub-hosted windows-latest). It downloads the real platform
///      artifact and runs <c>bcdevenv verify</c>, which imports the BC management modules in-process
///      and asserts the exact cmdlets create-env (container DB + server instance) and install-app
///      rely on are present. This validates the create-container + install-app capability without
///      needing SQL or Docker.
///   2. <see cref="Create_container_and_install_app_end_to_end"/> is the heavy path (create-env ->
///      build-image -> start), gated behind an extra opt-in because it needs SQL Server and Docker
///      Windows containers.
/// </summary>
public class ContainerInstallAppTests
{
    private readonly ITestOutputHelper _output;

    public ContainerInstallAppTests(ITestOutputHelper output) => _output = output;

    /// <summary>One row per major version under test (see <see cref="IntegrationSettings.Majors"/>).</summary>
    public static IEnumerable<object[]> MajorVersions =>
        IntegrationSettings.Majors.Select(m => new object[] { m });

    [IntegrationTheory]
    [MemberData(nameof(MajorVersions))]
    public async Task Artifact_supports_creating_a_container_and_installing_an_app(int major)
    {
        var all = await PlatformIndex.FetchAsync();
        var latest = PlatformIndex.LatestForMajor(all, major);
        _output.WriteLine($"[major {major}] latest = {latest.Raw}");

        var artifactDir = await PlatformArtifact.EnsureAsync(latest.Raw, _output.WriteLine);

        // The extracted layout must be what the CLI consumes behind --platform.
        Assert.True(File.Exists(Path.Combine(artifactDir, "manifest.json")),
            $"Artifact {latest.Raw} is missing manifest.json under {artifactDir}.");

        // Drive the real CLI: 'verify' resolves the service tier, imports the management modules
        // and asserts the create-env / install-app cmdlet surface exists.
        var result = CliRunner.Run("verify", "--platform", artifactDir);
        _output.WriteLine(result.Combined);

        Assert.True(result.Ok,
            $"'bcdevenv verify' failed for platform {latest.Raw} (exit {result.ExitCode}).\n{result.Combined}");
        Assert.Contains(latest.Raw, result.Combined, StringComparison.Ordinal);
    }

    [ContainerTheory]
    [MemberData(nameof(MajorVersions))]
    public async Task Create_container_and_install_app_end_to_end(int major)
    {
        var all = await PlatformIndex.FetchAsync();
        var latest = PlatformIndex.LatestForMajor(all, major);
        var artifactDir = await PlatformArtifact.EnsureAsync(latest.Raw, _output.WriteLine);

        var slug = latest.Raw.Replace('.', '_');
        var envName = $"it-{slug}";
        var dbName = $"CRONUS_IT{major}";
        var tag = $"bcdevenv-it:{slug}";
        var container = $"bcdevenv-it-{slug}";
        var sqlServer = Environment.GetEnvironmentVariable("BCDEVENV_SQL_SERVER") ?? "localhost";
        var testApp = Environment.GetEnvironmentVariable("BCDEVENV_TEST_APP"); // optional bake-time app

        try
        {
            // 1. Create a fresh empty platform database (the container's DB) -> .bak.
            var create = CliRunner.Run(
                "create-env", "--platform", artifactDir, "--name", envName,
                "--database-name", dbName, "--sql-server", sqlServer);
            _output.WriteLine(create.Combined);
            Assert.True(create.Ok, $"create-env failed (exit {create.ExitCode}).\n{create.Combined}");

            // 2. Bake the DB + platform binaries (+ optional app) into a Windows container image.
            var buildArgs = new List<string> { "build-image", "--env", envName, "--tag", tag };
            if (!string.IsNullOrWhiteSpace(testApp))
            {
                buildArgs.Add("--app-file");
                buildArgs.Add(testApp);
            }
            var build = CliRunner.Run(buildArgs.ToArray());
            _output.WriteLine(build.Combined);
            Assert.True(build.Ok, $"build-image failed (exit {build.ExitCode}).\n{build.Combined}");

            // 3. Start the container.
            var start = CliRunner.Run("start", "--image", tag, "--name", container, "--detach");
            _output.WriteLine(start.Combined);
            Assert.True(start.Ok, $"start failed (exit {start.ExitCode}).\n{start.Combined}");

            // 4. Wait for the BC server inside the container to report healthy/running.
            Assert.True(WaitForContainerRunning(container, TimeSpan.FromMinutes(10)),
                $"Container '{container}' did not become healthy in time.");
        }
        finally
        {
            CliRunner.Run("remove", "--name", container, "--purge-image");
        }
    }

    private bool WaitForContainerRunning(string container, TimeSpan timeout)
    {
        var deadline = DateTime.UtcNow + timeout;
        while (DateTime.UtcNow < deadline)
        {
            var (code, stdout) = Docker("inspect", "-f", "{{.State.Health.Status}}|{{.State.Running}}", container);
            var status = stdout.Trim();
            _output.WriteLine($"container state: {status}");
            if (code == 0)
            {
                // Healthy, or running with no healthcheck defined.
                if (status.StartsWith("healthy", StringComparison.OrdinalIgnoreCase)) return true;
                if (status.StartsWith("|true", StringComparison.OrdinalIgnoreCase)) return true;
                if (status.Contains("unhealthy", StringComparison.OrdinalIgnoreCase)) return false;
            }
            Thread.Sleep(TimeSpan.FromSeconds(10));
        }
        return false;
    }

    private static (int Code, string StdOut) Docker(params string[] args)
    {
        var psi = new ProcessStartInfo("docker")
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
        };
        foreach (var a in args) psi.ArgumentList.Add(a);
        using var p = Process.Start(psi)!;
        var stdout = p.StandardOutput.ReadToEnd();
        p.WaitForExit((int)TimeSpan.FromSeconds(60).TotalMilliseconds);
        return (p.HasExited ? p.ExitCode : -1, stdout);
    }
}
