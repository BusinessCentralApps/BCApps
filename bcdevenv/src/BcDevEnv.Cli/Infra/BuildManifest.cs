using System.Text.Json;
using System.Text.Json.Serialization;

namespace BcDevEnv.Cli.Infra;

/// <summary>
/// Staged into the Docker build context and read by 'bcdevenv provision' inside the image.
/// File names are context-relative leaves (the whole context is COPYied into the image).
/// </summary>
public sealed class BuildManifest
{
    public string Country { get; set; } = "W1";
    public string PlatformVersion { get; set; } = "";
    public string DatabaseName { get; set; } = "";
    public string ServerInstance { get; set; } = "BC";
    public string BakFile { get; set; } = "";
    public string? LicenseFile { get; set; }
    public string CredentialType { get; set; } = "Windows";
    public List<string> AppFiles { get; set; } = new();

    /// <summary>Company the test context is provisioned in; null = <see cref="DefaultCompanyName"/>.</summary>
    public string? CompanyName { get; set; }

    public const string DefaultCompanyName = "Test";

    [JsonIgnore]
    public string EffectiveCompanyName => string.IsNullOrWhiteSpace(CompanyName) ? DefaultCompanyName : CompanyName!;

    /// <summary>Create the company as an evaluation company (New-NAVCompany -EvaluationCompany).</summary>
    public bool EvaluationCompany { get; set; }

    /// <summary>
    /// Codeunits run in the company after it is created (e.g. Company-Initialize and the Contoso
    /// demo-data codeunits), in order. Any failure fails the image build.
    /// </summary>
    public List<CompanyCodeunitCall> CompanyCodeunits { get; set; } = new();

    /// <summary>Server settings applied (strictly) on top of the built-in test-run defaults.</summary>
    public Dictionary<string, string> ServerSettings { get; set; } = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>Parses repeated --server-setting key=value options.</summary>
    public static Dictionary<string, string> ParseServerSettings(IEnumerable<string> values)
    {
        var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var raw in values)
        {
            var eq = raw.IndexOf('=');
            if (eq <= 0)
                throw new BcDevEnvException($"Invalid --server-setting '{raw}'. Expected <key>=<value>.");
            result[raw[..eq].Trim()] = raw[(eq + 1)..].Trim();
        }
        return result;
    }

    private static readonly JsonSerializerOptions Options = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    public void Save(string path) => File.WriteAllText(path, JsonSerializer.Serialize(this, Options));

    public static BuildManifest Load(string path)
    {
        if (!File.Exists(path))
            throw new BcDevEnvException($"build-manifest.json not found at '{path}'.");
        return JsonSerializer.Deserialize<BuildManifest>(File.ReadAllText(path), Options)
               ?? throw new BcDevEnvException($"Could not parse build manifest '{path}'.");
    }
}

/// <summary>A codeunit (optionally a single method of it) to run in the provisioned company.</summary>
public sealed class CompanyCodeunitCall
{
    public int CodeunitId { get; set; }
    public string? MethodName { get; set; }

    public override string ToString() => MethodName == null ? CodeunitId.ToString() : $"{CodeunitId}:{MethodName}";

    /// <summary>Parses a --company-codeunit value: &lt;id&gt; or &lt;id&gt;:&lt;method&gt;.</summary>
    public static CompanyCodeunitCall Parse(string value)
    {
        var parts = value.Split(':', 2, StringSplitOptions.TrimEntries);
        if (!int.TryParse(parts[0], out var id) || id <= 0)
            throw new BcDevEnvException($"Invalid --company-codeunit '{value}'. Expected <id> or <id>:<method>.");
        var method = parts.Length == 2 ? parts[1] : null;
        if (parts.Length == 2 && string.IsNullOrWhiteSpace(method))
            throw new BcDevEnvException($"Invalid --company-codeunit '{value}'. The method name is empty.");
        return new CompanyCodeunitCall { CodeunitId = id, MethodName = method };
    }
}
