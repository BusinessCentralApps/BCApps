using System.Diagnostics;
using System.Text;

namespace BcDevEnv.Cli.IntegrationTests;

/// <summary>Result of running the bcdevenv CLI as a child process.</summary>
public sealed record CliResult(int ExitCode, string StdOut, string StdErr)
{
    public string Combined => (StdOut + Environment.NewLine + StdErr).Trim();
    public bool Ok => ExitCode == 0;
}

/// <summary>
/// Runs the real, built <c>bcdevenv</c> executable as a separate process. Using a subprocess (not
/// an in-process call) matters: each invocation loads exactly one platform version's management
/// modules + native/.NET assemblies, so running <c>verify</c> across several majors in one test
/// run can never suffer from cross-version assembly clashes in a single process.
/// </summary>
public static class CliRunner
{
    private static readonly Lazy<(string exe, string[] prefixArgs)> Resolved = new(Resolve);

    public static CliResult Run(params string[] args) => Run(TimeSpan.FromMinutes(15), args);

    public static CliResult Run(TimeSpan timeout, params string[] args)
    {
        var (exe, prefixArgs) = Resolved.Value;
        var psi = new ProcessStartInfo
        {
            FileName = exe,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
        };
        foreach (var a in prefixArgs) psi.ArgumentList.Add(a);
        foreach (var a in args) psi.ArgumentList.Add(a);

        var stdout = new StringBuilder();
        var stderr = new StringBuilder();
        using var proc = new Process { StartInfo = psi };
        proc.OutputDataReceived += (_, e) => { if (e.Data != null) stdout.AppendLine(e.Data); };
        proc.ErrorDataReceived += (_, e) => { if (e.Data != null) stderr.AppendLine(e.Data); };

        proc.Start();
        proc.BeginOutputReadLine();
        proc.BeginErrorReadLine();

        if (!proc.WaitForExit((int)timeout.TotalMilliseconds))
        {
            try { proc.Kill(entireProcessTree: true); } catch { /* ignore */ }
            throw new TimeoutException(
                $"bcdevenv {string.Join(' ', args)} did not complete within {timeout}.");
        }
        proc.WaitForExit(); // flush async readers

        return new CliResult(proc.ExitCode, stdout.ToString(), stderr.ToString());
    }

    /// <summary>
    /// Locates the CLI to run. Order: BCDEVENV_CLI_EXE, then bcdevenv.exe next to the test assembly
    /// (the referenced Exe project's apphost is copied there), then bcdevenv.dll via `dotnet`.
    /// </summary>
    private static (string exe, string[] prefixArgs) Resolve()
    {
        var overridePath = Environment.GetEnvironmentVariable("BCDEVENV_CLI_EXE");
        if (!string.IsNullOrWhiteSpace(overridePath) && File.Exists(overridePath))
            return (overridePath, Array.Empty<string>());

        var baseDir = AppContext.BaseDirectory;
        var exe = Path.Combine(baseDir, "bcdevenv.exe");
        if (File.Exists(exe)) return (exe, Array.Empty<string>());

        var dll = Path.Combine(baseDir, "bcdevenv.dll");
        if (File.Exists(dll)) return ("dotnet", new[] { dll });

        throw new FileNotFoundException(
            $"Could not find the bcdevenv CLI. Looked for BCDEVENV_CLI_EXE, '{exe}' and '{dll}'. " +
            "Build the solution first (dotnet build).");
    }
}
