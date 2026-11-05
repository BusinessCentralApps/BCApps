using BcDevEnv.Cli.Cli;
using BcDevEnv.Cli.Infra;
using BcDevEnv.Cli.Nav;

namespace BcDevEnv.Cli.Commands;

/// <summary>
/// serve: the container ENTRYPOINT. Starts SQL + the NST and keeps the container alive,
/// restarting the NST if it stops.
/// </summary>
public static class ServeCommand
{
    public static int Run(ParsedArgs a)
    {
        if (!string.Equals(Environment.GetEnvironmentVariable("ACCEPT_EULA"), "Y", StringComparison.OrdinalIgnoreCase))
        {
            Log.Error("You must accept the EULA by passing -e ACCEPT_EULA=Y to 'docker run'.");
            return 1;
        }

        var sqlInstance = Environment.GetEnvironmentVariable("BCDEVENV_SQL_INSTANCE") ?? "SQLEXPRESS";
        var instance = a.GetOr("server-instance", Environment.GetEnvironmentVariable("BCDEVENV_INSTANCE") ?? "BC");

        // 1. Start SQL Server (native service control, not PowerShell).
        StartSqlService(sqlInstance);

        // 2. Start the NST.
        using var rs = new NavRunspace();
        var server = new NavServerService(rs);
        server.Start(instance);
        WaitUntilRunning(server, instance, TimeSpan.FromMinutes(5));
        Log.Success($"Server instance '{instance}' is running.");

        // 3. Keep the container alive; restart the NST if it stops.
        while (true)
        {
            Thread.Sleep(TimeSpan.FromSeconds(30));
            try
            {
                if (!server.IsRunning(instance))
                {
                    Log.Warn($"Server instance '{instance}' is not running; restarting...");
                    server.Start(instance);
                }
            }
            catch (Exception ex)
            {
                Log.Warn($"Health check failed: {ex.Message}");
            }
        }
    }

    private static void StartSqlService(string sqlInstance)
    {
        var serviceName = sqlInstance.Equals("MSSQLSERVER", StringComparison.OrdinalIgnoreCase)
            ? "MSSQLSERVER"
            : $"MSSQL${sqlInstance}";
        Log.Info($"Starting SQL service '{serviceName}'...");
        // 'sc start' returns immediately; a non-zero code when already running is fine.
        ProcessRunner.Run("sc", new[] { "start", serviceName });
        // Full-Text Search (BC's text-optimized indexes); absent on engine-only instances, which is fine.
        var fullTextServiceName = sqlInstance.Equals("MSSQLSERVER", StringComparison.OrdinalIgnoreCase)
            ? "MSSQLFDLauncher"
            : $"MSSQLFDLauncher${sqlInstance}";
        ProcessRunner.Run("sc", new[] { "start", fullTextServiceName });
        Thread.Sleep(TimeSpan.FromSeconds(5));
    }

    private static void WaitUntilRunning(NavServerService server, string instance, TimeSpan timeout)
    {
        var deadline = DateTime.UtcNow + timeout;
        while (DateTime.UtcNow < deadline)
        {
            try { if (server.IsRunning(instance)) return; }
            catch { /* instance may not be queryable yet */ }
            Thread.Sleep(TimeSpan.FromSeconds(5));
        }
        throw new BcDevEnvException($"Server instance '{instance}' did not reach Running within {timeout}.");
    }
}
