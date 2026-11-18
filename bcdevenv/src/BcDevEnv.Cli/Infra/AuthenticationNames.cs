using System.Security;
using System.Security.Cryptography;

namespace BcDevEnv.Cli.Infra;

/// <summary>
/// Authentication names shared by build-image (--credential-type), provision and run-tests (--auth).
/// The server setting ClientServicesCredentialType calls user name/password authentication
/// NavUserPassword; clients (Basic auth, the AL tool's --authentication) call it UserPassword.
/// Both commands accept either name.
/// </summary>
public static class AuthenticationNames
{
    public const string Windows = "Windows";

    /// <summary>Server name (ClientServicesCredentialType, build-image --credential-type).</summary>
    public const string NavUserPassword = "NavUserPassword";

    /// <summary>Client name (run-tests --auth, the AL tool's --authentication).</summary>
    public const string UserPassword = "UserPassword";

    /// <summary>The SUPER user build-image creates for NavUserPassword images unless --admin-user names another.</summary>
    public const string DefaultAdminUserName = "admin";

    /// <summary>Environment variable that set-password and run-tests read the password from by default.</summary>
    public const string PasswordVariable = "BCDEVENV_ADMIN_PASSWORD";

    /// <summary>True for UserPassword / NavUserPassword (case-insensitive, trimmed).</summary>
    public static bool IsUserPassword(string? value)
    {
        var trimmed = value?.Trim();
        return string.Equals(trimmed, UserPassword, StringComparison.OrdinalIgnoreCase) ||
               string.Equals(trimmed, NavUserPassword, StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>Server credential type: Windows (default) or NavUserPassword.</summary>
    public static string ServerCredentialType(string? value, string option = "--credential-type") =>
        Normalize(value, option) == Windows ? Windows : NavUserPassword;

    /// <summary>Client authentication: Windows (default) or UserPassword.</summary>
    public static string ClientAuthentication(string? value, string option = "--auth") =>
        Normalize(value, option) == Windows ? Windows : UserPassword;

    private static string Normalize(string? value, string option)
    {
        if (string.IsNullOrWhiteSpace(value)) return Windows;
        if (string.Equals(value.Trim(), Windows, StringComparison.OrdinalIgnoreCase)) return Windows;
        if (IsUserPassword(value)) return UserPassword;
        throw new BcDevEnvException($"Unknown {option} '{value}'. Use Windows or NavUserPassword (UserPassword is accepted as the same).");
    }

    /// <summary>
    /// A random password that meets the server's password policy (upper and lower case letters, digits
    /// and symbols; 32 characters). Used for the provisioning-time password of the NavUserPassword user,
    /// which is never stored or printed.
    /// </summary>
    public static string NewRandomPassword(int length = 32)
    {
        const string upper = "ABCDEFGHJKLMNPQRSTUVWXYZ";
        const string lower = "abcdefghijkmnopqrstuvwxyz";
        const string digits = "23456789";
        const string symbols = "-_.!";
        if (length < 8) throw new ArgumentOutOfRangeException(nameof(length), "The password must have at least 8 characters.");

        var all = upper + lower + digits + symbols;
        var chars = new char[length];
        chars[0] = upper[RandomNumberGenerator.GetInt32(upper.Length)];
        chars[1] = lower[RandomNumberGenerator.GetInt32(lower.Length)];
        chars[2] = digits[RandomNumberGenerator.GetInt32(digits.Length)];
        chars[3] = symbols[RandomNumberGenerator.GetInt32(symbols.Length)];
        for (var i = 4; i < length; i++) chars[i] = all[RandomNumberGenerator.GetInt32(all.Length)];
        RandomNumberGenerator.Shuffle(chars.AsSpan());
        return new string(chars);
    }

    public static SecureString ToSecureString(string value)
    {
        var secure = new SecureString();
        foreach (var c in value) secure.AppendChar(c);
        secure.MakeReadOnly();
        return secure;
    }
}
