using BcDevEnv.Cli.Cli;
using BcDevEnv.Cli.Infra;
using BcDevEnv.Cli.Nav;

namespace BcDevEnv.Cli.Commands;

/// <summary>
/// provision: runs INSIDE the image at build time. Restores the staged .bak, registers +
/// configures the NST from the baked binaries, imports the license, and installs bake-time apps.
/// </summary>
public static class ProvisionCommand
{
    public static int Run(ParsedArgs a)
    {
        var contextDir = a.GetOr("context", Environment.CurrentDirectory);
        var manifest = BuildManifest.Load(Path.Combine(contextDir, "build-manifest.json"));

        var sqlServer = Environment.GetEnvironmentVariable("BCDEVENV_SQL_SERVER") ?? "localhost";
        var sqlInstance = Environment.GetEnvironmentVariable("BCDEVENV_SQL_INSTANCE") ?? "SQLEXPRESS";
        var dataDir = Environment.GetEnvironmentVariable("BCDEVENV_DATA_DIR");

        var sql = new SqlDatabaseService(sqlServer, sqlInstance);

        // 1. Restore the database.
        var bak = Path.Combine(contextDir, "db", manifest.BakFile);
        sql.Drop(manifest.DatabaseName);
        sql.RestoreFromBak(manifest.DatabaseName, bak, dataDir);

        // 1b. The NST runs as NT AUTHORITY\NETWORK SERVICE; grant it SQL access so the server
        //     can open the database when it starts (otherwise Start-NAVServerInstance fails).
        sql.EnsureSysadminLogin("NT AUTHORITY\\NETWORK SERVICE");

        // 2. Register + configure the server instance from the baked binaries.
        using var rs = new NavRunspace();
        var server = new NavServerService(rs);

        if (!server.InstanceExists(manifest.ServerInstance))
        {
            server.NewInstance(manifest.ServerInstance, sqlServer, sqlInstance, manifest.DatabaseName,
                new NavServerService.ServerPorts());
        }

        // The BC server takes the host and the SQL instance as SEPARATE settings
        // (DatabaseServer=host, DatabaseInstance=instance). Writing the combined
        // "host\instance" into DatabaseServer while DatabaseInstance is also set makes the
        // server build an invalid "host\instance\instance" target and fail to connect to SQL.
        server.SetConfiguration(manifest.ServerInstance, "DatabaseServer", sqlServer);
        server.SetConfiguration(manifest.ServerInstance, "DatabaseInstance", sqlInstance ?? string.Empty);
        server.SetConfiguration(manifest.ServerInstance, "DatabaseName", manifest.DatabaseName);
        server.SetConfiguration(manifest.ServerInstance, "DeveloperServicesEnabled", true);
        server.SetConfiguration(manifest.ServerInstance, "ODataServicesEnabled", true);
        server.SetConfiguration(manifest.ServerInstance, "ApiServicesEnabled", true);
        server.SetConfiguration(manifest.ServerInstance, "UsePermissionSetsFromExtensions", true);
        server.SetConfiguration(manifest.ServerInstance, "ClientServicesCredentialType", manifest.CredentialType);

        // Test-run settings (as AL-Go's NewBcContainer sets them for test containers) and a per-call
        // OData ceiling high enough for the largest test codeunit. Best-effort: older platforms may
        // not know every key.
        foreach (var (key, value) in TestServerSettings)
        {
            try { server.SetConfiguration(manifest.ServerInstance, key, value); }
            catch (Exception ex) { Log.Warn($"Could not set server setting '{key}': {ex.Message}"); }
        }

        // Settings requested at build-image time (--server-setting) are strict: a pipeline that asks
        // for e.g. EnableTaskScheduler=false depends on it.
        foreach (var (key, value) in manifest.ServerSettings)
        {
            Log.Info($"Server setting {key}={value}");
            server.SetConfiguration(manifest.ServerInstance, key, value);
        }

        // 3. Start the server, then do everything that needs a running, licensed NST:
        //    import the license (Import-NAVServerLicense talks to the running management API),
        //    install the apps, and create the test company + user. The empty-image path (no
        //    license and no apps) needs none of this, so the server is only started when required.
        var licensePath = string.IsNullOrWhiteSpace(manifest.LicenseFile)
            ? null
            : Path.Combine(contextDir, "license", manifest.LicenseFile);
        var needRunning = (licensePath != null && File.Exists(licensePath)) || manifest.AppFiles.Count > 0;
        var licenseImported = false;

        if (needRunning)
        {
            try
            {
                server.Start(manifest.ServerInstance);

                // License first - a BC server refuses app operations until it is licensed.
                if (licensePath != null && File.Exists(licensePath))
                {
                    server.ImportLicense(manifest.ServerInstance, licensePath);
                    licenseImported = true;
                }
                else
                {
                    Log.Warn("No license file in the build context; using the platform's built-in license.");
                }

                // Bring the freshly created platform database to the operational state before any
                // extension is synchronized (otherwise Sync-NAVApp reports the DB is not synced).
                server.SyncTenant(manifest.ServerInstance);

                // Install the apps (publish + sync + install) into the database, in manifest order.
                var appSvc = new NavAppService(rs);
                var index = 0;
                foreach (var leaf in manifest.AppFiles)
                {
                    index++;
                    Log.Info($"[{index}/{manifest.AppFiles.Count}] Installing '{leaf}'...");
                    appSvc.PublishSyncInstall(manifest.ServerInstance, Path.Combine(contextDir, "apps", leaf));
                }

                // A company (initialized with all installed apps, plus any requested demo-data
                // codeunits) + an authorized user so the OData test runner can execute.
                ProvisionTestContext(server, manifest);

                server.Stop(manifest.ServerInstance);
            }
            catch (Exception ex)
            {
                Log.Error($"Bake-time provisioning failed: {ex.Message}");
                var hint = LicenseHint(ex.Message, licenseImported);
                if (hint != null) Log.Error(hint);
                DumpServerDiagnostics(manifest.ServerInstance);
                throw;
            }
        }

        Log.Success($"Provisioned server instance '{manifest.ServerInstance}'.");
        return 0;
    }

    private static readonly (string Key, string Value)[] TestServerSettings =
    {
        ("EnforceUserPathForAlFileOperations", "false"),
        ("NavHttpClientAntiSSRFEnabled", "false"),
        ("ODataServicesOperationTimeout", "04:00:00"),
    };

    /// <summary>
    /// A licensing-specific explanation for a provisioning error, or null when the error does not
    /// look license related.
    /// </summary>
    public static string? LicenseHint(string errorMessage, bool licenseImported)
    {
        if (errorMessage.IndexOf("licen", StringComparison.OrdinalIgnoreCase) < 0) return null;
        return licenseImported
            ? "The error is license related: the imported license does not permit this operation (check its object ranges and expiry)."
            : "The error is license related and no license was imported, so the platform's built-in license was used. " +
              "Provide a license file (build-image --license / BCDEVENV_LICENSE) that covers these apps.";
    }

    /// <summary>
    /// Creates the company + SUPER user the live OData test run needs, then runs the requested
    /// company codeunits (Company-Initialize, demo data) in order. Every step is strict: tests run
    /// in a missing or half-initialized company would only fail later with misleading errors.
    /// </summary>
    private static void ProvisionTestContext(NavServerService server, BuildManifest manifest)
    {
        var instance = manifest.ServerInstance;
        var companyName = manifest.EffectiveCompanyName;
        server.CreateCompany(instance, companyName, manifest.EvaluationCompany);

        var account = Environment.UserName;
        if (string.IsNullOrWhiteSpace(account))
            throw new BcDevEnvException("Cannot create the SUPER user for the test run: the current Windows account name is empty.");
        server.CreateSuperUser(instance, account);

        foreach (var call in manifest.CompanyCodeunits)
            server.InvokeCodeunit(instance, companyName, call.CodeunitId, call.MethodName);
    }

    /// <summary>Best-effort dump of why the NST failed to start/serve during the build.</summary>
    private static void DumpServerDiagnostics(string instance)
    {
        var serviceName = $"MicrosoftDynamicsNavServer${instance}";
        try
        {
            Log.Info($"--- sc query {serviceName} ---");
            var (_, scOut, scErr) = ProcessRunner.Capture("sc.exe", new[] { "query", serviceName });
            Console.WriteLine(scOut + scErr);
        }
        catch { /* best effort */ }

        // The generated per-instance config - verify the root/key settings the server loads.
        try
        {
            var cfg = Path.Combine(Paths.ServiceFolderForProvision(), "Instances", instance, "CustomSettings.config");
            Log.Info($"--- {cfg} (head) ---");
            if (File.Exists(cfg))
                Console.WriteLine(string.Join(Environment.NewLine, File.ReadLines(cfg).Take(8)));
            else
                Console.WriteLine("(instance config not found)");
        }
        catch { /* best effort */ }

        // Broad event-log dump - a .NET startup crash shows up under 'Application Error' /
        // '.NET Runtime', and the Service Control Manager logs service-start failures in 'System'.
        try
        {
            Log.Info("--- recent Application/System event-log errors ---");
            var ps =
                "$ev = foreach ($log in 'Application','System') { " +
                "Get-WinEvent -FilterHashtable @{ LogName=$log; Level=1,2,3 } -MaxEvents 30 -ErrorAction SilentlyContinue | " +
                "Select-Object TimeCreated, @{n='Log';e={$log}}, ProviderName, Id, Message }; " +
                "$ev | Sort-Object TimeCreated | Select-Object -Last 30 | Format-List | Out-String -Width 500";
            var (_, evtOut, evtErr) = ProcessRunner.Capture("powershell.exe", new[] { "-NoProfile", "-Command", ps });
            Console.WriteLine(evtOut + evtErr);
        }
        catch { /* best effort */ }
    }
}
