using Xunit;
using Xunit.Abstractions;

namespace BcDevEnv.Cli.IntegrationTests;

/// <summary>
/// Validates that the platform version(s) under test are resolved from the live BC platform index
/// (per the task: "the platform version should be determined from the platform index").
/// </summary>
public class PlatformIndexTests
{
    private readonly ITestOutputHelper _output;

    public PlatformIndexTests(ITestOutputHelper output) => _output = output;

    [IntegrationFact]
    public async Task Index_exposes_latest_per_major()
    {
        var all = await PlatformIndex.FetchAsync();
        Assert.NotEmpty(all);

        var latestPerMajor = PlatformIndex.LatestPerMajor(all);
        foreach (var (major, entry) in latestPerMajor.OrderBy(kv => kv.Key))
            _output.WriteLine($"Major {major}: latest = {entry.Raw} (created {entry.CreationTime:u})");

        // Each grouped entry really is the max version for its major.
        foreach (var (major, entry) in latestPerMajor)
            Assert.Equal(entry.Version, all.Where(e => e.Major == major).Max(e => e.Version));

        // The majors the suite targets should be resolvable from the index.
        foreach (var major in IntegrationSettings.Majors)
            Assert.True(latestPerMajor.ContainsKey(major),
                $"Index has no platform version for major {major}. Available: " +
                string.Join(", ", latestPerMajor.Keys.OrderBy(k => k)));
    }

    [IntegrationTheory]
    [MemberData(nameof(ContainerInstallAppTests.MajorVersions), MemberType = typeof(ContainerInstallAppTests))]
    public async Task LatestForMajor_returns_highest_patch(int major)
    {
        var all = await PlatformIndex.FetchAsync();
        var latest = PlatformIndex.LatestForMajor(all, major);

        _output.WriteLine($"Latest {major}.x resolved from index: {latest.Raw}");
        Assert.Equal(major, latest.Major);
        Assert.Equal(all.Where(e => e.Major == major).Max(e => e.Version), latest.Version);
    }
}
