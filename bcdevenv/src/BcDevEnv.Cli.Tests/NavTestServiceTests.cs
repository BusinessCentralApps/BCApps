using BcDevEnv.Cli.Nav;
using BcDevEnv.Cli.Testing;
using Xunit;

namespace BcDevEnv.Cli.Tests;

public class NavTestServiceTests
{
    [Fact]
    public void BuildRunnerUrl_composes_unbound_action()
    {
        var url = NavTestService.BuildRunnerUrl(new NavTestService.RunOptions
        {
            ODataBaseUrl = "http://localhost:7048/BC/ODataV4/",
            ServiceName = "BcDevEnvTestRunner",
            RunAction = "RunAll",
        });
        Assert.Equal("http://localhost:7048/BC/ODataV4/BcDevEnvTestRunner_RunAll", url);
    }

    [Fact]
    public void BuildRunnerUrl_includes_company_key_when_supplied()
    {
        var url = NavTestService.BuildRunnerUrl(new NavTestService.RunOptions
        {
            ODataBaseUrl = "http://host:7048/BC/ODataV4",
            ServiceName = "Runner",
            RunAction = "RunAll",
            Company = "CRONUS US",
        });
        Assert.Equal("http://host:7048/BC/ODataV4/Runner_RunAll?company=CRONUS%20US", url);
    }

    [Fact]
    public void ExtractXml_returns_xml_directly()
    {
        var xml = "<assemblies><assembly/></assemblies>";
        Assert.Equal(xml, NavTestService.ExtractXml(xml));
    }

    [Fact]
    public void ExtractXml_unwraps_odata_value_envelope()
    {
        var body = "{\"@odata.context\":\"x\",\"value\":\"<assemblies><assembly/></assemblies>\"}";
        Assert.Equal("<assemblies><assembly/></assemblies>", NavTestService.ExtractXml(body));
    }

    [Fact]
    public void ExtractXml_strips_bom_and_whitespace()
    {
        var body = "\uFEFF\n  <assemblies/>";
        Assert.Equal("<assemblies/>", NavTestService.ExtractXml(body));
    }

    [Fact]
    public void XUnit_to_JUnit_roundtrip_preserves_totals()
    {
        const string xunit = """
<assemblies>
  <assembly name="A">
    <collection name="Codeunit 1 A Tests">
      <test method="T1" result="Pass" time="1" />
      <test method="T2" result="Fail" time="2"><failure><message>boom</message></failure></test>
    </collection>
  </assembly>
</assemblies>
""";
        var run = XUnitResultParser.Parse(xunit);
        var doc = JUnitResultWriter.ToDocument(run);
        Assert.Equal("2", doc.Root!.Attribute("tests")!.Value);
        Assert.Equal("1", doc.Root!.Attribute("failures")!.Value);
    }

    [Fact]
    public void XUnit_to_JUnit_preserves_ALGo_app_metadata()
    {
        const string xml = """
<assemblies><assembly name="DEFAULT">
  <collection name="Codeunit 1 Tests" appName="System Application Test" extensionId="test-extension">
    <test method="Example" result="Pass" time="1"/>
  </collection>
</assembly></assemblies>
""";
        var doc = JUnitResultWriter.ToDocument(XUnitResultParser.Parse(xml));
        var properties = doc.Descendants("property").ToDictionary(
            p => p.Attribute("name")!.Value, p => p.Attribute("value")!.Value);
        Assert.Equal("System Application Test", properties["appName"]);
        Assert.Equal("test-extension", properties["extensionId"]);
    }
}
