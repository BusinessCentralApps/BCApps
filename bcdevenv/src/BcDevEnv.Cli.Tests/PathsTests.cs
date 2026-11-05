using System.Text.Json;
using BcDevEnv.Cli.Infra;
using Xunit;

namespace BcDevEnv.Cli.Tests;

// Paths keeps the resolved platform root in a process-static field, so these
// tests must not run in parallel with each other. A single non-parallel class
// (xUnit runs tests within one class sequentially) is sufficient since no other
// test class touches that state.
public class PathsTests
{
    private static string NewTempDir()
    {
        var dir = Path.Combine(Path.GetTempPath(), "bcdevenv-plat-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        return dir;
    }

    [Fact]
    public void ReadPlatformInfo_reads_version_and_country_from_manifest()
    {
        var dir = NewTempDir();
        try
        {
            var manifest = new { version = "30.0.54604.0", country = "W1" };
            File.WriteAllText(Path.Combine(dir, "manifest.json"), JsonSerializer.Serialize(manifest));

            Paths.UsePlatform(dir);
            var info = Paths.ReadPlatformInfo();

            Assert.Equal("30.0.54604.0", info.Version);
            Assert.Equal("W1", info.Country);
        }
        finally
        {
            Directory.Delete(dir, recursive: true);
        }
    }

    [Fact]
    public void ReadPlatformInfo_defaults_when_manifest_absent()
    {
        var dir = NewTempDir();
        try
        {
            Paths.UsePlatform(dir);
            var info = Paths.ReadPlatformInfo();

            Assert.Equal("unknown", info.Version);
            Assert.Equal("W1", info.Country);
        }
        finally
        {
            Directory.Delete(dir, recursive: true);
        }
    }

    [Fact]
    public void UsePlatform_throws_when_folder_missing()
    {
        var missing = Path.Combine(Path.GetTempPath(), "bcdevenv-does-not-exist-" + Guid.NewGuid().ToString("N"));
        Assert.Throws<BcDevEnvException>(() => Paths.UsePlatform(missing));
    }

    [Fact]
    public void UsePlatform_stores_absolute_root()
    {
        var dir = NewTempDir();
        try
        {
            Paths.UsePlatform(dir);
            Assert.Equal(Path.GetFullPath(dir), Paths.PlatformRoot);
        }
        finally
        {
            Directory.Delete(dir, recursive: true);
        }
    }
}
