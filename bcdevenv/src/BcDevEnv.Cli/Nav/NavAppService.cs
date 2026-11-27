using System.Management.Automation;
using BcDevEnv.Cli.Infra;

namespace BcDevEnv.Cli.Nav;

/// <summary>App publish/sync/install via the BC apps-management cmdlets (in-process).</summary>
public sealed class NavAppService
{
    private readonly NavRunspace _rs;

    public NavAppService(NavRunspace rs)
    {
        _rs = rs;
        _rs.ImportManagementModules();
    }

    /// <summary>Publishes, syncs and installs a single .app package into the server instance.</summary>
    public void PublishSyncInstall(string instance, string appPath, string scope = "Global", bool skipVerification = true)
    {
        if (!File.Exists(appPath))
            throw new BcDevEnvException($"App package not found: '{appPath}'.");

        var (name, version, publisher) = ReadAppInfo(appPath);
        Log.Info($"Publishing '{name}' {version} ({publisher})...");
        _rs.Invoke("Publish-NAVApp", new Dictionary<string, object?>
        {
            ["ServerInstance"] = instance,
            ["Path"] = appPath,
            ["Scope"] = scope,
            ["SkipVerification"] = skipVerification,
        });

        Log.Info($"Syncing '{name}'...");
        _rs.Invoke("Sync-NAVApp", new Dictionary<string, object?>
        {
            ["ServerInstance"] = instance,
            ["Name"] = name,
            ["Version"] = version,
            ["Mode"] = "Add",
            ["Force"] = true,
        });

        Log.Info($"Installing '{name}'...");
        _rs.Invoke("Install-NAVApp", new Dictionary<string, object?>
        {
            ["ServerInstance"] = instance,
            ["Name"] = name,
            ["Version"] = version,
        });
        Log.Success($"Installed '{name}' {version}.");
    }

    private (string Name, string Version, string Publisher) ReadAppInfo(string appPath)
    {
        var results = _rs.Invoke("Get-NAVAppInfo", new Dictionary<string, object?> { ["Path"] = appPath });
        if (results.Count == 0)
            throw new BcDevEnvException($"Get-NAVAppInfo returned nothing for '{appPath}'.");
        var info = results[0];
        var name = info.Properties["Name"]?.Value?.ToString()
                   ?? throw new BcDevEnvException($"Could not read app Name from '{appPath}'.");
        var version = info.Properties["Version"]?.Value?.ToString() ?? "";
        var publisher = info.Properties["Publisher"]?.Value?.ToString() ?? "";
        return (name, version, publisher);
    }

    /// <summary>Expands a list of --app-file patterns (files, folders, globs) into concrete .app paths.</summary>
    public static IReadOnlyList<string> ResolveAppFiles(IEnumerable<string> patterns)
    {
        var files = new List<string>();
        foreach (var pattern in patterns)
        {
            if (Directory.Exists(pattern))
            {
                files.AddRange(Directory.GetFiles(pattern, "*.app", SearchOption.TopDirectoryOnly));
                continue;
            }
            var dir = Path.GetDirectoryName(pattern);
            var leaf = Path.GetFileName(pattern);
            if (!string.IsNullOrEmpty(leaf) && (leaf.Contains('*') || leaf.Contains('?')))
            {
                var searchDir = string.IsNullOrEmpty(dir) ? Environment.CurrentDirectory : dir;
                if (Directory.Exists(searchDir))
                    files.AddRange(Directory.GetFiles(searchDir, leaf, SearchOption.TopDirectoryOnly));
            }
            else if (File.Exists(pattern))
            {
                files.Add(Path.GetFullPath(pattern));
            }
            else
            {
                throw new BcDevEnvException($"No .app files matched '{pattern}'.");
            }
        }
        return files.Distinct(StringComparer.OrdinalIgnoreCase).ToList();
    }
}
