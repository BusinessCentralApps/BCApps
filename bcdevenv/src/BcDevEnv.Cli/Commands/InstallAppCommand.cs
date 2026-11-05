using BcDevEnv.Cli.Cli;
using BcDevEnv.Cli.Infra;
using BcDevEnv.Cli.Nav;

namespace BcDevEnv.Cli.Commands;

/// <summary>
/// install-app: publish + sync + install a set of .app packages into a running server instance.
/// Standalone action - reuse at package time, container build time, or against a live container.
/// Depends only on the platform artifact (the apps-management cmdlets); it does not know about the
/// NAV enlistment or projects.json, so apps are supplied as concrete .app files.
/// </summary>
public static class InstallAppCommand
{
    public static int Run(ParsedArgs a)
    {
        var appFiles = a.GetAll("app-file");
        if (appFiles.Count == 0)
        {
            Log.Warn("No --app-file specified; nothing to install.");
            return 0;
        }

        var scope = a.GetOr("scope", "Global");
        var envName = a.Get("env");

        EnvManifest? manifest = null;
        if (envName != null) manifest = EnvManifest.Load(Paths.EnvPath(envName));

        // Modules come from the artifact (or BCDEVENV_MGMT_DIR inside the container).
        Paths.UsePlatform(a.Get("platform"), required: false);

        var serverInstance = a.Get("server-instance")
                             ?? manifest?.ServerInstance
                             ?? Environment.GetEnvironmentVariable("BCDEVENV_INSTANCE")
                             ?? "BC";

        using var rs = new NavRunspace();
        var appSvc = new NavAppService(rs);

        Log.Info($"Installing app set into server instance '{serverInstance}' (scope={scope}).");

        var resolved = NavAppService.ResolveAppFiles(appFiles);
        foreach (var file in resolved)
            appSvc.PublishSyncInstall(serverInstance, file, scope);

        if (manifest != null && envName != null)
        {
            foreach (var f in resolved)
            {
                var leaf = Path.GetFileName(f);
                if (!manifest.AppFiles.Contains(leaf)) manifest.AppFiles.Add(leaf);
            }
            manifest.Save(Paths.EnvPath(envName));
        }

        Log.Success($"Installed {resolved.Count} package file(s).");
        return 0;
    }
}
