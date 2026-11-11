namespace BcDevEnv.Cli.Cli;

public static class HelpText
{
    public const string Root = """
bcdevenv - build a self-contained Business Central dev container whose database
           is created from a specified platform artifact (independent of
           BcContainerHelper and of the NAV enlistment). A .NET 10 CLI that
           drives the BC management library in-process (no PowerShell scripts).

           The tool depends ONLY on a BC platform artifact folder (e.g.
           platform_30.0.54604.0), so it can live in its own repository. Point it
           at the artifact with --platform <dir> or BCDEVENV_PLATFORM.

USAGE
  bcdevenv <command> [options]

COMMANDS (host)
  create-env     Create a fresh empty platform database -> .bak (+ manifest)
  verify         Validate a platform artifact is usable (no SQL/Docker needed)
  install-app    Install a set of .app packages into a running server instance
  run-tests      Run the BC test suite against a running instance -> JUnit report
  build-image    Bake DB + platform binaries + license into a Windows image (Docker)
  start          Run a container from a built image (Docker)
  stop           Stop a running container (Docker)
  remove         Remove a container, optionally its image (Docker)
  list           List bcdevenv environments and images
  help [command] Show help

COMMANDS (inside the container image)
  provision      Restore .bak, register + configure the NST, license, bake-time apps
  serve          Container entrypoint: start SQL + NST and keep alive

Run 'bcdevenv help <command>' for command-specific options.
""";

    private static readonly Dictionary<string, string> Commands = new(StringComparer.OrdinalIgnoreCase)
    {
        ["create-env"] = """
create-env - Create a fresh, EMPTY platform database from the platform artifact
             and produce a .bak (+ manifest). Installs no apps and no demo data;
             add the app set separately with 'install-app' (the System/Base
             Application .app packages are just part of that set).

  --platform <dir>          Platform artifact folder (or set BCDEVENV_PLATFORM)
  --country <cc>            Country of the environment (default: artifact's); the image
                            provisioning sets it as the database application family
                            (upper-cased; blank/base = W1)
  --name <name>             Environment name (default: <country>-<version>)
  --database-name <n>       Database name to create (default: BC; empty platform
                            DB - no Base Application and no Cronus demo data)
  --collation <c>           SQL collation (default: Latin1_General_100_CS_AS)
  --data-dir <path>         Folder for the DB files (default: SQL default)
  --sql-server <host>       SQL host (default: localhost / BCDEVENV_SQL_SERVER)
  --sql-instance <name>     SQL instance (default: BCDEVENV_SQL_INSTANCE)
  --output <path>           Output .bak path (default: <home>\<name>\<db>.bak)
""",
        ["verify"] = """
verify - Validate that a platform artifact is usable without touching SQL,
         Docker or a live server instance: resolve the service tier + web client,
         import the BC management modules in-process, and assert the cmdlets that
         create-env (container DB + server instance) and install-app depend on are
         available. Exits non-zero if the artifact is unusable.

  --platform <dir>          Platform artifact folder (or set BCDEVENV_PLATFORM)
""",
        ["install-app"] = """
install-app - Publish + sync + install a set of .app packages into a running
              server instance. Standalone action; reuse at package time,
              container build time, or against a live container.

  --platform <dir>          Platform artifact (or BCDEVENV_PLATFORM / BCDEVENV_MGMT_DIR)
  --env <name>              Environment to read the target instance from
  --server-instance <name>  Target NST instance (default: env / BCDEVENV_INSTANCE / BC)
  --app-file <path>        .app file, folder, or glob; repeatable
  --scope <Global|Dev>     Publish scope (default: Global)
""",
        ["run-tests"] = """
run-tests - Run the Business Central test suite against a RUNNING server instance (or convert a
            test-runner result document produced elsewhere) and write a JUnit XML report. Exits
            non-zero when any test fails (unless --allow-failures), so it gates a CI build.

  RESULT OUTPUT
  --result-file <path>      JUnit report to write (default: TestResults\junit.xml)
  --suite-name <name>       Top-level <testsuites> name (default: BusinessCentral)
  --allow-failures          Do not fail the process when tests fail (still writes the report)
  --allow-empty             Treat "no tests found" as success instead of failure

  CONVERT MODE (no running server needed)
  --from-xml <path>         xUnit result document to convert; repeatable
  --results-dir <dir>       Folder of *.xml xUnit result documents to merge

  LIVE MODE (against a running instance created by create-env/start)
  --odata-url <url>         OData v4 base (default: http://<server>:<odata-port>/<instance>/ODataV4)
  --server <host>           Host for the derived URL (default: localhost)
  --odata-port <n>          OData port for the derived URL (default: 7048)
  --server-instance <name>  NST instance segment for the derived URL (default: BC)
  --service-name <name>     Published runner web service (default: BcDevEnvTestRunner)
  --run-action <name>       Runner action to invoke (default: RunAll)
  --test-suite <name>       Test suite to run (default: DEFAULT)
  --extension <guid>        Limit the run to a single extension (app id)
  --test-codeunit <filter>  Limit the run to a codeunit id / range
  --company <name>          Company to run in
  --auth <Windows|UserPassword>  Authentication (default: Windows)
  --user <name> / --password <pw> Credentials for UserPassword auth
  --timeout-minutes <n>     Runner HTTP timeout per call (default: 30)

  PER-CODEUNIT PROTOCOL (PrepareTests once, then one RunCodeunit call per test codeunit)
  --protocol <p>            per-codeunit | run-all (default: per-codeunit when any option
                            below is given, otherwise run-all)
  --disabled-tests <path>   DisabledTests root folder, app folder, or .json file; repeatable.
                            With --app-name only <root>\<App_Name>\*.json is read (spaces in
                            the app name become '_'). Matching tests are excluded BEFORE
                            execution and reported as skipped ("Disabled by DisabledTests").
                            A disabled test that still ran fails the command.
  --app-name <name>         App whose DisabledTests folder to read
  --test-type <t>           UnitTest | IntegrationTest | Uncategorized | AITest (or 0-4;
                            default: no categorization filter)
  --required-test-isolation <i>  None | Disabled | Codeunit | Function (or 0-3; with
                            --test-type, None selects codeunits requiring None or Codeunit)
  --test-runner-codeunit-id <n>  Test runner codeunit for the suite (e.g. 130450, 130451)

  EXECUTOR (who runs the selected tests; per-codeunit protocol only)
  --executor <odata|altool> odata (default): the runner's RunCodeunit over OData (a background
                            session: TestPage tests cannot run). altool: the AL tool's runtests
                            through the development endpoint (a client session, so TestPages
                            work). PrepareTests still selects the tests (test type, isolation,
                            DisabledTests); only the enabled methods are sent to the AL tool.
  --altool <path>           altool.dll (run via dotnet) or altool.exe; required for altool
  --dotnet <path>           dotnet host for altool.dll (default: %ProgramFiles%\dotnet\dotnet.exe)
  --dev-server <url>        Development endpoint host (default: http://localhost)
  --dev-port <n>            Development endpoint port (default: 7049)
  --altool-batch-size <n>   Test codeunits per runtests call (default: 20, at most 50)
  --app-timeout-minutes <n> Total AL tool time budget for this run (default: 240); batches
                            that do not fit are reported as infrastructure errors
  --permissions-mock <on|off>  Each AL tool invocation (batch) logs in once, and its test codeunits
                            share the last error, single-instance state and the permissions mock.
                            While the run is active (PrepareTests until the CLI ends it), the
                            BcDevEnv Test Runner clears the ApplicationArea that the login sets,
                            as the Test Runner does before every method. Before every test
                            codeunit a BcDevEnv Test Runner codeunit resets the state that
                            carries over: it restores the Application Area Setup table to its
                            state before the first test and commits it, turns off the
                            testability flags (SaaS, sandbox, preview, early preview) of
                            Environment Info Test Library and clears the secrets of Azure Key
                            Vault Test Library when System Application Test Library is
                            installed, runs codeunits 130301/132553 when present and clears the
                            last error. on (default):
                            the permissions mock is then started: without assignments for
                            codeunits whose TestPermissions is Disabled, otherwise with the
                            D365 Full Access base of codeunit 130302 (when present), as the
                            Test Runner does per method; off: it is stopped. When Application
                            Test Library is installed, a test method whose Initialize raises
                            Library - Test Initialize's OnTestInitialize gets the last error
                            cleared, the random seed 1 and the temporary notification context
                            cleared, as the Test Runner does per method, and, when Permissions
                            Mock is installed too and the mock is stopped, the mock restarted
                            with its codeunit's base (a started mock is left as it
                            is). A failed reset is an infrastructure error. The restores and the
                            sessions whose login ApplicationArea was cleared are logged as
                            "State reset: ..." after the run.
  --state-probe <on|off>    Diagnostic, off by default. on: the BcDevEnv State Probe codeunit
                            runs first in every batch, before the first reset; it always fails and
                            its message (ApplicationArea and the login hook, session,
                            Application Area Setup and its restores, TestPage control
                            visibility, permissions mock and its recorded base, the compiled
                            per-method and System Application Test Library resets, work date) is
                            logged as "State probe: ...". It is not a test result.

  Runner call failures and disabled-test violations fail the command even with --allow-failures.
""",
        ["build-image"] = """
build-image - Stage the .bak + platform Service/WebClient binaries (from the
              artifact) + license + the CLI, and run 'docker build'. Requires
              Docker in Windows-container mode.

  --platform <dir>          Platform artifact (default: --env's recorded artifact)
  --env <name>              Environment to bake (reads its manifest)
  --bak <path>              Explicit .bak (overrides --env)
  --country <cc>            Database application family to provision, e.g. FR or GB
                            (default: --env's country, else the artifact's; blank/base = W1).
                            Selects country-specific feature keys and GetApplicationFamily()
  --app-file <path>        Bake-time .app file/folder/glob; repeatable. Installed in the
                            given order (pass dependencies first)
  --app-list <file>         Text file with one .app path per line ('#' comments and blank
                            lines ignored); installed in file order after any --app-file
  --company <name>          Company the test context is provisioned in (default: Test)
  --evaluation-company      Create the company as an evaluation company
  --company-codeunit <id>[:<method>]  Codeunit (or codeunit method) to run in the company
                            after it is created, e.g. 2 (Company-Initialize) or
                            5193:CreateSetupDemoData; repeatable, run in order, any failure
                            fails the build
  --company-codeunit-timeout <minutes>  Network timeout for each company codeunit run
                            (default: 60; BC 30's Invoke-NAVCodeunit defaults to 10 minutes,
                            which full demo-data generation can exceed). Never retried
  --server-setting <key>=<value>  NST setting applied at provision time (e.g.
                            EnableTaskScheduler=false); repeatable, strict
  --server-instance <name>  NST instance baked into the image (default: BC)
  --tag <tag>               Image tag (default: bcdevenv:<version>-<country>)
  --base-image <ref>        Base image (default: mcr.microsoft.com/windows/servercore:ltsc2022)
  --credential-type <t>     Windows | NavUserPassword (default: Windows)
  --license <path>          License file to bake (or BCDEVENV_LICENSE). Required to bake
                            apps into the empty create-env database, which holds no
                            license - e.g. the CRONUS license (Cronus.bclicense) of a
                            Business Central application artifact
  --system32-file <path>    File copied into C:\Windows\System32 of the image when the base
                            image does not have it; repeatable. E.g. t2embed.dll (from
                            nav-docker-install.zip, install\t2embed.dll): Windows Server Core
                            lacks it, and rendering reports as PDF fails without it
  --registry <host>         Registry to prefix the tag with
  --push                    Push the image after building (never push an image that
                            contains a private license)
""",
        ["start"] = """
start - Run a container from a built image.

  --image <ref>             Image to run (required)
  --name <name>             Container name (default: bcdevenv)
  --port <n>                Host port mapped to the NST client services (default: 7049)
  --detach                  Run detached
""",
        ["stop"] = "stop - Stop a running container.\n\n  --name <name>   Container name (default: bcdevenv)",
        ["remove"] = "remove - Remove a container.\n\n  --name <name>    Container name (default: bcdevenv)\n  --purge-image    Also remove the image",
        ["list"] = "list - List bcdevenv environments (from the home folder) and images.",
        ["provision"] = """
provision - (container build step) Restore the staged .bak, register + configure
            the NST from baked binaries, import the license, install any
            bake-time apps, then create the test company + SUPER user(s) (the
            current account and, with Windows authentication, the server's
            NETWORK SERVICE account) and run the requested company codeunits.
            Reads build-manifest.json from --context (or cwd).
""",
        ["serve"] = "serve - (container entrypoint) Start SQL + the NST and keep the container alive.",
    };

    public static string For(string? command)
    {
        if (command != null && Commands.TryGetValue(command, out var text)) return text;
        return Root;
    }
}
