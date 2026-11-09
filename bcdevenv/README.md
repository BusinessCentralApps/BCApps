# bcdevenv

> **Provenance.** Copied from
> [BusinessCentralApps/bcdevenv](https://github.com/BusinessCentralApps/bcdevenv) at commit
> `16e2402765a5a1bdebdab3c12fbaf462ea3739b8` (the `bcdevenv/` CLI folder; the AL test-runner
> app that lived in that repository's `build/testrunner/` is now [`testrunner/`](testrunner/app.json)).
> Changes made here: the per-codeunit test protocol and DisabledTests support in `run-tests`
> and the runner app, `build-image` company/server-setting options and license checks, and the
> SQL Server Express setup script (`container/Install-SqlExpress.ps1`, replacing Chocolatey).
>
> In this repository the CLI drives the CI build: the
> [`RunBcDevEnvPipeline`](../.github/actions/RunBcDevEnvPipeline/action.yaml) action replaces
> AL-Go's `RunPipeline` in [`_BuildALGoProject.yaml`](../.github/workflows/_BuildALGoProject.yaml)
> (see [BCApps CI pipeline](#bcapps-ci-pipeline) below).

A **.NET 10 CLI** for building a **self-contained Business Central dev container**
whose database is created from a **BC platform artifact** — independent of both
BcContainerHelper and the NAV enlistment.

It exists to avoid the failure you hit with BcContainerHelper: when a new
platform lands, a *prebuilt* database snapshot no longer matches the platform.
`bcdevenv` creates a fresh database from the platform artifact you point it at,
and bakes it **together with that same artifact's binaries** into the image, so
the schema and the service tier can never drift.

## Depends only on the platform artifact

The tool needs **nothing but a BC platform artifact folder** (the thing you
download/produce as e.g. `platform_30.0.54604.0`). That artifact ships:

- the **pure-PowerShell BC management modules** (`ServiceTier\...\Service\Admin\`)
  — `New-NAVApplicationDatabase`, `New-NAVServerInstance`, `Import-NAVServerLicense`,
  `Publish/Sync/Install-NAVApp`, etc.;
- the **service-tier** binaries (`ServiceTier\...\Service`) and the **web client**
  (`WebClient\`).

Because there is no dependency on `INETROOT`, `projects.json`, `BuildDatabase.ps1`
or any other enlistment code, **this folder can be lifted into its own repository**
and still build and run. Point the tool at the artifact with `--platform <dir>`
or the `BCDEVENV_PLATFORM` environment variable.

## How it drives BC

The CLI hosts the BC management cmdlets **in-process** via
`Microsoft.PowerShell.SDK` (no `.ps1` scripts, no `powershell.exe` subprocess),
because the management operations are implemented inside `PSCmdlet` classes.
SQL steps (backup/restore/drop) go directly through **ADO.NET**
(`Microsoft.Data.SqlClient`). The CLI targets **net10.0**; the platform's own
assemblies are .NET (the sample artifact reports `dotNetVersion 10.0.12`).

## What create-env produces (important)

`create-env` builds a **fresh, EMPTY platform database** via
`New-NAVApplicationDatabase` — platform/system tables only. It installs **no
System/Base Application and no Contoso demo data**, because those are *not* part
of a platform artifact. You add the app set separately with `install-app`
(or at `build-image` time); the System/Base Application `.app` packages are
simply part of that set. This matches the "app install is a separate action"
design.

## Requirements

- **Windows containers only** for the image (`build-image`/`start`); BC Server is
  a Windows service and the image OS must match the host kernel. ~8–16 GB RAM.
- **.NET 10 SDK** to build the CLI.
- A reachable **SQL Server** for `create-env` (creates the DB) — local or remote.
- A **BC platform artifact** folder.

## Build

```powershell
cd <tool-folder>
dotnet build .\src\BcDevEnv.Cli\BcDevEnv.Cli.csproj -c Release
```

> The tool folder ships its own `Directory.Build.props/targets`,
> `Directory.Packages.props`, and `nuget.config`. Inside the NAV monorepo these
> disable Central Package Management / CoreXT inheritance and restore
> `Microsoft.PowerShell.SDK` + `Microsoft.Data.SqlClient` from **nuget.org**.
> In a standalone repo they are harmless and the project builds the same way.

## Install on PATH

```powershell
$env:PATH = "<tool-folder>;$env:PATH"
$env:BCDEVENV_PLATFORM = "C:\path\to\platform_30.0.54604.0"
bcdevenv help
```

`bcdevenv.cmd` runs the built exe if present, otherwise `dotnet run`.

## Commands

| Command | Phase | Runs where |
|---|---|---|
| `create-env` | Create a fresh empty platform DB from the artifact -> `.bak` | host |
| `verify` | Validate a platform artifact is usable (no SQL/Docker needed) | host |
| `install-app` | Install a set of `.app` packages into a running NST | host / live NST |
| `run-tests` | Run the BC test suite against a running NST -> JUnit report | host / live NST |
| `build-image` | Bake DB + platform binaries + license into a Windows image | host + Docker |
| `start` / `stop` / `remove` | Container lifecycle | host + Docker |
| `list` | List environments and images | host |
| `provision` | (inside image) restore `.bak`, register + configure the NST, license, bake-time apps | container build |
| `serve` | (inside image) entrypoint: start SQL + NST and keep alive | container runtime |
| `help [cmd]` | Usage | anywhere |

Run `bcdevenv help <command>` for flags.

## Typical flow

```powershell
$env:BCDEVENV_PLATFORM = "C:\artifacts\platform_30.0.54604.0"

# 1. Create a fresh empty platform database -> .bak (+ manifest).
bcdevenv create-env --database-name CRONUS --sql-server localhost
#   -> %LOCALAPPDATA%\bcdevenv\W1-30_0_54604_0\CRONUS.bak (+ manifest.json)

# 2. Install the app set (System/Base Application + your apps, as .app files).
bcdevenv install-app --env W1-30_0_54604_0 `
                     --server-instance BC `
                     --app-file C:\apps\System.app `
                     --app-file C:\apps\*.app

# 3. Bake DB + artifact binaries into a Windows image.
bcdevenv build-image --env W1-30_0_54604_0 --tag my-bc:30.0.54604

# 4. Run it.
bcdevenv start --image my-bc:30.0.54604 --name bc1 --port 7049 --detach
bcdevenv list
bcdevenv stop --name bc1
bcdevenv remove --name bc1 --purge-image
```

Apps can instead be installed **at bake time** by passing `--app-file` to
`build-image`. Because `install-app` is a standalone action, the same logic is
reused in three places: host packaging, container build time, and against a live
container.

## Running tests

`run-tests` runs the Business Central test suite against a **running** server
instance and writes a **JUnit XML** report that CI systems (GitHub Actions,
Azure DevOps, Jenkins, …) render natively. It exits non-zero when any test
fails, so it gates a build. Like `install-app`, it depends only on a live NST —
not on BcContainerHelper.

```powershell
# Convert an xUnit result document the test toolkit produced (no live server):
bcdevenv run-tests --from-xml .\TestResults\result.xml --result-file .\TestResults\junit.xml

# Or run live against a container started with 'bcdevenv start':
bcdevenv run-tests --odata-url http://localhost:7048/BC/ODataV4 `
                   --service-name BcDevEnvTestRunner `
                   --result-file .\TestResults\junit.xml
```

Two input paths, both funnelling through the same result pipeline:

- `--from-xml <file>` (repeatable) / `--results-dir <dir>` — parse existing
  xUnit result documents and re-emit merged JUnit. Needs no running server, so
  it is the reliable path in CI: the environment's test toolkit runs the tests
  and `run-tests` produces the canonical report and pass/fail gate.
- **live** (default) — invoke the toolkit's runner web service over the NST's
  OData v4 endpoint (via `HttpClient`, no client-automation DLL), receive the
  xUnit result and convert it.

The live mode has two protocols against the [`BcDevEnv Test Runner`](testrunner/app.json)
app (`BcDevEnvTestRunner` web service):

- `run-all` — one `RunAll` call for the whole suite.
- `per-codeunit` — `PrepareTests` once (selects the test codeunits of `--extension`,
  filtered by `--test-type` / `--required-test-isolation`, assigns
  `--test-runner-codeunit-id`, and **removes the DisabledTests entries before anything
  runs**), then one `RunCodeunit` call per codeunit, so a hanging or crashing codeunit
  is reported against that codeunit instead of losing the whole run.

### DisabledTests

`--disabled-tests <root>` (repeatable) together with `--app-name <name>` reads
`<root>\<App_Name>\*.json` (spaces become `_`), exactly like the repository's
`src\DisabledTests` layout used by `Get-DisabledTestsForApp`
(`build\scripts\ParallelTestExecution.psm1`).
Each file holds `{ "codeunitId", "codeunitName", "method", "bug" }` entries; `method`
may be `*` (whole codeunit) or contain `*`/`?` wildcards, and names match
case-insensitively. Matching test methods are disabled in the suite **before**
execution and appear in the JUnit report as
`<skipped message="Disabled by DisabledTests"/>`. After the run the result is checked
against the catalog: a disabled test that still ran, or a test the runner disabled
without a matching entry, fails the command even with `--allow-failures`. The
skip report also counts entries that matched no test in the run (stale, or outside
the selection; listed with `--verbose`).

Run `bcdevenv help run-tests` for all flags (`--allow-failures`, `--extension`,
`--test-codeunit`, `--auth`, …).

## BCApps CI pipeline

[`.github/actions/RunBcDevEnvPipeline`](../.github/actions/RunBcDevEnvPipeline/action.yaml)
replaces `microsoft/AL-Go/Actions/RunPipeline` for every AL-Go project
(`build\projects\*`) built by `_BuildALGoProject.yaml`. The apps are still compiled
by AL-Go's `CompileApps` (workspace compilation) and the dependency apps still come
from `DownloadProjectDependencies`. The pipeline logic is in
[`build\scripts\BcDevEnvPipeline.psm1`](../build/scripts/BcDevEnvPipeline.psm1)
(Pester tests: `build\scripts\tests\BcDevEnvPipeline.Test.ps1`). For each project and
build mode it:

1. reads the AL-Go settings of the project/build mode (`country`, `testType`,
   `companyName`, `doNotRunTests`, `doNotPublishApps`, `enableTaskScheduler`,
   `enableCleanTestCodeunitExecution`, `runTestsInAllInstalledTestApps`), the
   dependency apps, the project's `.buildartifacts\Apps` and `.buildartifacts\TestApps`,
   and orders them by their `app.json` dependencies (apps excluded by the project's
   `PublishBcContainerApp.ps1` override are not installed);
2. makes sure the Docker engine is running (starts the `docker` service when it is
   stopped and waits up to 5 minutes for `docker info` to answer with Windows
   containers, otherwise fails with a clear error; checked again right before the
   image build), builds this CLI (`dotnet build`), prepares a local SQL Server
   Express (`container\Install-SqlExpress.ps1`, also used by the image: Microsoft's
   SHA256-checked Express with Advanced Services download (engine + Full-Text Search)
   instead of the Chocolatey feed, setup retried and verified
   by the instance service starting; on runners whose system disk reports a physical
   sector size above 4 KB, which SQL Server cannot use, the instance's data files and
   the environment folder (`BCDEVENV_HOME`) go to an expandable VHDX volume with 4 KB
   sectors instead, because the `ForcedPhysicalSectorSizeInBytes` registry workaround
   needs a reboot), downloads the **platform-only** artifact of the
   `BCPlatform` version in `build\Packages.json` (with retries; a truncated or
   invalid zip is deleted and downloaded again) and compiles the test runner app
   with that platform's AL compiler;
3. `create-env` creates an **empty** platform database (no Cronus/demo data),
   `build-image` provisions it with all the apps plus the test runner, sets the
   database's application family to the project's `country` (upper-cased; `w1`/`base`
   = `W1`), so that country-specific feature keys (e.g. FR `Payment`, GB
   `VATReverseCharge`) and `EnvironmentInformation.GetApplicationFamily()` match a
   localized environment, creates the
   company and runs the same company codeunits as
   `build\scripts\ImportTestDataInBcContainer.ps1` (`Company-Initialize` for every
   test type, which upstream's client-session login runs for `UnitTest`; plus the
   Contoso demo data for `IntegrationTest`/`Uncategorized`; each call may take up to
   60 minutes, `build-image --company-codeunit-timeout <minutes>`, instead of the
   management API's 600-second default, and is not retried), maps the build account
   and, with Windows authentication, the server's own account (`NT AUTHORITY\NETWORK
   SERVICE`, which the API tests' default-credential calls to the server
   authenticate as) to SUPER users, and `start` runs the container (the server's URL
   reservations include the report rendering side service's port 7084 and the
   management API port, so the reporting service can start and tests can render
   reports);
4. selects the test apps like the project's `.AL-Go\RunTestsInBcContainer.ps1`
   override (the test-type bucket from `build\projects.json`/`build\groups.json` when
   the project uses `Invoke-PerProjectTestRun`, otherwise the project's own test apps) and runs
   `run-tests --protocol per-codeunit` per app and isolation pass (runner 130450,
   and 130451 for codeunits that require isolation `Disabled`), with every
   `DisabledTests` folder of the repository (`src\DisabledTests`) copied into the
   container;
5. merges the JUnit reports into `<project>\TestResults.xml` (read by AL-Go's
   `AnalyzeTests`) and `<project>\.buildartifacts\TestResults.xml` (uploaded test
   results artifact); the log is written to `<project>\BuildOutput.txt`, and on
   failure the container's event log to `<project>\ContainerEventLog.evtx`.

The step fails on any failing test, on runner/DisabledTests violations, on a
missing report, and when test apps were selected but no test ran. It does not use
BcContainerHelper; the surrounding AL-Go steps (`CompileApps`, `PipelineCleanup`, …)
are unchanged and still do, except that `PipelineCleanup` is `continue-on-error`:
hosted runners are sometimes started without a running Docker engine, and its
failure would otherwise fail a compile-only job (and, through `Build1`, skip every
test job).

**License.** An empty platform database holds no license, and Business Central does
not publish apps without one. The action reads the `licenseFileUrl` entry of the
AL-Go secrets (map it to another secret with the AL-Go `licenseFileUrlSecretName`
setting); the value may be an http(s) URL, a gzip+base64-encoded license (`H4sI…`)
or a path. Without it, a warning is written and — as AL-Go does without
`licenseFileUrl` — the CRONUS license of the AL-Go application artifact is used
(the artifact resolved from the `artifact` setting, e.g. `sandbox/<version>/base`;
the entry named by its `manifest.json` `licenseFile`, normally `Cronus.bclicense`,
read with HTTP range requests, falling back to downloading the whole artifact).
Licensing errors during provisioning are reported as such. `build-image` itself
refuses to bake apps into a `create-env` database without `--license`.

**Not supported** (the step fails with an explicit message): projects without
workspace compilation, `testType` `Legacy` (demo data generated through a page
action), and the RU projects (company initialization must be interleaved with the
app installation). Upgrade testing from the previous release is not performed.

**Known difference from AL-Go/BcContainerHelper.** The tests run inside an OData
web-service call (the `BcDevEnvTestRunner` codeunit), not in a client session
(BcContainerHelper drives the test tool page through the web client's client
services endpoint). A web-service session has no client UI, so tests that open
`TestPage`s, report request pages or rely on UI handlers fail with
`NotSupportedException`/"cannot be used in background or server sessions" errors.
Running them needs a client-session test runner (web server components in the image
plus `Microsoft.Dynamics.Framework.UI.Client`), which bcdevenv does not provide yet.
The same applies to tests that expect the data a client login creates: `System
Initialization` only records the signup context and the user's login information
for client sessions, so e.g. `User Login Time Tracker Test` and `System
Initialization Test` fail with "User Login"/"Signup Context Values" records that do
not exist. Some tests also depend on data that only specific upstream setups create
(for example the AMC banking license user), and are not seeded generically.

The build jobs of the `CI/CD` and `Pull Request Build` workflows run on `windows-2022`
(`gitHubRunner` in the `repositories: ["BCApps"]` conditional settings of
`.github\CICD.settings.json` and `.github\Pull Request Build.settings.json`) because
the container image is based on `servercore:ltsc2022` and runs with process
isolation. The workflow settings files are merged after the project settings, so
this replaces the projects' `GitHub-BCAppsPL` runner. AL-Go matches `repositories`
against the repository name without its owner, so the condition cannot tell a fork
from `microsoft/BCApps`.

## Environment artifacts

Each environment lives under `%LOCALAPPDATA%\bcdevenv\<name>\`
(override with `BCDEVENV_HOME`) and holds the `.bak` and a `manifest.json`
recording the platform version, the artifact path, the database/instance names,
and the installed app files.

## Hosting in a separate repository

The folder is self-contained: copy it out, keep the same layout
(`src\BcDevEnv.Cli`, `container\Dockerfile` + `container\Install-SqlExpress.ps1`,
`bcdevenv.cmd`, the `Directory.*`
+ `nuget.config` files), and it builds and runs unchanged. The only external
input at runtime is the platform artifact (`--platform` / `BCDEVENV_PLATFORM`).
`build-image` locates the tool root from the running executable, so it also
works from a standalone checkout (override with `BCDEVENV_TOOL_ROOT`).

## Key environment variables

| Variable | Purpose |
|---|---|
| `BCDEVENV_PLATFORM` | Platform artifact folder (same as `--platform`) |
| `BCDEVENV_HOME` | Where environments are stored (default `%LOCALAPPDATA%\bcdevenv`) |
| `BCDEVENV_SQL_SERVER` / `BCDEVENV_SQL_INSTANCE` | SQL target for `create-env` |
| `BCDEVENV_MGMT_DIR` | Management-module dir baked into the container image |
| `BCDEVENV_SERVICE_FOLDER` / `BCDEVENV_WEBCLIENT_FOLDER` | Override staged binaries |
| `BCDEVENV_TOOL_ROOT` | Override the tool-root autodetection for `build-image` |

## Not runnable end-to-end in every environment

The CLI builds cleanly (`dotnet build -c Release`, 0 warnings) and the
artifact-only path is validated on-box: the artifact's management module imports
in-process with no errors and exposes the DB/server/app cmdlets, and the SQL
client connects. A full image build/run must happen on a Windows-container host.
Caveats:

- The image installs SQL Server Express with `container\Install-SqlExpress.ps1`
  (Microsoft's `SQLEXPRADV_x64_ENU.exe`, Express with Advanced Services, pinned by
  SHA256, features `SQLENGINE,FULLTEXT`: BC creates full-text indexes when a company
  is created); update its URL and hash together when moving to another SQL Server
  Express release. Its sector-size mitigation (a VHDX data volume when the system
  disk reports physical sectors above 4 KB) needs `diskpart`; where it cannot create
  the virtual disk (e.g. inside a container) setup uses the default data folder.
- Registering an NST from baked binaries on a plain Windows base image may need
  manual service setup, since `New-NAVServerInstance` normally expects the
  product installed.

## Tests

Unit tests (`src\BcDevEnv.Cli.Tests`) cover arg parsing, path resolution and the
env manifest. They need no artifact, SQL or Docker and run in the `CI` workflow.

Integration tests (`src\BcDevEnv.Cli.IntegrationTests`) exercise the real product
against real platform artifacts. They **determine the platform version from the
platform index**
(`https://bcinsider-fvh2ekdjecfjd6gk.b02.azurefd.net/platform/indexes/platform.json`)
and run one case **per major version, taking the latest available** (e.g. latest
28, latest 29, latest 30). Each case downloads the artifact and runs
`bcdevenv verify`, which imports the BC management modules in-process and asserts
the cmdlets `create-env` (container database + server instance) and `install-app`
depend on are present — i.e. the "create a container + install an app" capability,
validated without needing SQL or Docker.

They are **off by default** so `dotnet test` stays hermetic; enable them with
environment switches:

| Variable | Purpose |
|---|---|
| `BCDEVENV_RUN_INTEGRATION=1` | Enable the index + artifact-download tests |
| `BCDEVENV_MAJORS` | Comma-separated majors to test (default `28,29,30`; the workflow auto-detects from the index) |
| `BCDEVENV_ARTIFACT_CACHE` | Where artifacts are downloaded/extracted (default `%TEMP%\bcdevenv-artifacts`) |
| `BCDEVENV_RUN_CONTAINER_TESTS=1` | Additionally run the heavy end-to-end `create-env` -> `build-image` -> `start` path (needs SQL + Docker Windows containers) |

```powershell
$env:BCDEVENV_RUN_INTEGRATION = "1"
dotnet test .\src\BcDevEnv.Cli.IntegrationTests\BcDevEnv.Cli.IntegrationTests.csproj -c Release
```

The integration workflows of the source repository are not part of this repository;
here the CLI is exercised end to end by the CI build (`RunBcDevEnvPipeline`).
