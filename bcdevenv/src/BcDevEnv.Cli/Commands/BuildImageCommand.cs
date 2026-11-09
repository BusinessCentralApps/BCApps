using BcDevEnv.Cli.Cli;
using BcDevEnv.Cli.Infra;
using BcDevEnv.Cli.Nav;

namespace BcDevEnv.Cli.Commands;

/// <summary>
/// build-image: stage the .bak + platform Service/WebClient binaries (from the artifact) + license
/// + the CLI itself into a Docker build context and run 'docker build'. Depends only on the
/// platform artifact.
/// </summary>
public static class BuildImageCommand
{
    private const string DefaultBaseImage = "mcr.microsoft.com/windows/servercore:ltsc2022";

    public static int Run(ParsedArgs a)
    {
        Docker.RequireWindowsContainers();

        var envName = a.Get("env");
        EnvManifest? manifest = envName != null ? EnvManifest.Load(Paths.EnvPath(envName)) : null;

        // Platform artifact: explicit flag, else the one recorded in the env manifest, else env var.
        Paths.UsePlatform(a.Get("platform") ?? manifest?.PlatformArtifact);
        var platform = Paths.ReadPlatformInfo();

        var country = a.GetOr("country", manifest?.Country ?? platform.Country);
        // Fail before staging when provisioning could not set the application family.
        var applicationFamily = NavServerService.ApplicationFamilyFor(country);
        var platformVersion = manifest?.PlatformVersion ?? platform.Version;
        var bak = a.Get("bak") ?? manifest?.Bak
                  ?? throw new BcDevEnvException("No .bak available. Pass --env or --bak.");
        if (!File.Exists(bak)) throw new BcDevEnvException($"Backup not found: '{bak}'.");

        var dbName = manifest?.DatabaseName ?? Path.GetFileNameWithoutExtension(bak);
        var serverInstance = a.GetOr("server-instance", manifest?.ServerInstance ?? "BC");
        var credentialType = a.GetOr("credential-type", "Windows");
        var baseImage = a.GetOr("base-image", DefaultBaseImage);
        var tag = a.Get("tag") ?? $"bcdevenv:{platformVersion}-{country}".ToLowerInvariant().Replace('.', '_');
        var registry = a.Get("registry");
        if (!string.IsNullOrWhiteSpace(registry)) tag = $"{registry.TrimEnd('/')}/{tag}";

        var toolRoot = ToolRoot();

        // License + bake-time apps are resolved up front so that an image that cannot be provisioned
        // fails before anything is staged.
        var license = a.Get("license") ?? Environment.GetEnvironmentVariable("BCDEVENV_LICENSE");
        if (!string.IsNullOrWhiteSpace(license) && !File.Exists(license))
            throw new BcDevEnvException($"License file not found: '{license}'.");
        var appFiles = NavAppService.ResolveAppFiles(a.GetAll("app-file").Concat(ReadAppList(a.Get("app-list"))));
        var licenseWarning = CheckLicense(
            hasLicense: !string.IsNullOrWhiteSpace(license),
            emptyDatabase: manifest != null && a.Get("bak") == null,
            appCount: appFiles.Count);

        var context = Path.Combine(manifest != null ? Paths.EnvPath(manifest.Name) : Path.GetTempPath(), "image-context");
        PrepareCleanDir(context);

        // 1. Dockerfile + the files its early layers COPY.
        var dockerfile = StageContainerFiles(toolRoot, context);

        // 2. Database backup.
        var dbDir = Path.Combine(context, "db");
        Directory.CreateDirectory(dbDir);
        var bakLeaf = Path.GetFileName(bak);
        File.Copy(bak, Path.Combine(dbDir, bakLeaf), overwrite: true);

        // 3. Platform binaries (Service + WebClient) - straight from the artifact.
        var serviceFolder = Environment.GetEnvironmentVariable("BCDEVENV_SERVICE_FOLDER") ?? Paths.ServiceFolder();
        var webClientFolder = Environment.GetEnvironmentVariable("BCDEVENV_WEBCLIENT_FOLDER") ?? Paths.WebClientFolderOrNull();
        Log.Info($"Staging service binaries from '{serviceFolder}'...");
        CopyDirectory(serviceFolder, Path.Combine(context, "binaries", "Service"));
        if (!string.IsNullOrWhiteSpace(webClientFolder) && Directory.Exists(webClientFolder))
        {
            Log.Info($"Staging web client binaries from '{webClientFolder}'...");
            CopyDirectory(webClientFolder, Path.Combine(context, "binaries", "WebClient"));
        }

        // 3b. Stage the platform's test mock assemblies (MockTest.dll, ...) into the server's
        // Add-Ins folder. The test libraries reference them via DotNet, and the server recompiles
        // each extension on Publish-NAVApp - without them publish fails with AL0451 (MockTest not
        // found). They ship OUTSIDE the Service folder (platform\Test Assemblies\Mock Assemblies).
        StageTestMockAssemblies(Path.Combine(context, "binaries", "Service", "Add-Ins"));

        // 4. License (optional, see CheckLicense).
        string? licenseLeaf = null;
        if (!string.IsNullOrWhiteSpace(license))
        {
            var licDir = Path.Combine(context, "license");
            Directory.CreateDirectory(licDir);
            licenseLeaf = Path.GetFileName(license);
            File.Copy(license, Path.Combine(licDir, licenseLeaf), overwrite: true);
        }

        // 5. Bake-time apps (.app files only), installed in the order given.
        var appLeaves = new List<string>();
        if (appFiles.Count > 0)
        {
            var appDir = Path.Combine(context, "apps");
            Directory.CreateDirectory(appDir);
            appLeaves.AddRange(StagedAppLeaves(appFiles));
            for (var i = 0; i < appFiles.Count; i++)
                File.Copy(appFiles[i], Path.Combine(appDir, appLeaves[i]), overwrite: true);
            Log.Info($"Staged {appLeaves.Count} app(s) for bake-time install.");
        }

        // 6. The bcdevenv CLI itself (self-contained), used for provision + serve inside the image.
        PublishCli(toolRoot, Path.Combine(context, "cli"));

        // 7. Build manifest consumed by 'bcdevenv provision' inside the image.
        new BuildManifest
        {
            Country = country,
            PlatformVersion = platformVersion,
            DatabaseName = dbName,
            ServerInstance = serverInstance,
            BakFile = bakLeaf,
            LicenseFile = licenseLeaf,
            CredentialType = credentialType,
            AppFiles = appLeaves,
            CompanyName = a.Get("company"),
            EvaluationCompany = a.Flag("evaluation-company"),
            CompanyCodeunits = a.GetAll("company-codeunit").Select(CompanyCodeunitCall.Parse).ToList(),
            CompanyCodeunitTimeoutMinutes = BuildManifest.ParseCompanyCodeunitTimeout(a.Get("company-codeunit-timeout")),
            ServerSettings = BuildManifest.ParseServerSettings(a.GetAll("server-setting")),
        }.Save(Path.Combine(context, "build-manifest.json"));

        if (licenseWarning != null) Log.Warn(licenseWarning);

        // 8. docker build.
        Log.Info($"Building image '{tag}' (base={baseImage}, application family {applicationFamily})...");
        var code = Docker.Build(tag, context, dockerfile, new Dictionary<string, string> { ["BASE_IMAGE"] = baseImage });
        if (code != 0) throw new BcDevEnvException($"docker build failed (exit {code}).");
        Log.Success($"Built image '{tag}'.");

        if (a.Flag("push"))
        {
            Log.Info($"Pushing '{tag}'...");
            if (Docker.Push(tag) != 0) throw new BcDevEnvException("docker push failed.");
            Log.Success($"Pushed '{tag}'.");
        }
        return 0;
    }

    /// <summary>Files from the tool's container folder that the Dockerfile COPYs from the context root.</summary>
    public static readonly string[] ContainerSetupFiles = { "Install-SqlExpress.ps1" };

    /// <summary>
    /// Copies the Dockerfile and the setup scripts its early (cached) layers COPY into the context
    /// root; returns the staged Dockerfile path.
    /// </summary>
    public static string StageContainerFiles(string toolRoot, string context)
    {
        var containerDir = Path.Combine(toolRoot, "container");
        foreach (var leaf in ContainerSetupFiles.Prepend("Dockerfile"))
        {
            var source = Path.Combine(containerDir, leaf);
            if (!File.Exists(source)) throw new BcDevEnvException($"Container file not found: '{source}'.");
            File.Copy(source, Path.Combine(context, leaf), overwrite: true);
        }
        return Path.Combine(context, "Dockerfile");
    }

    /// <summary>
    /// Business Central refuses to publish apps without a license, and the database of a create-env
    /// environment (an empty platform database) holds none: baking apps into it without --license
    /// fails here instead of deep inside 'docker build'. Otherwise returns the warning to log when
    /// no license is baked (null when one is).
    /// </summary>
    public static string? CheckLicense(bool hasLicense, bool emptyDatabase, int appCount)
    {
        if (hasLicense) return null;
        if (emptyDatabase && appCount > 0)
            throw new BcDevEnvException(
                $"No license to bake: the environment's database is an empty platform database (create-env) that holds no license, " +
                $"and Business Central does not publish the {appCount} bake-time app(s) without one. Pass --license (or set " +
                "BCDEVENV_LICENSE), e.g. the CRONUS license (Cronus.bclicense) of a Business Central application artifact.");
        return emptyDatabase
            ? "No license baked into the image; the empty create-env database holds none, so apps cannot be published into the container."
            : "No license baked into the image; provisioning relies on a license already stored in the database backup.";
    }

    /// <summary>Reads an --app-list file: one .app path per line; blank lines and '#' comments are ignored.</summary>
    public static IReadOnlyList<string> ReadAppList(string? listFile)
    {
        if (string.IsNullOrWhiteSpace(listFile)) return Array.Empty<string>();
        if (!File.Exists(listFile)) throw new BcDevEnvException($"App list file not found: '{listFile}'.");
        return File.ReadAllLines(listFile)
            .Select(l => l.Trim())
            .Where(l => l.Length > 0 && !l.StartsWith('#'))
            .ToList();
    }

    /// <summary>
    /// File names the apps are staged under in the flat image context. Two different files with the
    /// same name would silently overwrite each other, so that is an error.
    /// </summary>
    public static IReadOnlyList<string> StagedAppLeaves(IReadOnlyList<string> appFiles)
    {
        var seen = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        var leaves = new List<string>();
        foreach (var file in appFiles)
        {
            var leaf = Path.GetFileName(file);
            if (seen.TryGetValue(leaf, out var other))
                throw new BcDevEnvException($"Two app files share the name '{leaf}': '{other}' and '{file}'.");
            seen[leaf] = file;
            leaves.Add(leaf);
        }
        return leaves;
    }

    /// <summary>
    /// Resolves the tool folder (the one holding container\Dockerfile and src\BcDevEnv.Cli).
    /// Derived from the running executable so the tool works when copied into a standalone repo;
    /// override with BCDEVENV_TOOL_ROOT.
    /// </summary>
    private static string ToolRoot()
    {
        var overridePath = Environment.GetEnvironmentVariable("BCDEVENV_TOOL_ROOT");
        if (!string.IsNullOrWhiteSpace(overridePath) && Directory.Exists(overridePath)) return overridePath;

        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir != null)
        {
            if (File.Exists(Path.Combine(dir.FullName, "container", "Dockerfile")) &&
                Directory.Exists(Path.Combine(dir.FullName, "src", "BcDevEnv.Cli")))
            {
                return dir.FullName;
            }
            dir = dir.Parent;
        }
        throw new BcDevEnvException(
            "Could not locate the bcdevenv tool root (folder with container\\Dockerfile and " +
            "src\\BcDevEnv.Cli). Set BCDEVENV_TOOL_ROOT.");
    }

    private static void PublishCli(string toolRoot, string outDir)
    {
        var csproj = Path.Combine(toolRoot, "src", "BcDevEnv.Cli", "BcDevEnv.Cli.csproj");
        if (!File.Exists(csproj))
            throw new BcDevEnvException($"CLI project not found for publishing: '{csproj}'.");
        Log.Info("Publishing bcdevenv CLI into the image context...");
        var code = ProcessRunner.Run("dotnet", new[]
        {
            "publish", csproj, "-c", "Release", "-r", "win-x64", "--self-contained", "true",
            "-p:PublishSingleFile=false", "-o", outDir,
        });
        if (code != 0) throw new BcDevEnvException($"dotnet publish failed (exit {code}).");
    }

    private static void PrepareCleanDir(string dir)
    {
        if (Directory.Exists(dir)) Directory.Delete(dir, recursive: true);
        Directory.CreateDirectory(dir);
    }

    /// <summary>
    /// Copies the platform's test mock assemblies (e.g. MockTest.dll) into the staged server
    /// Add-Ins folder so server-side extension compilation can resolve the DotNet references the
    /// test libraries declare. They live under &lt;platform&gt;\Test Assemblies\Mock Assemblies.
    /// </summary>
    private static void StageTestMockAssemblies(string addInsDir)
    {
        if (Paths.PlatformRootOrNull == null) return;
        var mockDir = Path.Combine(Paths.PlatformRoot, "Test Assemblies", "Mock Assemblies");
        if (!Directory.Exists(mockDir))
            mockDir = Directory.EnumerateDirectories(Paths.PlatformRoot, "Mock Assemblies", SearchOption.AllDirectories).FirstOrDefault();
        if (mockDir == null || !Directory.Exists(mockDir))
        {
            Log.Warn("Test mock assemblies folder not found; test libraries referencing MockTest may fail to publish.");
            return;
        }
        Directory.CreateDirectory(addInsDir);
        foreach (var dll in Directory.GetFiles(mockDir, "*.dll"))
            File.Copy(dll, Path.Combine(addInsDir, Path.GetFileName(dll)), overwrite: true);
        Log.Info($"Staged test mock assemblies from '{mockDir}' into Service\\Add-Ins.");
    }

    private static void CopyDirectory(string source, string dest)
    {
        if (!Directory.Exists(source))
            throw new BcDevEnvException($"Source folder to stage not found: '{source}'.");
        Directory.CreateDirectory(dest);
        // robocopy is far faster than a managed walk for large binary trees; exit codes < 8 are success.
        var code = ProcessRunner.Run("robocopy", new[] { source, dest, "/E", "/NFL", "/NDL", "/NJH", "/NJS", "/NP", "/R:1", "/W:1" });
        if (code >= 8) throw new BcDevEnvException($"robocopy failed copying '{source}' -> '{dest}' (exit {code}).");
    }
}
