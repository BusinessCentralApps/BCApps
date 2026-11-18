using System.IO.Compression;
using System.Net.Http;

namespace BcDevEnv.Cli.IntegrationTests;

/// <summary>
/// Downloads and extracts a BC platform artifact (the <c>platform</c> blob for a version) into a
/// local cache folder whose layout is exactly what the CLI expects behind <c>--platform</c>
/// (manifest.json at the root, ServiceTier\...\Service\Admin\*.psd1, WebClient\...). The download
/// is cached per version, so re-runs and multiple tests reuse a single extraction.
/// </summary>
public static class PlatformArtifact
{
    private const string PlatformContainerUrl =
        "https://bcinsider-fvh2ekdjecfjd6gk.b02.azurefd.net/platform";

    /// <summary>Where extracted artifacts are cached (override with BCDEVENV_ARTIFACT_CACHE).</summary>
    public static string CacheRoot =>
        Environment.GetEnvironmentVariable("BCDEVENV_ARTIFACT_CACHE")
        ?? Path.Combine(Path.GetTempPath(), "bcdevenv-artifacts");

    /// <summary>
    /// Ensures the artifact for <paramref name="version"/> is extracted locally and returns its
    /// root folder. Cached: if a completed extraction already exists it is reused.
    /// </summary>
    public static async Task<string> EnsureAsync(
        string version, Action<string>? log = null, HttpClient? http = null, CancellationToken ct = default)
    {
        Directory.CreateDirectory(CacheRoot);
        var artifactDir = Path.Combine(CacheRoot, version);
        var marker = Path.Combine(artifactDir, ".extracted");
        if (File.Exists(marker))
        {
            log?.Invoke($"Using cached platform artifact: {artifactDir}");
            return artifactDir;
        }

        var owned = http is null;
        http ??= new HttpClient { Timeout = TimeSpan.FromMinutes(30) };
        try
        {
            var url = $"{PlatformContainerUrl}/{version}/platform";
            var zipPath = Path.Combine(CacheRoot, $"{version}-platform.zip");
            log?.Invoke($"Downloading platform artifact {version} from {url} ...");

            using (var response = await http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead, ct))
            {
                response.EnsureSuccessStatusCode();
                await using var src = await response.Content.ReadAsStreamAsync(ct);
                await using var dst = File.Create(zipPath);
                await src.CopyToAsync(dst, ct);
            }

            // Extract into a clean folder, then drop the completion marker.
            if (Directory.Exists(artifactDir)) Directory.Delete(artifactDir, recursive: true);
            Directory.CreateDirectory(artifactDir);
            log?.Invoke($"Extracting to {artifactDir} ...");
            ZipFile.ExtractToDirectory(zipPath, artifactDir);

            File.WriteAllText(marker, DateTime.UtcNow.ToString("o"));
            try { File.Delete(zipPath); } catch { /* best effort */ }

            log?.Invoke($"Platform artifact {version} ready.");
            return artifactDir;
        }
        finally
        {
            if (owned) http.Dispose();
        }
    }
}
