namespace BcDevEnv.Cli.Infra;

/// <summary>Minimal leveled logger. Writes to stderr so stdout stays clean for any structured output.</summary>
public static class Log
{
    private static readonly object Gate = new();

    public static bool VerboseEnabled { get; set; } =
        string.Equals(Environment.GetEnvironmentVariable("BCDEVENV_VERBOSE"), "1", StringComparison.Ordinal);

    private static void Write(string level, ConsoleColor color, string message)
    {
        lock (Gate)
        {
            var prev = Console.ForegroundColor;
            try { Console.ForegroundColor = color; }
            catch { /* no console (redirected) */ }
            Console.Error.WriteLine($"[bcdevenv] {level,-5} {message}");
            try { Console.ForegroundColor = prev; } catch { /* ignore */ }
        }
    }

    public static void Info(string message) => Write("INFO", ConsoleColor.Cyan, message);
    public static void Success(string message) => Write("OK", ConsoleColor.Green, message);
    public static void Warn(string message) => Write("WARN", ConsoleColor.Yellow, message);
    public static void Error(string message) => Write("ERROR", ConsoleColor.Red, message);

    public static void Verbose(string message)
    {
        if (VerboseEnabled) Write("VERB", ConsoleColor.DarkGray, message);
    }
}
