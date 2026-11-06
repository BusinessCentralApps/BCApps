using BcDevEnv.Cli.Commands;
using BcDevEnv.Cli.Infra;
using BcDevEnv.Cli.Testing;
using Xunit;

namespace BcDevEnv.Cli.Tests;

public class PipelineSupportTests
{
    [Fact]
    public void XUnit_parser_reads_runner_codeunit_attributes_and_skip_reason()
    {
        var run = XUnitResultParser.Parse(FakeRunnerHandler.XUnit(50001, "Alpha Tests",
            ("Off", "Skipped", TestSkipReasons.DisabledByDisabledTests)));

        var cu = Assert.Single(run.Codeunits);
        Assert.Equal(50001, cu.CodeunitId);
        Assert.Equal("Alpha Tests", cu.CodeunitName);
        Assert.Equal("My Test App", cu.AppName);
        var method = Assert.Single(cu.Methods);
        Assert.Equal(TestOutcome.Skipped, method.Outcome);
        Assert.Equal(TestSkipReasons.DisabledByDisabledTests, method.Message);
    }

    [Fact]
    public void Staged_app_names_keep_order_and_reject_collisions()
    {
        Assert.Equal(new[] { "b.app", "a.app" }, BuildImageCommand.StagedAppLeaves(new[] { @"C:\x\b.app", @"C:\y\a.app" }));
        Assert.Throws<BcDevEnvException>(() => BuildImageCommand.StagedAppLeaves(new[] { @"C:\x\a.app", @"C:\y\A.app" }));
    }

    [Fact]
    public void App_list_ignores_blank_lines_and_comments()
    {
        using var dir = new TempDir();
        var list = dir.Write("apps.txt", "# ordered\r\nC:\\a\\first.app\r\n\r\n  C:\\b\\second.app  \r\n");

        Assert.Equal(new[] { @"C:\a\first.app", @"C:\b\second.app" }, BuildImageCommand.ReadAppList(list));
        Assert.Empty(BuildImageCommand.ReadAppList(null));
        Assert.Throws<BcDevEnvException>(() => BuildImageCommand.ReadAppList(Path.Combine(dir.Path, "missing.txt")));
    }

    [Fact]
    public void Build_manifest_round_trips_the_company()
    {
        using var dir = new TempDir();
        var path = Path.Combine(dir.Path, "build-manifest.json");

        new BuildManifest { CompanyName = "Empty Company" }.Save(path);
        Assert.Equal("Empty Company", BuildManifest.Load(path).EffectiveCompanyName);

        new BuildManifest().Save(path);
        Assert.DoesNotContain("companyName", File.ReadAllText(path));
        Assert.Equal(BuildManifest.DefaultCompanyName, BuildManifest.Load(path).EffectiveCompanyName);
    }

    [Fact]
    public void Build_manifest_round_trips_company_provisioning()
    {
        using var dir = new TempDir();
        var path = Path.Combine(dir.Path, "build-manifest.json");

        new BuildManifest
        {
            CompanyName = "CRONUS International Ltd.",
            EvaluationCompany = true,
            CompanyCodeunits = new[] { "2", "5193:CreateAllDemoData", "5140:DeleteWarehouseEmployee", "5691" }
                .Select(CompanyCodeunitCall.Parse).ToList(),
            ServerSettings = BuildManifest.ParseServerSettings(new[] { "EnableTaskScheduler=true", "Foo = a=b " }),
        }.Save(path);

        var loaded = BuildManifest.Load(path);
        Assert.True(loaded.EvaluationCompany);
        Assert.Equal(new[] { "2", "5193:CreateAllDemoData", "5140:DeleteWarehouseEmployee", "5691" },
            loaded.CompanyCodeunits.Select(c => c.ToString()));
        Assert.Null(loaded.CompanyCodeunits[0].MethodName);
        Assert.Equal("true", loaded.ServerSettings["EnableTaskScheduler"]);
        Assert.Equal("a=b", loaded.ServerSettings["Foo"]);

        new BuildManifest().Save(path);
        var empty = BuildManifest.Load(path);
        Assert.False(empty.EvaluationCompany);
        Assert.Empty(empty.CompanyCodeunits);
        Assert.Empty(empty.ServerSettings);
    }

    [Theory]
    [InlineData("")]
    [InlineData("abc")]
    [InlineData("0")]
    [InlineData("-2")]
    [InlineData("5193:")]
    [InlineData(":CreateAllDemoData")]
    public void Company_codeunit_rejects_invalid_values(string value)
    {
        Assert.Throws<BcDevEnvException>(() => CompanyCodeunitCall.Parse(value));
    }

    [Theory]
    [InlineData("EnableTaskScheduler")]
    [InlineData("=false")]
    public void Server_setting_requires_key_and_value(string value)
    {
        Assert.Throws<BcDevEnvException>(() => BuildManifest.ParseServerSettings(new[] { value }));
    }

    [Fact]
    public void License_hint_distinguishes_missing_and_insufficient_licenses()
    {
        Assert.Null(ProvisionCommand.LicenseHint("Sync failed", licenseImported: false));
        var missing = ProvisionCommand.LicenseHint("No license file has been uploaded to the server.", false);
        Assert.Contains("no license was imported", missing);
        Assert.Contains("Cronus.bclicense", missing);
        Assert.DoesNotContain("built-in", missing);
        Assert.Contains("imported license", ProvisionCommand.LicenseHint("The license has expired", true));
    }

    [Theory]
    [InlineData("Windows", "ContainerAdministrator", "NT AUTHORITY\\NETWORK SERVICE")]
    [InlineData("windows", "ContainerUser", "NT AUTHORITY\\NETWORK SERVICE")]
    [InlineData("Windows", "NT AUTHORITY\\NETWORK SERVICE", null)]
    [InlineData("NavUserPassword", "ContainerAdministrator", null)]
    public void Server_account_is_mapped_to_a_user_only_with_windows_authentication(string credentialType, string account, string? expected)
    {
        Assert.Equal(expected, ProvisionCommand.ServerServiceAccountUser(credentialType, account));
    }

    [Fact]
    public void Build_image_fails_fast_when_apps_would_be_baked_into_an_unlicensed_empty_database()
    {
        var ex = Assert.Throws<BcDevEnvException>(() => BuildImageCommand.CheckLicense(hasLicense: false, emptyDatabase: true, appCount: 3));
        Assert.Contains("--license", ex.Message);
        Assert.Contains("3 bake-time app(s)", ex.Message);

        Assert.Null(BuildImageCommand.CheckLicense(hasLicense: true, emptyDatabase: true, appCount: 3));
        Assert.Contains("apps cannot be published", BuildImageCommand.CheckLicense(false, emptyDatabase: true, appCount: 0));
        // An explicit --bak may already hold a license (e.g. a demo database).
        Assert.Contains("database backup", BuildImageCommand.CheckLicense(false, emptyDatabase: false, appCount: 3));
    }

    [Fact]
    public void Container_files_are_staged_into_the_context_root()
    {
        using var tool = new TempDir();
        using var context = new TempDir();
        tool.Write(Path.Combine("container", "Dockerfile"), "FROM x");
        tool.Write(Path.Combine("container", "Install-SqlExpress.ps1"), "# sql");

        var dockerfile = BuildImageCommand.StageContainerFiles(tool.Path, context.Path);

        Assert.Equal(Path.Combine(context.Path, "Dockerfile"), dockerfile);
        Assert.Equal("# sql", File.ReadAllText(Path.Combine(context.Path, "Install-SqlExpress.ps1")));

        File.Delete(Path.Combine(tool.Path, "container", "Install-SqlExpress.ps1"));
        Assert.Throws<BcDevEnvException>(() => BuildImageCommand.StageContainerFiles(tool.Path, context.Path));
    }

    [Fact]
    public void Dockerfile_installs_sql_with_the_staged_script_and_not_chocolatey()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir != null && !File.Exists(Path.Combine(dir.FullName, "container", "Dockerfile"))) dir = dir.Parent;
        Assert.NotNull(dir);
        var containerDir = Path.Combine(dir!.FullName, "container");
        var dockerfile = File.ReadAllText(Path.Combine(containerDir, "Dockerfile"));

        foreach (var leaf in BuildImageCommand.ContainerSetupFiles)
        {
            Assert.True(File.Exists(Path.Combine(containerDir, leaf)), $"{leaf} is missing from the container folder.");
            Assert.Contains($"COPY {leaf} ", dockerfile);
        }
        Assert.Contains(@"C:\bcdevenv-setup\Install-SqlExpress.ps1", dockerfile);
        Assert.DoesNotContain("choco ", dockerfile);
    }
}
