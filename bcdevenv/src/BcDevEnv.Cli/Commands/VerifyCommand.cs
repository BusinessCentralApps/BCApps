using BcDevEnv.Cli.Cli;
using BcDevEnv.Cli.Infra;
using BcDevEnv.Cli.Nav;

namespace BcDevEnv.Cli.Commands;

/// <summary>
/// verify: validate that a platform artifact is actually usable by the tool WITHOUT touching SQL,
/// Docker or a live server instance. It resolves the service tier + web client, imports the BC
/// management modules in-process, and asserts the cmdlets that 'create-env' (create a container's
/// database + server instance) and 'install-app' rely on are all available. This is the artifact
/// pre-check the integration tests run for every supported platform version.
/// </summary>
public static class VerifyCommand
{
    /// <summary>
    /// Cmdlets the host-side flow needs: create-env uses New-NAVApplicationDatabase; provision
    /// registers/configures the instance; install-app publishes/syncs/installs apps.
    /// </summary>
    private static readonly string[] RequiredCmdlets =
    {
        "New-NAVApplicationDatabase",
        "New-NAVServerInstance",
        "Set-NAVServerConfiguration",
        "Get-NAVAppInfo",
        "Publish-NAVApp",
        "Sync-NAVApp",
        "Install-NAVApp",
    };

    public static int Run(ParsedArgs a)
    {
        Paths.UsePlatform(a.Get("platform"));
        var info = Paths.ReadPlatformInfo();
        Log.Info($"Platform artifact: {Paths.PlatformRoot}");
        Log.Info($"Version {info.Version} (country {info.Country}).");

        var service = Paths.ServiceFolder();
        Log.Info($"Service tier binaries: {service}");

        var webClient = Paths.WebClientFolderOrNull();
        Log.Info(webClient != null ? $"Web client binaries: {webClient}" : "Web client binaries: (none)");

        var mgmt = Paths.ManagementModuleDir();
        Log.Info($"Management modules: {mgmt}");

        Log.Info("Importing BC management modules in-process...");
        using var rs = new NavRunspace();
        rs.ImportManagementModules();

        var missing = new List<string>();
        foreach (var cmdlet in RequiredCmdlets)
        {
            if (!CommandExists(rs, cmdlet)) missing.Add(cmdlet);
        }

        if (missing.Count > 0)
        {
            throw new BcDevEnvException(
                $"Platform artifact '{info.Version}' is missing required cmdlets: {string.Join(", ", missing)}.");
        }

        Log.Success(
            $"Artifact OK: version {info.Version} exposes all {RequiredCmdlets.Length} cmdlets needed to " +
            "create a container database + server instance and install an app.");
        return 0;
    }

    private static bool CommandExists(NavRunspace rs, string command)
    {
        var result = rs.InvokeScalar($"[bool](Get-Command -Name '{command}' -ErrorAction SilentlyContinue)");
        return result?.BaseObject is bool b && b;
    }
}
