using System.Text.Json;
using BcDevEnv.Cli.Infra;
using BcDevEnv.Cli.Testing;
using Xunit;

namespace BcDevEnv.Cli.Tests;

public class DisabledTestCatalogTests
{
    [Fact]
    public void Parse_reads_the_repository_entry_format()
    {
        const string json = """
[
  { "codeunitId": 134000, "codeunitName": "ERM Tests", "method": "TestOne", "bug": "12345" },
  { "codeunitId": "134001", "codeunitName": "Other Tests", "method": "*", "bugId": 7 }
]
""";
        var entries = DisabledTestCatalog.Parse(json, "x.json");

        Assert.Equal(2, entries.Count);
        Assert.Equal(new DisabledTestEntry("ERM Tests", "TestOne", 134000, "12345", "x.json"), entries[0]);
        Assert.Equal(134001, entries[1].CodeunitId);
        Assert.Equal("*", entries[1].Method);
        Assert.Equal("7", entries[1].Bug);
    }

    [Theory]
    [InlineData("""[{ "codeunitName": "A" }]""")]
    [InlineData("""[{ "method": "M" }]""")]
    [InlineData("""[{ "codeunitName": " ", "method": "M" }]""")]
    [InlineData("""[1]""")]
    [InlineData("""42""")]
    [InlineData("""not json""")]
    public void Parse_rejects_invalid_documents(string json)
    {
        Assert.Throws<BcDevEnvException>(() => DisabledTestCatalog.Parse(json, "bad.json"));
    }

    [Fact]
    public void Load_with_app_name_reads_only_that_apps_folder()
    {
        using var root = new TempDir();
        root.Write("My_Test_App/My_Test_App.DisabledTest.json", """[{"codeunitName":"A","method":"M1"}]""");
        root.Write("My_Test_App/Extra.json", """[{"codeunitName":"A","method":"M2"}]""");
        root.Write("Other_App/Other_App.DisabledTest.json", """[{"codeunitName":"B","method":"M"}]""");

        var catalog = DisabledTestCatalog.Load(new[] { root.Path }, "My Test App");

        Assert.Equal(2, catalog.SourceFiles.Count);
        Assert.Equal(new[] { "M1", "M2" }, catalog.Entries.Select(e => e.Method).OrderBy(m => m));
        Assert.True(catalog.IsDisabled("a", "m1"));
        Assert.False(catalog.IsDisabled("B", "M"));
    }

    [Fact]
    public void Load_accepts_the_app_folder_itself_and_explicit_files()
    {
        using var root = new TempDir();
        var file = root.Write("My_App/My_App.DisabledTest.json", """[{"codeunitName":"A","method":"M"}]""");

        Assert.Single(DisabledTestCatalog.Load(new[] { Path.Combine(root.Path, "My_App") }, "My App").Entries);
        Assert.Single(DisabledTestCatalog.Load(new[] { file }, "Another App").Entries);
    }

    [Fact]
    public void Load_without_app_name_reads_every_file_and_missing_app_folder_is_empty()
    {
        using var root = new TempDir();
        root.Write("A_App/a.json", """[{"codeunitName":"A","method":"M"}]""");
        root.Write("B_App/b.json", """[{"codeunitName":"B","method":"M"}]""");

        Assert.Equal(2, DisabledTestCatalog.Load(new[] { root.Path }, null).Entries.Count);
        Assert.Empty(DisabledTestCatalog.Load(new[] { root.Path }, "App Without Entries").Entries);
        Assert.Throws<BcDevEnvException>(() => DisabledTestCatalog.Load(new[] { Path.Combine(root.Path, "missing") }, null));
    }

    [Theory]
    [InlineData("*", "Anything", true)]
    [InlineData("TestOne", "testone", true)]
    [InlineData("TestOne", "TestOnes", false)]
    [InlineData("Test*Posting", "TestSalesPosting", true)]
    [InlineData("Test*Posting", "TestSalesPost", false)]
    [InlineData("Test?", "Test1", true)]
    [InlineData("Test?", "Test12", false)]
    public void MethodMatches_supports_exact_and_wildcards(string pattern, string method, bool expected)
    {
        Assert.Equal(expected, DisabledTestCatalog.MethodMatches(pattern, method));
    }

    [Fact]
    public void ToRunnerJson_groups_methods_by_codeunit()
    {
        var catalog = Catalog("""
[
  {"codeunitName":"A","method":"M1"},
  {"codeunitName":"a","method":"M2"},
  {"codeunitName":"A","method":"m1"},
  {"codeunitName":"B","method":"*"}
]
""");
        using var doc = JsonDocument.Parse(catalog.ToRunnerJson());
        var groups = doc.RootElement.EnumerateArray().ToList();

        Assert.Equal(2, groups.Count);
        Assert.Equal("A", groups[0].GetProperty("codeunitName").GetString());
        Assert.Equal(new[] { "M1", "M2" }, groups[0].GetProperty("methods").EnumerateArray().Select(m => m.GetString()));
        Assert.Equal(new[] { "*" }, groups[1].GetProperty("methods").EnumerateArray().Select(m => m.GetString()));
    }

    [Fact]
    public void Verify_accepts_tests_skipped_before_execution_and_reports_unmatched_entries()
    {
        var catalog = Catalog("""[{"codeunitName":"Alpha Tests","method":"Disabled*"},{"codeunitName":"Gone","method":"X"}]""");
        var run = Run(("Alpha Tests", "DisabledOne", TestOutcome.Skipped, TestSkipReasons.DisabledByDisabledTests),
                      ("Alpha Tests", "Enabled", TestOutcome.Passed, null));

        var verification = catalog.Verify(run);

        Assert.True(verification.IsValid);
        Assert.Equal(1, verification.SkippedByCatalog);
        Assert.Equal("Gone", Assert.Single(verification.UnmatchedEntries).CodeunitName);
    }

    [Fact]
    public void Verify_flags_disabled_tests_that_ran_and_unexpected_disables()
    {
        var catalog = Catalog("""[{"codeunitName":"Alpha Tests","method":"Ran"}]""");
        var run = Run(("Alpha Tests", "Ran", TestOutcome.Failed, "boom"),
                      ("Alpha Tests", "NotListed", TestOutcome.Skipped, TestSkipReasons.DisabledByDisabledTests));

        var verification = catalog.Verify(run);

        Assert.False(verification.IsValid);
        Assert.Equal(new ExecutedDisabledTest("Alpha Tests", "Ran", TestOutcome.Failed), Assert.Single(verification.ExecutedDisabledTests));
        Assert.Equal("Alpha Tests:NotListed", Assert.Single(verification.UnexpectedlyDisabled));
    }

    [Fact]
    public void CodeunitNameOf_prefers_reported_name_and_strips_the_id_prefix()
    {
        Assert.Equal("X", DisabledTestCatalog.CodeunitNameOf(new TestCodeunitResult { Name = "Codeunit 5 Y", CodeunitName = "X" }));
        Assert.Equal("My Tests", DisabledTestCatalog.CodeunitNameOf(new TestCodeunitResult { Name = "Codeunit 5 My Tests" }));
        Assert.Equal("Plain", DisabledTestCatalog.CodeunitNameOf(new TestCodeunitResult { Name = "Plain" }));
    }

    [Fact]
    public void Every_repository_DisabledTests_file_parses()
    {
        // Guards the parser against the real src/DisabledTests data (skipped outside the repository).
        var root = FindRepositoryDisabledTests();
        if (root == null) return;

        var files = Directory.GetFiles(root, "*.json", SearchOption.AllDirectories);
        var catalog = DisabledTestCatalog.Load(new[] { root }, null);

        Assert.Equal(files.Length, catalog.SourceFiles.Count);
        Assert.NotEmpty(catalog.Entries);
        Assert.All(catalog.Entries, e =>
        {
            Assert.False(string.IsNullOrWhiteSpace(e.CodeunitName));
            Assert.False(string.IsNullOrWhiteSpace(e.Method));
        });

        // The native app-name -> folder mapping reaches the entries of the repository's apps.
        var srcRoot = Path.GetDirectoryName(root)!;
        var appNames = Directory.EnumerateFiles(srcRoot, "app.json", SearchOption.AllDirectories)
            .Select(ReadAppName).Where(n => n != null).Select(n => n!).Distinct().ToList();
        var reached = 0;
        foreach (var appName in appNames)
        {
            var folder = Path.Combine(root, DisabledTestCatalog.AppFolderName(appName));
            if (!Directory.Exists(folder)) continue;
            reached++;
            Assert.Equal(Directory.GetFiles(folder, "*.json").Length,
                DisabledTestCatalog.Load(new[] { root }, appName).SourceFiles.Count);
        }
        Assert.True(reached > Directory.GetDirectories(root).Length * 9 / 10,
            $"Only {reached} DisabledTests folders were reached from app names.");
    }

    private static string? ReadAppName(string appJson)
    {
        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(appJson),
                new JsonDocumentOptions { AllowTrailingCommas = true, CommentHandling = JsonCommentHandling.Skip });
            return doc.RootElement.TryGetProperty("name", out var name) ? name.GetString() : null;
        }
        catch (JsonException)
        {
            return null;
        }
    }

    internal static DisabledTestCatalog Catalog(string json)
    {
        using var dir = new TempDir();
        var file = dir.Write("entries.json", json);
        return DisabledTestCatalog.Load(new[] { file }, null);
    }

    internal static TestRunResult Run(params (string Codeunit, string Method, TestOutcome Outcome, string? Message)[] tests)
    {
        var run = new TestRunResult();
        foreach (var group in tests.GroupBy(t => t.Codeunit))
        {
            var cu = new TestCodeunitResult { Name = $"Codeunit 1 {group.Key}", CodeunitName = group.Key };
            foreach (var t in group)
                cu.Methods.Add(new TestMethodResult { Name = t.Method, Outcome = t.Outcome, Message = t.Message });
            run.Codeunits.Add(cu);
        }
        return run;
    }

    private static string? FindRepositoryDisabledTests()
    {
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir != null; dir = dir.Parent)
        {
            var candidate = Path.Combine(dir.FullName, "src", "DisabledTests");
            if (Directory.Exists(candidate) && File.Exists(Path.Combine(dir.FullName, "build", "Packages.json")))
                return candidate;
        }
        return null;
    }
}

internal sealed class TempDir : IDisposable
{
    public TempDir()
    {
        Path = System.IO.Path.Combine(System.IO.Path.GetTempPath(), $"bcdevenv-tests-{Guid.NewGuid():N}");
        Directory.CreateDirectory(Path);
    }

    public string Path { get; }

    public string Write(string relativePath, string content)
    {
        var full = System.IO.Path.Combine(Path, relativePath);
        Directory.CreateDirectory(System.IO.Path.GetDirectoryName(full)!);
        File.WriteAllText(full, content);
        return full;
    }

    public void Dispose()
    {
        try { Directory.Delete(Path, recursive: true); } catch (IOException) { }
    }
}
