using System.Text.Json;
using BcDevEnv.Cli.Infra;

namespace BcDevEnv.Cli.Testing;

/// <summary>One DisabledTests entry: a test method (or '*' for all) of a named test codeunit.</summary>
public sealed record DisabledTestEntry(string CodeunitName, string Method, int? CodeunitId, string? Bug, string Source);

/// <summary>A disabled test that nevertheless produced a pass/fail result.</summary>
public sealed record ExecutedDisabledTest(string CodeunitName, string Method, TestOutcome Outcome);

/// <summary>Outcome of checking a test run against the disabled-test catalog.</summary>
public sealed class DisabledTestVerification
{
    /// <summary>Tests matching an entry that still reported Passed/Failed - the exclusion did not happen before execution.</summary>
    public List<ExecutedDisabledTest> ExecutedDisabledTests { get; } = new();

    /// <summary>Tests the runner skipped with <see cref="TestSkipReasons.DisabledByDisabledTests"/> that match an entry.</summary>
    public int SkippedByCatalog { get; set; }

    /// <summary>Tests the runner reported as disabled although no entry matches them.</summary>
    public List<string> UnexpectedlyDisabled { get; } = new();

    /// <summary>Entries that matched no test in the run (stale, or outside this selection).</summary>
    public List<DisabledTestEntry> UnmatchedEntries { get; } = new();

    public bool IsValid => ExecutedDisabledTests.Count == 0 && UnexpectedlyDisabled.Count == 0;
}

/// <summary>
/// Loads the repository's DisabledTests files and converts them to the runner payload, mirroring
/// the native AL-Go flow (Get-DisabledTestsForApp): for an app named "My App", every
/// <c>&lt;DisabledTests root&gt;\My_App\*.json</c> file holds an array of
/// <c>{ "codeunitId", "codeunitName", "method", "bug" }</c> objects. <c>method</c> may be '*' (whole
/// codeunit) or contain '*'/'?' wildcards. Codeunit and method names match case-insensitively.
/// </summary>
public sealed class DisabledTestCatalog
{
    private readonly List<DisabledTestEntry> _entries;

    private DisabledTestCatalog(List<DisabledTestEntry> entries, List<string> sourceFiles)
    {
        _entries = entries;
        SourceFiles = sourceFiles;
    }

    public IReadOnlyList<DisabledTestEntry> Entries => _entries;
    public IReadOnlyList<string> SourceFiles { get; }

    public static DisabledTestCatalog Empty { get; } = new(new List<DisabledTestEntry>(), new List<string>());

    /// <summary>Folder name native AL-Go derives from an app name (spaces become underscores).</summary>
    public static string AppFolderName(string appName) => appName.Trim().Replace(' ', '_');

    /// <summary>
    /// Loads entries from files and/or folders. A folder is treated as a DisabledTests root: with an
    /// app name only its <c>&lt;App_Name&gt;\*.json</c> files are read (or the folder itself when it is
    /// the app folder); without an app name every *.json below it is read.
    /// </summary>
    public static DisabledTestCatalog Load(IEnumerable<string> paths, string? appName)
    {
        var files = new List<string>();
        foreach (var path in paths)
        {
            if (File.Exists(path))
            {
                files.Add(Path.GetFullPath(path));
                continue;
            }
            if (!Directory.Exists(path))
                throw new BcDevEnvException($"Disabled tests path not found: '{path}'.");

            if (string.IsNullOrWhiteSpace(appName))
            {
                files.AddRange(Directory.GetFiles(path, "*.json", SearchOption.AllDirectories));
                continue;
            }

            var folder = AppFolderName(appName);
            var appDir = Path.Combine(path, folder);
            if (Directory.Exists(appDir))
                files.AddRange(Directory.GetFiles(appDir, "*.json", SearchOption.TopDirectoryOnly));
            else if (string.Equals(new DirectoryInfo(path).Name, folder, StringComparison.OrdinalIgnoreCase))
                files.AddRange(Directory.GetFiles(path, "*.json", SearchOption.TopDirectoryOnly));
        }

        var distinct = files.Select(Path.GetFullPath).Distinct(StringComparer.OrdinalIgnoreCase)
            .OrderBy(f => f, StringComparer.OrdinalIgnoreCase).ToList();
        var entries = new List<DisabledTestEntry>();
        foreach (var file in distinct)
            entries.AddRange(ParseFile(file));
        return new DisabledTestCatalog(entries, distinct);
    }

    /// <summary>Parses one DisabledTests JSON document (an array of entries, or a single entry).</summary>
    public static IReadOnlyList<DisabledTestEntry> Parse(string json, string source)
    {
        JsonDocument doc;
        try
        {
            doc = JsonDocument.Parse(json, new JsonDocumentOptions { AllowTrailingCommas = true, CommentHandling = JsonCommentHandling.Skip });
        }
        catch (JsonException ex)
        {
            throw new BcDevEnvException($"Invalid DisabledTests JSON in '{source}': {ex.Message}", ex);
        }

        using (doc)
        {
            var items = doc.RootElement.ValueKind switch
            {
                JsonValueKind.Array => doc.RootElement.EnumerateArray().ToList(),
                JsonValueKind.Object => new List<JsonElement> { doc.RootElement },
                _ => throw new BcDevEnvException($"DisabledTests file '{source}' must contain a JSON array of entries."),
            };

            var result = new List<DisabledTestEntry>();
            var index = 0;
            foreach (var item in items)
            {
                index++;
                if (item.ValueKind != JsonValueKind.Object)
                    throw new BcDevEnvException($"DisabledTests entry #{index} in '{source}' is not an object.");
                var codeunitName = GetString(item, "codeunitName");
                var method = GetString(item, "method");
                if (string.IsNullOrWhiteSpace(codeunitName) || string.IsNullOrWhiteSpace(method))
                    throw new BcDevEnvException(
                        $"DisabledTests entry #{index} in '{source}' needs non-empty 'codeunitName' and 'method'.");
                int? codeunitId = null;
                if (TryGetProperty(item, "codeunitId", out var idElement))
                {
                    if (idElement.ValueKind == JsonValueKind.Number && idElement.TryGetInt32(out var id)) codeunitId = id;
                    else if (idElement.ValueKind == JsonValueKind.String && int.TryParse(idElement.GetString(), out var sid)) codeunitId = sid;
                }
                result.Add(new DisabledTestEntry(codeunitName.Trim(), method.Trim(), codeunitId,
                    GetString(item, "bug") ?? GetString(item, "bugId"), source));
            }
            return result;
        }
    }

    /// <summary>True when an entry disables <paramref name="method"/> of <paramref name="codeunitName"/>.</summary>
    public bool IsDisabled(string codeunitName, string method) =>
        _entries.Any(e => Matches(e, codeunitName, method));

    /// <summary>
    /// Serialises the catalog for the runner's PrepareTests action:
    /// <c>[{"codeunitName":"...","methods":["...","*"]}]</c>, grouped by codeunit.
    /// </summary>
    public string ToRunnerJson()
    {
        var groups = _entries
            .GroupBy(e => e.CodeunitName, StringComparer.OrdinalIgnoreCase)
            .Select(g => new
            {
                codeunitName = g.First().CodeunitName,
                methods = g.Select(e => e.Method).Distinct(StringComparer.OrdinalIgnoreCase).ToList(),
            })
            .ToList();
        return JsonSerializer.Serialize(groups);
    }

    /// <summary>
    /// Checks the run: a test covered by an entry must have been skipped by the runner before
    /// execution, and the runner must not disable anything the catalog does not list.
    /// </summary>
    public DisabledTestVerification Verify(TestRunResult run)
    {
        var verification = new DisabledTestVerification();
        var matched = new HashSet<DisabledTestEntry>();
        var byCodeunit = _entries.GroupBy(e => e.CodeunitName, StringComparer.OrdinalIgnoreCase)
            .ToDictionary(g => g.Key, g => g.ToList(), StringComparer.OrdinalIgnoreCase);

        foreach (var cu in run.Codeunits)
        {
            var codeunitName = CodeunitNameOf(cu);
            byCodeunit.TryGetValue(codeunitName, out var codeunitEntries);
            foreach (var method in cu.Methods)
            {
                var entries = codeunitEntries?.Where(e => MethodMatches(e.Method, method.Name)).ToList()
                              ?? new List<DisabledTestEntry>();
                foreach (var entry in entries) matched.Add(entry);

                var skippedAsDisabled = method.Outcome == TestOutcome.Skipped &&
                    string.Equals(method.Message, TestSkipReasons.DisabledByDisabledTests, StringComparison.Ordinal);

                if (entries.Count > 0)
                {
                    if (skippedAsDisabled)
                        verification.SkippedByCatalog++;
                    else if (method.Outcome != TestOutcome.Skipped)
                        verification.ExecutedDisabledTests.Add(new ExecutedDisabledTest(codeunitName, method.Name, method.Outcome));
                }
                else if (skippedAsDisabled)
                {
                    verification.UnexpectedlyDisabled.Add($"{codeunitName}:{method.Name}");
                }
            }
        }

        verification.UnmatchedEntries.AddRange(_entries.Where(e => !matched.Contains(e)));
        return verification;
    }

    /// <summary>Case-insensitive glob match supporting '*' and '?' (same semantics as the AL runner).</summary>
    public static bool MethodMatches(string pattern, string method)
    {
        if (pattern == "*") return true;
        if (pattern.IndexOfAny(new[] { '*', '?' }) < 0)
            return string.Equals(pattern, method, StringComparison.OrdinalIgnoreCase);

        var value = method.ToLowerInvariant();
        var glob = pattern.ToLowerInvariant();
        int v = 0, p = 0, star = -1, mark = 0;
        while (v < value.Length)
        {
            if (p < glob.Length && (glob[p] == '?' || glob[p] == value[v])) { v++; p++; }
            else if (p < glob.Length && glob[p] == '*') { star = p++; mark = v; }
            else if (star >= 0) { p = star + 1; v = ++mark; }
            else return false;
        }
        while (p < glob.Length && glob[p] == '*') p++;
        return p == glob.Length;
    }

    /// <summary>The AL codeunit name of a result ("Codeunit 1 My Tests" -> "My Tests" when not reported explicitly).</summary>
    public static string CodeunitNameOf(TestCodeunitResult cu)
    {
        if (!string.IsNullOrWhiteSpace(cu.CodeunitName)) return cu.CodeunitName!;
        var parts = cu.Name.Split(' ', 3, StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length == 3 && parts[0].Equals("Codeunit", StringComparison.OrdinalIgnoreCase) && int.TryParse(parts[1], out _))
            return parts[2];
        return cu.Name;
    }

    private static bool Matches(DisabledTestEntry entry, string codeunitName, string method) =>
        string.Equals(entry.CodeunitName, codeunitName, StringComparison.OrdinalIgnoreCase) &&
        MethodMatches(entry.Method, method);

    private static IReadOnlyList<DisabledTestEntry> ParseFile(string file)
    {
        Log.Info($"Reading disabled tests from '{file}'.");
        return Parse(File.ReadAllText(file), file);
    }

    private static bool TryGetProperty(JsonElement element, string name, out JsonElement value)
    {
        foreach (var property in element.EnumerateObject())
        {
            if (property.Name.Equals(name, StringComparison.OrdinalIgnoreCase))
            {
                value = property.Value;
                return true;
            }
        }
        value = default;
        return false;
    }

    private static string? GetString(JsonElement element, string name)
    {
        if (!TryGetProperty(element, name, out var value)) return null;
        return value.ValueKind switch
        {
            JsonValueKind.String => value.GetString(),
            JsonValueKind.Number => value.GetRawText(),
            _ => null,
        };
    }
}
