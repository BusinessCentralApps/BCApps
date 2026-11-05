<#
.SYNOPSIS
    Replacement for AL-Go's RunPipeline action, built on the bcdevenv CLI (see action.yaml).

.DESCRIPTION
    For the current AL-Go project and build mode:
      1. builds the bcdevenv CLI (bcdevenv/),
      2. creates an EMPTY-database Business Central container from the BCPlatform version in
         build/Packages.json (platform artifact only - no application database, no demo data),
      3. installs the project's apps and test apps (compiled by the CompileApps action) together with
         the dependency apps downloaded by DownloadProjectDependencies,
      4. runs the tests through the BcDevEnvTestRunner OData service, excluding the tests listed in the
         repository's DisabledTests folders (src/DisabledTests) BEFORE they are executed.

    Test results are written to <project>/TestResults.xml (read by AL-Go's AnalyzeTests) and
    <project>/.buildartifacts/TestResults.xml (uploaded as the test results artifact).
#>
[CmdletBinding()]
param(
    [string] $Project = '.',
    [string] $BuildMode = 'Default',
    [string] $InstallAppsJson = '',
    [string] $InstallTestAppsJson = '',
    [string] $LicenseSecretName = 'licenseFileUrl',
    [string] $PreviousAppsPath = ''
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Version 2.0

Import-Module (Join-Path $PSScriptRoot '../../../build/scripts/BcDevEnvPipeline.psm1' -Resolve) -Force -DisableNameChecking

$repoRoot = if ($env:GITHUB_WORKSPACE) { $env:GITHUB_WORKSPACE } else { (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path }
if ([string]::IsNullOrWhiteSpace($Project) -or $Project -eq '.') {
    $Project = '.'
    $projectPath = $repoRoot
}
else {
    $projectPath = Join-Path $repoRoot $Project
}
if (-not (Test-Path -LiteralPath $projectPath -PathType Container)) { throw "Project folder '$projectPath' does not exist." }
if ([string]::IsNullOrWhiteSpace($env:Settings)) { throw 'The AL-Go settings ($env:Settings, written by the ReadSettings action) are not available.' }
$settings = $env:Settings | ConvertFrom-Json

$containerCli = 'C:\bcdevenv\cli\bcdevenv.exe'
$odataUrl = 'http://localhost:7048/BC/ODataV4'
$containerRunFolder = 'C:\bcdevenv-run'
$runnerAppId = 'b7f1d6c2-6a1e-4d3a-9d7c-9a2b5e4f0c11'
$runnerDependencyIds = @('63ca2fa4-4f03-4f2b-a480-172fef340d3f', '23de40a6-dfe8-4f80-80db-d70f83ce8caf')

function Write-Section([string] $Title) { Write-Host "::endgroup::"; Write-Host "::group::$Title" }

function Invoke-Docker {
    param([string[]] $Arguments, [switch] $AllowFailure, [string] $Description = '')
    if (-not $Description) { $Description = "docker $($Arguments[0])" }
    return Invoke-BcDevEnvNativeCommand -FilePath 'docker' -Arguments $Arguments -Description $Description -AllowFailure:$AllowFailure
}

function Test-ContainerExists([string] $Name) {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & docker container inspect $Name *> $null
        return ($LASTEXITCODE -eq 0)
    }
    finally { $ErrorActionPreference = $previous }
}

# --- Plan ---------------------------------------------------------------------------------------
Write-Host "::group::Plan ($Project, $BuildMode)"
$plan = Get-BcDevEnvPipelinePlan -Settings $settings -Project $Project
if ($plan.Action -eq 'Skip') {
    Write-Host "::endgroup::"
    Write-Host "::notice::$Project ($BuildMode): $($plan.Reason)"
    return
}
Write-Host "Action:        $($plan.Action) $($plan.Reason)"
Write-Host "Country:       $($plan.Country)"
Write-Host "Test type:     $(if ($plan.TestType) { $plan.TestType } else { '(none - all test codeunits)' })"
Write-Host "Company:       $($plan.CompanyName)$(if ($plan.EvaluationCompany) { ' (evaluation company)' })"
Write-Host "Company setup: $(if (@($plan.CompanyCodeunits).Count) { $plan.CompanyCodeunits -join ', ' } else { '(empty company)' })"
foreach ($pass in $plan.Passes) { Write-Host "Test pass:     $($pass.Name), test runner $($pass.RunnerId)" }
if ($PreviousAppsPath -and (Test-Path -LiteralPath $PreviousAppsPath)) {
    Write-Host "::notice::Previous release apps were downloaded, but the bcdevenv pipeline installs into an empty database and does not perform upgrade testing."
}

# --- Install set and test selection -------------------------------------------------------------
Write-Section 'Apps to install'
$installSet = Get-BcDevEnvInstallSet -ProjectPath $projectPath -InstallAppsJson $InstallAppsJson -InstallTestAppsJson $InstallTestAppsJson
$apps = @($installSet.Apps)
foreach ($app in @($installSet.Excluded)) { Write-Host "Not installed (excluded like the native PublishBcContainerApp): $($app.Name)" }
$index = 0
foreach ($app in $apps) {
    $index++
    Write-Host ("{0,4}. {1} {2} [{3}, {4}{5}]" -f $index, $app.Name, $app.Version, $app.Kind, $app.Source, $(if ($app.Wrapped) { ', no tests' } else { '' }))
}
if ($apps.Count -eq 0) {
    Write-Host "::endgroup::"
    Write-Host "::notice::$Project ($BuildMode): there are no apps to install; nothing to do."
    return
}

$selected = @()
if ($plan.Action -eq 'Test') {
    $selected = @(Get-BcDevEnvTestAppSelection -InstalledApps $apps -ProjectPath $projectPath -Plan $plan)
    Write-Host "Test apps to run ($($selected.Count)): $(@($selected | ForEach-Object { $_.Name }) -join ', ')"
    if ($selected.Count -eq 0) {
        Write-Host "::warning::$Project ($BuildMode): no installed test app is selected for test type '$($plan.TestType)'; the apps are installed but no tests are run."
    }
}

# --- Resources ----------------------------------------------------------------------------------
$names = Get-BcDevEnvResourceNames -Project $Project -BuildMode $BuildMode -RunId "$env:GITHUB_RUN_ID" -RunAttempt "$env:GITHUB_RUN_ATTEMPT"
$tempRoot = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [System.IO.Path]::GetTempPath() }
$work = Join-Path $tempRoot "bcdevenv\$($names.EnvName)"
if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
New-Item -ItemType Directory -Path $work -Force | Out-Null
# The SQL Server service account writes the empty database backup here (it cannot write to the runner's temp/profile folders).
$dataHome = Join-Path "$env:SystemDrive\" "bcdevenv-home\$($names.EnvName)"
if ($env:GITHUB_ENV) {
    Add-Content -Encoding UTF8 -Path $env:GITHUB_ENV -Value @(
        "BCDEVENV_PIPELINE_CONTAINER=$($names.ContainerName)",
        "BCDEVENV_PIPELINE_IMAGE=$($names.ImageTag)",
        "BCDEVENV_PIPELINE_WORK=$work",
        "BCDEVENV_PIPELINE_HOME=$dataHome"
    )
}
Write-Host "Container: $($names.ContainerName); image: $($names.ImageTag); work folder: $work"

$licensePath = $null
$succeeded = $false
try {
    # --- bcdevenv CLI ---------------------------------------------------------------------------
    Write-Section 'Build the bcdevenv CLI'
    $toolRoot = Join-Path $repoRoot 'bcdevenv'
    $env:BCDEVENV_TOOL_ROOT = $toolRoot
    Remove-Item Env:\BCDEVENV_LICENSE -ErrorAction SilentlyContinue
    $cliProject = Join-Path $toolRoot 'src/BcDevEnv.Cli/BcDevEnv.Cli.csproj'
    Invoke-BcDevEnvNativeCommand -FilePath 'dotnet' -Arguments @('build', $cliProject, '-c', 'Release', '--nologo', '-v', 'q') -Description 'dotnet build bcdevenv' | Out-Null
    $bcdevenv = Get-ChildItem -LiteralPath (Join-Path $toolRoot 'src/BcDevEnv.Cli/bin/Release') -Recurse -File -Filter 'bcdevenv.exe' | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    if ($null -eq $bcdevenv) { throw 'The bcdevenv CLI build did not produce bcdevenv.exe.' }
    $bcdevenv = $bcdevenv.FullName
    Write-Host "bcdevenv: $bcdevenv"

    # --- SQL Server -------------------------------------------------------------------------------
    Write-Section 'SQL Server'
    Initialize-BcDevEnvSqlServer -Instance 'SQLEXPRESS' -DataHome $dataHome | Out-Null

    # --- Platform artifact ------------------------------------------------------------------------
    Write-Section 'Platform artifact (build/Packages.json BCPlatform)'
    $platform = Get-BcDevEnvPlatformArtifact
    Write-Host "BCPlatform $($platform.Version): $($platform.Url)"
    $platformZip = Join-Path $work 'platform.zip'
    $platformDir = Join-Path $work 'platform'
    Invoke-WebRequest -Uri $platform.Url -OutFile $platformZip -UseBasicParsing -TimeoutSec 3600
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::ExtractToDirectory($platformZip, $platformDir)
    Remove-Item -LiteralPath $platformZip -Force
    $layout = Get-BcDevEnvPlatformLayout -PlatformDir $platformDir
    Write-Host "System symbols: $($layout.SystemApp)"
    Write-Host "Service tier:   $($layout.ServiceDir)"

    # --- Test runner app ----------------------------------------------------------------------------
    $runnerApp = $null
    if ($selected.Count -gt 0) {
        Write-Section 'Compile the BcDevEnv Test Runner app'
        if ($apps | Where-Object { $_.Id -eq $runnerAppId }) { throw "The install set already contains an app with the BcDevEnv Test Runner id $runnerAppId." }
        $symbols = Join-Path $work 'runner-symbols'
        New-Item -ItemType Directory -Path $symbols -Force | Out-Null
        Copy-Item -LiteralPath $layout.SystemApp -Destination $symbols
        foreach ($dependency in @(Get-BcDevEnvDependencyClosure -OrderedApps $apps -RootIds $runnerDependencyIds)) {
            Copy-Item -LiteralPath $dependency.Path -Destination $symbols
        }
        $runnerSource = Join-Path $work 'runner-src'
        Copy-Item -LiteralPath (Join-Path $toolRoot 'testrunner') -Destination $runnerSource -Recurse
        $alc = Find-BcDevEnvAlc -VsixPath $layout.Vsix -Destination (Join-Path $work 'alc')
        $runnerApp = Join-Path $work 'runner\BcDevEnv_BcDevEnv Test Runner.app'
        New-Item -ItemType Directory -Path (Split-Path $runnerApp -Parent) -Force | Out-Null
        Invoke-BcDevEnvNativeCommand -FilePath $alc -Arguments @("/project:$runnerSource", "/packagecachepath:$symbols", "/out:$runnerApp", "/assemblyprobingpaths:$($layout.ServiceDir)") -Description 'Compiling the BcDevEnv Test Runner' | Out-Null
        if (-not (Test-Path -LiteralPath $runnerApp)) { throw 'The AL compiler did not produce the BcDevEnv Test Runner app.' }
    }

    # --- License ------------------------------------------------------------------------------------
    Write-Section 'License'
    $licensePath = Resolve-BcDevEnvLicense -SecretsJson "$env:Secrets" -SecretName $LicenseSecretName -Destination (Join-Path $work 'license')
    if (-not $licensePath) {
        Write-Host "::warning::No license secret '$LicenseSecretName' is available; the apps are installed and tested with the platform's built-in license."
    }

    # --- Empty database, image, container -------------------------------------------------------------
    Write-Section 'Create the empty platform database'
    Invoke-BcDevEnvNativeCommand -FilePath $bcdevenv -Arguments @('create-env', '--platform', $platformDir, '--country', $plan.Country, '--name', $names.EnvName, '--sql-server', 'localhost', '--sql-instance', 'SQLEXPRESS') -Description 'bcdevenv create-env' | Out-Null

    Write-Section "Build the container image (install $($apps.Count) apps$(if ($runnerApp) { ' + test runner' }))"
    $appList = Join-Path $work 'apps.txt'
    $lines = @("# $Project ($BuildMode) - install order") + @($apps | ForEach-Object { $_.Path })
    if ($runnerApp) { $lines += $runnerApp }
    Set-Content -LiteralPath $appList -Value $lines -Encoding UTF8
    $buildArguments = @('build-image', '--env', $names.EnvName, '--tag', $names.ImageTag, '--app-list', $appList, '--company', $plan.CompanyName)
    if ($plan.EvaluationCompany) { $buildArguments += '--evaluation-company' }
    foreach ($codeunit in @($plan.CompanyCodeunits)) { $buildArguments += @('--company-codeunit', $codeunit) }
    foreach ($setting in @($plan.ServerSettings)) { $buildArguments += @('--server-setting', $setting) }
    if ($licensePath) { $buildArguments += @('--license', $licensePath) }
    Invoke-BcDevEnvNativeCommand -FilePath $bcdevenv -Arguments $buildArguments -Description 'bcdevenv build-image (provisioning the empty database with the apps)' | Out-Null

    Write-Section 'Start the container'
    Invoke-BcDevEnvNativeCommand -FilePath $bcdevenv -Arguments @('start', '--image', $names.ImageTag, '--name', $names.ContainerName, '--detach') -Description 'bcdevenv start' | Out-Null
    $requiredText = if ($runnerApp) { 'BcDevEnvTestRunner_PrepareTests' } else { '' }
    $probe = ConvertTo-BcDevEnvEncodedScript -Script (Get-BcDevEnvReadinessScript -ODataUrl $odataUrl -RequiredText $requiredText)
    $probeExit = Invoke-Docker -Arguments @('exec', $names.ContainerName, 'powershell', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $probe) -AllowFailure -Description 'OData readiness probe'
    if ($probeExit -ne 0) {
        Invoke-Docker -Arguments @('logs', '--tail', '80', $names.ContainerName) -AllowFailure | Out-Null
        throw 'The Business Central server in the container did not become ready (OData $metadata).'
    }

    if ($plan.Action -ne 'Test' -or $selected.Count -eq 0) {
        Write-Host "::endgroup::"
        Write-Host "The container was provisioned with $($apps.Count) apps; no tests were run."
        $succeeded = $true
        return
    }

    # --- DisabledTests --------------------------------------------------------------------------------
    Write-Section 'DisabledTests'
    $disabledRoots = @(Get-BcDevEnvDisabledTestsRoots -BaseFolder $repoRoot)
    Invoke-Docker -Arguments @('exec', '-u', 'ContainerAdministrator', $names.ContainerName, 'cmd', '/c', 'mkdir', "$containerRunFolder\results", "$containerRunFolder\disabled") -Description 'Preparing the container run folder' | Out-Null
    $containerDisabledRoots = @()
    for ($i = 0; $i -lt $disabledRoots.Count; $i++) {
        $containerRoot = "$containerRunFolder\disabled\$i"
        $files = @(Get-ChildItem -LiteralPath $disabledRoots[$i] -Recurse -File -Filter '*.json').Count
        Write-Host "$($disabledRoots[$i]) ($files file(s)) -> $containerRoot"
        Invoke-Docker -Arguments @('cp', $disabledRoots[$i], "$($names.ContainerName):$containerRoot") -Description "Copying '$($disabledRoots[$i])' into the container" | Out-Null
        $containerDisabledRoots += $containerRoot
    }
    if ($disabledRoots.Count -eq 0) { Write-Host 'No DisabledTests folders found.' }

    # --- Tests ------------------------------------------------------------------------------------------
    $resultsFolder = Join-Path $work 'results'
    New-Item -ItemType Directory -Path $resultsFolder -Force | Out-Null
    $resultFiles = @()
    $infrastructureErrors = @()
    $passIndex = 0
    foreach ($pass in $plan.Passes) {
        $passIndex++
        $appIndex = 0
        foreach ($app in $selected) {
            $appIndex++
            Write-Section "Tests: $($app.Name) - $($pass.Name)"
            $resultName = '{0:D2}-{1:D3}.xml' -f $passIndex, $appIndex
            $containerResult = "$containerRunFolder\results\$resultName"
            $hostResult = Join-Path $resultsFolder $resultName
            $runArguments = Get-BcDevEnvRunTestsArguments -ODataUrl $odataUrl -CompanyName $plan.CompanyName -App $app -Pass $pass -DisabledTestsRoots $containerDisabledRoots -ResultFile $containerResult
            $exitCode = Invoke-Docker -Arguments (@('exec', '-u', 'ContainerAdministrator', $names.ContainerName, $containerCli) + $runArguments) -AllowFailure -Description "bcdevenv run-tests ($($app.Name))"
            $copyExit = Invoke-Docker -Arguments @('cp', "$($names.ContainerName):$containerResult", $hostResult) -AllowFailure -Description 'Copying the test results'
            if ($copyExit -ne 0 -or -not (Test-Path -LiteralPath $hostResult)) {
                $infrastructureErrors += "$($app.Name) [$($pass.Name)]: no test report was produced (run-tests exit code $exitCode)."
                continue
            }
            $resultFiles += $hostResult
            $summary = Get-BcDevEnvJUnitSummary -Path $hostResult
            Write-Host ("{0} [{1}]: {2} test(s), {3} failed, {4} skipped" -f $app.Name, $pass.Name, $summary.Tests, ($summary.Failures + $summary.Errors), $summary.Skipped)
            if ($exitCode -ne 0) {
                $infrastructureErrors += "$($app.Name) [$($pass.Name)]: run-tests reported runner/DisabledTests errors (exit code $exitCode); see its log above."
            }
        }
    }

    Write-Section 'Test results'
    $outputs = @((Join-Path $projectPath 'TestResults.xml'), (Join-Path $projectPath '.buildartifacts/TestResults.xml'))
    $counts = Merge-BcDevEnvJUnitResults -InputFiles $resultFiles -OutputFiles $outputs -SuiteName 'BusinessCentral'
    Write-Host ("Total: {0} test(s), {1} failure(s), {2} error(s), {3} skipped (DisabledTests), {4:0.#}s" -f $counts.Tests, $counts.Failures, $counts.Errors, $counts.Skipped, $counts.Time)
    foreach ($output in $outputs) { Write-Host "Written: $output" }
    Write-Host "::endgroup::"

    $gateFailures = @(Get-BcDevEnvTestGateFailures -SelectedAppCount $selected.Count -Counts $counts -InfrastructureErrors $infrastructureErrors)
    if ($gateFailures.Count -gt 0) {
        throw ("$Project ($BuildMode) failed:`n" + ($gateFailures -join "`n"))
    }
    $succeeded = $true
}
finally {
    Write-Host "::endgroup::"
    Write-Host "::group::Cleanup"
    if (Test-ContainerExists $names.ContainerName) {
        if (-not $succeeded) {
            Write-Host 'Exporting the container event log.'
            $exported = Invoke-Docker -Arguments @('exec', '-u', 'ContainerAdministrator', $names.ContainerName, 'wevtutil', 'epl', 'Application', 'C:\ContainerEventLog.evtx', '/ow:true') -AllowFailure -Description 'Exporting the event log'
            if ($exported -eq 0) {
                Invoke-Docker -Arguments @('cp', "$($names.ContainerName):C:\ContainerEventLog.evtx", (Join-Path $projectPath 'ContainerEventLog.evtx')) -AllowFailure | Out-Null
            }
        }
        Invoke-Docker -Arguments @('rm', '-f', $names.ContainerName) -AllowFailure | Out-Null
    }
    Invoke-Docker -Arguments @('image', 'rm', '-f', $names.ImageTag) -AllowFailure -Description 'docker image rm' | Out-Null
    if ($licensePath -and (Test-Path -LiteralPath $licensePath)) { Remove-Item -LiteralPath $licensePath -Force -ErrorAction SilentlyContinue }
    foreach ($folder in @($work, $dataHome)) {
        if (Test-Path -LiteralPath $folder) { Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue }
    }
    Write-Host "::endgroup::"
}
