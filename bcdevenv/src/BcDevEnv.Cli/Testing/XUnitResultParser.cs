using System.Globalization;
using System.Xml.Linq;
using BcDevEnv.Cli.Infra;

namespace BcDevEnv.Cli.Testing;

/// <summary>
/// Parses the xUnit-style result document that the Business Central test runner emits
/// (root &lt;assemblies&gt; with &lt;assembly&gt;/&lt;collection&gt;/&lt;test&gt; elements) into the
/// tool's <see cref="TestRunResult"/> model. This is the single conversion point used by both the
/// live run path (the automated Test Tool hands back this XML) and <c>run-tests --from-xml</c>.
/// </summary>
public static class XUnitResultParser
{
    public static TestRunResult Parse(string xml)
    {
        if (string.IsNullOrWhiteSpace(xml))
            throw new BcDevEnvException("The test runner returned an empty result document.");

        XDocument doc;
        try
        {
            doc = XDocument.Parse(xml);
        }
        catch (Exception ex)
        {
            throw new BcDevEnvException($"Could not parse the test result XML: {ex.Message}", ex);
        }

        var root = doc.Root ?? throw new BcDevEnvException("The test result XML has no root element.");
        var run = new TestRunResult();

        // <assemblies> may be the root, or a single <assembly> may be the root.
        var assemblies = root.Name.LocalName.Equals("assembly", StringComparison.OrdinalIgnoreCase)
            ? new[] { root }
            : root.Elements().Where(e => e.Name.LocalName.Equals("assembly", StringComparison.OrdinalIgnoreCase));

        foreach (var assembly in assemblies)
        {
            // Each <collection> maps to one AL test codeunit.
            foreach (var collection in assembly.Elements().Where(e => e.Name.LocalName.Equals("collection", StringComparison.OrdinalIgnoreCase)))
            {
                var collectionName = Attr(collection, "name");
                var cu = new TestCodeunitResult
                {
                    Name = collectionName ?? "UnknownCodeunit",
                    CodeunitId = ParseInt(Attr(collection, "codeunitId")) ?? ExtractCodeunitId(collectionName),
                    CodeunitName = Attr(collection, "codeunitName"),
                    AppName = Attr(collection, "appName") ?? Attr(assembly, "name"),
                    ExtensionId = Attr(collection, "extensionId"),
                };

                foreach (var test in collection.Elements().Where(e => e.Name.LocalName.Equals("test", StringComparison.OrdinalIgnoreCase)))
                {
                    var method = Attr(test, "method") ?? StripCodeunitPrefix(Attr(test, "name")) ?? "UnknownMethod";
                    var outcome = TestOutcomeParser.FromBc(Attr(test, "result"));

                    string? message = null, stack = null;
                    var failure = test.Elements().FirstOrDefault(e => e.Name.LocalName.Equals("failure", StringComparison.OrdinalIgnoreCase));
                    if (failure != null)
                    {
                        message = ElementText(failure, "message") ?? Attr(failure, "message");
                        stack = ElementText(failure, "stack-trace") ?? ElementText(failure, "stacktrace");
                    }
                    else
                    {
                        // xUnit v2 records why a test was skipped in a <reason> child.
                        message = ElementText(test, "reason");
                    }

                    cu.Methods.Add(new TestMethodResult
                    {
                        Name = method,
                        Outcome = outcome,
                        DurationSeconds = ParseSeconds(Attr(test, "time")),
                        Message = message,
                        StackTrace = stack,
                    });
                }

                run.Codeunits.Add(cu);
            }
        }

        return run;
    }

    private static string? Attr(XElement e, string name) =>
        e.Attributes().FirstOrDefault(a => a.Name.LocalName.Equals(name, StringComparison.OrdinalIgnoreCase))?.Value;

    private static string? ElementText(XElement parent, string name)
    {
        var child = parent.Elements().FirstOrDefault(e => e.Name.LocalName.Equals(name, StringComparison.OrdinalIgnoreCase));
        return child == null ? null : child.Value;
    }

    private static double ParseSeconds(string? value) =>
        double.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out var d) ? d : 0d;

    private static int? ParseInt(string? value) =>
        int.TryParse(value, NumberStyles.Integer, CultureInfo.InvariantCulture, out var i) ? i : null;

    // Collection names look like "Codeunit 134000 My Tests" - pull the numeric id when present.
    private static int? ExtractCodeunitId(string? name)
    {
        if (string.IsNullOrWhiteSpace(name)) return null;
        foreach (var token in name.Split(' ', StringSplitOptions.RemoveEmptyEntries))
            if (int.TryParse(token, out var id)) return id;
        return null;
    }

    // Test names are often "CodeunitName:MethodName" or "CodeunitName MethodName".
    private static string? StripCodeunitPrefix(string? name)
    {
        if (string.IsNullOrWhiteSpace(name)) return name;
        var colon = name.LastIndexOf(':');
        return colon >= 0 && colon < name.Length - 1 ? name[(colon + 1)..] : name;
    }
}
