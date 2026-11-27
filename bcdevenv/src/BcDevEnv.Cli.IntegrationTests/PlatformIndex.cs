using System.Net.Http;
using System.Net.Http.Json;

namespace BcDevEnv.Cli.IntegrationTests;

/// <summary>A single platform version entry from the index.</summary>
public sealed record PlatformVersionEntry(Version Version, DateTimeOffset CreationTime)
{
    public int Major => Version.Major;

    /// <summary>The four-part version string as it appears in blob paths (e.g. 30.0.54717.0).</summary>
    public string Raw => Version.ToString();
}

/// <summary>
/// Reads the public BC platform index and resolves the versions to test. The index is the source
/// of truth the task calls out: the platform version(s) under test are always derived from it, so
/// the tests follow the platform as new builds land.
/// </summary>
public static class PlatformIndex
{
    /// <summary>The platform index feed (a JSON array of {Version, CreationTime}).</summary>
    public const string IndexUrl =
        "https://bcinsider-fvh2ekdjecfjd6gk.b02.azurefd.net/platform/indexes/platform.json";

    private sealed record IndexRow(string? Version, DateTimeOffset CreationTime);

    /// <summary>Fetches and parses the full platform index.</summary>
    public static async Task<IReadOnlyList<PlatformVersionEntry>> FetchAsync(
        HttpClient? http = null, CancellationToken ct = default)
    {
        var owned = http is null;
        http ??= new HttpClient { Timeout = TimeSpan.FromMinutes(2) };
        try
        {
            var rows = await http.GetFromJsonAsync<List<IndexRow>>(IndexUrl, ct)
                       ?? throw new InvalidOperationException($"Platform index at {IndexUrl} was empty.");

            var entries = new List<PlatformVersionEntry>(rows.Count);
            foreach (var row in rows)
            {
                if (Version.TryParse(row.Version, out var v))
                    entries.Add(new PlatformVersionEntry(v, row.CreationTime));
            }
            if (entries.Count == 0)
                throw new InvalidOperationException($"Platform index at {IndexUrl} contained no parseable versions.");
            return entries;
        }
        finally
        {
            if (owned) http.Dispose();
        }
    }

    /// <summary>The highest (latest) version for a given major.</summary>
    public static PlatformVersionEntry LatestForMajor(IEnumerable<PlatformVersionEntry> all, int major)
    {
        var latest = all.Where(e => e.Major == major).OrderByDescending(e => e.Version).FirstOrDefault();
        return latest ?? throw new InvalidOperationException(
            $"No platform version found for major {major} in the index.");
    }

    /// <summary>The latest version for every major present in the index.</summary>
    public static IReadOnlyDictionary<int, PlatformVersionEntry> LatestPerMajor(
        IEnumerable<PlatformVersionEntry> all) =>
        all.GroupBy(e => e.Major)
           .ToDictionary(g => g.Key, g => g.OrderByDescending(e => e.Version).First());
}
