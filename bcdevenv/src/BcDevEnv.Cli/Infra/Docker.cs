using System.Diagnostics;
using System.Text;

namespace BcDevEnv.Cli.Infra;

/// <summary>Thin wrapper for launching native processes (docker, sqlservr, etc.). Not PowerShell.</summary>
public static class ProcessRunner
{
    /// <summary>Runs a process, inheriting stdout/stderr, and returns its exit code.</summary>
    public static int Run(string fileName, IEnumerable<string> args, string? workingDirectory = null)
    {
        var argList = args.ToList();
        Log.Verbose($"$ {fileName} {string.Join(' ', argList)}");
        var psi = new ProcessStartInfo
        {
            FileName = fileName,
            UseShellExecute = false,
            WorkingDirectory = workingDirectory ?? Environment.CurrentDirectory,
        };
        foreach (var a in argList) psi.ArgumentList.Add(a);
        using var p = Process.Start(psi) ?? throw new BcDevEnvException($"Failed to start '{fileName}'.");
        p.WaitForExit();
        return p.ExitCode;
    }

    /// <summary>Runs a process capturing stdout/stderr.</summary>
    public static (int Code, string StdOut, string StdErr) Capture(string fileName, IEnumerable<string> args)
    {
        var argList = args.ToList();
        Log.Verbose($"$ {fileName} {string.Join(' ', argList)}");
        var psi = new ProcessStartInfo
        {
            FileName = fileName,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        foreach (var a in argList) psi.ArgumentList.Add(a);

        var outSb = new StringBuilder();
        var errSb = new StringBuilder();
        using var p = new Process { StartInfo = psi };
        p.OutputDataReceived += (_, e) => { if (e.Data != null) outSb.AppendLine(e.Data); };
        p.ErrorDataReceived += (_, e) => { if (e.Data != null) errSb.AppendLine(e.Data); };
        try { p.Start(); }
        catch (Exception ex) { throw new BcDevEnvException($"Failed to start '{fileName}': {ex.Message}", ex); }
        p.BeginOutputReadLine();
        p.BeginErrorReadLine();
        p.WaitForExit();
        return (p.ExitCode, outSb.ToString(), errSb.ToString());
    }

    /// <summary>
    /// Runs a process capturing stdout/stderr; kills the whole process tree when it has not exited
    /// within <paramref name="timeout"/> (zero or negative = no limit). Extra environment variables are
    /// added to the inherited ones (they are not logged).
    /// </summary>
    public static ProcessCapture Capture(string fileName, IEnumerable<string> args, TimeSpan timeout,
        IReadOnlyDictionary<string, string>? environment = null)
    {
        var argList = args.ToList();
        Log.Verbose($"$ {fileName} {string.Join(' ', argList)}");
        var psi = new ProcessStartInfo
        {
            FileName = fileName,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        foreach (var a in argList) psi.ArgumentList.Add(a);
        if (environment != null)
            foreach (var kv in environment) psi.Environment[kv.Key] = kv.Value;

        var outSb = new StringBuilder();
        var errSb = new StringBuilder();
        using var p = new Process { StartInfo = psi };
        p.OutputDataReceived += (_, e) => { if (e.Data != null) lock (outSb) outSb.AppendLine(e.Data); };
        p.ErrorDataReceived += (_, e) => { if (e.Data != null) lock (errSb) errSb.AppendLine(e.Data); };
        try { p.Start(); }
        catch (Exception ex) { throw new BcDevEnvException($"Failed to start '{fileName}': {ex.Message}", ex); }
        p.BeginOutputReadLine();
        p.BeginErrorReadLine();

        var milliseconds = timeout <= TimeSpan.Zero || timeout.TotalMilliseconds >= int.MaxValue ? -1 : (int)timeout.TotalMilliseconds;
        var timedOut = false;
        if (!p.WaitForExit(milliseconds))
        {
            timedOut = true;
            try { p.Kill(entireProcessTree: true); }
            catch (InvalidOperationException) { /* exited in the meantime */ }
            catch (System.ComponentModel.Win32Exception ex) { Log.Warn($"Could not kill '{fileName}': {ex.Message}"); }
        }
        p.WaitForExit();
        string stdout, stderr;
        lock (outSb) stdout = outSb.ToString();
        lock (errSb) stderr = errSb.ToString();
        return new ProcessCapture(timedOut ? -1 : p.ExitCode, stdout, stderr, timedOut);
    }
}

/// <summary>Captured result of a process run with a timeout.</summary>
public sealed record ProcessCapture(int ExitCode, string StdOut, string StdErr, bool TimedOut);

/// <summary>docker CLI helper. docker is a native CLI (not PowerShell), so we shell out to it directly.</summary>
public static class Docker
{
    public static void RequireWindowsContainers()
    {
        var (code, stdout, _) = ProcessRunner.Capture("docker", new[] { "version", "--format", "{{.Server.Os}}" });
        if (code != 0)
            throw new BcDevEnvException("Docker is not available. Ensure Docker Desktop is installed and running.");
        var os = stdout.Trim();
        if (!os.Equals("windows", StringComparison.OrdinalIgnoreCase))
        {
            throw new BcDevEnvException(
                $"Docker is in '{os}'-container mode. bcdevenv images are Windows containers - " +
                "switch Docker Desktop to Windows containers.");
        }
    }

    public static int Build(string tag, string contextDir, string dockerfile, IReadOnlyDictionary<string, string> buildArgs)
    {
        var args = new List<string> { "build", "-t", tag, "-f", dockerfile };
        foreach (var kv in buildArgs) { args.Add("--build-arg"); args.Add($"{kv.Key}={kv.Value}"); }
        args.Add(contextDir);
        return ProcessRunner.Run("docker", args);
    }

    public static int Push(string tag) => ProcessRunner.Run("docker", new[] { "push", tag });
}
