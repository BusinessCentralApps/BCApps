using BcDevEnv.Cli.Cli;
using BcDevEnv.Cli.Infra;
using BcDevEnv.Cli.Nav;

namespace BcDevEnv.Cli.Commands;

/// <summary>
/// set-password: runs INSIDE a running NavUserPassword container. Sets the password of the image's
/// SUPER user from an environment variable, so the password exists only in the running container's
/// server database - never in the image, its history or the container's configuration
/// (pass it with a name-only 'docker exec -e BCDEVENV_ADMIN_PASSWORD').
/// </summary>
public static class SetPasswordCommand
{
    public const string ManifestPath = @"C:\bcdevenv\build-manifest.json";

    public static int Run(ParsedArgs a)
    {
        var passwordVariable = a.GetOr("password-env", AuthenticationNames.PasswordVariable);
        var password = Environment.GetEnvironmentVariable(passwordVariable);
        if (string.IsNullOrEmpty(password))
            throw new BcDevEnvException($"The environment variable '{passwordVariable}' that holds the password is not set or empty.");

        var manifest = File.Exists(ManifestPath) ? BuildManifest.Load(ManifestPath) : null;
        var userName = ResolveUserName(a.Get("user"), manifest);
        var instance = a.GetOr("server-instance",
            Environment.GetEnvironmentVariable("BCDEVENV_INSTANCE") ?? manifest?.ServerInstance ?? "BC");

        using var rs = new NavRunspace();
        var server = new NavServerService(rs);
        ServeCommand.WaitUntilRunning(server, instance, TimeSpan.FromMinutes(10));

        using var secure = AuthenticationNames.ToSecureString(password);
        var deadline = DateTime.UtcNow + TimeSpan.FromMinutes(5);
        while (true)
        {
            try
            {
                server.SetUserPassword(instance, userName, secure);
                break;
            }
            catch (BcDevEnvException ex) when (DateTime.UtcNow < deadline)
            {
                // The management endpoint can lag behind the service state right after start.
                Log.Warn($"Setting the password of '{userName}' failed, retrying: {ex.Message}");
                Thread.Sleep(TimeSpan.FromSeconds(10));
            }
        }
        Log.Success($"Set the password of user '{userName}' on '{instance}'.");
        return 0;
    }

    /// <summary>--user, else the image's NavUserPassword user, else admin; a Windows image has none.</summary>
    public static string ResolveUserName(string? user, BuildManifest? manifest)
    {
        if (!string.IsNullOrWhiteSpace(user)) return user.Trim();
        if (manifest != null && !AuthenticationNames.IsUserPassword(manifest.CredentialType))
            throw new BcDevEnvException(
                $"The image uses {manifest.CredentialType} authentication, which has no user name/password user. Build it with --credential-type NavUserPassword.");
        return string.IsNullOrWhiteSpace(manifest?.AdminUserName) ? AuthenticationNames.DefaultAdminUserName : manifest!.AdminUserName!.Trim();
    }
}
