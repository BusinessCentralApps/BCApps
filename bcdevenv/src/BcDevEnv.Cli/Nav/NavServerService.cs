using System.Management.Automation;
using BcDevEnv.Cli.Infra;

namespace BcDevEnv.Cli.Nav;

/// <summary>Server-instance and license operations via the BC management cmdlets (in-process).</summary>
public sealed class NavServerService
{
    private readonly NavRunspace _rs;

    public NavServerService(NavRunspace rs)
    {
        _rs = rs;
        _rs.ImportManagementModules();
    }

    public sealed record ServerPorts(
        int Management = 7045,
        int Client = 7046,
        int Soap = 7047,
        int ODataV4 = 7048,
        int Developer = 7049,
        int Reporting = 7084)
    {
        /// <summary>REST management API port (ManagementApiServicesPort; the server default is ManagementServicesPort + 41).</summary>
        public int ManagementApi => Management + 41;
    }

    /// <summary>
    /// Ports the NST and its side services bind through HTTP.sys as the service account, each of
    /// which needs a 'http://+:&lt;port&gt;/' URL reservation: management WCF, client, SOAP, OData,
    /// developer, the REST management API and the reporting side service
    /// (Microsoft.BusinessCentral.Reporting.Service.exe, which renders RDLC/Word layouts and saves
    /// reports as PDF/Excel/Word; without a reservation it dies with HttpSysException 'Access is
    /// denied' and every report run fails with 'Reporting service is not available').
    /// </summary>
    public static IReadOnlyList<int> UrlAclPorts(ServerPorts ports) =>
        new[] { ports.Management, ports.Client, ports.Soap, ports.ODataV4, ports.Developer, ports.ManagementApi, ports.Reporting }
            .Where(p => p > 0)
            .Distinct()
            .ToArray();

    /// <summary>Default network timeout for a company codeunit run (Invoke-NAVCodeunit).</summary>
    public static readonly TimeSpan DefaultCodeunitTimeout = TimeSpan.FromMinutes(BuildManifest.DefaultCompanyCodeunitTimeoutMinutes);

    /// <summary>
    /// Invoke-NAVCodeunit parameters. BC 30's script implementation defaults -NetworkTimeout to
    /// 600 s, which a full demo-data run (5193 CreateAllDemoData) can exceed on a slow runner, so
    /// the timeout is always passed. Retries are disabled explicitly: a codeunit run is not
    /// idempotent, and re-running demo-data generation after a client-side timeout would corrupt
    /// the company.
    /// </summary>
    public static Dictionary<string, object?> InvokeCodeunitParameters(
        string instance, string companyName, int codeunitId, string? methodName, TimeSpan timeout)
    {
        if (timeout <= TimeSpan.Zero)
            throw new BcDevEnvException($"The codeunit timeout must be positive (got {timeout}).");
        var parameters = new Dictionary<string, object?>
        {
            ["ServerInstance"] = instance,
            ["CompanyName"] = companyName,
            ["CodeunitId"] = codeunitId,
            ["NetworkTimeout"] = timeout,
            ["MaxRetries"] = 0,
        };
        if (!string.IsNullOrWhiteSpace(methodName)) parameters["MethodName"] = methodName;
        return parameters;
    }

    /// <summary>
    /// The database application family for an environment country: the upper-case country code
    /// (FR, GB, US, ...), or W1 for a blank, 'base' or 'w1' country. The server reads it to decide
    /// which country-specific feature keys exist (e.g. SalesFR and Payment only for FR,
    /// VATReverseCharge only for GB), and AL reads it through
    /// EnvironmentInformation.GetApplicationFamily(). A create-env database has none, which the
    /// server treats as W1 - so without it a localized app set runs as if it were W1.
    /// </summary>
    public static string ApplicationFamilyFor(string? country)
    {
        var value = (country ?? string.Empty).Trim();
        if (value.Length == 0 || value.Equals("base", StringComparison.OrdinalIgnoreCase))
            return "W1";
        if (value.Length > 50 || !value.All(char.IsAsciiLetterOrDigit))
            throw new BcDevEnvException($"Invalid country '{country}': expected a country code such as W1, FR or GB.");
        return value.ToUpperInvariant();
    }

    /// <summary>Sets the database application family (Set-NAVApplication) on a running instance.</summary>
    public void SetApplicationFamily(string instance, string applicationFamily)
    {
        Log.Info($"Setting the application family of '{instance}' to '{applicationFamily}'...");
        _rs.Invoke("Set-NAVApplication", new Dictionary<string, object?>
        {
            ["ServerInstance"] = instance,
            ["ApplicationFamily"] = applicationFamily,
            ["Force"] = true,
        });
        Log.Success($"Application family is '{applicationFamily}'.");
    }

    /// <summary>
    /// Creates a fresh, empty Business Central application database from the platform artifact
    /// (New-NAVApplicationDatabase). This contains the platform/system tables only - no System or
    /// Base Application and no demo data (those are installed later as .app packages via install-app).
    /// </summary>
    public void NewApplicationDatabase(string databaseServer, string databaseName, string? databaseLocation, string? collation)
    {
        Log.Info($"Creating application database '{databaseName}' on '{databaseServer}'...");
        var p = new Dictionary<string, object?>
        {
            ["DatabaseServer"] = databaseServer,
            ["DatabaseName"] = databaseName,
            ["Force"] = true,
        };
        if (!string.IsNullOrWhiteSpace(databaseLocation)) p["DatabaseLocation"] = databaseLocation;
        if (!string.IsNullOrWhiteSpace(collation)) p["Collation"] = collation;
        _rs.Invoke("New-NAVApplicationDatabase", p);
        Log.Success($"Created application database '{databaseName}'.");
    }

    public bool InstanceExists(string instance)
    {
        var results = _rs.Invoke("Get-NAVServerInstance", new Dictionary<string, object?>
        {
            ["ServerInstance"] = instance,
        });
        return results.Count > 0;
    }

    public void NewInstance(string instance, string databaseServer, string? databaseInstance, string databaseName, ServerPorts ports)
    {
        Log.Info($"Registering NST '{instance}' (db='{databaseName}' on '{databaseServer}')...");
        var p = new Dictionary<string, object?>
        {
            ["ServerInstance"] = instance,
            ["DatabaseServer"] = databaseServer,
            ["DatabaseName"] = databaseName,
            ["ManagementServicesPort"] = ports.Management,
            ["ClientServicesPort"] = ports.Client,
            ["SOAPServicesPort"] = ports.Soap,
            ["ODataServicesPort"] = ports.ODataV4,
            ["DeveloperServicesPort"] = ports.Developer,
        };
        if (!string.IsNullOrWhiteSpace(databaseInstance))
            p["DatabaseInstance"] = databaseInstance;
        try
        {
            _rs.Invoke("New-NAVServerInstance", p);
        }
        catch (BcDevEnvException ex) when (NeedsTemplateInstance(ex))
        {
            // New-NAVServerInstance clones a "template" server instance that only the BC product
            // installer creates. From loose platform-artifact binaries that template is absent, so
            // we register the Windows service directly - exactly what the NAV ServerUtil/
            // WindowsServiceInstaller does under the covers (the service points the server exe at a
            // per-instance CustomSettings.config and runs as NT AUTHORITY\NetworkService).
            Log.Warn("No template server instance (expected with loose artifact binaries); " +
                     "registering the NST as a Windows service directly.");
            RegisterInstanceViaService(instance, databaseServer, databaseInstance, databaseName, ports);
        }
    }

    private static bool NeedsTemplateInstance(Exception ex)
    {
        var m = ex.Message;
        return m.Contains("template server instance", StringComparison.OrdinalIgnoreCase)
            || m.Contains("Install at least one BC server instance", StringComparison.OrdinalIgnoreCase)
            || m.Contains("Install at least one NAV Server instance", StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>
    /// Registers a Business Central server instance as a Windows service without a pre-installed
    /// template instance. Writes a per-instance CustomSettings.config under
    /// &lt;ServiceDir&gt;\Instances\&lt;instance&gt; (the layout the management cmdlets expect) and
    /// creates the service with the same shape the product installer uses:
    ///   bin: "&lt;Server.exe&gt;" $&lt;instance&gt; /config "&lt;instance config&gt;"  as NT AUTHORITY\NetworkService
    /// After this, Set-NAVServerConfiguration / Start-NAVServerInstance operate on the instance.
    /// </summary>
    public void RegisterInstanceViaService(string instance, string databaseServer, string? databaseInstance, string databaseName, ServerPorts ports)
    {
        var serviceDir = Paths.ServiceFolderForProvision();
        var serverExe = Path.Combine(serviceDir, "Microsoft.Dynamics.Nav.Server.exe");
        if (!File.Exists(serverExe))
            throw new BcDevEnvException($"BC server executable not found: '{serverExe}'.");

        var instanceDir = Path.Combine(serviceDir, "Instances", instance);
        Directory.CreateDirectory(instanceDir);
        var configPath = Path.Combine(instanceDir, "CustomSettings.config");

        var dbServerValue = databaseServer;
        var settings = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            ["ServerInstance"] = instance,
            ["DatabaseServer"] = dbServerValue,
            ["DatabaseInstance"] = databaseInstance ?? string.Empty,
            ["DatabaseName"] = databaseName,
            ["ManagementServicesPort"] = ports.Management.ToString(),
            ["ClientServicesPort"] = ports.Client.ToString(),
            ["SOAPServicesPort"] = ports.Soap.ToString(),
            ["ODataServicesPort"] = ports.ODataV4.ToString(),
            ["DeveloperServicesPort"] = ports.Developer.ToString(),
            ["ManagementApiServicesPort"] = ports.ManagementApi.ToString(),
            ["ReportingServicePort"] = ports.Reporting.ToString(),
            ["DeveloperServicesEnabled"] = "true",
            ["ODataServicesEnabled"] = "true",
            ["SOAPServicesEnabled"] = "true",
            ["ClientServicesCredentialType"] = "Windows",
            ["NetworkProtocol"] = "Default",
        };
        WriteInstanceConfig(serviceDir, configPath, settings);

        var serviceName = $"MicrosoftDynamicsNavServer${instance}";
        // Remove any stale registration first (ignore failure if absent).
        ProcessRunner.Capture("sc.exe", new[] { "delete", serviceName });

        var binPath = $"\"{serverExe}\" ${instance} /config \"{configPath}\"";
        var createArgs = new[]
        {
            "create", serviceName,
            "binPath=", binPath,
            "obj=", "NT AUTHORITY\\NetworkService",
            "start=", "demand",
            "DisplayName=", $"Microsoft Dynamics 365 Business Central Server [{instance}]",
        };
        var (code, stdout, stderr) = ProcessRunner.Capture("sc.exe", createArgs);
        if (code != 0)
            throw new BcDevEnvException($"Failed to register BC server service '{serviceName}': {stdout} {stderr}".Trim());
        Log.Success($"Registered BC server service '{serviceName}'.");

        // The BC server writes to a Windows event-log source named like the service. The product
        // installer normally creates it; from loose binaries it does not exist, and the server
        // (especially running as NETWORK SERVICE) cannot create it itself - it FailFast-crashes on
        // start with a SecurityException. Pre-create it here while running as admin.
        EnsureEventSource(serviceName);

        // The server (as NETWORK SERVICE) creates per-tenant working folders under
        // C:\ProgramData\Microsoft\Microsoft Dynamics NAV\<ver>\Server; the installer grants that
        // tree to the service account. Without it the server throws UnauthorizedAccessException in
        // ConfigureTenants and crashes on start. Grant NETWORK SERVICE full control (inherited),
        // plus the binaries/instance folder it reads config from and writes keys to.
        EnsureServerDataAccess(serviceDir);

        // The server and its reporting side service listen via HTTP.sys; NETWORK SERVICE cannot
        // bind 'http://+:<port>/' without a URL reservation (the installer registers these).
        // Without it the NST crashes on start with HttpSysException (5) 'prefix ... is not
        // registered', and the reporting service with 'Access is denied'.
        EnsureUrlAcls(ports);
    }

    /// <summary>Reserves the HTTP.sys URL namespaces the NST and its side services bind, for the service account.</summary>
    private static void EnsureUrlAcls(ServerPorts ports)
    {
        const string account = "NT AUTHORITY\\NETWORK SERVICE";
        var failed = 0;
        foreach (var port in UrlAclPorts(ports))
        {
            try
            {
                var (code, stdout, stderr) = ProcessRunner.Capture("netsh.exe", new[] { "http", "add", "urlacl", $"url=http://+:{port}/", $"user={account}" });
                // Error 183 = ERROR_ALREADY_EXISTS (reservation present from an earlier run).
                if (code != 0 && code != 183 && !(stdout + stderr).Contains("183"))
                {
                    failed++;
                    Log.Warn($"netsh http add urlacl for port {port} failed (exit {code}): {(stdout + stderr).Trim()}");
                }
            }
            catch (Exception ex) { failed++; Log.Warn($"Could not add urlacl for port {port}: {ex.Message}"); }
        }
        if (failed == 0) Log.Success("Reserved HTTP.sys URL ACLs for the NST and its reporting service.");
    }

    /// <summary>Creates the server's ProgramData tree and grants the NST service account access.</summary>
    private static void EnsureServerDataAccess(string serviceDir)
    {
        // *S-1-5-20 = NT AUTHORITY\NETWORK SERVICE (locale-independent).
        foreach (var dir in new[] { @"C:\ProgramData\Microsoft\Microsoft Dynamics NAV", serviceDir })
        {
            try
            {
                Directory.CreateDirectory(dir);
                ProcessRunner.Capture("icacls.exe", new[] { dir, "/grant", "*S-1-5-20:(OI)(CI)F", "/T", "/C", "/Q" });
                Log.Success($"Granted NETWORK SERVICE full control on '{dir}'.");
            }
            catch (Exception ex) { Log.Warn($"Could not grant server data access on '{dir}': {ex.Message}"); }
        }
    }

    /// <summary>Creates the Application event-log source the NST writes to, if it does not exist.</summary>
    private static void EnsureEventSource(string source)
    {
        var script =
            $"try {{ if (-not [System.Diagnostics.EventLog]::SourceExists('{source}')) {{ " +
            $"[System.Diagnostics.EventLog]::CreateEventSource('{source}','Application') }} }} catch {{ Write-Host $_.Exception.Message }}";
        var (_, stdout, stderr) = ProcessRunner.Capture("powershell.exe", new[] { "-NoProfile", "-Command", script });
        var msg = (stdout + stderr).Trim();
        if (!string.IsNullOrEmpty(msg)) Log.Verbose($"EnsureEventSource: {msg}");
        Log.Success($"Ensured event-log source '{source}'.");
    }

    /// <summary>
    /// Writes a per-instance CustomSettings.config by cloning the service-tier template
    /// (&lt;ServiceDir&gt;\CustomSettings.config) and applying the supplied overrides. The template is
    /// &lt;appSettings&gt;-rooted, so it is wrapped in &lt;configuration&gt; which the server requires.
    /// </summary>
    private static void WriteInstanceConfig(string serviceDir, string configPath, IReadOnlyDictionary<string, string> overrides)
    {
        var templatePath = Path.Combine(serviceDir, "CustomSettings.config");
        System.Xml.Linq.XElement appSettings;
        if (File.Exists(templatePath))
        {
            var templateDoc = System.Xml.Linq.XDocument.Load(templatePath);
            appSettings = templateDoc.Descendants("appSettings").FirstOrDefault()
                          ?? new System.Xml.Linq.XElement("appSettings");
            appSettings = new System.Xml.Linq.XElement(appSettings); // detached copy
        }
        else
        {
            appSettings = new System.Xml.Linq.XElement("appSettings");
        }

        foreach (var kv in overrides)
        {
            var node = appSettings.Elements("add")
                .FirstOrDefault(e => string.Equals((string?)e.Attribute("key"), kv.Key, StringComparison.OrdinalIgnoreCase));
            if (node == null)
            {
                node = new System.Xml.Linq.XElement("add", new System.Xml.Linq.XAttribute("key", kv.Key));
                appSettings.Add(node);
            }
            node.SetAttributeValue("value", kv.Value);
        }

        // The per-instance CustomSettings.config must be a standard .NET app.config
        // (<configuration><appSettings>) - that is what Set-NAVServerConfiguration and the server
        // read. (A bare <appSettings> root makes Set-NAVServerConfiguration fall back to defaults.)
        var doc = new System.Xml.Linq.XDocument(
            new System.Xml.Linq.XDeclaration("1.0", "utf-8", null),
            new System.Xml.Linq.XElement("configuration", appSettings));
        doc.Save(configPath);
    }

    public void SetConfiguration(string instance, string key, object value)
    {
        _rs.Invoke("Set-NAVServerConfiguration", new Dictionary<string, object?>
        {
            ["ServerInstance"] = instance,
            ["KeyName"] = key,
            ["KeyValue"] = value.ToString(),
            ["Force"] = true,
        });
    }

    public void ImportLicense(string instance, string licenseFile)
    {
        if (!File.Exists(licenseFile))
            throw new BcDevEnvException($"License file not found: '{licenseFile}'.");
        Log.Info($"Importing license into '{instance}'...");
        _rs.Invoke("Import-NAVServerLicense", new Dictionary<string, object?>
        {
            ["ServerInstance"] = instance,
            ["LicenseFile"] = licenseFile,
            // Store the license in the application database ($ndo$srvproperty), which exists there.
            // The default scope targets master.dbo.$ndo$srvproperty, which a loose-binary install
            // has not created (SQL error 208, invalid object name).
            ["Database"] = "NavDatabase",
        });
    }

    public void Start(string instance)
    {
        Log.Info($"Starting NST '{instance}'...");
        _rs.Invoke("Start-NAVServerInstance", new Dictionary<string, object?> { ["ServerInstance"] = instance });
    }

    /// <summary>
    /// Creates a company (no demo data). An evaluation company is what the Contoso demo tool expects
    /// when it generates the full (CRONUS-style) data set.
    /// </summary>
    public void CreateCompany(string instance, string companyName, bool evaluationCompany = false)
    {
        Log.Info($"Creating {(evaluationCompany ? "evaluation " : "")}company '{companyName}' on '{instance}'...");
        var parameters = new Dictionary<string, object?>
        {
            ["ServerInstance"] = instance,
            ["CompanyName"] = companyName,
        };
        if (evaluationCompany) parameters["EvaluationCompany"] = true;
        _rs.Invoke("New-NAVCompany", parameters);
        Log.Success($"Created company '{companyName}'.");
    }

    /// <summary>Runs a codeunit (or one of its methods) in a company, as Invoke-NAVCodeunit does.</summary>
    public void InvokeCodeunit(string instance, string companyName, int codeunitId, string? methodName = null, TimeSpan? timeout = null)
    {
        var target = methodName == null ? $"codeunit {codeunitId}" : $"codeunit {codeunitId} ({methodName})";
        var effectiveTimeout = timeout ?? DefaultCodeunitTimeout;
        Log.Info($"Running {target} in company '{companyName}' (timeout {effectiveTimeout})...");
        _rs.Invoke("Invoke-NAVCodeunit", InvokeCodeunitParameters(instance, companyName, codeunitId, methodName, effectiveTimeout));
        Log.Success($"Completed {target}.");
    }

    /// <summary>
    /// Creates a Business Central user mapped to a Windows account and grants it SUPER, so an
    /// OData/web-service call authenticated as that account is authorized. Needed because an empty
    /// platform database has no users (and installing apps creates none).
    /// </summary>
    public void CreateSuperUser(string instance, string windowsAccount)
    {
        Log.Info($"Creating SUPER user for '{windowsAccount}' on '{instance}'...");
        _rs.Invoke("New-NAVServerUser", new Dictionary<string, object?>
        {
            ["ServerInstance"] = instance,
            ["WindowsAccount"] = windowsAccount,
        });
        _rs.Invoke("New-NAVServerUserPermissionSet", new Dictionary<string, object?>
        {
            ["ServerInstance"] = instance,
            ["WindowsAccount"] = windowsAccount,
            ["PermissionSetId"] = "SUPER",
        });
        Log.Success($"Granted SUPER to '{windowsAccount}'.");
    }

    public void Stop(string instance)
    {
        _rs.Invoke("Stop-NAVServerInstance", new Dictionary<string, object?> { ["ServerInstance"] = instance });
    }

    /// <summary>
    /// Synchronizes the tenant database schema, bringing a freshly created platform database to the
    /// operational state (version &gt; 0). Required before any extension can be synchronized.
    /// </summary>
    public void SyncTenant(string instance)
    {
        Log.Info($"Synchronizing tenant database for '{instance}'...");
        _rs.Invoke("Sync-NAVTenant", new Dictionary<string, object?>
        {
            ["ServerInstance"] = instance,
            ["Mode"] = "Sync",
            ["Force"] = true,
        });
        Log.Success("Synchronized tenant database.");
    }

    public bool IsRunning(string instance)
    {
        var results = _rs.Invoke("Get-NAVServerInstance", new Dictionary<string, object?>
        {
            ["ServerInstance"] = instance,
        });
        if (results.Count == 0) return false;
        var state = results[0].Properties["State"]?.Value?.ToString();
        return string.Equals(state, "Running", StringComparison.OrdinalIgnoreCase);
    }
}
