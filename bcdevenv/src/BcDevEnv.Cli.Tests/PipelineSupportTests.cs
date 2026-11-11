using BcDevEnv.Cli.Commands;
using BcDevEnv.Cli.Infra;
using BcDevEnv.Cli.Nav;
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
    public void System32_files_are_validated_and_staged_flat()
    {
        using var source = new TempDir();
        using var context = new TempDir();
        var dll = source.Write(Path.Combine("a", "t2embed.dll"), "MZ-dll");

        var files = BuildImageCommand.ResolveSystem32Files(new[] { dll, " " });
        Assert.Equal(new[] { Path.GetFullPath(dll) }, files);

        BuildImageCommand.StageSystem32Files(files, context.Path);
        Assert.Equal("MZ-dll", File.ReadAllText(Path.Combine(context.Path, BuildImageCommand.System32ContextFolder, "t2embed.dll")));

        // No files: no system32 folder in the context (the Dockerfile step is then a no-op).
        using var empty = new TempDir();
        BuildImageCommand.StageSystem32Files(BuildImageCommand.ResolveSystem32Files(Array.Empty<string>()), empty.Path);
        Assert.False(Directory.Exists(Path.Combine(empty.Path, BuildImageCommand.System32ContextFolder)));
    }

    [Fact]
    public void System32_files_reject_missing_files_and_name_collisions()
    {
        using var source = new TempDir();
        var first = source.Write(Path.Combine("a", "t2embed.dll"), "1");
        var second = source.Write(Path.Combine("b", "T2EMBED.DLL"), "2");

        var missing = Assert.Throws<BcDevEnvException>(() => BuildImageCommand.ResolveSystem32Files(new[] { Path.Combine(source.Path, "none.dll") }));
        Assert.Contains("not found", missing.Message);
        var collision = Assert.Throws<BcDevEnvException>(() => BuildImageCommand.ResolveSystem32Files(new[] { first, second }));
        Assert.Contains("share the name", collision.Message);
    }

    [Fact]
    public void Dockerfile_copies_staged_system32_files_only_when_missing_and_verifies_them()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir != null && !File.Exists(Path.Combine(dir.FullName, "container", "Dockerfile"))) dir = dir.Parent;
        Assert.NotNull(dir);
        var dockerfile = File.ReadAllText(Path.Combine(dir!.FullName, "container", "Dockerfile"));

        Assert.Contains(@"C:\bcdevenv\" + BuildImageCommand.System32ContextFolder, dockerfile);
        Assert.Contains("if (Test-Path $target)", dockerfile);
        Assert.Contains("is missing after the copy", dockerfile);
        Assert.Contains("'t2embed.dll'", dockerfile);
        // The copy must happen before provisioning, which starts the server.
        var copyStep = dockerfile.IndexOf(@"Get-ChildItem C:\bcdevenv\" + BuildImageCommand.System32ContextFolder, StringComparison.Ordinal);
        var provisionStep = dockerfile.IndexOf("bcdevenv.exe provision", StringComparison.Ordinal);
        Assert.InRange(copyStep, 0, provisionStep);
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

    [Fact]
    public void Url_reservations_cover_the_reporting_side_service_and_management_api()
    {
        var ports = NavServerService.UrlAclPorts(new NavServerService.ServerPorts());

        Assert.Equal(new[] { 7045, 7046, 7047, 7048, 7049, 7086, 7084 }, ports);
        Assert.Contains(7084, ports);
        Assert.Equal(ports.Count, ports.Distinct().Count());

        var custom = NavServerService.UrlAclPorts(new NavServerService.ServerPorts(Management: 8045, Developer: 0, Reporting: 8045));
        Assert.Equal(new[] { 8045, 7046, 7047, 7048, 8086 }, custom);
    }

    [Fact]
    public void Codeunit_runs_pass_the_timeout_and_never_retry()
    {
        var parameters = NavServerService.InvokeCodeunitParameters("BC", "Test", 5193, "CreateAllDemoData", TimeSpan.FromMinutes(45));

        Assert.Equal("BC", parameters["ServerInstance"]);
        Assert.Equal("Test", parameters["CompanyName"]);
        Assert.Equal(5193, parameters["CodeunitId"]);
        Assert.Equal("CreateAllDemoData", parameters["MethodName"]);
        Assert.Equal(TimeSpan.FromMinutes(45), parameters["NetworkTimeout"]);
        Assert.Equal(0, parameters["MaxRetries"]);

        var noMethod = NavServerService.InvokeCodeunitParameters("BC", "Test", 2, " ", TimeSpan.FromMinutes(1));
        Assert.False(noMethod.ContainsKey("MethodName"));

        Assert.Throws<BcDevEnvException>(() => NavServerService.InvokeCodeunitParameters("BC", "Test", 2, null, TimeSpan.Zero));
        Assert.Equal(TimeSpan.FromMinutes(60), NavServerService.DefaultCodeunitTimeout);
    }

    [Theory]
    [InlineData(null, null)]
    [InlineData("", null)]
    [InlineData(" 30 ", 30)]
    [InlineData("1", 1)]
    public void Company_codeunit_timeout_parses_positive_minutes(string? value, int? expected)
    {
        Assert.Equal(expected, BuildManifest.ParseCompanyCodeunitTimeout(value));
    }

    [Theory]
    [InlineData("0")]
    [InlineData("-5")]
    [InlineData("1.5")]
    [InlineData("ten")]
    public void Company_codeunit_timeout_rejects_invalid_values(string value)
    {
        Assert.Throws<BcDevEnvException>(() => BuildManifest.ParseCompanyCodeunitTimeout(value));
    }

    [Fact]
    public void Company_codeunit_timeout_defaults_to_an_hour_and_round_trips()
    {
        Assert.Equal(TimeSpan.FromMinutes(60), new BuildManifest().EffectiveCompanyCodeunitTimeout);

        var path = Path.Combine(Path.GetTempPath(), "bcdevenv-manifest-" + Guid.NewGuid().ToString("N") + ".json");
        try
        {
            new BuildManifest { CompanyCodeunitTimeoutMinutes = 90 }.Save(path);
            var json = File.ReadAllText(path);
            Assert.Contains("\"companyCodeunitTimeoutMinutes\": 90", json);
            Assert.DoesNotContain("effectiveCompanyCodeunitTimeout", json, StringComparison.OrdinalIgnoreCase);
            Assert.Equal(TimeSpan.FromMinutes(90), BuildManifest.Load(path).EffectiveCompanyCodeunitTimeout);

            new BuildManifest().Save(path);
            Assert.DoesNotContain("companyCodeunitTimeoutMinutes", File.ReadAllText(path));
            Assert.Null(BuildManifest.Load(path).CompanyCodeunitTimeoutMinutes);
        }
        finally
        {
            if (File.Exists(path)) File.Delete(path);
        }
    }

    [Theory]
    [InlineData(null, "W1")]
    [InlineData("", "W1")]
    [InlineData("base", "W1")]
    [InlineData("w1", "W1")]
    [InlineData(" fr ", "FR")]
    [InlineData("GB", "GB")]
    [InlineData("US", "US")]
    public void Application_family_is_the_upper_case_country(string? country, string expected)
    {
        Assert.Equal(expected, NavServerService.ApplicationFamilyFor(country));
    }

    [Theory]
    [InlineData("fr-FR")]
    [InlineData("F R")]
    [InlineData("FR;DROP")]
    public void Application_family_rejects_non_country_values(string country)
    {
        Assert.Throws<BcDevEnvException>(() => NavServerService.ApplicationFamilyFor(country));
    }
}
