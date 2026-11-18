using BcDevEnv.Cli.Cli;
using BcDevEnv.Cli.Infra;
using BcDevEnv.Cli.Nav;

namespace BcDevEnv.Cli.Commands;

/// <summary>
/// create-env: create a fresh, empty platform database from the platform artifact and produce a
/// .bak + manifest. This installs NO apps and NO demo data - the app set (which may include the
/// System/Base Application .app packages) is added separately with 'install-app' or at 'build-image'
/// time. Depends only on the platform artifact (no NAV enlistment).
/// </summary>
public static class CreateEnvCommand
{
    public static int Run(ParsedArgs a)
    {
        Paths.UsePlatform(a.Get("platform"));
        var platform = Paths.ReadPlatformInfo();

        var country = a.GetOr("country", platform.Country);
        var versionLabel = platform.Version;
        var name = a.Get("name") ?? $"{country}-{versionLabel}".Replace('.', '_');
        var dbName = a.GetOr("database-name", "BC");
        var collation = a.Get("collation");
        var dataDir = a.Get("data-dir") ?? Environment.GetEnvironmentVariable("BCDEVENV_DATA_DIR");

        var sqlServer = a.Get("sql-server") ?? Environment.GetEnvironmentVariable("BCDEVENV_SQL_SERVER") ?? "localhost";
        var sqlInstance = a.Get("sql-instance") ?? Environment.GetEnvironmentVariable("BCDEVENV_SQL_INSTANCE");
        var dbServer = string.IsNullOrWhiteSpace(sqlInstance) ? sqlServer : $"{sqlServer}\\{sqlInstance}";

        var envPath = Paths.EnvPath(name);
        Directory.CreateDirectory(envPath);

        Log.Info($"Creating environment '{name}' (country={country}, platform={versionLabel}, db='{dbName}' on '{dbServer}')");

        // 1. Create a fresh empty platform database (New-NAVApplicationDatabase, from the artifact).
        var sql = new SqlDatabaseService(sqlServer, sqlInstance);
        sql.Drop(dbName);
        using (var rs = new NavRunspace())
        {
            var server = new NavServerService(rs);
            server.NewApplicationDatabase(dbServer, dbName, dataDir, collation);
        }

        // 2. Produce a .bak of the freshly created database (pure ADO.NET - no cmdlet).
        var output = a.Get("output") ?? Path.Combine(envPath, $"{dbName}.bak");
        sql.BackupToBak(dbName, output);

        // 3. Record the manifest.
        var manifest = new EnvManifest
        {
            Name = name,
            Country = country,
            PlatformVersion = versionLabel,
            PlatformArtifact = Paths.PlatformRoot,
            DatabaseName = dbName,
            Bak = output,
            CreatedUtc = DateTime.UtcNow.ToString("o"),
        };
        manifest.Save(envPath);

        Log.Success($"Environment '{name}' created. Backup: {output}");
        Log.Info("Next: 'bcdevenv install-app' to add apps, or 'bcdevenv build-image' to containerize.");
        return 0;
    }
}
