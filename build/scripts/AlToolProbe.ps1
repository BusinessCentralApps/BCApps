<#
.SYNOPSIS
    Temporary probe: does `al runtests` (AL tool, dev endpoint TestRunnerHub) support TestPage, which the
    OData runner session cannot (NavSession.CreateNavTestService -> NotSupportedException)?

.DESCRIPTION
    Provisions one bcdevenv container with a few TestPage-heavy System Application test apps, runs them with
    the current OData runner (baseline) and with `altool runtests --testgroups`, and compares per test method.
    Everything is written to <repo>/probe-results.
#>
[CmdletBinding()]
param(
    [string] $ProbeRoot = 'probe',
    [string[]] $TestAppNames = @('Date-Time Dialog Test', 'Cues and KPIs Test', 'Feature Key Test', 'Privacy Notice Tests', 'Data Classification Test', 'Guided Experience Test', 'Email Test', 'No. Series Tests'),
    [string] $AlToolVersion = '30.0.42.60748-beta',
    [int] $RunTimeoutMinutes = 40
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Version 2.0

Import-Module (Join-Path $PSScriptRoot 'BcDevEnvPipeline.psm1' -Resolve) -Force -DisableNameChecking

$repoRoot = if ($env:GITHUB_WORKSPACE) { $env:GITHUB_WORKSPACE } else { (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path }
$projectPath = Join-Path $repoRoot $ProbeRoot
$out = Join-Path $repoRoot 'probe-results'
New-Item -ItemType Directory -Path $out -Force | Out-Null
$settings = Get-Content -LiteralPath (Join-Path $repoRoot '.github/AL-Go-Settings.json') -Raw | ConvertFrom-Json

$companyName = 'CRONUS International Ltd.'
$containerCli = 'C:\bcdevenv\cli\bcdevenv.exe'
$odataUrl = 'http://localhost:7048/BC/ODataV4'
$runFolder = 'C:\bcdevenv-run'
$runnerAppId = 'b7f1d6c2-6a1e-4d3a-9d7c-9a2b5e4f0c11'
$runnerDependencyIds = @('63ca2fa4-4f03-4f2b-a480-172fef340d3f', '23de40a6-dfe8-4f80-80db-d70f83ce8caf')
$summary = New-Object System.Collections.Generic.List[string]

function Write-Section([string] $Title) { Write-Host "::endgroup::"; Write-Host "::group::$Title" }
function Add-Summary([string] $Line) { $summary.Add($Line); Write-Host $Line }

function Invoke-Captured {
    param([string] $FilePath, [string[]] $Arguments, [string] $OutFile, [int] $TimeoutMinutes = 30)
    $psi = [System.Diagnostics.ProcessStartInfo]::new($FilePath)
    foreach ($argument in $Arguments) { $psi.ArgumentList.Add($argument) }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $process = [System.Diagnostics.Process]::Start($psi)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    $timedOut = -not $process.WaitForExit($TimeoutMinutes * 60000)
    if ($timedOut) { try { $process.Kill($true) } catch { Write-Host "Kill failed: $_" } }
    $process.WaitForExit()
    $watch.Stop()
    Set-Content -LiteralPath $OutFile -Value $stdout.Result -Encoding UTF8
    Set-Content -LiteralPath "$OutFile.stderr.txt" -Value $stderr.Result -Encoding UTF8
    return [pscustomobject]@{ ExitCode = $(if ($timedOut) { -999 } else { $process.ExitCode }); Seconds = [math]::Round($watch.Elapsed.TotalSeconds, 1); TimedOut = $timedOut; Stdout = $stdout.Result; Stderr = $stderr.Result }
}

function Invoke-Docker([string[]] $Arguments, [switch] $AllowFailure, [string] $Description = '') {
    if (-not $Description) { $Description = "docker $($Arguments[0])" }
    return Invoke-BcDevEnvNativeCommand -FilePath 'docker' -Arguments $Arguments -Description $Description -AllowFailure:$AllowFailure
}

function Get-FailureCategory([string] $Text) {
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    if ($Text -match 'CreateNavTestService|TestPageClient|TestServiceConnection') { return 'TestPage-NotSupported' }
    if ($Text -match 'NotSupportedException') { return 'NotSupported-other' }
    if ($Text -match 'Handler') { return 'Handler' }
    if ($Text -match 'does not exist') { return 'MissingRecord' }
    return 'Other'
}

function Read-ODataResults([string] $Path) {
    $map = @{}
    $xml = New-Object System.Xml.XmlDocument
    $xml.Load($Path)
    foreach ($case in $xml.SelectNodes('//testcase')) {
        $codeunitId = if ($case.GetAttribute('classname') -match '^Codeunit (\d+)') { [int]$Matches[1] } else { 0 }
        $status = 'Passed'
        $message = ''
        $failure = $case.SelectSingleNode('failure')
        if (-not $failure) { $failure = $case.SelectSingleNode('error') }
        if ($failure) { $status = 'Failed'; $message = "$($failure.GetAttribute('message'))`n$($failure.InnerText)" }
        elseif ($case.SelectSingleNode('skipped')) { $status = 'Skipped' }
        $map["$codeunitId|$($case.GetAttribute('name'))"] = [pscustomobject]@{ Status = $status; Message = $message }
    }
    return $map
}

function Get-JsonProperty($Object, [string] $Name) {
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties | Where-Object { $_.Name -ieq $Name } | Select-Object -First 1
    if ($property) { return $property.Value }
    return $null
}

function Read-AlToolResults([string] $Text) {
    $map = @{}
    $start = $Text.IndexOf('{')
    if ($start -lt 0) { return $map }
    $json = $Text.Substring($start) | ConvertFrom-Json -Depth 20
    foreach ($result in @(Get-JsonProperty $json 'results')) {
        if ($null -eq $result) { continue }
        $codeunitId = [int](Get-JsonProperty $result 'codeunitId')
        $method = [string](Get-JsonProperty $result 'methodName')
        $map["$codeunitId|$method"] = [pscustomobject]@{ Status = [string](Get-JsonProperty $result 'status'); Message = [string](Get-JsonProperty $result 'output'); DurationMs = Get-JsonProperty $result 'durationMs' }
    }
    return $map
}

$names = Get-BcDevEnvResourceNames -Project 'altool-probe' -BuildMode 'Default' -RunId "$env:GITHUB_RUN_ID" -RunAttempt "$env:GITHUB_RUN_ATTEMPT"
$work = Join-Path $(if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [System.IO.Path]::GetTempPath() }) "bcdevenv\$($names.EnvName)"
New-Item -ItemType Directory -Path $work -Force | Out-Null
$dataHome = Join-Path "$env:SystemDrive\" "bcdevenv-home\$($names.EnvName)"

Write-Host "::group::Install set"
$installSet = Get-BcDevEnvInstallSet -ProjectPath $projectPath
$all = @($installSet.Apps)
$selected = @()
foreach ($name in $TestAppNames) {
    $app = $all | Where-Object { $_.Name -eq $name } | Select-Object -First 1
    if ($app) { $selected += $app } else { Write-Host "::warning::Test app '$name' not found in the artifacts." }
}
if ($selected.Count -eq 0) { throw 'None of the probe test apps were found.' }
$apps = @(Get-BcDevEnvDependencyClosure -OrderedApps $all -RootIds (@($selected | ForEach-Object { $_.Id }) + $runnerDependencyIds))
Write-Host "Installing $($apps.Count) of $($all.Count) apps; test apps: $(@($selected | ForEach-Object { $_.Name }) -join ', ')"

$succeeded = $false
try {
    Write-Section 'Docker, CLI, SQL, platform'
    Wait-BcDevEnvDockerEngine -ServiceName 'docker' -TimeoutSeconds 300 | Out-Null
    $toolRoot = Join-Path $repoRoot 'bcdevenv'
    $env:BCDEVENV_TOOL_ROOT = $toolRoot
    $cliProject = Join-Path $toolRoot 'src/BcDevEnv.Cli/BcDevEnv.Cli.csproj'
    Invoke-BcDevEnvWithRetry -Description 'dotnet restore bcdevenv' -MaxAttempts 4 -ScriptBlock {
        Invoke-BcDevEnvNativeCommand -FilePath 'dotnet' -Arguments @('restore', $cliProject, '--nologo', '-v', 'q') -Description 'dotnet restore bcdevenv' | Out-Null
    } | Out-Null
    Invoke-BcDevEnvNativeCommand -FilePath 'dotnet' -Arguments @('build', $cliProject, '-c', 'Release', '--no-restore', '--nologo', '-v', 'q') -Description 'dotnet build bcdevenv' | Out-Null
    $bcdevenv = (Get-ChildItem -LiteralPath (Join-Path $toolRoot 'src/BcDevEnv.Cli/bin/Release') -Recurse -File -Filter 'bcdevenv.exe' | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1).FullName
    Initialize-BcDevEnvSqlServer -Instance 'SQLEXPRESS' -DataHome $dataHome -InstallScript (Join-Path $toolRoot 'container/Install-SqlExpress.ps1') | Out-Null
    $platform = Invoke-BcDevEnvWithRetry -Description 'Resolving the BCPlatform artifact' -MaxAttempts 3 -ScriptBlock { Get-BcDevEnvPlatformArtifact }
    $platformZip = Join-Path $work 'platform.zip'
    $platformDir = Join-Path $work 'platform'
    Save-BcDevEnvDownload -Uri $platform.Url -OutFile $platformZip -ValidateZip -Description "Downloading BCPlatform $($platform.Version)" | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::ExtractToDirectory($platformZip, $platformDir)
    Remove-Item -LiteralPath $platformZip -Force
    $layout = Get-BcDevEnvPlatformLayout -PlatformDir $platformDir
    Add-Summary "Platform: $($platform.Version)"

    Write-Section 'AL tool'
    $nupkg = Join-Path $work 'altool.nupkg'
    $alToolDir = Join-Path $work 'altool'
    $id = 'microsoft.dynamics.businesscentral.development.tools'
    Save-BcDevEnvDownload -Uri "https://api.nuget.org/v3-flatcontainer/$id/$($AlToolVersion.ToLowerInvariant())/$id.$($AlToolVersion.ToLowerInvariant()).nupkg" -OutFile $nupkg -ValidateZip -Description "Downloading the AL tool $AlToolVersion" | Out-Null
    [System.IO.Compression.ZipFile]::ExtractToDirectory($nupkg, $alToolDir)
    $alToolBin = Join-Path $alToolDir 'tools\net10.0\any'
    $alToolDll = Join-Path $alToolBin 'altool.dll'
    if (-not (Test-Path -LiteralPath $alToolDll)) { throw "altool.dll not found under $alToolBin" }
    Add-Summary "AL tool: $AlToolVersion"

    Write-Section 'Compile the BcDevEnv Test Runner app'
    $symbols = Join-Path $work 'runner-symbols'
    New-Item -ItemType Directory -Path $symbols -Force | Out-Null
    Copy-Item -LiteralPath $layout.SystemApp -Destination $symbols
    foreach ($dependency in @(Get-BcDevEnvDependencyClosure -OrderedApps $apps -RootIds $runnerDependencyIds)) { Copy-Item -LiteralPath $dependency.Path -Destination $symbols }
    $runnerSource = Join-Path $work 'runner-src'
    Copy-Item -LiteralPath (Join-Path $toolRoot 'testrunner') -Destination $runnerSource -Recurse
    $alc = Find-BcDevEnvAlc -VsixPath $layout.Vsix -Destination (Join-Path $work 'alc')
    $runnerApp = Join-Path $work 'runner\BcDevEnv_BcDevEnv Test Runner.app'
    New-Item -ItemType Directory -Path (Split-Path $runnerApp -Parent) -Force | Out-Null
    Invoke-BcDevEnvNativeCommand -FilePath $alc -Arguments @("/project:$runnerSource", "/packagecachepath:$symbols", "/out:$runnerApp", "/assemblyprobingpaths:$($layout.ServiceDir)") -Description 'Compiling the BcDevEnv Test Runner' | Out-Null

    Write-Section 'License'
    $artifactUrl = Get-BcDevEnvApplicationArtifactUrl -ResolvedArtifactUrl '' -Settings $settings
    $licensePath = Get-BcDevEnvArtifactLicense -ArtifactUrl $artifactUrl -Destination (Join-Path $work 'license')

    Write-Section "Provision ($($apps.Count) apps + runner)"
    Invoke-BcDevEnvNativeCommand -FilePath $bcdevenv -Arguments @('create-env', '--platform', $platformDir, '--country', 'w1', '--name', $names.EnvName, '--sql-server', 'localhost', '--sql-instance', 'SQLEXPRESS') -Description 'bcdevenv create-env' | Out-Null
    $appList = Join-Path $work 'apps.txt'
    Set-Content -LiteralPath $appList -Value (@('# altool probe') + @($apps | ForEach-Object { $_.Path }) + @($runnerApp)) -Encoding UTF8
    $buildArguments = @('build-image', '--env', $names.EnvName, '--tag', $names.ImageTag, '--app-list', $appList, '--company', $companyName, '--license', $licensePath,
        '--server-setting', 'EnforceUserPathForAlFileOperations=false', '--server-setting', 'UsePermissionSetsFromExtensions=true', '--server-setting', 'NavHttpClientAntiSSRFEnabled=false', '--server-setting', 'EnableTaskScheduler=false')
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    Invoke-BcDevEnvNativeCommand -FilePath $bcdevenv -Arguments $buildArguments -Description 'bcdevenv build-image' | Out-Null
    Add-Summary ("build-image: {0:N0}s for {1} apps" -f $watch.Elapsed.TotalSeconds, ($apps.Count + 1))
    Invoke-BcDevEnvNativeCommand -FilePath $bcdevenv -Arguments @('start', '--image', $names.ImageTag, '--name', $names.ContainerName, '--detach') -Description 'bcdevenv start' | Out-Null
    $probe = ConvertTo-BcDevEnvEncodedScript -Script (Get-BcDevEnvReadinessScript -ODataUrl $odataUrl -RequiredText 'BcDevEnvTestRunner_PrepareTests')
    if ((Invoke-Docker -Arguments @('exec', $names.ContainerName, 'powershell', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $probe) -AllowFailure -Description 'readiness') -ne 0) {
        throw 'The server did not become ready.'
    }
    Invoke-Docker -Arguments @('exec', '-u', 'ContainerAdministrator', $names.ContainerName, 'cmd', '/c', 'mkdir', "$runFolder\results", "$runFolder\altool-groups") | Out-Null
    Invoke-Docker -Arguments @('cp', $alToolBin, "$($names.ContainerName):C:\altool") -Description 'Copying the AL tool into the container' | Out-Null
    $containerDotnet = 'C:\Program Files\dotnet\dotnet.exe'
    $version = Invoke-Captured -FilePath 'docker' -Arguments @('exec', '-u', 'ContainerAdministrator', $names.ContainerName, $containerDotnet, '--list-runtimes') -OutFile (Join-Path $out 'container-dotnet-runtimes.txt') -TimeoutMinutes 2
    Write-Host $version.Stdout

    $comparison = New-Object System.Collections.Generic.List[object]
    $appIndex = 0
    foreach ($app in $selected) {
        $appIndex++
        $slug = ($app.Name -replace '[^A-Za-z0-9]+', '-').Trim('-')

        Write-Section "OData runner: $($app.Name)"
        $containerResult = "$runFolder\results\odata-$appIndex.xml"
        $hostResult = Join-Path $out "odata-$slug.xml"
        $pass = [pscustomobject]@{ Name = 'All test codeunits'; TestType = ''; Isolation = ''; RunnerId = 130450 }
        $runArguments = Get-BcDevEnvRunTestsArguments -ODataUrl $odataUrl -CompanyName $companyName -App $app -Pass $pass -DisabledTestsRoots @() -ResultFile $containerResult
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        Invoke-Docker -Arguments (@('exec', '-u', 'ContainerAdministrator', $names.ContainerName, $containerCli) + $runArguments) -AllowFailure -Description "run-tests $($app.Name)" | Out-Null
        $odataSeconds = [math]::Round($watch.Elapsed.TotalSeconds, 1)
        Invoke-Docker -Arguments @('cp', "$($names.ContainerName):$containerResult", $hostResult) -AllowFailure | Out-Null
        $odata = if (Test-Path -LiteralPath $hostResult) { Read-ODataResults $hostResult } else { @{} }

        Write-Section "AL tool runtests: $($app.Name)"
        $listFile = Join-Path $out "listtests-$slug.json"
        $list = Invoke-Captured -FilePath 'dotnet' -Arguments @($alToolDll, 'listtests', '--appfile', $app.Path) -OutFile $listFile -TimeoutMinutes 5
        $discovered = $list.Stdout.Substring([Math]::Max(0, $list.Stdout.IndexOf('{'))) | ConvertFrom-Json -Depth 20
        $groups = @(@(Get-JsonProperty $discovered 'codeunits') | ForEach-Object { [ordered]@{ codeunitId = [int](Get-JsonProperty $_ 'id'); testMethods = @() } })
        $groupFile = Join-Path $work "groups-$appIndex.json"
        ConvertTo-Json -InputObject @($groups) -Depth 5 | Set-Content -LiteralPath $groupFile -Encoding UTF8
        $containerGroups = "$runFolder\altool-groups\groups-$appIndex.json"
        Invoke-Docker -Arguments @('cp', $groupFile, "$($names.ContainerName):$containerGroups") | Out-Null
        $altoolArgs = @('exec', '-u', 'ContainerAdministrator', $names.ContainerName, $containerDotnet, 'C:\altool\altool.dll', 'runtests', '--testgroups', $containerGroups,
            '--company', $companyName, '--server', 'http://localhost', '--serverinstance', 'BC', '--port', '7049', '--authentication', 'Windows')
        $run = Invoke-Captured -FilePath 'docker' -Arguments $altoolArgs -OutFile (Join-Path $out "altool-$slug.json") -TimeoutMinutes $RunTimeoutMinutes
        Write-Host "altool exit $($run.ExitCode) in $($run.Seconds)s (timed out: $($run.TimedOut))"
        Write-Host ($run.Stdout.Substring(0, [Math]::Min(3000, $run.Stdout.Length)))
        Write-Host ($run.Stderr.Substring(0, [Math]::Min(3000, $run.Stderr.Length)))
        if ($appIndex -eq 1) {
            Invoke-Captured -FilePath 'docker' -Arguments ($altoolArgs + @('--raw')) -OutFile (Join-Path $out "altool-raw-$slug.txt") -TimeoutMinutes $RunTimeoutMinutes | Out-Null
        }
        $altool = @{}
        try { $altool = Read-AlToolResults $run.Stdout } catch { Write-Host "::warning::Could not parse the altool output for $($app.Name): $_" }

        $keys = @($odata.Keys) + @($altool.Keys) | Sort-Object -Unique
        $counts = [ordered]@{ OData = $odata.Count; AlTool = $altool.Count; OPassed = 0; OFailed = 0; APassed = 0; AFailed = 0; ASkipped = 0; FixedByAlTool = 0; BrokenByAlTool = 0; OTestPage = 0; ATestPage = 0 }
        foreach ($key in $keys) {
            $o = $odata[$key]; $a = $altool[$key]
            $oCat = if ($o -and $o.Status -eq 'Failed') { Get-FailureCategory $o.Message } else { '' }
            $aCat = if ($a -and $a.Status -eq 'Failed') { Get-FailureCategory $a.Message } else { '' }
            if ($o -and $o.Status -eq 'Passed') { $counts.OPassed++ }
            if ($o -and $o.Status -eq 'Failed') { $counts.OFailed++ }
            if ($a -and $a.Status -eq 'Passed') { $counts.APassed++ }
            if ($a -and $a.Status -eq 'Failed') { $counts.AFailed++ }
            if ($a -and $a.Status -eq 'Skipped') { $counts.ASkipped++ }
            if ($oCat -eq 'TestPage-NotSupported') { $counts.OTestPage++ }
            if ($aCat -eq 'TestPage-NotSupported') { $counts.ATestPage++ }
            if ($o -and $a -and $o.Status -eq 'Failed' -and $a.Status -eq 'Passed') { $counts.FixedByAlTool++ }
            if ($o -and $a -and $o.Status -eq 'Passed' -and $a.Status -eq 'Failed') { $counts.BrokenByAlTool++ }
            $comparison.Add([pscustomobject]@{
                    App = $app.Name; Test = $key
                    OData = if ($o) { $o.Status } else { '-' }; ODataCategory = $oCat
                    AlTool = if ($a) { $a.Status } else { '-' }; AlToolCategory = $aCat
                    ODataMessage = if ($o) { ($o.Message -split "`n")[0] } else { '' }
                    AlToolMessage = if ($a) { ($a.Message -split "`n" | Select-Object -First 3) -join ' | ' } else { '' }
                })
        }
        Add-Summary ("| {0} | OData {1}s: {2} tests, {3} passed, {4} failed ({5} TestPage) | altool {6}s exit {7}: {8} tests, {9} passed, {10} failed ({11} TestPage), {12} skipped | fixed {13}, broken {14} |" -f
            $app.Name, $odataSeconds, $counts.OData, $counts.OPassed, $counts.OFailed, $counts.OTestPage, $run.Seconds, $run.ExitCode, $counts.AlTool, $counts.APassed, $counts.AFailed, $counts.ATestPage, $counts.ASkipped, $counts.FixedByAlTool, $counts.BrokenByAlTool)
    }
    $comparison | Export-Csv -LiteralPath (Join-Path $out 'comparison.csv') -NoTypeInformation -Encoding UTF8
    $succeeded = $true
}
catch {
    Add-Summary "PROBE ERROR: $($_.Exception.Message)"
    Write-Host $_.ScriptStackTrace
}
finally {
    Write-Host "::endgroup::"
    $summary | Set-Content -LiteralPath (Join-Path $out 'summary.md') -Encoding UTF8
    if ($env:GITHUB_STEP_SUMMARY) { $summary | Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Encoding UTF8 }
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    if (-not $succeeded) { & docker logs --tail 200 $names.ContainerName *> (Join-Path $out 'container-logs.txt') }
    & docker exec -u ContainerAdministrator $names.ContainerName wevtutil epl Application C:\ContainerEventLog.evtx /ow:true *> $null
    & docker cp "$($names.ContainerName):C:\ContainerEventLog.evtx" (Join-Path $out 'ContainerEventLog.evtx') *> $null
    & docker rm -f $names.ContainerName *> $null
    $ErrorActionPreference = $previous
}
if (-not $succeeded) { exit 1 }
