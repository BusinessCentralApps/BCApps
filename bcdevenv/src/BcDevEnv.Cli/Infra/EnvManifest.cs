using System.Text.Json;
using System.Text.Json.Serialization;

namespace BcDevEnv.Cli.Infra;

/// <summary>Persisted description of a built environment (its .bak and what went into it).</summary>
public sealed class EnvManifest
{
    public string Name { get; set; } = "";
    public string Country { get; set; } = "W1";
    public string PlatformVersion { get; set; } = "";
    public string PlatformArtifact { get; set; } = "";
    public string DatabaseName { get; set; } = "";
    public string ServerInstance { get; set; } = "BC";
    public string Bak { get; set; } = "";
    public List<string> AppFiles { get; set; } = new();
    public string CreatedUtc { get; set; } = "";

    private static readonly JsonSerializerOptions Options = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    public void Save(string envPath)
    {
        Directory.CreateDirectory(envPath);
        File.WriteAllText(Path.Combine(envPath, "manifest.json"), JsonSerializer.Serialize(this, Options));
    }

    public static EnvManifest Load(string envPath)
    {
        var p = Path.Combine(envPath, "manifest.json");
        if (!File.Exists(p))
            throw new BcDevEnvException($"No manifest at '{p}'. Run 'bcdevenv create-env' first, or pass explicit options.");
        return JsonSerializer.Deserialize<EnvManifest>(File.ReadAllText(p), Options)
               ?? throw new BcDevEnvException($"Manifest at '{p}' could not be parsed.");
    }
}
