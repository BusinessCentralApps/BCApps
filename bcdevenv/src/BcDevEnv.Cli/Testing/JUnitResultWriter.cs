using System.Globalization;
using System.Xml.Linq;

namespace BcDevEnv.Cli.Testing;

/// <summary>
/// Serialises a <see cref="TestRunResult"/> to a JUnit XML document (the standard
/// &lt;testsuites&gt;/&lt;testsuite&gt;/&lt;testcase&gt; schema understood by GitHub Actions test
/// reporters, Azure DevOps, Jenkins, etc.). Pure and side-effect free apart from <see cref="WriteFile"/>.
/// Suites and test cases are named like BcContainerHelper's JUnit output ("&lt;codeunit id&gt; &lt;codeunit
/// name&gt;", properties <c>appName</c> and <c>extensionid</c> with the app id as a lower-case GUID), so
/// AL-Go's AnalyzeTests and BCApps' Test Tolerance (build/scripts/TestTolerance) read them.
/// </summary>
public static class JUnitResultWriter
{
    public static XDocument ToDocument(TestRunResult run, string suiteName = "BusinessCentral")
    {
        var root = new XElement("testsuites",
            new XAttribute("name", suiteName),
            new XAttribute("tests", run.Total),
            new XAttribute("failures", run.Failed),
            new XAttribute("errors", 0),
            new XAttribute("skipped", run.Skipped),
            new XAttribute("time", Fmt(run.DurationSeconds)));

        foreach (var cu in run.Codeunits)
        {
            var name = SuiteName(cu);
            var suite = new XElement("testsuite",
                new XAttribute("name", name),
                new XAttribute("tests", cu.Total),
                new XAttribute("failures", cu.Failed),
                new XAttribute("errors", 0),
                new XAttribute("skipped", cu.Skipped),
                new XAttribute("time", Fmt(cu.DurationSeconds)),
                new XAttribute("timestamp", run.StartedUtc.ToString("o", CultureInfo.InvariantCulture)));

            if (cu.CodeunitId is int id)
                suite.Add(new XAttribute("id", id));

            var properties = new XElement("properties",
                new XElement("property", new XAttribute("name", "appName"),
                    new XAttribute("value", Clean(cu.AppName) ?? suiteName)));
            if (cu.ExtensionId != null)
                properties.Add(new XElement("property", new XAttribute("name", "extensionid"),
                    new XAttribute("value", NormalizeExtensionId(cu.ExtensionId))));
            suite.Add(properties);

            foreach (var m in cu.Methods)
            {
                var test = new XElement("testcase",
                    new XAttribute("name", m.Name),
                    new XAttribute("classname", name),
                    new XAttribute("time", Fmt(m.DurationSeconds)));

                switch (m.Outcome)
                {
                    case TestOutcome.Failed:
                        var failure = new XElement("failure",
                            new XAttribute("message", Clean(m.Message) ?? "Test failed"),
                            new XAttribute("type", "Failure"));
                        if (!string.IsNullOrWhiteSpace(m.StackTrace))
                            failure.Add(new XText(Clean(m.StackTrace)!));
                        test.Add(failure);
                        break;
                    case TestOutcome.Skipped:
                        var skipped = new XElement("skipped",
                            new XAttribute("message", Clean(m.Message) ?? "Test skipped"));
                        test.Add(skipped);
                        break;
                }

                suite.Add(test);
            }

            root.Add(suite);
        }

        return new XDocument(new XDeclaration("1.0", "utf-8", null), root);
    }

    public static string ToXml(TestRunResult run, string suiteName = "BusinessCentral")
    {
        var doc = ToDocument(run, suiteName);
        using var sw = new StringWriter();
        doc.Save(sw);
        return sw.ToString();
    }

    public static void WriteFile(TestRunResult run, string path, string suiteName = "BusinessCentral")
    {
        var dir = Path.GetDirectoryName(Path.GetFullPath(path));
        if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
        ToDocument(run, suiteName).Save(path);
    }

    /// <summary>"&lt;codeunit id&gt; &lt;codeunit name&gt;" (e.g. "134000 Customer Tests"); the result's name when the id is unknown.</summary>
    public static string SuiteName(TestCodeunitResult cu)
    {
        var name = Clean(cu.Name) ?? string.Empty;
        if (cu.CodeunitId is not int id) return name;
        var codeunitName = Clean(DisabledTestCatalog.CodeunitNameOf(cu))?.Trim();
        var idText = id.ToString(CultureInfo.InvariantCulture);
        if (string.IsNullOrEmpty(codeunitName) || codeunitName == idText ||
            string.Equals(codeunitName, "Codeunit " + idText, StringComparison.OrdinalIgnoreCase))
            return idText;
        return $"{idText} {codeunitName}";
    }

    /// <summary>The app id as a lower-case GUID without braces (as AL-Go writes it); other values trimmed as is.</summary>
    public static string NormalizeExtensionId(string extensionId)
    {
        var value = (Clean(extensionId) ?? string.Empty).Trim();
        return Guid.TryParse(value, out var guid) ? guid.ToString("D") : value;
    }

    private static string Fmt(double seconds) =>
        seconds.ToString("0.000", CultureInfo.InvariantCulture);

    // XML attribute/content must not contain raw control characters that the runner sometimes emits.
    private static string? Clean(string? s)
    {
        if (s == null) return null;
        var chars = s.Where(c => c == '\t' || c == '\n' || c == '\r' || c >= ' ').ToArray();
        return new string(chars);
    }
}
