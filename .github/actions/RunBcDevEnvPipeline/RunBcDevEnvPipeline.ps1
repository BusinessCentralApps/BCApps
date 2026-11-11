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
      4. runs the tests, excluding the tests listed in the repository's DisabledTests folders
         (src/DisabledTests) BEFORE they are executed: the BcDevEnvTestRunner OData service selects
         the tests of each pass (test type, required test isolation, DisabledTests) and, with the
         default test executor 'altool', the AL tool's runtests (Microsoft.Dynamics.BusinessCentral.
         Development.Tools from nuget.org) executes them in a client session through the
         development endpoint; with the test executor 'odata' the OData service executes them.

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
    [string] $PreviousAppsPath = '',
    [string] $TestExecutor = '',
    [string] $AlToolVersion = '',
    [string] $AppTestTimeoutMinutes = '',
    [string] $T2EmbedUrl = ''
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
$containerAlToolFolder = 'C:\altool'
$containerAlTool = "$containerAlToolFolder\altool.dll"
$containerDotnet = 'C:\Program Files\dotnet\dotnet.exe'
$devPort = 7049

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
$executor = Get-BcDevEnvTestExecutorSettings -Settings $settings -Executor $TestExecutor -AlToolVersion $AlToolVersion -AppTimeoutMinutes $AppTestTimeoutMinutes
$executorLabel = if ($executor.Executor -eq 'altool') { "altool $($executor.AlToolVersion)" } else { 'odata' }
if ($plan.Action -eq 'Test') {
    if ($executor.Executor -eq 'altool') {
        Write-Host "Test executor: altool - AL tool $($executor.AlToolVersion) runtests (client session, development endpoint port $devPort), $($executor.AppTimeoutMinutes) min per test app and pass; the BcDevEnvTestRunner selects the tests"
    }
    else {
        Write-Host "Test executor: odata - the BcDevEnvTestRunner OData service selects and runs the tests"
    }
}
# Resolved up front so that an invalid configured URL fails before the long setup.
$t2embedSource = Get-BcDevEnvT2EmbedUrl -Settings $settings -Url $T2EmbedUrl
Write-Host "t2embed.dll:   $(([System.Uri]$t2embedSource).GetLeftPart([System.UriPartial]::Path))"
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
$dockerReady = $false
try {
    # --- Docker engine (checked first so that a runner without a running engine fails fast) --------
    Write-Section 'Docker engine'
    Wait-BcDevEnvDockerEngine -ServiceName 'docker' -TimeoutSeconds 300 | Out-Null
    $dockerReady = $true

    # --- bcdevenv CLI ---------------------------------------------------------------------------
    Write-Section 'Build the bcdevenv CLI'
    $toolRoot = Join-Path $repoRoot 'bcdevenv'
    $env:BCDEVENV_TOOL_ROOT = $toolRoot
    Remove-Item Env:\BCDEVENV_LICENSE -ErrorAction SilentlyContinue
    $cliProject = Join-Path $toolRoot 'src/BcDevEnv.Cli/BcDevEnv.Cli.csproj'
    # nuget.org occasionally resets connections on hosted runners, so the restore is retried on its own.
    Invoke-BcDevEnvWithRetry -Description 'dotnet restore bcdevenv' -MaxAttempts 4 -ScriptBlock {
        Invoke-BcDevEnvNativeCommand -FilePath 'dotnet' -Arguments @('restore', $cliProject, '--nologo', '-v', 'q') -Description 'dotnet restore bcdevenv' | Out-Null
    } | Out-Null
    Invoke-BcDevEnvNativeCommand -FilePath 'dotnet' -Arguments @('build', $cliProject, '-c', 'Release', '--no-restore', '--nologo', '-v', 'q') -Description 'dotnet build bcdevenv' | Out-Null
    $bcdevenv = Get-ChildItem -LiteralPath (Join-Path $toolRoot 'src/BcDevEnv.Cli/bin/Release') -Recurse -File -Filter 'bcdevenv.exe' | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    if ($null -eq $bcdevenv) { throw 'The bcdevenv CLI build did not produce bcdevenv.exe.' }
    $bcdevenv = $bcdevenv.FullName
    Write-Host "bcdevenv: $bcdevenv"

    # --- SQL Server -------------------------------------------------------------------------------
    Write-Section 'SQL Server'
    # On a runner whose system volume reports a sector size above 4 KB the data home moves to the SQL Server data volume.
    $sqlDataHome = @(Initialize-BcDevEnvSqlServer -Instance 'SQLEXPRESS' -DataHome $dataHome -InstallScript (Join-Path $toolRoot 'container/Install-SqlExpress.ps1'))[-1]
    if ($sqlDataHome -and $sqlDataHome -ne $dataHome) {
        $dataHome = $sqlDataHome
        if ($env:GITHUB_ENV) { Add-Content -Encoding UTF8 -Path $env:GITHUB_ENV -Value "BCDEVENV_PIPELINE_HOME=$dataHome" }
    }

    # --- Platform artifact ------------------------------------------------------------------------
    Write-Section 'Platform artifact (build/Packages.json BCPlatform)'
    $platform = Invoke-BcDevEnvWithRetry -Description 'Resolving the BCPlatform artifact' -MaxAttempts 3 -ScriptBlock { Get-BcDevEnvPlatformArtifact }
    Write-Host "BCPlatform $($platform.Version): $($platform.Url)"
    $platformZip = Join-Path $work 'platform.zip'
    $platformDir = Join-Path $work 'platform'
    Save-BcDevEnvDownload -Uri $platform.Url -OutFile $platformZip -ValidateZip -Description "Downloading the BCPlatform $($platform.Version) artifact" | Out-Null
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

    # --- AL tool (test executor) ----------------------------------------------------------------------
    $alToolBin = $null
    if ($selected.Count -gt 0 -and $executor.Executor -eq 'altool') {
        Write-Section "AL tool $($executor.AlToolVersion) (test executor)"
        $alToolPackage = Join-Path $work 'altool.nupkg'
        $alToolPackageDir = Join-Path $work 'altool'
        Save-BcDevEnvDownload -Uri (Get-BcDevEnvAlToolPackageUrl -Version $executor.AlToolVersion) -OutFile $alToolPackage -ValidateZip -Description "Downloading the AL tool $($executor.AlToolVersion)" | Out-Null
        [System.IO.Compression.ZipFile]::ExtractToDirectory($alToolPackage, $alToolPackageDir)
        Remove-Item -LiteralPath $alToolPackage -Force
        $alToolBin = Find-BcDevEnvAlToolFolder -PackageDir $alToolPackageDir
        Write-Host "AL tool: $alToolBin"
    }

    # --- License ------------------------------------------------------------------------------------
    Write-Section 'License'
    $licensePath = Resolve-BcDevEnvLicense -SecretsJson "$env:Secrets" -SecretName $LicenseSecretName -Destination (Join-Path $work 'license')
    if (-not $licensePath) {
        # An empty platform database holds no license and Business Central does not publish apps
        # without one, so fall back to what AL-Go uses without licenseFileUrl: the CRONUS license
        # of the AL-Go application artifact (resolved by DetermineArtifactUrl into $env:artifact).
        $artifactUrl = Get-BcDevEnvApplicationArtifactUrl -ResolvedArtifactUrl "$env:artifact" -Settings $settings
        $artifactDisplayUrl = ([System.Uri]$artifactUrl).GetLeftPart([System.UriPartial]::Path)
        $licensePath = Get-BcDevEnvArtifactLicense -ArtifactUrl $artifactUrl -Destination (Join-Path $work 'license')
        Write-Host "::warning::No license secret '$LicenseSecretName' is available; the apps are installed and tested with the CRONUS license of the AL-Go application artifact ($artifactDisplayUrl). Licensing errors are reported as such; provide a license through the '$LicenseSecretName' secret if the apps need more."
    }

    # --- t2embed.dll ------------------------------------------------------------------------------------
    # Windows Server Core lacks t2embed.dll (font embedding); without it rendering reports as PDF fails
    # with "Unable to load DLL 'T2Embed'". The image copies it into System32 when missing, like the
    # official images. A failed download only costs the PDF rendering tests, which then fail visibly.
    Write-Section 't2embed.dll (font embedding for PDF report rendering)'
    $t2embedPath = $null
    try {
        $t2embedPath = Get-BcDevEnvT2Embed -Url $t2embedSource -Destination (Join-Path $work 't2embed')
    }
    catch {
        Write-Host "::warning::t2embed.dll could not be obtained ($($_.Exception.Message)); the image is built without it, so rendering reports as PDF fails in the container (Unable to load DLL 'T2Embed')."
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
    if ($t2embedPath) { $buildArguments += @('--system32-file', $t2embedPath) }
    # The Docker engine was seen to stop mid-job on hosted runners; re-check it before the long build.
    Wait-BcDevEnvDockerEngine -ServiceName 'docker' -TimeoutSeconds 300 | Out-Null
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

    if ($alToolBin) {
        Write-Section 'AL tool in the container'
        Invoke-Docker -Arguments @('cp', $alToolBin, "$($names.ContainerName):$containerAlToolFolder") -Description 'Copying the AL tool into the container' | Out-Null
        $alToolProbe = ConvertTo-BcDevEnvEncodedScript -Script (Get-BcDevEnvAlToolReadinessScript -AlToolPath $containerAlTool -DotnetPath $containerDotnet -Port $devPort)
        $alToolProbeExit = Invoke-Docker -Arguments @('exec', $names.ContainerName, 'powershell', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $alToolProbe) -AllowFailure -Description 'AL tool readiness probe'
        if ($alToolProbeExit -ne 0) {
            throw "The altool test executor cannot run in the container (see the AL tool readiness probe above). Set the bcdevenvTestExecutor setting (or the testExecutor input) to 'odata' to run the tests through the OData service instead."
        }
    }

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
            Write-Section "Tests: $($app.Name) - $($pass.Name) (executor $executorLabel)"
            $resultName = '{0:D2}-{1:D3}.xml' -f $passIndex, $appIndex
            $containerResult = "$containerRunFolder\results\$resultName"
            $hostResult = Join-Path $resultsFolder $resultName
            $runArguments = Get-BcDevEnvRunTestsArguments -ODataUrl $odataUrl -CompanyName $plan.CompanyName -App $app -Pass $pass -DisabledTestsRoots $containerDisabledRoots -ResultFile $containerResult `
                -Executor $executor.Executor -AlToolPath $containerAlTool -DotnetPath $containerDotnet -DevPort $devPort -ServerInstance 'BC' -AppTimeoutMinutes $executor.AppTimeoutMinutes
            $exitCode = Invoke-Docker -Arguments (@('exec', '-u', 'ContainerAdministrator', $names.ContainerName, $containerCli) + $runArguments) -AllowFailure -Description "bcdevenv run-tests ($($app.Name))"
            $copyExit = Invoke-Docker -Arguments @('cp', "$($names.ContainerName):$containerResult", $hostResult) -AllowFailure -Description 'Copying the test results'
            if ($copyExit -ne 0 -or -not (Test-Path -LiteralPath $hostResult)) {
                $infrastructureErrors += "$($app.Name) [$($pass.Name)]: no test report was produced (run-tests exit code $exitCode)."
                continue
            }
            $resultFiles += $hostResult
            $summary = Get-BcDevEnvJUnitSummary -Path $hostResult
            Write-Host ("{0} [{1}, executor {2}]: {3} test(s), {4} failed, {5} skipped" -f $app.Name, $pass.Name, $executorLabel, $summary.Tests, ($summary.Failures + $summary.Errors), $summary.Skipped)
            if ($exitCode -ne 0) {
                $infrastructureErrors += "$($app.Name) [$($pass.Name)]: run-tests reported runner/DisabledTests errors (exit code $exitCode); see its log above."
            }
        }
    }

    Write-Section 'Test results'
    $outputs = @((Join-Path $projectPath 'TestResults.xml'), (Join-Path $projectPath '.buildartifacts/TestResults.xml'))
    $counts = Merge-BcDevEnvJUnitResults -InputFiles $resultFiles -OutputFiles $outputs -SuiteName 'BusinessCentral'
    Write-Host ("Total: {0} test(s), {1} failure(s), {2} error(s), {3} skipped (DisabledTests or by the test runner), {4:0.#}s; executor {5}" -f $counts.Tests, $counts.Failures, $counts.Errors, $counts.Skipped, $counts.Time, $executorLabel)
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
    if (-not $dockerReady) {
        Write-Host 'The Docker engine was not ready; no container or image was created.'
    }
    elseif (Test-ContainerExists $names.ContainerName) {
        if (-not $succeeded) {
            Write-Host 'Exporting the container event log.'
            $exported = Invoke-Docker -Arguments @('exec', '-u', 'ContainerAdministrator', $names.ContainerName, 'wevtutil', 'epl', 'Application', 'C:\ContainerEventLog.evtx', '/ow:true') -AllowFailure -Description 'Exporting the event log'
            if ($exported -eq 0) {
                Invoke-Docker -Arguments @('cp', "$($names.ContainerName):C:\ContainerEventLog.evtx", (Join-Path $projectPath 'ContainerEventLog.evtx')) -AllowFailure | Out-Null
            }
        }
        Invoke-Docker -Arguments @('rm', '-f', $names.ContainerName) -AllowFailure | Out-Null
    }
    if ($dockerReady) {
        Invoke-Docker -Arguments @('image', 'rm', '-f', $names.ImageTag) -AllowFailure -Description 'docker image rm' | Out-Null
    }
    if ($licensePath -and (Test-Path -LiteralPath $licensePath)) { Remove-Item -LiteralPath $licensePath -Force -ErrorAction SilentlyContinue }
    foreach ($folder in @($work, $dataHome)) {
        if (Test-Path -LiteralPath $folder) { Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue }
    }
    Write-Host "::endgroup::"
}
