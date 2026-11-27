using Microsoft.Data.SqlClient;
using BcDevEnv.Cli.Infra;

namespace BcDevEnv.Cli.Nav;

/// <summary>
/// Database backup/restore/drop/exists done directly against SQL Server via ADO.NET.
/// These are plain T-SQL operations (RESTORE/BACKUP) and need no NAV cmdlet - this is the
/// "SQL steps done directly" half of the architecture.
/// </summary>
public sealed class SqlDatabaseService
{
    private readonly string _masterConnectionString;

    public SqlDatabaseService(string server, string? instance = null)
    {
        var dataSource = string.IsNullOrWhiteSpace(instance) ? server : $"{server}\\{instance}";
        _masterConnectionString = new SqlConnectionStringBuilder
        {
            DataSource = dataSource,
            InitialCatalog = "master",
            IntegratedSecurity = true,
            TrustServerCertificate = true,
            ConnectTimeout = 30,
        }.ConnectionString;
    }

    private SqlConnection Open()
    {
        var c = new SqlConnection(_masterConnectionString);
        c.Open();
        return c;
    }

    public bool DatabaseExists(string databaseName)
    {
        using var c = Open();
        using var cmd = new SqlCommand("SELECT database_id FROM sys.databases WHERE name = @n", c);
        cmd.Parameters.AddWithValue("@n", databaseName);
        return cmd.ExecuteScalar() != null;
    }

    public void Drop(string databaseName)
    {
        if (!DatabaseExists(databaseName)) return;
        var q = QuoteName(databaseName);
        using var c = Open();
        Exec(c, $"ALTER DATABASE {q} SET SINGLE_USER WITH ROLLBACK IMMEDIATE;");
        Exec(c, $"DROP DATABASE {q};");
        Log.Verbose($"Dropped database '{databaseName}'.");
    }

    /// <summary>Restores a .bak into <paramref name="databaseName"/>, relocating files into <paramref name="dataDir"/>.</summary>
    public void RestoreFromBak(string databaseName, string bakPath, string? dataDir)
    {
        if (!File.Exists(bakPath))
            throw new BcDevEnvException($"Backup file not found: '{bakPath}'.");
        dataDir ??= DefaultDataDir();
        Directory.CreateDirectory(dataDir);

        var moves = new List<string>();
        using (var c = Open())
        using (var cmd = new SqlCommand("RESTORE FILELISTONLY FROM DISK = @bak", c) { CommandTimeout = 0 })
        {
            cmd.Parameters.AddWithValue("@bak", bakPath);
            using var r = cmd.ExecuteReader();
            var i = 0;
            while (r.Read())
            {
                var logical = r.GetString(r.GetOrdinal("LogicalName"));
                var type = r.GetString(r.GetOrdinal("Type")); // 'D' data, 'L' log, 'F' fulltext
                var ext = type.Equals("L", StringComparison.OrdinalIgnoreCase) ? "ldf" : "mdf";
                var target = Path.Combine(dataDir, $"{databaseName}_{i}.{ext}");
                moves.Add($"MOVE N'{Escape(logical)}' TO N'{Escape(target)}'");
                i++;
            }
        }
        if (moves.Count == 0)
            throw new BcDevEnvException($"Backup '{bakPath}' contains no files (RESTORE FILELISTONLY returned nothing).");

        var sql = $"RESTORE DATABASE {QuoteName(databaseName)} FROM DISK = @bak WITH REPLACE, STATS = 5, {string.Join(", ", moves)};";
        using (var c = Open())
        using (var cmd = new SqlCommand(sql, c) { CommandTimeout = 0 })
        {
            cmd.Parameters.AddWithValue("@bak", bakPath);
            Log.Info($"Restoring '{databaseName}' from '{bakPath}'...");
            cmd.ExecuteNonQuery();
        }
        Log.Success($"Restored database '{databaseName}'.");
    }

    /// <summary>Backs up <paramref name="databaseName"/> to <paramref name="bakPath"/>.</summary>
    public void BackupToBak(string databaseName, string bakPath)
    {
        if (!DatabaseExists(databaseName))
            throw new BcDevEnvException($"Cannot back up '{databaseName}': database not found on the server.");
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(bakPath))!);

        // COMPRESSION is not available on SQL Express, so it is intentionally omitted.
        var sql = $"BACKUP DATABASE {QuoteName(databaseName)} TO DISK = @bak WITH INIT, FORMAT, STATS = 5;";
        using var c = Open();
        using var cmd = new SqlCommand(sql, c) { CommandTimeout = 0 };
        cmd.Parameters.AddWithValue("@bak", bakPath);
        Log.Info($"Backing up '{databaseName}' to '{bakPath}'...");
        cmd.ExecuteNonQuery();
        Log.Success($"Wrote backup '{bakPath}'.");
    }

    /// <summary>
    /// Ensures a Windows login exists for <paramref name="account"/> and is a member of the
    /// sysadmin server role. The BC server instance runs as NT AUTHORITY\NETWORK SERVICE, which
    /// has no login in a freshly-installed SQL Express; without this it cannot open the database
    /// and the NST fails to start. Acceptable for a throwaway dev/CI container.
    /// </summary>
    public void EnsureSysadminLogin(string account)
    {
        using var c = Open();
        using var cmd = new SqlCommand(
            $"IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = @acct) " +
            $"CREATE LOGIN {QuoteName(account)} FROM WINDOWS; " +
            $"ALTER SERVER ROLE sysadmin ADD MEMBER {QuoteName(account)};", c);
        cmd.Parameters.AddWithValue("@acct", account);
        cmd.ExecuteNonQuery();
        Log.Success($"Granted SQL sysadmin to '{account}'.");
    }

    private string DefaultDataDir()
    {
        using var c = Open();
        using var cmd = new SqlCommand(
            "SELECT CAST(SERVERPROPERTY('InstanceDefaultDataPath') AS nvarchar(4000))", c);
        var val = cmd.ExecuteScalar() as string;
        return string.IsNullOrWhiteSpace(val) ? Path.GetTempPath() : val;
    }

    private static void Exec(SqlConnection c, string sql)
    {
        using var cmd = new SqlCommand(sql, c) { CommandTimeout = 0 };
        cmd.ExecuteNonQuery();
    }

    private static string QuoteName(string name) => "[" + name.Replace("]", "]]") + "]";
    private static string Escape(string value) => value.Replace("'", "''");
}
