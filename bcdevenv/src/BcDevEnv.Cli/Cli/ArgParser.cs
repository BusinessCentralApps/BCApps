namespace BcDevEnv.Cli.Cli;

/// <summary>
/// Tiny, dependency-free argument parser. Flags are kebab-case (e.g. --platform-version).
/// Repeated flags accumulate (e.g. --app a --app b). Names in <c>switchNames</c> take no value.
/// Supports --key value and --key=value.
/// </summary>
public sealed class ParsedArgs
{
    private readonly Dictionary<string, List<string>> _values = new(StringComparer.OrdinalIgnoreCase);
    private readonly HashSet<string> _switches = new(StringComparer.OrdinalIgnoreCase);
    private readonly List<string> _positional = new();

    public IReadOnlyList<string> Positional => _positional;

    public string? Get(string name) =>
        _values.TryGetValue(name, out var v) && v.Count > 0 ? v[^1] : null;

    public string GetOr(string name, string fallback) => Get(name) ?? fallback;

    public string Require(string name) =>
        Get(name) ?? throw new BcDevEnv.Cli.Infra.BcDevEnvException($"Missing required option --{name}.");

    public IReadOnlyList<string> GetAll(string name) =>
        _values.TryGetValue(name, out var v) ? v : Array.Empty<string>();

    public bool Flag(string name) => _switches.Contains(name);

    public bool Has(string name) => _switches.Contains(name) || _values.ContainsKey(name);

    public static ParsedArgs Parse(IReadOnlyList<string> args, ISet<string> switchNames)
    {
        var result = new ParsedArgs();
        for (var i = 0; i < args.Count; i++)
        {
            var token = args[i];
            if (!token.StartsWith("--", StringComparison.Ordinal))
            {
                result._positional.Add(token);
                continue;
            }

            var name = token[2..];
            string? inlineValue = null;
            var eq = name.IndexOf('=');
            if (eq >= 0)
            {
                inlineValue = name[(eq + 1)..];
                name = name[..eq];
            }

            if (switchNames.Contains(name))
            {
                result._switches.Add(name);
                continue;
            }

            string value;
            if (inlineValue != null)
            {
                value = inlineValue;
            }
            else if (i + 1 < args.Count && !args[i + 1].StartsWith("--", StringComparison.Ordinal))
            {
                value = args[++i];
            }
            else
            {
                // Flag-like token not declared as a switch and with no value: treat as a bare switch.
                result._switches.Add(name);
                continue;
            }

            if (!result._values.TryGetValue(name, out var list))
            {
                list = new List<string>();
                result._values[name] = list;
            }
            list.Add(value);
        }
        return result;
    }
}
