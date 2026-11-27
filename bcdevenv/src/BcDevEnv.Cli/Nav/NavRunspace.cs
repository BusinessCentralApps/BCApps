using System.Collections.ObjectModel;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using BcDevEnv.Cli.Infra;

namespace BcDevEnv.Cli.Nav;

/// <summary>
/// Hosts the PowerShell engine in-process (via Microsoft.PowerShell.SDK) and invokes the BC
/// management cmdlets directly - no powershell.exe subprocess and no .ps1 scripts in the CLI.
/// The management operations (New-NAVServerInstance, Publish/Sync/Install-NAVApp, ...) are
/// implemented inside PSCmdlet classes, so this is the supported way to reuse that exact logic
/// from a .NET application.
/// </summary>
public sealed class NavRunspace : IDisposable
{
    private readonly Runspace _runspace;
    private bool _managementImported;

    public NavRunspace()
    {
        // When hosting Microsoft.PowerShell.SDK in-process (especially from a
        // self-contained published app inside the container, where no system
        // PowerShell is installed), the engine must be able to find its built-in
        // modules (Microsoft.PowerShell.Management, ...Utility) that the BC
        // management modules depend on (e.g. Join-Path). Ensure the app's own
        // bundled 'Modules' folder is on PSModulePath so they resolve without a
        // system PowerShell installation.
        EnsureBundledModulesOnPath();

        var iss = InitialSessionState.CreateDefault2();
        // The BC modules and enlistment scripts are trusted local code.
        if (OperatingSystem.IsWindows())
        {
            iss.ExecutionPolicy = Microsoft.PowerShell.ExecutionPolicy.Bypass;
        }
        _runspace = RunspaceFactory.CreateRunspace(iss);
        _runspace.Open();
    }

    private static void EnsureBundledModulesOnPath()
    {
        // Self-contained publish flattens runtime files, so the built-in modules
        // land at <app>\Modules. A framework-dependent build keeps them under
        // <app>\runtimes\win\lib\net<ver>\Modules. Add whichever exists.
        var candidates = new List<string>
        {
            Path.Combine(AppContext.BaseDirectory, "Modules"),
        };
        var runtimesWin = Path.Combine(AppContext.BaseDirectory, "runtimes", "win", "lib");
        if (Directory.Exists(runtimesWin))
        {
            foreach (var tfm in Directory.GetDirectories(runtimesWin))
            {
                var mods = Path.Combine(tfm, "Modules");
                if (Directory.Exists(mods)) candidates.Add(mods);
            }
        }

        var current = Environment.GetEnvironmentVariable("PSModulePath") ?? string.Empty;
        var parts = current.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries).ToList();
        var changed = false;
        foreach (var dir in candidates)
        {
            if (Directory.Exists(dir) && !parts.Contains(dir, StringComparer.OrdinalIgnoreCase))
            {
                parts.Insert(0, dir);
                changed = true;
            }
        }
        if (changed)
            Environment.SetEnvironmentVariable("PSModulePath", string.Join(Path.PathSeparator, parts));
    }

    /// <summary>Imports the BC management + apps-management modules into the runspace (idempotent).</summary>
    public void ImportManagementModules()
    {
        if (_managementImported) return;
        foreach (var modulePath in Paths.ManagementModulePaths())
        {
            Log.Verbose($"Import-Module {modulePath}");
            Invoke("Import-Module", new Dictionary<string, object?>
            {
                ["Name"] = modulePath,
                ["DisableNameChecking"] = true,
                ["Global"] = true,
            });
        }
        _managementImported = true;
    }

    /// <summary>Imports an arbitrary module by path (used for enlistment helper modules).</summary>
    public void ImportModule(string modulePath)
    {
        Log.Verbose($"Import-Module {modulePath}");
        Invoke("Import-Module", new Dictionary<string, object?>
        {
            ["Name"] = modulePath,
            ["DisableNameChecking"] = true,
            ["Global"] = true,
        });
    }

    /// <summary>Invokes a command/cmdlet/function. Bool values are treated as switch parameters.</summary>
    public IReadOnlyList<PSObject> Invoke(string command, IDictionary<string, object?>? parameters = null)
    {
        using var ps = PowerShell.Create();
        ps.Runspace = _runspace;
        ps.AddCommand(command);
        AddParameters(ps, parameters);
        return Run(ps, command);
    }

    /// <summary>Invokes a .ps1 script file with parameters (used for enlistment build scripts).</summary>
    public IReadOnlyList<PSObject> InvokeScriptFile(string scriptPath, IDictionary<string, object?>? parameters = null)
    {
        if (!File.Exists(scriptPath))
            throw new BcDevEnvException($"Script not found: '{scriptPath}'.");
        using var ps = PowerShell.Create();
        ps.Runspace = _runspace;
        ps.AddCommand(scriptPath);
        AddParameters(ps, parameters);
        return Run(ps, scriptPath);
    }

    /// <summary>Evaluates a scalar expression and returns the single result (e.g. a helper function call).</summary>
    public PSObject? InvokeScalar(string script)
    {
        using var ps = PowerShell.Create();
        ps.Runspace = _runspace;
        ps.AddScript(script);
        var results = Run(ps, script);
        return results.Count > 0 ? results[0] : null;
    }

    private static void AddParameters(PowerShell ps, IDictionary<string, object?>? parameters)
    {
        if (parameters == null) return;
        foreach (var kv in parameters)
        {
            if (kv.Value is bool b)
            {
                if (b) ps.AddParameter(kv.Key, true); // switch present
            }
            else if (kv.Value != null)
            {
                ps.AddParameter(kv.Key, kv.Value);
            }
        }
    }

    private static IReadOnlyList<PSObject> Run(PowerShell ps, string what)
    {
        ps.Streams.Verbose.DataAdded += (_, e) => Log.Verbose(ps.Streams.Verbose[e.Index].Message);
        ps.Streams.Warning.DataAdded += (_, e) => Log.Warn(ps.Streams.Warning[e.Index].Message);
        ps.Streams.Information.DataAdded += (_, e) =>
        {
            var msg = ps.Streams.Information[e.Index]?.MessageData?.ToString();
            if (!string.IsNullOrEmpty(msg)) Log.Info(msg);
        };

        Collection<PSObject> results;
        try
        {
            results = ps.Invoke();
        }
        catch (RuntimeException rex)
        {
            throw new BcDevEnvException($"'{what}' failed: {rex.Message}", rex);
        }

        if (ps.HadErrors && ps.Streams.Error.Count > 0)
        {
            var first = ps.Streams.Error[0];
            throw new BcDevEnvException($"'{what}' failed: {first.Exception?.Message ?? first.ToString()}", first.Exception);
        }
        return results;
    }

    public void Dispose() => _runspace.Dispose();
}
