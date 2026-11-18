namespace BcDevEnv.Cli.Infra;

/// <summary>Exception type for expected, user-facing failures (prints a clean message, no stack trace).</summary>
public sealed class BcDevEnvException : Exception
{
    public BcDevEnvException(string message) : base(message) { }
    public BcDevEnvException(string message, Exception? inner) : base(message, inner) { }
}
