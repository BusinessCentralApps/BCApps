using BcDevEnv.Cli.Infra;
using Xunit;

namespace BcDevEnv.Cli.Tests;

public class EnvManifestTests
{
    [Fact]
    public void Save_then_load_round_trips()
    {
        var dir = Path.Combine(Path.GetTempPath(), "bcdevenv-test-" + Guid.NewGuid().ToString("N"));
        try
        {
            var m = new EnvManifest
            {
                Name = "W1-30_0_54604_0",
                Country = "W1",
                PlatformVersion = "30.0.54604.0",
                PlatformArtifact = "C:\\artifacts\\platform_30.0.54604.0",
                DatabaseName = "CRONUS",
                ServerInstance = "BC",
                Bak = "CRONUS.bak",
                AppFiles = { "System.app", "Base.app" },
                CreatedUtc = "2026-09-14T00:00:00Z",
            };
            m.Save(dir);

            Assert.True(File.Exists(Path.Combine(dir, "manifest.json")));

            var loaded = EnvManifest.Load(dir);
            Assert.Equal(m.Name, loaded.Name);
            Assert.Equal(m.PlatformVersion, loaded.PlatformVersion);
            Assert.Equal(m.PlatformArtifact, loaded.PlatformArtifact);
            Assert.Equal(m.DatabaseName, loaded.DatabaseName);
            Assert.Equal(m.ServerInstance, loaded.ServerInstance);
            Assert.Equal(new[] { "System.app", "Base.app" }, loaded.AppFiles);
        }
        finally
        {
            if (Directory.Exists(dir)) Directory.Delete(dir, recursive: true);
        }
    }

    [Fact]
    public void Manifest_is_camel_cased_on_disk()
    {
        var dir = Path.Combine(Path.GetTempPath(), "bcdevenv-test-" + Guid.NewGuid().ToString("N"));
        try
        {
            new EnvManifest { Name = "x", PlatformArtifact = "y" }.Save(dir);
            var json = File.ReadAllText(Path.Combine(dir, "manifest.json"));
            Assert.Contains("\"platformArtifact\"", json);
            Assert.Contains("\"serverInstance\"", json);
        }
        finally
        {
            if (Directory.Exists(dir)) Directory.Delete(dir, recursive: true);
        }
    }

    [Fact]
    public void Load_throws_when_manifest_missing()
    {
        var dir = Path.Combine(Path.GetTempPath(), "bcdevenv-test-" + Guid.NewGuid().ToString("N"));
        Assert.Throws<BcDevEnvException>(() => EnvManifest.Load(dir));
    }
}
