using System.Text.Json;

namespace BcDevEnv.Cli.Infra;

/// <summary>
/// Filesystem + environment resolution. The tool depends ONLY on a BC platform artifact
/// (the folder produced/downloaded as e.g. platform_30.0.54604.0) - not on a NAV enlistment.
/// The artifact ships the pure-PowerShell BC management modules plus the Service + WebClient
/// binaries, which is everything the CLI needs.
/// </summary>
public static class Paths
{
    private static string? _platformRoot;

    /// <summary>The platform artifact root, resolved from --platform or BCDEVENV_PLATFORM.</summary>
    public static string? PlatformRootOrNull => _platformRoot;

    public static string PlatformRoot =>
        _platformRoot ?? throw new BcDevEnvException(
            "No platform artifact set. Pass --platform <dir> or set BCDEVENV_PLATFORM to the " +
            "platform artifact folder (e.g. C:\\...\\platform_30.0.54604.0).");

    /// <summary>
    /// Establishes the platform artifact for this process from an explicit path (flag) or
    /// BCDEVENV_PLATFORM. When <paramref name="required"/> is false and the modules are already
    /// resolvable via BCDEVENV_MGMT_DIR (inside the container), the artifact is optional.
    /// </summary>
    public static void UsePlatform(string? overridePath, bool required = true)
    {
        var path = overridePath ?? Environment.GetEnvironmentVariable("BCDEVENV_PLATFORM");
        if (!string.IsNullOrWhiteSpace(path))
        {
            if (!Directory.Exists(path))
                throw new BcDevEnvException($"Platform artifact folder not found: '{path}'.");
            _platformRoot = Path.GetFullPath(path);
            return;
        }
        if (required && string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable("BCDEVENV_MGMT_DIR")))
            throw new BcDevEnvException(
                "No platform artifact set. Pass --platform <dir> or set BCDEVENV_PLATFORM to the " +
                "platform artifact folder (e.g. C:\\...\\platform_30.0.54604.0).");
    }

    /// <summary>Service-tier binaries folder inside the artifact (contains the Admin\ mgmt modules).</summary>
    public static string ServiceFolder()
    {
        var navRoot = Path.Combine(PlatformRoot, "ServiceTier", "PFiles64", "Microsoft Dynamics NAV");
        if (!Directory.Exists(navRoot))
            throw new BcDevEnvException($"Service tier not found under the artifact: '{navRoot}'.");
        // The version-numbered subfolder (e.g. 300) varies by platform version.
        var versioned = Directory.GetDirectories(navRoot)
            .Select(d => Path.Combine(d, "Service"))
            .FirstOrDefault(Directory.Exists)
            ?? throw new BcDevEnvException($"No '<version>\\Service' folder under '{navRoot}'.");
        return versioned;
    }

    /// <summary>
    /// Resolves the service-tier binaries folder for provisioning, where the full platform artifact
    /// may not be mounted (e.g. inside the container). Order:
    ///   BCDEVENV_SERVICE_FOLDER -> parent of BCDEVENV_MGMT_DIR (…\Service\Admin -> …\Service)
    ///   -> the artifact's ServiceFolder().
    /// </summary>
    public static string ServiceFolderForProvision()
    {
        var overrideFolder = Environment.GetEnvironmentVariable("BCDEVENV_SERVICE_FOLDER");
        if (!string.IsNullOrWhiteSpace(overrideFolder) &&
            File.Exists(Path.Combine(overrideFolder, "Microsoft.Dynamics.Nav.Server.exe")))
        {
            return overrideFolder;
        }

        var mgmt = Environment.GetEnvironmentVariable("BCDEVENV_MGMT_DIR");
        if (!string.IsNullOrWhiteSpace(mgmt))
        {
            var parent = Path.GetDirectoryName(mgmt.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar));
            if (parent != null && File.Exists(Path.Combine(parent, "Microsoft.Dynamics.Nav.Server.exe")))
                return parent;
        }

        if (PlatformRootOrNull != null) return ServiceFolder();

        throw new BcDevEnvException(
            "Could not locate the BC server binaries for provisioning. Set BCDEVENV_SERVICE_FOLDER, " +
            "BCDEVENV_MGMT_DIR, or --platform / BCDEVENV_PLATFORM.");
    }

    /// <summary>Web client binaries folder inside the artifact (optional).</summary>
    public static string? WebClientFolderOrNull()
    {
        var wc = Path.Combine(PlatformRoot, "WebClient");
        return Directory.Exists(wc) ? wc : null;
    }

    /// <summary>Root folder where per-environment artifacts (.bak + manifest.json) are stored.</summary>
    public static string Home
    {
        get
        {
            var overridePath = Environment.GetEnvironmentVariable("BCDEVENV_HOME");
            if (!string.IsNullOrWhiteSpace(overridePath)) return overridePath;
            var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            return Path.Combine(local, "bcdevenv");
        }
    }

    public static string EnvPath(string name) => Path.Combine(Home, name);

    /// <summary>
    /// Resolves the folder holding the BC management PowerShell modules
    /// (Microsoft.BusinessCentral.Management.psd1 + .Apps.Management.psd1).
    /// Order: BCDEVENV_MGMT_DIR (used inside the container) -> the artifact's Service\Admin.
    /// </summary>
    public static string ManagementModuleDir()
    {
        var mgmtOverride = Environment.GetEnvironmentVariable("BCDEVENV_MGMT_DIR");
        if (!string.IsNullOrWhiteSpace(mgmtOverride) &&
            File.Exists(Path.Combine(mgmtOverride, "Microsoft.BusinessCentral.Management.psd1")))
        {
            return mgmtOverride;
        }

        var admin = Path.Combine(ServiceFolder(), "Admin");
        if (File.Exists(Path.Combine(admin, "Microsoft.BusinessCentral.Management.psd1")))
            return admin;

        throw new BcDevEnvException(
            "Could not locate the BC management modules (Microsoft.BusinessCentral.Management.psd1). " +
            $"Looked in BCDEVENV_MGMT_DIR and '{admin}'. Set --platform / BCDEVENV_PLATFORM correctly.");
    }

    public static IReadOnlyList<string> ManagementModulePaths()
    {
        var dir = ManagementModuleDir();
        var names = new[]
        {
            "Microsoft.BusinessCentral.Management.psd1",
            "Microsoft.BusinessCentral.Apps.Management.psd1",
        };
        var paths = new List<string>();
        foreach (var name in names)
        {
            var p = Path.Combine(dir, name);
            if (File.Exists(p)) paths.Add(p);
        }
        if (paths.Count == 0)
            throw new BcDevEnvException($"No BC management modules found under '{dir}'.");
        return paths;
    }

    /// <summary>Platform artifact metadata (from the artifact's manifest.json).</summary>
    public sealed record PlatformInfo(string Version, string Country);

    public static PlatformInfo ReadPlatformInfo()
    {
        var manifest = Path.Combine(PlatformRoot, "manifest.json");
        if (!File.Exists(manifest))
            return new PlatformInfo("unknown", "W1");
        using var doc = JsonDocument.Parse(File.ReadAllText(manifest));
        var root = doc.RootElement;
        var version = root.TryGetProperty("version", out var v) ? v.GetString() ?? "unknown" : "unknown";
        var country = root.TryGetProperty("country", out var c) ? c.GetString() ?? "W1" : "W1";
        return new PlatformInfo(version, country);
    }
}
