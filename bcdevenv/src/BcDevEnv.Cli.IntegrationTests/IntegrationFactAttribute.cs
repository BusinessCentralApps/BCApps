using Xunit;

namespace BcDevEnv.Cli.IntegrationTests;

/// <summary>
/// A <see cref="FactAttribute"/> that skips itself (via <see cref="FactAttribute.Skip"/>) unless
/// the integration tests are enabled. Skipping is decided in the constructor from environment
/// state, so no extra NuGet package (SkippableFact) is required.
/// </summary>
[AttributeUsage(AttributeTargets.Method)]
public sealed class IntegrationFactAttribute : FactAttribute
{
    public IntegrationFactAttribute()
    {
        if (!IntegrationSettings.Enabled) Skip = IntegrationSettings.DisabledReason;
    }
}

/// <summary>Theory counterpart of <see cref="IntegrationFactAttribute"/>.</summary>
[AttributeUsage(AttributeTargets.Method)]
public sealed class IntegrationTheoryAttribute : TheoryAttribute
{
    public IntegrationTheoryAttribute()
    {
        if (!IntegrationSettings.Enabled) Skip = IntegrationSettings.DisabledReason;
    }
}

/// <summary>
/// Theory that additionally requires the heavy container infrastructure (SQL + Docker Windows
/// containers) to be explicitly opted in.
/// </summary>
[AttributeUsage(AttributeTargets.Method)]
public sealed class ContainerTheoryAttribute : TheoryAttribute
{
    public ContainerTheoryAttribute()
    {
        if (!IntegrationSettings.ContainerTestsEnabled) Skip = IntegrationSettings.ContainerDisabledReason;
    }
}
