<#
.SYNOPSIS
    Building blocks for the bcdevenv-based replacement of AL-Go's RunPipeline action
    (.github/actions/RunBcDevEnvPipeline).

.DESCRIPTION
    The pipeline takes the apps already compiled by AL-Go's CompileApps action (workspace
    compilation), creates an EMPTY-database Business Central container with the bcdevenv CLI
    from the BCPlatform version pinned in build/Packages.json, installs the project's apps and
    test apps into it and runs the tests, honoring the DisabledTests folders (src/DisabledTests)
    before execution. The BcDevEnvTestRunner OData service selects the tests (test type, test
    isolation pass, DisabledTests); by default the AL tool's runtests executes them in a client
    session (test executor 'altool'), or the OData service itself does (test executor 'odata').

    Nothing in here uses BcContainerHelper / NavContainerHelper. The functions are kept pure where
    possible so they can be covered by Pester (build/scripts/tests/BcDevEnvPipeline.Test.ps1).
#>

Set-StrictMode -Version 2.0

$script:ApplicationAppId = 'c1335042-3002-4257-bf8a-75c898ccb1b8'
$script:SystemApplicationAppId = '63ca2fa4-4f03-4f2b-a480-172fef340d3f'
$script:TestRunnerAppId = '23de40a6-dfe8-4f80-80db-d70f83ce8caf'

# Same defaults as build/scripts/PublishBcContainerApp.ps1 (the native AL-Go publish override).
$script:DefaultAppsNotToPublish = @('Library - No Transactions', 'Prevent Metadata Updates Library')

$script:SupportedTestTypes = @('', 'UnitTest', 'IntegrationTest', 'Uncategorized')

# Codeunits of the Microsoft test framework used by the native BCApps pipeline.
$script:IsolatedTestRunnerId = 130450
$script:IsolationDisabledTestRunnerId = 130451

# Test executors of bcdevenv run-tests: 'altool' runs the selected tests in a client session through the
# AL tool's runtests (development endpoint), 'odata' runs them with the BcDevEnvTestRunner OData service.
$script:SupportedTestExecutors = @('altool', 'odata')
$script:DefaultTestExecutor = 'altool'
# Microsoft.Dynamics.BusinessCentral.Development.Tools. 30.0.42.60748-beta cannot be used: it refuses the
# platform 30.0 server ("Tool supports Web API <= 7.0, debuggers <= 8.0; server Web API 8.0, Debugger 9.0").
$script:AlToolPackageId = 'microsoft.dynamics.businesscentral.development.tools'
$script:DefaultAlToolVersion = '30.0.44.47290-beta'
$script:DefaultAppTestTimeoutMinutes = 240
# Permissions Mock (src/Tools/Test Framework/Test Libraries/Permissions Mock). When it is installed, the
# BcDevEnv Test Runner is compiled against it so its state reset can start and stop the mock.
$script:PermissionsMockAppId = '40860557-a18d-42ad-aecb-22b7dd80dc80'
$script:PermissionsMockSymbol = 'BCDEVENV_PERMISSIONSMOCK'
# Source of t2embed.dll (font embedding, needed to render reports as PDF), which Windows Server Core
# lacks: the install archive of the official Business Central images (nav-docker generic/Run/SetupUrls.ps1
# $navDockerInstallUrl; navinstall.ps1 copies its Install\t2embed.dll into System32 when missing).
$script:DefaultT2EmbedUrl = 'https://bcartifacts-exdbf9fwegejdqak.b02.azurefd.net/prerequisites/nav-docker-install.zip'

<#
.SYNOPSIS
    Reads a setting from an AL-Go settings object (PSCustomObject or dictionary), case-insensitively.
.OUTPUTS
    The setting value, or -Default when the setting is missing or $null. Arrays are unrolled by
    PowerShell, so callers that expect an array should wrap the call in @().
#>
function Get-BcDevEnvSetting {
    param(
        [AllowNull()] $Settings,
        [Parameter(Mandatory = $true)] [string] $Name,
        $Default = $null
    )

    if ($null -eq $Settings) { return $Default }
    $value = $null
    $found = $false
    if ($Settings -is [System.Collections.IDictionary]) {
        foreach ($key in $Settings.Keys) {
            if ([string]::Equals([string]$key, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
                $value = $Settings[$key]
                $found = $true
                break
            }
        }
    }
    else {
        $property = $Settings.PSObject.Properties[$Name]
        if ($null -ne $property) {
            $value = $property.Value
            $found = $true
        }
    }
    if (-not $found -or $null -eq $value) { return $Default }
    return $value
}

function Get-BcDevEnvStringArray {
    param([AllowNull()] $Value)
    return @(@($Value) | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ })
}

<#
.SYNOPSIS
    Mirrors Test-IsRUProject in build/scripts/ImportTestDataInBcContainer.ps1.
#>
function Test-BcDevEnvIsRUProject {
    param(
        [AllowNull()] $Settings,
        [string] $Project = ''
    )

    $projectName = [string](Get-BcDevEnvSetting -Settings $Settings -Name 'projectName' -Default '')
    if ($projectName -match '\(RU\)') { return $true }
    foreach ($projectToTest in (Get-BcDevEnvStringArray (Get-BcDevEnvSetting -Settings $Settings -Name 'projectsToTest'))) {
        if ((($projectToTest -replace '\\', '/').TrimEnd('/')) -ieq 'build/projects/Apps RU') { return $true }
    }
    if ((($Project -replace '\\', '/').TrimEnd('/')) -ieq 'build/projects/Test Apps RU') { return $true }
    return $false
}

<#
.SYNOPSIS
    Decides what the pipeline does for a project/build mode, from the AL-Go settings.
.DESCRIPTION
    Mirrors the native BCApps pipeline (RunPipeline + NewBcContainer/ImportTestDataInBcContainer/
    RunTestsInBcContainer overrides) as far as an empty-database container driven over OData can:

      * doNotPublishApps (with workspace compilation)  -> Skip (AL-Go's RunPipeline does nothing).
      * workspaceCompilation.enabled must be true       -> apps come from the CompileApps action.
      * testType Legacy                                 -> not supported (needs the legacy DemoTool,
                                                           which runs through a web client page action).
      * RU projects                                     -> not supported (needs base apps, then the
                                                           company and Company-Initialize, then the rest).
      * doNotRunTests                                   -> ProvisionOnly (container is created and the
                                                           apps are installed, no tests are run).

    Company data per test type (from build/scripts/ImportTestDataInBcContainer.ps1):
      UnitTest / none : empty company, Company-Initialize (2). Upstream's tests log in through a client
                        session, whose OnAfterLogin subscriber runs Company-Initialize; the OData runner
                        session has no GUI, so that subscriber exits and the pipeline runs it instead.
      IntegrationTest : Company-Initialize (2), Contoso CreateSetupDemoData (5193), 5691.
      Uncategorized   : evaluation company, Company-Initialize (2), Contoso CreateAllDemoData (5193),
                        DeleteWarehouseEmployee (5140), 5691.

    Test passes (from build/scripts/RunTestsInBcContainer.ps1 / ParallelTestExecution.psm1):
      pass 1: codeunits requiring isolation None/Codeunit with runner 130450;
      pass 2: codeunits requiring isolation Disabled with runner 130451 - when the test type is
              UnitTest or enableCleanTestCodeunitExecution is set.
      Without a test type: a single pass over every test codeunit with runner 130450.
#>
function Get-BcDevEnvPipelinePlan {
    param(
        [Parameter(Mandatory = $true)] $Settings,
        [string] $Project = '.'
    )

    $country = [string](Get-BcDevEnvSetting -Settings $Settings -Name 'country' -Default '')
    if ([string]::IsNullOrWhiteSpace($country) -or $country -ieq 'base') { $country = 'w1' }
    $testType = [string](Get-BcDevEnvSetting -Settings $Settings -Name 'testType' -Default '')
    $companyName = [string](Get-BcDevEnvSetting -Settings $Settings -Name 'companyName' -Default '')
    if ([string]::IsNullOrWhiteSpace($companyName)) { $companyName = 'CRONUS International Ltd.' }

    $plan = [ordered]@{
        Action                         = 'Test'
        Reason                         = ''
        TestType                       = $testType
        Country                        = $country
        CompanyName                    = $companyName
        EvaluationCompany              = $false
        CompanyCodeunits               = @()
        ServerSettings                 = @()
        Passes                         = @()
        RunTestsInAllInstalledTestApps = [bool](Get-BcDevEnvSetting -Settings $Settings -Name 'runTestsInAllInstalledTestApps' -Default $false)
        BucketNumber                   = [int](Get-BcDevEnvSetting -Settings $Settings -Name 'bucketNumber' -Default 0)
    }

    $workspaceCompilation = Get-BcDevEnvSetting -Settings $Settings -Name 'workspaceCompilation'
    $workspaceCompilationEnabled = [bool](Get-BcDevEnvSetting -Settings $workspaceCompilation -Name 'enabled' -Default $false)

    if ([bool](Get-BcDevEnvSetting -Settings $Settings -Name 'doNotPublishApps' -Default $false)) {
        $plan.Action = 'Skip'
        $plan.Reason = 'doNotPublishApps is set: the apps are compiled by CompileApps and nothing is published or tested (same as AL-Go RunPipeline with workspace compilation).'
        return [pscustomobject]$plan
    }
    if (-not $workspaceCompilationEnabled) {
        throw "The bcdevenv pipeline requires workspaceCompilation.enabled = true (the apps are compiled by the AL-Go CompileApps action); project '$Project' does not enable it."
    }
    if ($testType -ieq 'Legacy') {
        throw "testType 'Legacy' (build mode bucket $($plan.BucketNumber)) is not supported by the bcdevenv pipeline: the legacy demo data (DemoTool) is generated through a web client page action that has no OData equivalent in an empty-database container."
    }
    if ($script:SupportedTestTypes -notcontains $testType) {
        throw "testType '$testType' is not supported by the bcdevenv pipeline. Supported: UnitTest, IntegrationTest, Uncategorized (or none)."
    }
    if (Test-BcDevEnvIsRUProject -Settings $Settings -Project $Project) {
        throw "RU projects are not supported by the bcdevenv pipeline: they need the base apps installed, then the company created and Company-Initialize run, before the remaining apps (CD Tracking) can be installed, which a bake-time app install cannot interleave."
    }

    switch ($testType) {
        'IntegrationTest' {
            $plan.CompanyCodeunits = @('2', '5193:CreateSetupDemoData', '5691')
        }
        'Uncategorized' {
            $plan.EvaluationCompany = $true
            $plan.CompanyCodeunits = @('2', '5193:CreateAllDemoData', '5140:DeleteWarehouseEmployee', '5691')
        }
        default {
            $plan.CompanyCodeunits = @('2')
        }
    }

    $enableTaskScheduler = [bool](Get-BcDevEnvSetting -Settings $Settings -Name 'enableTaskScheduler' -Default $false)
    $plan.ServerSettings = @(
        'EnforceUserPathForAlFileOperations=false',
        'UsePermissionSetsFromExtensions=true',
        'NavHttpClientAntiSSRFEnabled=false',
        "EnableTaskScheduler=$($enableTaskScheduler.ToString().ToLowerInvariant())"
    )

    if ([string]::IsNullOrEmpty($testType)) {
        $plan.Passes = @([pscustomobject]@{ Name = 'All test codeunits'; TestType = ''; Isolation = ''; RunnerId = $script:IsolatedTestRunnerId })
    }
    else {
        $passes = @([pscustomobject]@{ Name = "$testType (isolation None/Codeunit)"; TestType = $testType; Isolation = 'None'; RunnerId = $script:IsolatedTestRunnerId })
        $cleanExecution = [bool](Get-BcDevEnvSetting -Settings $Settings -Name 'enableCleanTestCodeunitExecution' -Default $false)
        if ($cleanExecution -or $testType -eq 'UnitTest') {
            $passes += [pscustomobject]@{ Name = "$testType (isolation Disabled)"; TestType = $testType; Isolation = 'Disabled'; RunnerId = $script:IsolationDisabledTestRunnerId }
        }
        $plan.Passes = $passes
    }

    if ([bool](Get-BcDevEnvSetting -Settings $Settings -Name 'doNotRunTests' -Default $false)) {
        $plan.Action = 'ProvisionOnly'
        $plan.Reason = 'doNotRunTests is set: the container is created and the apps are installed, but no tests are run.'
        $plan.Passes = @()
    }
    return [pscustomobject]$plan
}

<#
.SYNOPSIS
    Returns the resource names (container, image tag, environment) for a project/build mode run.
#>
function Get-BcDevEnvResourceNames {
    param(
        [string] $Project = '.',
        [string] $BuildMode = 'Default',
        [string] $RunId = '0',
        [string] $RunAttempt = '1'
    )

    $projectPart = (($Project -replace '[^A-Za-z0-9]+', '-').Trim('-')).ToLowerInvariant()
    if (-not $projectPart) { $projectPart = 'root' }
    $projectPart = $projectPart -replace '^build-projects-', ''
    $modePart = (($BuildMode -replace '[^A-Za-z0-9]+', '-').Trim('-')).ToLowerInvariant()
    if (-not $modePart) { $modePart = 'default' }
    $id = "$projectPart-$modePart"
    if ($id.Length -gt 48) { $id = $id.Substring(0, 48).Trim('-') }
    $runPart = (($RunId -replace '[^A-Za-z0-9]+', '') + '-' + ($RunAttempt -replace '[^A-Za-z0-9]+', '')).Trim('-').ToLowerInvariant()
    if (-not $runPart) { $runPart = 'local' }

    return [pscustomobject]@{
        ContainerName = "bcdevenv-$id-$runPart"
        ImageTag      = "bcdevenv-algo:$id-$runPart"
        EnvName       = "bcapps-$id-$runPart"
    }
}

<#
.SYNOPSIS
    Runs a script block and retries it with exponential backoff when it throws.
.DESCRIPTION
    For the transient infrastructure failures seen on hosted runners (truncated downloads, gateway
    timeouts, ...). The script block receives the attempt number as its first argument. After the last
    attempt the error is rethrown with the description and the attempt count.
#>
function Invoke-BcDevEnvWithRetry {
    param(
        [Parameter(Mandatory = $true)] [scriptblock] $ScriptBlock,
        [Parameter(Mandatory = $true)] [string] $Description,
        [ValidateRange(1, 100)] [int] $MaxAttempts = 5,
        [ValidateRange(0, 3600)] [int] $InitialDelaySeconds = 10,
        [ValidateRange(0, 3600)] [int] $MaxDelaySeconds = 120
    )

    $retryDelay = $InitialDelaySeconds
    for ($retryAttempt = 1; ; $retryAttempt++) {
        try {
            $retryResult = & $ScriptBlock $retryAttempt
            return $retryResult
        }
        catch {
            $retryMessage = $_.Exception.Message
            if ($retryAttempt -ge $MaxAttempts) {
                throw "$Description failed after $MaxAttempts attempt(s): $retryMessage"
            }
            Write-Host "$Description failed (attempt $retryAttempt of $MaxAttempts): $retryMessage Retrying in $retryDelay second(s)."
            Start-Sleep -Seconds $retryDelay
            $retryDelay = [Math]::Min($retryDelay * 2, $MaxDelaySeconds)
        }
    }
}

<#
.SYNOPSIS
    Checks a downloaded file: it must exist and be non-empty, and optionally match a SHA256 hash and
    be a readable zip archive (a truncated zip has no readable central directory).
#>
function Test-BcDevEnvDownloadedFile {
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [string] $Sha256 = '',
        [switch] $ValidateZip
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "The download did not produce '$Path'." }
    $length = (Get-Item -LiteralPath $Path).Length
    if ($length -le 0) { throw "The downloaded file '$Path' is empty." }
    if ($Sha256) {
        $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
        if ($actual -ne $Sha256) { throw "The downloaded file '$Path' ($length bytes) has SHA256 $actual; expected $Sha256." }
    }
    if ($ValidateZip) {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $entryCount = 0
        try {
            $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
            try { $entryCount = $zip.Entries.Count } finally { $zip.Dispose() }
        }
        catch {
            throw "The downloaded file '$Path' ($length bytes) is not a valid zip archive: $($_.Exception.Message)"
        }
        if ($entryCount -eq 0) { throw "The downloaded zip archive '$Path' ($length bytes) has no entries." }
    }
}

<#
.SYNOPSIS
    Downloads a file with retries: a failed or invalid attempt (see Test-BcDevEnvDownloadedFile) deletes
    the partial file and is retried with exponential backoff.
#>
function Save-BcDevEnvDownload {
    param(
        [Parameter(Mandatory = $true)] [string] $Uri,
        [Parameter(Mandatory = $true)] [string] $OutFile,
        [string] $Description = '',
        [string] $Sha256 = '',
        [switch] $ValidateZip,
        [ValidateRange(1, 100)] [int] $MaxAttempts = 5,
        [ValidateRange(0, 3600)] [int] $InitialDelaySeconds = 10,
        [int] $TimeoutSec = 3600
    )

    if (-not $Description) { $Description = "Downloading '$(([System.Uri]$Uri).GetLeftPart([System.UriPartial]::Path))'" }
    $parent = Split-Path -Parent $OutFile
    if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    Invoke-BcDevEnvWithRetry -Description $Description -MaxAttempts $MaxAttempts -InitialDelaySeconds $InitialDelaySeconds -ScriptBlock {
        if (Test-Path -LiteralPath $OutFile) { Remove-Item -LiteralPath $OutFile -Force }
        try {
            Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing -TimeoutSec $TimeoutSec | Out-Null
            Test-BcDevEnvDownloadedFile -Path $OutFile -Sha256 $Sha256 -ValidateZip:$ValidateZip
        }
        catch {
            Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
            throw
        }
    } | Out-Null
    $file = Get-Item -LiteralPath $OutFile
    Write-Host "Downloaded $($file.Length) bytes to '$OutFile'."
    return $file.FullName
}

<#
.SYNOPSIS
    Decodes one secret from the AL-Go ReadSecrets output ($env:Secrets: JSON, base64 values).
#>
function Get-BcDevEnvSecretValue {
    param(
        [AllowEmptyString()] [string] $SecretsJson,
        [Parameter(Mandatory = $true)] [string] $Name
    )

    if ([string]::IsNullOrWhiteSpace($SecretsJson)) { return '' }
    $secrets = $SecretsJson | ConvertFrom-Json
    $encoded = [string](Get-BcDevEnvSetting -Settings $secrets -Name $Name -Default '')
    if ([string]::IsNullOrWhiteSpace($encoded)) { return '' }
    try {
        return [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($encoded)).Trim()
    }
    catch {
        throw "Secret '$Name' in the AL-Go secrets is not base64 encoded as produced by the ReadSecrets action."
    }
}

function Get-BcDevEnvLicenseExtension {
    param([Parameter(Mandatory = $true)] [byte[]] $Bytes)

    $index = 0
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) { $index = 3 }
    elseif ($Bytes.Length -ge 2 -and (($Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) -or ($Bytes[0] -eq 0xFE -and $Bytes[1] -eq 0xFF))) { $index = 2 }
    while ($index -lt $Bytes.Length -and ($Bytes[$index] -eq 0x00 -or $Bytes[$index] -eq 0x20 -or $Bytes[$index] -eq 0x09 -or $Bytes[$index] -eq 0x0D -or $Bytes[$index] -eq 0x0A)) { $index++ }
    if ($index -lt $Bytes.Length -and $Bytes[$index] -eq 0x3C) { return '.bclicense' }
    return '.flf'
}

<#
.SYNOPSIS
    Restores the optional Business Central license from an AL-Go secret.
.DESCRIPTION
    The secret (default licenseFileUrl, the AL-Go convention; map another secret onto it with the
    AL-Go licenseFileUrlSecretName setting) may hold:
      * an http(s) URL to the license file (AL-Go licenseFileUrl semantics),
      * a gzip-compressed, base64-encoded license file (value starting with H4sI),
      * a path to a license file on the runner.
    When the secret is absent or empty a warning is written and $null is returned: the pipeline
    then uses the CRONUS license of the AL-Go application artifact (Get-BcDevEnvArtifactLicense),
    because an empty platform database holds no license. The secret value is never written to the log.
.OUTPUTS
    Full path of the restored license file, or $null.
#>
function Resolve-BcDevEnvLicense {
    param(
        [AllowEmptyString()] [string] $SecretsJson,
        [string] $SecretName = 'licenseFileUrl',
        [Parameter(Mandatory = $true)] [string] $Destination
    )

    if ([string]::IsNullOrWhiteSpace($SecretName)) { $SecretName = 'licenseFileUrl' }
    $value = Get-BcDevEnvSecretValue -SecretsJson $SecretsJson -Name $SecretName
    if ([string]::IsNullOrWhiteSpace($value)) {
        Write-Warning "No license secret '$SecretName' is available. The CRONUS license of the AL-Go application artifact is used instead; if publishing, installing or running tests needs more, provide a license through the '$SecretName' secret (or map another secret with the AL-Go licenseFileUrlSecretName setting)."
        return $null
    }

    [byte[]] $bytes = $null
    $source = ''
    if ($value -match '^https?://') {
        $source = 'URL'
        $download = Join-Path $Destination "license-download-$([guid]::NewGuid().ToString('N')).tmp"
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
        try {
            # The URL is secret: only the exception type is reported.
            Invoke-BcDevEnvWithRetry -Description "Downloading the license referenced by secret '$SecretName'" -MaxAttempts 3 -ScriptBlock {
                try { Invoke-WebRequest -Uri $value -OutFile $download -UseBasicParsing -TimeoutSec 300 | Out-Null }
                catch { throw "download failed ($($_.Exception.GetType().Name))" }
            } | Out-Null
        }
        catch {
            throw "Could not download the license referenced by secret '$SecretName' ($($_.Exception.Message))."
        }
        try { $bytes = [System.IO.File]::ReadAllBytes($download) }
        finally { Remove-Item -LiteralPath $download -Force -ErrorAction SilentlyContinue }
    }
    elseif ($value.StartsWith('H4sI')) {
        $source = 'gzip+base64'
        try {
            $compressed = New-Object System.IO.MemoryStream (, [System.Convert]::FromBase64String($value))
            $gzip = New-Object System.IO.Compression.GZipStream ($compressed, [System.IO.Compression.CompressionMode]::Decompress)
            $output = New-Object System.IO.MemoryStream
            try { $gzip.CopyTo($output); $bytes = $output.ToArray() }
            finally { $gzip.Dispose(); $compressed.Dispose(); $output.Dispose() }
        }
        catch {
            throw "Secret '$SecretName' looks like a gzip+base64 license but could not be decoded."
        }
    }
    else {
        $isFile = $false
        try { $isFile = Test-Path -LiteralPath $value -PathType Leaf } catch { $isFile = $false }
        if (-not $isFile) {
            throw "Secret '$SecretName' is neither an http(s) URL, a gzip+base64 license, nor the path of an existing license file."
        }
        $source = 'file'
        $bytes = [System.IO.File]::ReadAllBytes($value)
    }
    if ($null -eq $bytes -or $bytes.Length -eq 0) {
        throw "The license restored from secret '$SecretName' is empty."
    }

    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $path = Join-Path $Destination ("license" + (Get-BcDevEnvLicenseExtension -Bytes $bytes))
    [System.IO.File]::WriteAllBytes($path, $bytes)
    Write-Host "Restored the license from secret '$SecretName' ($source) to '$path'."
    return $path
}

<#
.SYNOPSIS
    Returns the AL-Go application artifact URL whose CRONUS license is used when no license secret is
    available.
.DESCRIPTION
    Prefers the URL resolved by AL-Go's DetermineArtifactUrl action ($env:artifact). Otherwise the AL-Go
    'artifact' setting is used: a URL as is, or storageAccount/type/version/country/select, where an
    empty country falls back to the 'country' setting and then to 'base', and a partial version is
    resolved to the latest (or, with select 'first', the earliest) matching version from the artifact
    index.
#>
function Get-BcDevEnvApplicationArtifactUrl {
    param(
        [AllowEmptyString()] [AllowNull()] [string] $ResolvedArtifactUrl,
        [AllowNull()] $Settings
    )

    $resolved = "$ResolvedArtifactUrl".Trim()
    if ($resolved -match '^https?://') { return $resolved }
    $artifact = [string](Get-BcDevEnvSetting -Settings $Settings -Name 'artifact' -Default '')
    $artifact = $artifact.Trim()
    if ($artifact -match '^https?://') { return $artifact }

    $parts = @($artifact.Split('/'))
    if ($parts.Count -lt 3 -or -not $parts[0] -or -not $parts[1]) {
        throw "Cannot determine the AL-Go application artifact for the CRONUS license: the 'artifact' setting '$artifact' is not a URL or storageAccount/type/version/country/select. Provide a license through the license secret instead."
    }
    $hosts = @{
        'bcinsider'   = 'https://bcinsider-fvh2ekdjecfjd6gk.b02.azurefd.net'
        'bcartifacts' = 'https://bcartifacts-exdbf9fwegejdqak.b02.azurefd.net'
    }
    $storageAccount = $parts[0].ToLowerInvariant() -replace '\.azureedge\.net$', '' -replace '\.blob\.core\.windows\.net$', ''
    if (-not $hosts.ContainsKey($storageAccount)) {
        throw "Cannot determine the AL-Go application artifact for the CRONUS license: storage account '$($parts[0])' is not supported (bcinsider, bcartifacts). Provide a license through the license secret instead."
    }
    $baseUrl = $hosts[$storageAccount]
    $type = $parts[1].ToLowerInvariant()
    $version = $parts[2].Trim()
    $country = if ($parts.Count -gt 3) { $parts[3].Trim() } else { '' }
    if (-not $country) { $country = [string](Get-BcDevEnvSetting -Settings $Settings -Name 'country' -Default '') }
    if (-not $country) { $country = 'base' }
    $country = $country.ToLowerInvariant()
    $select = if ($parts.Count -gt 4 -and $parts[4]) { $parts[4].ToLowerInvariant() } else { 'latest' }

    if ($version -notmatch '^\d+\.\d+\.\d+\.\d+$') {
        $indexUrl = "$baseUrl/$type/indexes/$country.json"
        $index = Invoke-BcDevEnvWithRetry -Description "Reading the artifact index '$indexUrl'" -MaxAttempts 3 -ScriptBlock {
            Invoke-RestMethod -Uri $indexUrl -UseBasicParsing -TimeoutSec 120
        }
        $candidates = @(@($index) | ForEach-Object { [string]$_.Version } |
                Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' -and (-not $version -or $_ -eq $version -or $_.StartsWith("$version.")) } |
                Sort-Object { [version]$_ })
        if ($candidates.Count -eq 0) { throw "No $type artifact version matching '$version' for country '$country' in '$indexUrl'." }
        $version = if ($select -eq 'first') { $candidates[0] } else { $candidates[-1] }
    }
    return "$baseUrl/$type/$version/$country"
}

<#
.SYNOPSIS
    Picks the license entry of an application artifact: the manifest's licenseFile, else
    Cronus.bclicense, else Cronus.flf (names compared case-insensitively, also by file name).
#>
function Select-BcDevEnvArtifactLicenseEntry {
    param(
        [AllowEmptyCollection()] [string[]] $EntryNames = @(),
        [AllowEmptyString()] [AllowNull()] [string] $ManifestJson
    )

    $wanted = @()
    if (-not [string]::IsNullOrWhiteSpace($ManifestJson)) {
        try {
            $licenseFile = [string](Get-BcDevEnvSetting -Settings ($ManifestJson | ConvertFrom-Json) -Name 'licenseFile' -Default '')
            if ($licenseFile) { $wanted += $licenseFile }
        }
        catch {
            Write-Host "The artifact manifest.json could not be read: $($_.Exception.Message)"
        }
    }
    $wanted += @('Cronus.bclicense', 'Cronus.flf')
    foreach ($name in $wanted) {
        $match = @($EntryNames | Where-Object { $_ -ieq $name -or ($_ -replace '^.*/', '') -ieq ($name -replace '^.*[\\/]', '') }) | Select-Object -First 1
        if ($match) { return $match }
    }
    throw "The application artifact has no license entry (looked for: $(($wanted | Select-Object -Unique) -join ', '))."
}

function Get-BcDevEnvCrc32 {
    param([AllowEmptyCollection()] [byte[]] $Bytes = @())

    if (-not (Get-Variable -Scope Script -Name 'Crc32Table' -ErrorAction SilentlyContinue)) {
        $table = New-Object 'long[]' 256
        for ($n = 0; $n -lt 256; $n++) {
            [long] $c = $n
            for ($k = 0; $k -lt 8; $k++) {
                if ($c -band 1) { $c = 3988292384 -bxor ($c -shr 1) } else { $c = $c -shr 1 }
            }
            $table[$n] = $c
        }
        $script:Crc32Table = $table
    }
    [long] $crc = 4294967295
    foreach ($b in $Bytes) { $crc = $script:Crc32Table[($crc -bxor $b) -band 255] -bxor ($crc -shr 8) }
    return ($crc -bxor 4294967295)
}

<#
.SYNOPSIS
    Fetches a byte range of a remote file with an HTTP range request (From/To inclusive; From $null
    means the last To bytes). Returns the bytes, their offset and the total length of the file.
#>
function Invoke-BcDevEnvHttpRangeRequest {
    param(
        [Parameter(Mandatory = $true)] [string] $Uri,
        [AllowNull()] [Nullable[long]] $From,
        [Parameter(Mandatory = $true)] [long] $To
    )

    if (-not (Get-Variable -Scope Script -Name 'RangeHttpClient' -ErrorAction SilentlyContinue)) {
        $script:RangeHttpClient = [System.Net.Http.HttpClient]::new()
        $script:RangeHttpClient.Timeout = [TimeSpan]::FromMinutes(5)
    }
    $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $Uri)
    $request.Headers.Range = [System.Net.Http.Headers.RangeHeaderValue]::new($From, $To)
    try {
        $response = $script:RangeHttpClient.SendAsync($request, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        try {
            if ([int]$response.StatusCode -ne 206 -or $null -eq $response.Content.Headers.ContentRange) {
                throw [System.NotSupportedException]::new("The server did not answer the range request with a partial response (HTTP $([int]$response.StatusCode)).")
            }
            $range = $response.Content.Headers.ContentRange
            $bytes = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
            $expected = [long]$range.To - [long]$range.From + 1
            if ($bytes.Length -ne $expected) { throw "The range response has $($bytes.Length) bytes; expected $expected." }
            return [pscustomobject]@{ Bytes = $bytes; Offset = [long]$range.From; Length = [long]$range.Length }
        }
        finally { $response.Dispose() }
    }
    finally { $request.Dispose() }
}

<#
.SYNOPSIS
    Reads the central directory of a remote zip archive with HTTP range requests (no ZIP64 support:
    such archives throw NotSupportedException so that the caller can download the whole file).
#>
function Get-BcDevEnvRemoteZipDirectory {
    param([Parameter(Mandatory = $true)] [string] $Uri)

    $tail = Invoke-BcDevEnvHttpRangeRequest -Uri $Uri -From $null -To 65557
    $bytes = $tail.Bytes
    $eocd = -1
    for ($i = $bytes.Length - 22; $i -ge 0; $i--) {
        if ($bytes[$i] -eq 0x50 -and $bytes[$i + 1] -eq 0x4B -and $bytes[$i + 2] -eq 0x05 -and $bytes[$i + 3] -eq 0x06) { $eocd = $i; break }
    }
    if ($eocd -lt 0) { throw [System.NotSupportedException]::new('The end of the zip central directory was not found.') }
    $entryCount = [System.BitConverter]::ToUInt16($bytes, $eocd + 10)
    $directorySize = [long][System.BitConverter]::ToUInt32($bytes, $eocd + 12)
    $directoryOffset = [long][System.BitConverter]::ToUInt32($bytes, $eocd + 16)
    if ($entryCount -eq 0xFFFF -or $directorySize -eq 4294967295 -or $directoryOffset -eq 4294967295) {
        throw [System.NotSupportedException]::new('The zip archive uses ZIP64.')
    }
    if ($directoryOffset + $directorySize -gt $tail.Offset + $eocd) { throw 'The zip central directory lies beyond its end record.' }
    if ($directoryOffset -ge $tail.Offset) {
        $directory = [byte[]]::new($directorySize)
        [System.Array]::Copy($bytes, $directoryOffset - $tail.Offset, $directory, 0, $directorySize)
    }
    else {
        $directory = (Invoke-BcDevEnvHttpRangeRequest -Uri $Uri -From $directoryOffset -To ($directoryOffset + $directorySize - 1)).Bytes
    }

    $entries = @()
    $position = 0
    for ($n = 0; $n -lt $entryCount; $n++) {
        if ($position + 46 -gt $directory.Length -or [System.BitConverter]::ToUInt32($directory, $position) -ne 0x02014B50) {
            throw "Zip central directory entry $n is corrupt."
        }
        $flags = [System.BitConverter]::ToUInt16($directory, $position + 8)
        $nameLength = [System.BitConverter]::ToUInt16($directory, $position + 28)
        $extraLength = [System.BitConverter]::ToUInt16($directory, $position + 30)
        $commentLength = [System.BitConverter]::ToUInt16($directory, $position + 32)
        $encoding = if ($flags -band 0x800) { [System.Text.Encoding]::UTF8 } else { [System.Text.Encoding]::GetEncoding('ISO-8859-1') }
        $entry = [pscustomobject]@{
            Name              = $encoding.GetString($directory, $position + 46, $nameLength)
            Method            = [int][System.BitConverter]::ToUInt16($directory, $position + 10)
            Crc32             = [long][System.BitConverter]::ToUInt32($directory, $position + 16)
            CompressedSize    = [long][System.BitConverter]::ToUInt32($directory, $position + 20)
            Size              = [long][System.BitConverter]::ToUInt32($directory, $position + 24)
            LocalHeaderOffset = [long][System.BitConverter]::ToUInt32($directory, $position + 42)
        }
        if ($entry.CompressedSize -eq 4294967295 -or $entry.Size -eq 4294967295 -or $entry.LocalHeaderOffset -eq 4294967295) {
            throw [System.NotSupportedException]::new("Zip entry '$($entry.Name)' uses ZIP64.")
        }
        $entries += $entry
        $position += 46 + $nameLength + $extraLength + $commentLength
    }
    return [pscustomobject]@{ Uri = $Uri; Length = $tail.Length; Entries = $entries }
}

<#
.SYNOPSIS
    Reads one entry of a remote zip archive (see Get-BcDevEnvRemoteZipDirectory) with HTTP range
    requests, inflates it and checks its size and CRC-32.
#>
function Read-BcDevEnvRemoteZipEntry {
    param(
        [Parameter(Mandatory = $true)] [string] $Uri,
        [Parameter(Mandatory = $true)] $Entry
    )

    $header = (Invoke-BcDevEnvHttpRangeRequest -Uri $Uri -From $Entry.LocalHeaderOffset -To ($Entry.LocalHeaderOffset + 29)).Bytes
    if ([System.BitConverter]::ToUInt32($header, 0) -ne 0x04034B50) { throw "The local header of zip entry '$($Entry.Name)' is corrupt." }
    $dataOffset = $Entry.LocalHeaderOffset + 30 + [System.BitConverter]::ToUInt16($header, 26) + [System.BitConverter]::ToUInt16($header, 28)
    $data = if ($Entry.CompressedSize -gt 0) {
        (Invoke-BcDevEnvHttpRangeRequest -Uri $Uri -From $dataOffset -To ($dataOffset + $Entry.CompressedSize - 1)).Bytes
    }
    else { [byte[]]@() }

    switch ($Entry.Method) {
        0 { $content = $data }
        8 {
            $compressed = New-Object System.IO.MemoryStream (, [byte[]]$data)
            $deflate = New-Object System.IO.Compression.DeflateStream ($compressed, [System.IO.Compression.CompressionMode]::Decompress)
            $output = New-Object System.IO.MemoryStream
            try { $deflate.CopyTo($output); $content = $output.ToArray() }
            finally { $deflate.Dispose(); $compressed.Dispose(); $output.Dispose() }
        }
        default { throw [System.NotSupportedException]::new("Zip entry '$($Entry.Name)' uses compression method $($Entry.Method).") }
    }
    if ($content.Length -ne $Entry.Size) { throw "Zip entry '$($Entry.Name)' inflated to $($content.Length) bytes; expected $($Entry.Size)." }
    $crc = Get-BcDevEnvCrc32 -Bytes $content
    if ($crc -ne $Entry.Crc32) { throw "Zip entry '$($Entry.Name)' failed its CRC-32 check." }
    return , $content
}

<#
.SYNOPSIS
    Extracts the CRONUS license of an AL-Go application artifact to Destination and returns its path.
.DESCRIPTION
    An empty platform database holds no license, so without a license secret the pipeline uses the
    license that AL-Go/BcContainerHelper use by default: the one shipped in the application artifact
    (manifest.json licenseFile, normally Cronus.bclicense). Only the license entry is read, with HTTP
    range requests (a few KB instead of the whole artifact); when that is not possible the whole
    artifact is downloaded (with retries) and the entry extracted from it.
#>
function Get-BcDevEnvArtifactLicense {
    param(
        [Parameter(Mandatory = $true)] [string] $ArtifactUrl,
        [Parameter(Mandatory = $true)] [string] $Destination
    )

    $displayUrl = ([System.Uri]$ArtifactUrl).GetLeftPart([System.UriPartial]::Path)
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $entryName = $null
    [byte[]] $bytes = $null
    try {
        $remote = Invoke-BcDevEnvWithRetry -Description "Reading the license from '$displayUrl' (HTTP range requests)" -MaxAttempts 3 -InitialDelaySeconds 5 -ScriptBlock {
            $directory = Get-BcDevEnvRemoteZipDirectory -Uri $ArtifactUrl
            $names = @($directory.Entries | ForEach-Object { $_.Name })
            $manifestEntry = @($directory.Entries | Where-Object { $_.Name -ieq 'manifest.json' }) | Select-Object -First 1
            $manifestJson = if ($manifestEntry) { [System.Text.Encoding]::UTF8.GetString((Read-BcDevEnvRemoteZipEntry -Uri $ArtifactUrl -Entry $manifestEntry)) } else { '' }
            $name = Select-BcDevEnvArtifactLicenseEntry -EntryNames $names -ManifestJson $manifestJson
            $licenseEntry = @($directory.Entries | Where-Object { $_.Name -ceq $name }) | Select-Object -First 1
            [pscustomobject]@{ Name = $name; Bytes = (Read-BcDevEnvRemoteZipEntry -Uri $ArtifactUrl -Entry $licenseEntry) }
        }
        $entryName = $remote.Name
        $bytes = $remote.Bytes
    }
    catch {
        if ($_.Exception.Message -like '*has no license entry*') { throw }
        Write-Host "Reading the license with HTTP range requests failed ($($_.Exception.Message)); downloading the whole artifact."
        $zipPath = Join-Path $Destination 'application-artifact.zip'
        Save-BcDevEnvDownload -Uri $ArtifactUrl -OutFile $zipPath -ValidateZip -Description "Downloading the application artifact '$displayUrl'" | Out-Null
        try {
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
            try {
                $manifestEntry = @($zip.Entries | Where-Object { $_.FullName -ieq 'manifest.json' }) | Select-Object -First 1
                $manifestJson = ''
                if ($manifestEntry) {
                    $reader = New-Object System.IO.StreamReader ($manifestEntry.Open())
                    try { $manifestJson = $reader.ReadToEnd() } finally { $reader.Dispose() }
                }
                $entryName = Select-BcDevEnvArtifactLicenseEntry -EntryNames @($zip.Entries | ForEach-Object { $_.FullName }) -ManifestJson $manifestJson
                $entry = @($zip.Entries | Where-Object { $_.FullName -ceq $entryName }) | Select-Object -First 1
                $stream = $entry.Open()
                $buffer = New-Object System.IO.MemoryStream
                try { $stream.CopyTo($buffer); $bytes = $buffer.ToArray() } finally { $stream.Dispose(); $buffer.Dispose() }
            }
            finally { $zip.Dispose() }
        }
        finally { Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue }
    }
    if ($null -eq $bytes -or $bytes.Length -eq 0) { throw "The license '$entryName' in the application artifact '$displayUrl' is empty." }

    $path = Join-Path $Destination ($entryName -replace '^.*[\\/]', '')
    [System.IO.File]::WriteAllBytes($path, $bytes)
    Write-Host "Extracted the CRONUS license '$entryName' ($($bytes.Length) bytes) of the application artifact '$displayUrl' to '$path'."
    return $path
}

<#
.SYNOPSIS
    Resolves the URL of t2embed.dll: the action input wins over the AL-Go setting bcdevenvT2EmbedUrl,
    which wins over the install archive of the official Business Central images (nav-docker-install.zip).
    The URL is a zip archive with t2embed.dll (install/t2embed.dll) or t2embed.dll itself.
#>
function Get-BcDevEnvT2EmbedUrl {
    param(
        [AllowNull()] $Settings,
        [AllowEmptyString()] [string] $Url = ''
    )

    if ([string]::IsNullOrWhiteSpace($Url)) { $Url = [string](Get-BcDevEnvSetting -Settings $Settings -Name 'bcdevenvT2EmbedUrl' -Default '') }
    if ([string]::IsNullOrWhiteSpace($Url)) { $Url = $script:DefaultT2EmbedUrl }
    $Url = $Url.Trim()
    $parsed = $null
    if (-not [System.Uri]::TryCreate($Url, [System.UriKind]::Absolute, [ref]$parsed) -or @('http', 'https') -notcontains $parsed.Scheme) {
        throw "Invalid t2embed.dll URL '$Url'. Expected the http(s) URL of a zip archive with t2embed.dll or of t2embed.dll itself."
    }
    return $Url
}

<#
.SYNOPSIS
    Picks the t2embed.dll entry of an archive: install/t2embed.dll (the nav-docker-install.zip layout),
    else the first entry named t2embed.dll (case-insensitive). Returns $null when there is none.
#>
function Select-BcDevEnvT2EmbedEntry {
    param([AllowEmptyCollection()] [string[]] $EntryNames = @())

    $match = @($EntryNames | Where-Object { ($_ -replace '\\', '/') -ieq 'install/t2embed.dll' }) | Select-Object -First 1
    if (-not $match) { $match = @($EntryNames | Where-Object { ($_ -replace '^.*[\\/]', '') -ieq 't2embed.dll' }) | Select-Object -First 1 }
    return $match
}

<#
.SYNOPSIS
    Downloads t2embed.dll to Destination and returns its path.
.DESCRIPTION
    Windows Server Core (the image's base) has no t2embed.dll, and the server's report rendering fails
    without it when a report is saved as PDF ("Unable to load DLL 'T2Embed'"). The official images copy
    it from nav-docker-install.zip into System32; build-image --system32-file does the same.
    From a zip archive only the entry is read, with HTTP range requests (under 200 KB of the 35 MB
    archive); when that is not possible the whole archive is downloaded (with retries) and the entry
    extracted from it. A URL ending in .dll is downloaded as is. The file must be a PE image (MZ).
#>
function Get-BcDevEnvT2Embed {
    param(
        [Parameter(Mandatory = $true)] [string] $Url,
        [Parameter(Mandatory = $true)] [string] $Destination
    )

    $uri = [System.Uri]$Url
    $displayUrl = $uri.GetLeftPart([System.UriPartial]::Path)
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $path = Join-Path $Destination 't2embed.dll'
    $entryName = 't2embed.dll'
    [byte[]] $bytes = $null
    if ($uri.AbsolutePath -match '\.dll$') {
        Save-BcDevEnvDownload -Uri $Url -OutFile $path -Description "Downloading t2embed.dll from '$displayUrl'" | Out-Null
        $bytes = [System.IO.File]::ReadAllBytes($path)
    }
    else {
        $missing = "The archive '$displayUrl' has no t2embed.dll entry."
        $remote = $null
        try {
            $remote = Invoke-BcDevEnvWithRetry -Description "Reading t2embed.dll from '$displayUrl' (HTTP range requests)" -MaxAttempts 3 -InitialDelaySeconds 5 -ScriptBlock {
                $directory = Get-BcDevEnvRemoteZipDirectory -Uri $Url
                $name = Select-BcDevEnvT2EmbedEntry -EntryNames @($directory.Entries | ForEach-Object { $_.Name })
                # A missing entry is not transient: report it without retrying.
                if (-not $name) { return [pscustomobject]@{ Name = $null; Bytes = $null } }
                $entry = @($directory.Entries | Where-Object { $_.Name -ceq $name }) | Select-Object -First 1
                [pscustomobject]@{ Name = $name; Bytes = (Read-BcDevEnvRemoteZipEntry -Uri $Url -Entry $entry) }
            }
        }
        catch {
            Write-Host "Reading t2embed.dll with HTTP range requests failed ($($_.Exception.Message)); downloading the whole archive."
        }
        if ($null -ne $remote) {
            if (-not $remote.Name) { throw $missing }
            $entryName = $remote.Name
            $bytes = $remote.Bytes
        }
        else {
            $zipPath = Join-Path $Destination 't2embed-source.zip'
            Save-BcDevEnvDownload -Uri $Url -OutFile $zipPath -ValidateZip -Description "Downloading '$displayUrl'" | Out-Null
            try {
                Add-Type -AssemblyName System.IO.Compression.FileSystem
                $zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
                try {
                    $entryName = Select-BcDevEnvT2EmbedEntry -EntryNames @($zip.Entries | ForEach-Object { $_.FullName })
                    if (-not $entryName) { throw $missing }
                    $entry = @($zip.Entries | Where-Object { $_.FullName -ceq $entryName }) | Select-Object -First 1
                    $stream = $entry.Open()
                    $buffer = New-Object System.IO.MemoryStream
                    try { $stream.CopyTo($buffer); $bytes = $buffer.ToArray() } finally { $stream.Dispose(); $buffer.Dispose() }
                }
                finally { $zip.Dispose() }
            }
            finally { Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue }
        }
    }
    if ($null -eq $bytes -or $bytes.Length -lt 2 -or $bytes[0] -ne 0x4D -or $bytes[1] -ne 0x5A) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        throw "'$entryName' from '$displayUrl' is not a Windows DLL (no MZ header)."
    }

    [System.IO.File]::WriteAllBytes($path, $bytes)
    Write-Host "Saved t2embed.dll ('$entryName', $($bytes.Length) bytes) from '$displayUrl' to '$path'."
    return $path
}

<#
.SYNOPSIS
    Resolves the BCPlatform version from build/Packages.json and its platform artifact URL.
#>
function Get-BcDevEnvPlatformArtifact {
    Import-Module (Join-Path $PSScriptRoot 'EnlistmentHelperFunctions.psm1') -DisableNameChecking -Global
    Import-Module (Join-Path $PSScriptRoot 'PlatformHelper.psm1') -DisableNameChecking -Global

    $configured = Get-ConfigValue -Key 'BCPlatform' -ConfigType 'Packages'
    $versionSetting = [string](Get-BcDevEnvSetting -Settings $configured -Name 'Version' -Default '')
    if ([string]::IsNullOrWhiteSpace($versionSetting)) { throw "build/Packages.json has no BCPlatform.Version." }
    $version = Resolve-PlatformVersion -Version $versionSetting
    $url = "$(Get-PlatformVersionUrl -Version $version)/platform"
    return [pscustomobject]@{ Version = $version; Url = $url }
}

<#
.SYNOPSIS
    Reads an AL-Go installAppsJson / installTestAppsJson value.
.DESCRIPTION
    AL-Go passes the path of a JSON file holding an array of app paths (DownloadProjectDependencies
    output). A literal JSON array is accepted as well. Empty values and missing files yield no entries,
    like AL-Go's RunPipeline.
#>
function Read-BcDevEnvAppList {
    param([AllowEmptyString()] [AllowNull()] [string] $Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return @() }
    $trimmed = $Value.Trim()
    $json = $null
    if ($trimmed.StartsWith('[')) {
        $json = $trimmed
    }
    else {
        $isFile = $false
        try { $isFile = Test-Path -LiteralPath $trimmed -PathType Leaf } catch { $isFile = $false }
        if (-not $isFile) {
            Write-Host "App list '$trimmed' does not exist; no apps added from it."
            return @()
        }
        $json = Get-Content -LiteralPath $trimmed -Raw
    }
    if ([string]::IsNullOrWhiteSpace($json)) { return @() }
    return @(Get-BcDevEnvStringArray ($json | ConvertFrom-Json))
}

<#
.SYNOPSIS
    Expands app list entries (files, folders, wildcards) into .app files.
.DESCRIPTION
    Entries wrapped in parentheses are AL-Go's "install, but do not run the tests in it" marker; the
    marker is removed and reported in the Wrapped property.
#>
function Resolve-BcDevEnvAppEntries {
    param(
        [AllowEmptyCollection()] [string[]] $Entries = @(),
        [Parameter(Mandatory = $true)] [ValidateSet('App', 'TestApp')] [string] $Kind,
        [string] $Source = 'dependency'
    )

    $result = @()
    foreach ($entry in (Get-BcDevEnvStringArray $Entries)) {
        $path = $entry.Trim()
        $wrapped = $false
        if ($path.StartsWith('(') -and $path.EndsWith(')')) {
            $wrapped = $true
            $path = $path.Substring(1, $path.Length - 2).Trim()
        }
        if ($path -match '^[a-z][a-z0-9+.-]*://') {
            throw "App entry '$path' is a URL; the bcdevenv pipeline only installs local .app files (dependencies are downloaded by AL-Go's DownloadProjectDependencies)."
        }
        $files = @()
        if (Test-Path -LiteralPath $path -PathType Container) {
            $files = @(Get-ChildItem -LiteralPath $path -Recurse -File -Filter '*.app' | Sort-Object FullName)
        }
        elseif (Test-Path -LiteralPath $path -PathType Leaf) {
            $files = @(Get-Item -LiteralPath $path)
        }
        elseif ($path -match '[\*\?]') {
            $files = @(Get-ChildItem -Path $path -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -ieq '.app' } | Sort-Object FullName)
        }
        if ($files.Count -eq 0) {
            throw "App entry '$path' ($Kind) does not resolve to any .app file."
        }
        foreach ($file in $files) {
            $result += [pscustomobject]@{ Path = $file.FullName; Kind = $Kind; Wrapped = $wrapped; Source = $Source }
        }
    }
    return $result
}

<#
.SYNOPSIS
    Reads the NavxManifest.xml of a .app package (NAVX header + zip).
#>
function Read-BcDevEnvAppManifest {
    param([Parameter(Mandatory = $true)] [string] $Path)

    Add-Type -AssemblyName System.IO.Compression
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $offset = -1
    $limit = [Math]::Min($bytes.Length - 4, 4096)
    for ($i = 0; $i -le $limit; $i++) {
        if ($bytes[$i] -eq 0x50 -and $bytes[$i + 1] -eq 0x4B -and $bytes[$i + 2] -eq 0x03 -and $bytes[$i + 3] -eq 0x04) { $offset = $i; break }
    }
    if ($offset -lt 0) {
        throw "'$Path' is not a readable .app package (no zip payload found; runtime/encrypted packages are not supported)."
    }
    $zipBytes = New-Object byte[] ($bytes.Length - $offset)
    [System.Array]::Copy($bytes, $offset, $zipBytes, 0, $zipBytes.Length)

    $stream = New-Object System.IO.MemoryStream (, $zipBytes)
    try {
        $archive = New-Object System.IO.Compression.ZipArchive ($stream, [System.IO.Compression.ZipArchiveMode]::Read)
        try {
            $entry = $archive.Entries | Where-Object { $_.FullName -ieq 'NavxManifest.xml' } | Select-Object -First 1
            if ($null -eq $entry) { throw "'$Path' has no NavxManifest.xml." }
            $reader = New-Object System.IO.StreamReader ($entry.Open())
            try { $manifestText = $reader.ReadToEnd() } finally { $reader.Dispose() }
        }
        finally { $archive.Dispose() }
    }
    finally { $stream.Dispose() }

    $xml = New-Object System.Xml.XmlDocument
    $xml.LoadXml($manifestText)
    $app = $xml.SelectSingleNode("//*[local-name()='App']")
    if ($null -eq $app) { throw "'$Path' has no App element in its NavxManifest.xml." }

    $id = $app.GetAttribute('Id')
    $application = $app.GetAttribute('Application')
    $dependencies = @()
    foreach ($node in $xml.SelectNodes("//*[local-name()='Dependencies']/*[local-name()='Dependency']")) {
        $depId = $node.GetAttribute('Id')
        if (-not $depId) { $depId = $node.GetAttribute('AppId') }
        if (-not $depId) { continue }
        $minVersion = $node.GetAttribute('MinVersion')
        if (-not $minVersion) { $minVersion = $node.GetAttribute('Version') }
        if (-not $minVersion) { $minVersion = '0.0.0.0' }
        $dependencies += [pscustomobject]@{
            Id         = $depId.ToLowerInvariant()
            Name       = $node.GetAttribute('Name')
            Publisher  = $node.GetAttribute('Publisher')
            MinVersion = [version]$minVersion
        }
    }
    if ($application -and $id -ine $script:ApplicationAppId -and -not ($dependencies | Where-Object { $_.Id -eq $script:ApplicationAppId })) {
        $dependencies += [pscustomobject]@{ Id = $script:ApplicationAppId; Name = 'Application'; Publisher = 'Microsoft'; MinVersion = [version]$application }
    }

    return [pscustomobject]@{
        Path         = (Resolve-Path -LiteralPath $Path).Path
        Id           = $id.ToLowerInvariant()
        Name         = $app.GetAttribute('Name')
        Publisher    = $app.GetAttribute('Publisher')
        Version      = [version]$app.GetAttribute('Version')
        Application  = $application
        Dependencies = $dependencies
    }
}

<#
.SYNOPSIS
    Returns the app names that must not be published for a project.
.DESCRIPTION
    The native build/scripts/PublishBcContainerApp.ps1 always skips 'Library - No Transactions' and
    'Prevent Metadata Updates Library'; project overrides (.AL-Go/PublishBcContainerApp.ps1) add more
    through -AdditionalAppsNotToPublish. The override is parsed, never executed.
#>
function Get-BcDevEnvAppsNotToPublish {
    param([Parameter(Mandatory = $true)] [string] $ProjectPath)

    $names = @($script:DefaultAppsNotToPublish)
    $override = Join-Path $ProjectPath '.AL-Go/PublishBcContainerApp.ps1'
    if (Test-Path -LiteralPath $override -PathType Leaf) {
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($override, [ref]$tokens, [ref]$errors)
        $commands = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true)
        foreach ($command in $commands) {
            $elements = $command.CommandElements
            for ($i = 0; $i -lt $elements.Count; $i++) {
                $element = $elements[$i]
                if ($element -isnot [System.Management.Automation.Language.CommandParameterAst]) { continue }
                if ($element.ParameterName -ine 'AdditionalAppsNotToPublish') { continue }
                $argument = $element.Argument
                if ($null -eq $argument -and ($i + 1) -lt $elements.Count) { $argument = $elements[$i + 1] }
                if ($null -eq $argument) { continue }
                $strings = $argument.FindAll({ param($node) $node -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true)
                foreach ($string in $strings) { $names += $string.Value }
            }
        }
    }
    return @($names | Where-Object { $_ } | Select-Object -Unique)
}

function Test-BcDevEnvAppExcluded {
    param(
        [Parameter(Mandatory = $true)] $App,
        [AllowEmptyCollection()] [string[]] $ExcludedNames = @()
    )
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($App.Path)
    foreach ($name in $ExcludedNames) {
        if ($App.Name -eq $name) { return $true }
        if ($baseName -like "Microsoft_$($name)_*") { return $true }
    }
    return $false
}

<#
.SYNOPSIS
    De-duplicates apps by id (highest version wins) and sorts them in dependency order.
.DESCRIPTION
    The container database is empty (platform only), so every dependency must be part of the
    install set; missing or too-old dependencies and cycles fail with a list of the problems.
    The input order is kept wherever the dependencies allow it.
#>
function Get-BcDevEnvOrderedApps {
    param([AllowEmptyCollection()] [object[]] $Apps = @())

    $byId = [ordered]@{}
    foreach ($app in $Apps) {
        $key = $app.Id.ToLowerInvariant()
        if ($byId.Contains($key)) {
            $existing = $byId[$key]
            if ($app.Version -gt $existing.Version) {
                Write-Host "App '$($app.Name)' is supplied twice; using $($app.Version) ($($app.Path)) instead of $($existing.Version)."
                $byId[$key] = $app
            }
            continue
        }
        $byId[$key] = $app
    }

    $problems = @()
    foreach ($app in $byId.Values) {
        foreach ($dependency in $app.Dependencies) {
            if (-not $byId.Contains($dependency.Id)) {
                $problems += "'$($app.Name)' requires '$($dependency.Name)' by $($dependency.Publisher) ($($dependency.Id)) >= $($dependency.MinVersion), which is not in the install set."
            }
            elseif ($byId[$dependency.Id].Version -lt $dependency.MinVersion) {
                $problems += "'$($app.Name)' requires '$($dependency.Name)' >= $($dependency.MinVersion), but the install set has $($byId[$dependency.Id].Version)."
            }
        }
    }
    if ($problems.Count -gt 0) {
        throw ("The empty-database container only has what the pipeline installs, and these dependencies cannot be satisfied:`n - " + ($problems -join "`n - "))
    }

    $state = @{}
    $ordered = New-Object System.Collections.Generic.List[object]
    $path = New-Object System.Collections.Generic.List[string]
    $visit = {
        param($key)
        $current = $state[$key]
        if ($current -eq 2) { return }
        if ($current -eq 1) {
            $start = $path.IndexOf($key)
            $cycle = @($path.GetRange($start, $path.Count - $start) | ForEach-Object { $byId[$_].Name }) + $byId[$key].Name
            throw "App dependency cycle: $($cycle -join ' -> ')"
        }
        $state[$key] = 1
        $path.Add($key)
        foreach ($dependency in $byId[$key].Dependencies) { & $visit $dependency.Id }
        $path.RemoveAt($path.Count - 1)
        $state[$key] = 2
        $ordered.Add($byId[$key])
    }
    foreach ($key in @($byId.Keys)) { & $visit $key }
    return $ordered.ToArray()
}

<#
.SYNOPSIS
    Returns the given apps plus everything they depend on, in install order.
#>
function Get-BcDevEnvDependencyClosure {
    param(
        [AllowEmptyCollection()] [object[]] $OrderedApps = @(),
        [Parameter(Mandatory = $true)] [string[]] $RootIds
    )

    $byId = @{}
    foreach ($app in $OrderedApps) { $byId[$app.Id] = $app }
    $needed = @{}
    $queue = New-Object System.Collections.Generic.Queue[string]
    foreach ($rootId in $RootIds) {
        $key = $rootId.ToLowerInvariant()
        if (-not $byId.ContainsKey($key)) { throw "App $rootId is required but is not in the install set." }
        $queue.Enqueue($key)
    }
    while ($queue.Count -gt 0) {
        $key = $queue.Dequeue()
        if ($needed.ContainsKey($key)) { continue }
        $needed[$key] = $true
        foreach ($dependency in $byId[$key].Dependencies) {
            if (-not $byId.ContainsKey($dependency.Id)) { throw "App $($dependency.Name) ($($dependency.Id)) is required but is not in the install set." }
            $queue.Enqueue($dependency.Id)
        }
    }
    return @($OrderedApps | Where-Object { $needed.ContainsKey($_.Id) })
}

<#
.SYNOPSIS
    Builds the ordered install set for a project: its compiled apps and test apps plus the
    dependency apps and test apps downloaded by AL-Go, minus the apps that must not be published.
#>
function Get-BcDevEnvInstallSet {
    param(
        [Parameter(Mandatory = $true)] [string] $ProjectPath,
        [AllowEmptyString()] [string] $InstallAppsJson = '',
        [AllowEmptyString()] [string] $InstallTestAppsJson = ''
    )

    $entries = @()
    $appsFolder = Join-Path $ProjectPath '.buildartifacts/Apps'
    $testAppsFolder = Join-Path $ProjectPath '.buildartifacts/TestApps'
    $entries += @(Resolve-BcDevEnvAppEntries -Entries @(Read-BcDevEnvAppList $InstallAppsJson) -Kind App -Source 'dependency')
    if (Test-Path -LiteralPath $appsFolder -PathType Container) {
        $entries += @(Get-ChildItem -LiteralPath $appsFolder -File -Filter '*.app' | Sort-Object Name | ForEach-Object { [pscustomobject]@{ Path = $_.FullName; Kind = 'App'; Wrapped = $false; Source = 'project' } })
    }
    $entries += @(Resolve-BcDevEnvAppEntries -Entries @(Read-BcDevEnvAppList $InstallTestAppsJson) -Kind TestApp -Source 'dependency')
    if (Test-Path -LiteralPath $testAppsFolder -PathType Container) {
        $entries += @(Get-ChildItem -LiteralPath $testAppsFolder -File -Filter '*.app' | Sort-Object Name | ForEach-Object { [pscustomobject]@{ Path = $_.FullName; Kind = 'TestApp'; Wrapped = $false; Source = 'project' } })
    }

    $excludedNames = @(Get-BcDevEnvAppsNotToPublish -ProjectPath $ProjectPath)
    $apps = @()
    $excluded = @()
    foreach ($entry in $entries) {
        $manifest = Read-BcDevEnvAppManifest -Path $entry.Path
        $manifest | Add-Member -NotePropertyName Kind -NotePropertyValue $entry.Kind
        $manifest | Add-Member -NotePropertyName Wrapped -NotePropertyValue $entry.Wrapped
        $manifest | Add-Member -NotePropertyName Source -NotePropertyValue $entry.Source
        if (Test-BcDevEnvAppExcluded -App $manifest -ExcludedNames $excludedNames) {
            $excluded += $manifest
            continue
        }
        $apps += $manifest
    }

    return [pscustomobject]@{
        Apps     = @(Get-BcDevEnvOrderedApps -Apps $apps)
        Excluded = $excluded
    }
}

<#
.SYNOPSIS
    Uses the native BCApps test dispatch (build/projects.json + TestConfiguration.json buckets) to
    get the test app names for a country/test type, limited to the installed app names.
#>
function Get-BcDevEnvNativeTestAppNames {
    param(
        [string] $Country = 'w1',
        [string] $TestType = '',
        [int] $BucketNumber = 0,
        [AllowEmptyCollection()] [string[]] $InstalledAppNames = @()
    )

    if ([string]::IsNullOrWhiteSpace($Country) -or $Country -ieq 'base') { $Country = 'w1' }
    Import-Module (Join-Path $PSScriptRoot 'ParallelTestExecution.psm1') -DisableNameChecking -Global
    Import-Module (Join-Path $PSScriptRoot 'ALAppBuild.psm1') -DisableNameChecking -Global

    $expected = @(
        Get-ApplicationGroup -GroupName 'All' -CountryCode $Country -SkipLanguagePacks |
            Where-Object { $_.IsTest } |
            ForEach-Object { Get-AppNameFromMetadata -BuildMetadata $_ }
    )
    $installed = @($expected | Where-Object { $_ -in $InstalledAppNames } | Select-Object -Unique)
    if ($installed.Count -eq 0) { return @() }
    return @(Get-AppNamesForBucket -InstalledTestAppNames $installed -TestType $TestType -BucketNumber $BucketNumber)
}

<#
.SYNOPSIS
    Selects the installed test apps to run tests in.
.DESCRIPTION
    Projects whose .AL-Go/RunTestsInBcContainer.ps1 dispatches through Invoke-PerProjectTestRun (the
    BCApps "Test Apps <country>" projects) use the native dispatch: build/projects.json test apps of
    the country that are installed, minus the Legacy buckets of TestConfiguration.json.
    Other projects run the tests in the project's own test apps and in the dependency test apps that
    are not wrapped in parentheses (all of them with runTestsInAllInstalledTestApps).
#>
function Get-BcDevEnvTestAppSelection {
    param(
        [AllowEmptyCollection()] [object[]] $InstalledApps = @(),
        [Parameter(Mandatory = $true)] [string] $ProjectPath,
        [Parameter(Mandatory = $true)] $Plan
    )

    $override = Join-Path $ProjectPath '.AL-Go/RunTestsInBcContainer.ps1'
    $useNativeDispatch = (Test-Path -LiteralPath $override -PathType Leaf) -and ((Get-Content -LiteralPath $override -Raw) -match 'Invoke-PerProjectTestRun')
    if ($useNativeDispatch) {
        $installedNames = @($InstalledApps | ForEach-Object { $_.Name })
        $names = @(Get-BcDevEnvNativeTestAppNames -Country $Plan.Country -TestType $Plan.TestType -BucketNumber $Plan.BucketNumber -InstalledAppNames $installedNames)
        $selected = @()
        foreach ($name in $names) {
            $selected += @($InstalledApps | Where-Object { $_.Name -eq $name } | Select-Object -First 1)
        }
        return @($selected | Where-Object { $null -ne $_ })
    }

    return @($InstalledApps | Where-Object { $_.Kind -eq 'TestApp' -and ((-not $_.Wrapped) -or $Plan.RunTestsInAllInstalledTestApps) })
}

<#
.SYNOPSIS
    Finds the DisabledTests folders of the repository (same discovery as Get-DisabledTestsForApp in
    ParallelTestExecution.psm1), skipping .git and the bcdevenv tool folder.
#>
function Get-BcDevEnvDisabledTestsRoots {
    param([Parameter(Mandatory = $true)] [string] $BaseFolder)

    $base = (Resolve-Path -LiteralPath $BaseFolder).Path.TrimEnd('\', '/')
    $skip = @('.git', 'bcdevenv', '.bcdevenv-ref') | ForEach-Object { [System.IO.Path]::Combine($base, $_) }
    $roots = New-Object System.Collections.Generic.List[string]
    $stack = New-Object System.Collections.Generic.Stack[System.IO.DirectoryInfo]
    $stack.Push([System.IO.DirectoryInfo]::new($base))
    while ($stack.Count -gt 0) {
        $directory = $stack.Pop()
        foreach ($child in $directory.EnumerateDirectories()) {
            if (($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            if ($skip -contains $child.FullName) { continue }
            if ($child.Name -ieq 'DisabledTests') { $roots.Add($child.FullName); continue }
            $stack.Push($child)
        }
    }
    return @($roots | Sort-Object)
}

function ConvertTo-BcDevEnvPowerShellLiteral {
    param([AllowEmptyString()] [string] $Value)
    return "'" + ($Value -replace "['\u2018\u2019\u201A\u201B]", '$0$0') + "'"
}

<#
.SYNOPSIS
    Encodes a script for powershell.exe -EncodedCommand (avoids quoting a multi-line script through
    docker exec).
#>
function ConvertTo-BcDevEnvEncodedScript {
    param([Parameter(Mandatory = $true)] [string] $Script)
    return [System.Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($Script))
}

<#
.SYNOPSIS
    Returns the Windows PowerShell script that waits until the container's OData endpoint serves
    (and, when -RequiredText is given, until $metadata contains it).
#>
function Get-BcDevEnvReadinessScript {
    param(
        [Parameter(Mandatory = $true)] [string] $ODataUrl,
        [AllowEmptyString()] [string] $RequiredText = '',
        [int] $Attempts = 60,
        [int] $DelaySeconds = 10
    )

    $url = ConvertTo-BcDevEnvPowerShellLiteral ($ODataUrl.TrimEnd('/') + '/$metadata')
    $required = ConvertTo-BcDevEnvPowerShellLiteral $RequiredText
    return @"
`$ErrorActionPreference = 'Stop'
`$lastError = 'no response'
for (`$i = 1; `$i -le $Attempts; `$i++) {
  try {
    `$r = Invoke-WebRequest -UseDefaultCredentials -UseBasicParsing -Uri $url -TimeoutSec 30
    if (`$r.StatusCode -eq 200) {
      if (-not $required -or `$r.Content.Contains($required)) { Write-Host "OData is serving (attempt `$i)."; exit 0 }
      `$lastError = 'metadata does not contain ' + $required
    }
  } catch { `$lastError = `$_.Exception.Message }
  Start-Sleep -Seconds $DelaySeconds
}
Write-Host "OData did not become ready: `$lastError"
exit 1
"@
}

<#
.SYNOPSIS
    Resolves the test executor: action inputs win over the AL-Go settings bcdevenvTestExecutor,
    bcdevenvAlToolVersion, bcdevenvAppTestTimeoutMinutes and bcdevenvTestPermissionsMock, which win over
    the defaults (altool, the pinned AL tool version, 240 minutes per test app and pass, permissions
    mock on).
.DESCRIPTION
    PermissionsMock (altool executor only): the state reset that runs before every test codeunit starts
    the permissions mock without assignments (true / on) or stops it (false / off).
#>
function Get-BcDevEnvTestExecutorSettings {
    param(
        [AllowNull()] $Settings,
        [AllowEmptyString()] [string] $Executor = '',
        [AllowEmptyString()] [string] $AlToolVersion = '',
        [AllowEmptyString()] [string] $AppTimeoutMinutes = '',
        [AllowEmptyString()] [string] $PermissionsMock = ''
    )

    if ([string]::IsNullOrWhiteSpace($Executor)) { $Executor = [string](Get-BcDevEnvSetting -Settings $Settings -Name 'bcdevenvTestExecutor' -Default '') }
    if ([string]::IsNullOrWhiteSpace($Executor)) { $Executor = $script:DefaultTestExecutor }
    $Executor = $Executor.Trim().ToLowerInvariant()
    if ($script:SupportedTestExecutors -notcontains $Executor) {
        throw "Unknown test executor '$Executor'. Supported: $($script:SupportedTestExecutors -join ', ')."
    }

    if ([string]::IsNullOrWhiteSpace($AlToolVersion)) { $AlToolVersion = [string](Get-BcDevEnvSetting -Settings $Settings -Name 'bcdevenvAlToolVersion' -Default '') }
    if ([string]::IsNullOrWhiteSpace($AlToolVersion)) { $AlToolVersion = $script:DefaultAlToolVersion }
    $AlToolVersion = $AlToolVersion.Trim()
    if ($AlToolVersion -notmatch '^\d+(\.\d+){2,3}(-[0-9A-Za-z][0-9A-Za-z.-]*)?$') {
        throw "Invalid AL tool version '$AlToolVersion'. Expected a NuGet version of Microsoft.Dynamics.BusinessCentral.Development.Tools, e.g. $($script:DefaultAlToolVersion)."
    }

    if ([string]::IsNullOrWhiteSpace($AppTimeoutMinutes)) { $AppTimeoutMinutes = [string](Get-BcDevEnvSetting -Settings $Settings -Name 'bcdevenvAppTestTimeoutMinutes' -Default '') }
    $timeout = $script:DefaultAppTestTimeoutMinutes
    if (-not [string]::IsNullOrWhiteSpace($AppTimeoutMinutes)) {
        $parsed = 0
        if (-not [int]::TryParse($AppTimeoutMinutes.Trim(), [ref]$parsed) -or $parsed -le 0) {
            throw "Invalid test timeout '$AppTimeoutMinutes' (minutes per test app and pass). Expected a positive integer."
        }
        $timeout = $parsed
    }

    if ([string]::IsNullOrWhiteSpace($PermissionsMock)) {
        $setting = Get-BcDevEnvSetting -Settings $Settings -Name 'bcdevenvTestPermissionsMock' -Default $null
        if ($null -ne $setting) { $PermissionsMock = [string]$setting }
    }
    $mock = $true
    if (-not [string]::IsNullOrWhiteSpace($PermissionsMock)) {
        $normalized = $PermissionsMock.Trim().ToLowerInvariant()
        if (@('true', 'on') -contains $normalized) { $mock = $true }
        elseif (@('false', 'off') -contains $normalized) { $mock = $false }
        else { throw "Invalid permissions mock setting '$PermissionsMock' (bcdevenvTestPermissionsMock). Use true / on or false / off." }
    }

    return [pscustomobject]@{
        Executor          = $Executor
        AlToolVersion     = $AlToolVersion
        AppTimeoutMinutes = $timeout
        PermissionsMock   = $mock
    }
}

<#
.SYNOPSIS
    Returns the nuget.org download URL of the AL tool package (Microsoft.Dynamics.BusinessCentral.Development.Tools).
#>
function Get-BcDevEnvAlToolPackageUrl {
    param([Parameter(Mandatory = $true)] [string] $Version)

    $id = $script:AlToolPackageId
    $lower = $Version.Trim().ToLowerInvariant()
    return "https://api.nuget.org/v3-flatcontainer/$id/$lower/$id.$lower.nupkg"
}

<#
.SYNOPSIS
    Returns the folder of altool.dll in an extracted AL tool package (tools\<framework>\any), preferring
    net10.0, then the highest framework.
#>
function Find-BcDevEnvAlToolFolder {
    param([Parameter(Mandatory = $true)] [string] $PackageDir)

    $preferred = Join-Path $PackageDir 'tools\net10.0\any'
    if (Test-Path -LiteralPath (Join-Path $preferred 'altool.dll') -PathType Leaf) { return (Resolve-Path -LiteralPath $preferred).Path }
    $toolsDir = Join-Path $PackageDir 'tools'
    $candidates = @()
    if (Test-Path -LiteralPath $toolsDir -PathType Container) {
        foreach ($framework in @(Get-ChildItem -LiteralPath $toolsDir -Directory)) {
            $folder = Join-Path $framework.FullName 'any'
            if (-not (Test-Path -LiteralPath (Join-Path $folder 'altool.dll') -PathType Leaf)) { continue }
            $version = [version]'0.0'
            if ($framework.Name -match '^net(\d+)\.(\d+)$') { $version = [version]"$($matches[1]).$($matches[2])" }
            $candidates += [pscustomobject]@{ Folder = $folder; Version = $version }
        }
    }
    if ($candidates.Count -eq 0) { throw "altool.dll (tools\<framework>\any) was not found in the AL tool package '$PackageDir'." }
    return @($candidates | Sort-Object -Property Version -Descending)[0].Folder
}

<#
.SYNOPSIS
    Returns the Windows PowerShell script that checks, inside the container, that the AL tool and dotnet
    are in place and waits until the development endpoint accepts connections.
#>
function Get-BcDevEnvAlToolReadinessScript {
    param(
        [Parameter(Mandatory = $true)] [string] $AlToolPath,
        [Parameter(Mandatory = $true)] [string] $DotnetPath,
        [int] $Port = 7049,
        [int] $Attempts = 30,
        [int] $DelaySeconds = 5
    )

    $alTool = ConvertTo-BcDevEnvPowerShellLiteral $AlToolPath
    $dotnet = ConvertTo-BcDevEnvPowerShellLiteral $DotnetPath
    return @"
`$ErrorActionPreference = 'Stop'
foreach (`$file in @($alTool, $dotnet)) {
  if (-not (Test-Path -LiteralPath `$file -PathType Leaf)) { Write-Host "Not found in the container: `$file"; exit 1 }
}
`$lastError = 'no connection'
for (`$i = 1; `$i -le $Attempts; `$i++) {
  `$client = New-Object System.Net.Sockets.TcpClient
  try {
    `$client.Connect('localhost', $Port)
    Write-Host "The development endpoint (port $Port) accepts connections (attempt `$i)."
    exit 0
  } catch { `$lastError = `$_.Exception.Message } finally { `$client.Close() }
  Start-Sleep -Seconds $DelaySeconds
}
Write-Host "The development endpoint (port $Port) did not accept connections: `$lastError"
exit 1
"@
}

<#
.SYNOPSIS
    Builds the bcdevenv run-tests arguments for one app and one test pass.
.DESCRIPTION
    With -Executor altool the BcDevEnvTestRunner still selects the tests (test type, isolation pass,
    DisabledTests) and the AL tool (-AlToolPath, run with -DotnetPath) executes them through the
    development endpoint on -DevPort, within -AppTimeoutMinutes for the app and pass. -PermissionsMock
    selects the state reset before every test codeunit (permissions mock started or stopped).
#>
function Get-BcDevEnvRunTestsArguments {
    param(
        [Parameter(Mandatory = $true)] [string] $ODataUrl,
        [Parameter(Mandatory = $true)] [string] $CompanyName,
        [Parameter(Mandatory = $true)] $App,
        [Parameter(Mandatory = $true)] $Pass,
        [AllowEmptyCollection()] [string[]] $DisabledTestsRoots = @(),
        [Parameter(Mandatory = $true)] [string] $ResultFile,
        [string] $SuiteName = 'BusinessCentral',
        [int] $TimeoutMinutes = 60,
        [ValidateSet('odata', 'altool')] [string] $Executor = 'odata',
        [string] $AlToolPath = '',
        [string] $DotnetPath = '',
        [int] $DevPort = 7049,
        [string] $ServerInstance = 'BC',
        [int] $AppTimeoutMinutes = 240,
        [bool] $PermissionsMock = $true
    )

    $arguments = @(
        'run-tests',
        '--odata-url', $ODataUrl,
        '--service-name', 'BcDevEnvTestRunner',
        '--company', $CompanyName,
        '--protocol', 'per-codeunit',
        '--extension', $App.Id,
        '--app-name', $App.Name
    )
    foreach ($root in (Get-BcDevEnvStringArray $DisabledTestsRoots)) { $arguments += @('--disabled-tests', $root) }
    if ($Pass.TestType) { $arguments += @('--test-type', $Pass.TestType) }
    if ($Pass.Isolation) { $arguments += @('--required-test-isolation', $Pass.Isolation) }
    $arguments += @(
        '--test-runner-codeunit-id', [string]$Pass.RunnerId,
        '--result-file', $ResultFile,
        '--suite-name', $SuiteName,
        '--timeout-minutes', [string]$TimeoutMinutes,
        '--allow-failures',
        '--allow-empty'
    )
    if ($Executor -eq 'altool') {
        if ([string]::IsNullOrWhiteSpace($AlToolPath)) { throw 'The altool test executor needs -AlToolPath.' }
        $arguments += @('--executor', 'altool', '--altool', $AlToolPath)
        if (-not [string]::IsNullOrWhiteSpace($DotnetPath)) { $arguments += @('--dotnet', $DotnetPath) }
        $arguments += @(
            '--dev-port', [string]$DevPort,
            '--server-instance', $ServerInstance,
            '--app-timeout-minutes', [string]$AppTimeoutMinutes,
            '--permissions-mock', $(if ($PermissionsMock) { 'on' } else { 'off' })
        )
    }
    return $arguments
}

<#
.SYNOPSIS
    When Permissions Mock is in the install set (-Apps, Get-BcDevEnvAppInfo objects), makes a copy of the
    BcDevEnv Test Runner's app.json compile against it: adds the dependency and the preprocessor symbol
    BCDEVENV_PERMISSIONSMOCK, which enables the permissions mock part of the runner's state reset.
    Returns the Permissions Mock app, or $null (app.json unchanged) when it is not installed. Idempotent.
#>
function Set-BcDevEnvRunnerPermissionsMock {
    param(
        [Parameter(Mandatory = $true)] [string] $AppJsonPath,
        [AllowEmptyCollection()] [object[]] $Apps = @()
    )

    $mockApp = @($Apps | Where-Object { $null -ne $_ -and [string]$_.Id -eq $script:PermissionsMockAppId }) | Select-Object -First 1
    if ($null -eq $mockApp) { return $null }

    $json = Get-Content -LiteralPath $AppJsonPath -Raw | ConvertFrom-Json
    $dependencies = @()
    if ($json.PSObject.Properties['dependencies'] -and $null -ne $json.dependencies) {
        $dependencies = @($json.dependencies | Where-Object { [string]$_.id -ne $script:PermissionsMockAppId })
    }
    $dependencies += [pscustomobject]@{
        id        = $script:PermissionsMockAppId
        name      = [string]$mockApp.Name
        publisher = [string]$mockApp.Publisher
        version   = [string]$mockApp.Version
    }
    $json | Add-Member -NotePropertyName 'dependencies' -NotePropertyValue $dependencies -Force

    $symbols = @()
    if ($json.PSObject.Properties['preprocessorSymbols'] -and $null -ne $json.preprocessorSymbols) { $symbols = @($json.preprocessorSymbols) }
    if ($symbols -notcontains $script:PermissionsMockSymbol) { $symbols += $script:PermissionsMockSymbol }
    $json | Add-Member -NotePropertyName 'preprocessorSymbols' -NotePropertyValue $symbols -Force

    Set-Content -LiteralPath $AppJsonPath -Value ($json | ConvertTo-Json -Depth 10) -Encoding UTF8
    return $mockApp
}

function Get-BcDevEnvJUnitCounts {
    param([Parameter(Mandatory = $true)] [System.Xml.XmlNode] $Node, [string] $SuitePath)

    $time = 0.0
    foreach ($suite in $Node.SelectNodes($SuitePath)) {
        $value = 0.0
        if ([double]::TryParse($suite.GetAttribute('time'), [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$value)) { $time += $value }
    }
    return [pscustomobject]@{
        Tests    = $Node.SelectNodes("$SuitePath/testcase").Count
        Failures = $Node.SelectNodes("$SuitePath/testcase[failure]").Count
        Errors   = $Node.SelectNodes("$SuitePath/testcase[error]").Count
        Skipped  = $Node.SelectNodes("$SuitePath/testcase[skipped]").Count
        Time     = $time
        Suites   = $Node.SelectNodes($SuitePath).Count
    }
}

<#
.SYNOPSIS
    Counts the test cases of a JUnit report written by bcdevenv run-tests.
#>
function Get-BcDevEnvJUnitSummary {
    param([Parameter(Mandatory = $true)] [string] $Path)

    $xml = New-Object System.Xml.XmlDocument
    $xml.Load($Path)
    $suitePath = if ($xml.DocumentElement.LocalName -eq 'testsuite') { '/testsuite' } else { '/testsuites/testsuite' }
    return Get-BcDevEnvJUnitCounts -Node $xml -SuitePath $suitePath
}

<#
.SYNOPSIS
    Merges JUnit reports into one <testsuites> document (the format AL-Go's AnalyzeTests reads) and
    writes it to every output path.
#>
function Merge-BcDevEnvJUnitResults {
    param(
        [AllowEmptyCollection()] [string[]] $InputFiles = @(),
        [Parameter(Mandatory = $true)] [string[]] $OutputFiles,
        [string] $SuiteName = 'BusinessCentral'
    )

    $document = New-Object System.Xml.XmlDocument
    $document.AppendChild($document.CreateXmlDeclaration('1.0', 'UTF-8', $null)) | Out-Null
    $root = $document.CreateElement('testsuites')
    $document.AppendChild($root) | Out-Null
    foreach ($file in (Get-BcDevEnvStringArray $InputFiles)) {
        $xml = New-Object System.Xml.XmlDocument
        $xml.Load($file)
        $suitePath = if ($xml.DocumentElement.LocalName -eq 'testsuite') { '/testsuite' } else { '/testsuites/testsuite' }
        foreach ($suite in $xml.SelectNodes($suitePath)) {
            $root.AppendChild($document.ImportNode($suite, $true)) | Out-Null
        }
    }

    $counts = Get-BcDevEnvJUnitCounts -Node $document -SuitePath '/testsuites/testsuite'
    $root.SetAttribute('name', $SuiteName)
    $root.SetAttribute('tests', [string]$counts.Tests)
    $root.SetAttribute('failures', [string]$counts.Failures)
    $root.SetAttribute('errors', [string]$counts.Errors)
    $root.SetAttribute('skipped', [string]$counts.Skipped)
    $root.SetAttribute('time', $counts.Time.ToString('0.###', [System.Globalization.CultureInfo]::InvariantCulture))

    $writerSettings = New-Object System.Xml.XmlWriterSettings
    $writerSettings.Indent = $true
    $writerSettings.Encoding = New-Object System.Text.UTF8Encoding ($false)
    foreach ($output in $OutputFiles) {
        $directory = Split-Path -Path $output -Parent
        if ($directory) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
        $writer = [System.Xml.XmlWriter]::Create($output, $writerSettings)
        try { $document.Save($writer) } finally { $writer.Dispose() }
    }
    return $counts
}

<#
.SYNOPSIS
    Applies the strict pipeline gates and returns the failure messages (empty when the run passed).
.DESCRIPTION
    Runner/infrastructure errors (run-tests exit codes, missing reports, disabled tests that still
    ran) always fail; so do failing tests and a run in which test apps were selected but no test
    was executed.
#>
function Get-BcDevEnvTestGateFailures {
    param(
        [int] $SelectedAppCount = 0,
        [Parameter(Mandatory = $true)] $Counts,
        [AllowEmptyCollection()] [string[]] $InfrastructureErrors = @()
    )

    $failures = @()
    $infrastructure = @(Get-BcDevEnvStringArray $InfrastructureErrors)
    if ($infrastructure.Count -gt 0) {
        $failures += "$($infrastructure.Count) test run(s) failed in the runner/infrastructure:`n - $($infrastructure -join "`n - ")"
    }
    if (($Counts.Failures + $Counts.Errors) -gt 0) {
        $failures += "$($Counts.Failures + $Counts.Errors) of $($Counts.Tests) test(s) failed ($($Counts.Failures) failure(s), $($Counts.Errors) error(s))."
    }
    if ($SelectedAppCount -gt 0 -and ($Counts.Tests - $Counts.Skipped) -le 0 -and $infrastructure.Count -eq 0) {
        $failures += "$SelectedAppCount test app(s) were selected but no test was executed."
    }
    return $failures
}

<#
.SYNOPSIS
    Locates the files the pipeline needs inside an extracted platform artifact.
#>
function Get-BcDevEnvPlatformLayout {
    param([Parameter(Mandatory = $true)] [string] $PlatformDir)

    $systemApps = @(Get-ChildItem -LiteralPath $PlatformDir -Recurse -File -Filter 'System.app' -ErrorAction SilentlyContinue)
    $systemApp = @($systemApps | Where-Object { $_.FullName -match 'ModernDev' }) + $systemApps | Select-Object -First 1
    if ($null -eq $systemApp) { throw "System.app (platform symbols) not found in the platform artifact '$PlatformDir'." }
    $server = Get-ChildItem -LiteralPath $PlatformDir -Recurse -File -Filter 'Microsoft.Dynamics.Nav.Server.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $server) { throw "The service tier (Microsoft.Dynamics.Nav.Server.exe) was not found in the platform artifact '$PlatformDir'." }
    $vsix = Get-ChildItem -LiteralPath $PlatformDir -Recurse -File -Filter 'ALLanguage.vsix' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $vsix) { throw "ALLanguage.vsix (AL compiler) not found in the platform artifact '$PlatformDir'." }
    return [pscustomobject]@{
        PlatformDir = $PlatformDir
        SystemApp   = $systemApp.FullName
        ServiceDir  = $server.DirectoryName
        Vsix        = $vsix.FullName
    }
}

<#
.SYNOPSIS
    Extracts the AL compiler (alc.exe) from ALLanguage.vsix.
#>
function Find-BcDevEnvAlc {
    param(
        [Parameter(Mandatory = $true)] [string] $VsixPath,
        [Parameter(Mandatory = $true)] [string] $Destination
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Recurse -Force }
    [System.IO.Compression.ZipFile]::ExtractToDirectory($VsixPath, $Destination)
    $candidates = @(Get-ChildItem -LiteralPath $Destination -Recurse -File -Filter 'alc.exe')
    $alc = @($candidates | Where-Object { $_.FullName -match '[\\/]win32[\\/]alc\.exe$' }) + $candidates | Select-Object -First 1
    if ($null -eq $alc) { throw "alc.exe not found in '$VsixPath'." }
    return $alc.FullName
}

<#
.SYNOPSIS
    Runs a native command, streams its output to the host and returns its exit code; throws on a
    non-zero exit code unless -AllowFailure is given.
#>
function Invoke-BcDevEnvNativeCommand {
    param(
        [Parameter(Mandatory = $true)] [string] $FilePath,
        [AllowEmptyCollection()] [string[]] $Arguments = @(),
        [string] $Description = '',
        [switch] $AllowFailure
    )

    if (-not $Description) { $Description = [System.IO.Path]::GetFileName($FilePath) }
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $FilePath @Arguments 2>&1 | ForEach-Object { Write-Host ([string]$_) }
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
    }
    if ($null -eq $exitCode) { $exitCode = 0 }
    if ($exitCode -ne 0 -and -not $AllowFailure) { throw "$Description failed (exit code $exitCode)." }
    return $exitCode
}

<#
.SYNOPSIS
    Probes the Docker engine with `docker info`. Returns OSType/ServerVersion when the engine answers,
    otherwise OSType = $null and the probe's error output in Error.
#>
function Get-BcDevEnvDockerEngineState {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& docker info --format '{{.OSType}}|{{.ServerVersion}}' 2>&1 | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
        $exitCode = $LASTEXITCODE
    }
    catch {
        return [pscustomobject]@{ OSType = $null; ServerVersion = $null; Error = $_.Exception.Message }
    }
    finally {
        $ErrorActionPreference = $previous
    }
    $answer = @($output | Where-Object { $_ -match '^(windows|linux)\|' }) | Select-Object -Last 1
    if ($exitCode -eq 0 -and $answer) {
        $parts = $answer.Split('|')
        return [pscustomobject]@{ OSType = $parts[0]; ServerVersion = $parts[1]; Error = '' }
    }
    return [pscustomobject]@{ OSType = $null; ServerVersion = $null; Error = "docker info exited with code $exitCode`: $($output -join ' ')" }
}

<#
.SYNOPSIS
    Makes sure the Docker engine is running before the pipeline uses it: starts the Docker service when
    it is stopped and waits until `docker info` answers, failing with a clear error after the timeout,
    when the service or CLI is missing, or when the engine does not run the expected container OS.
#>
function Wait-BcDevEnvDockerEngine {
    param(
        [string] $ServiceName = 'docker',
        [int] $TimeoutSeconds = 300,
        [int] $PollSeconds = 5,
        [string] $ExpectedOSType = 'windows'
    )

    if (-not (Get-Command -Name 'docker' -CommandType Application -ErrorAction SilentlyContinue)) {
        throw 'The docker CLI is not available on this runner; the bcdevenv pipeline needs Docker with Windows containers (a Windows Server 2022 runner).'
    }
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastError = ''
    $startAttempts = 0
    while ($true) {
        $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
        if ($null -eq $service) {
            throw "The Docker engine service '$ServiceName' is not installed on this runner; the bcdevenv pipeline needs Docker with Windows containers."
        }
        $status = [string]$service.Status
        if ($status -eq 'Stopped') {
            $startAttempts++
            Write-Host "The Docker engine service '$ServiceName' is stopped; starting it (attempt $startAttempts)."
            try {
                Start-Service -Name $ServiceName -ErrorAction Stop
            }
            catch {
                $lastError = "Start-Service '$ServiceName' failed: $($_.Exception.Message)"
                Write-Host $lastError
            }
        }
        elseif ($status -eq 'Running') {
            $state = Get-BcDevEnvDockerEngineState
            if ($state.OSType) {
                if ($ExpectedOSType -and $state.OSType -ne $ExpectedOSType) {
                    throw "The Docker engine runs $($state.OSType) containers; the bcdevenv pipeline needs $ExpectedOSType containers."
                }
                Write-Host "The Docker engine is ready ($($state.OSType) containers, server $($state.ServerVersion))."
                return $state
            }
            $lastError = $state.Error
        }
        if ((Get-Date) -ge $deadline) {
            throw "The Docker engine did not become ready within $TimeoutSeconds seconds (service '$ServiceName' status: $status, start attempts: $startAttempts). Last error: $lastError"
        }
        Start-Sleep -Seconds $PollSeconds
    }
}

<#
.SYNOPSIS
    The larger of the physical sector sizes (atomicity, performance) that fsutil reports for the
    volume of a path; 0 when it cannot be determined.
#>
function Get-BcDevEnvVolumeSectorSize {
    param([Parameter(Mandatory = $true)] [string] $Path)

    $root = [System.IO.Path]::GetPathRoot($Path)
    if (-not $root) { return 0 }
    try { $lines = @(& fsutil fsinfo sectorinfo $root.TrimEnd('\') 2>&1 | ForEach-Object { [string] $_ }) }
    catch { return 0 }
    $size = 0
    foreach ($line in $lines) {
        if ($line -match '^\s*PhysicalBytesPerSectorFor(?:Atomicity|Performance)\s*:\s*(\d+)') {
            $size = [Math]::Max($size, [int] $Matches[1])
        }
    }
    return $size
}

<#
.SYNOPSIS
    The data root (registry SQLDataRoot) of a local SQL Server instance; empty when unknown.
#>
function Get-BcDevEnvSqlDataRoot {
    param([string] $Instance = 'SQLEXPRESS')

    $names = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL' -ErrorAction SilentlyContinue
    if ($null -eq $names -or $null -eq $names.PSObject.Properties[$Instance]) { return '' }
    $setup = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$($names.$Instance)\Setup" -ErrorAction SilentlyContinue
    if ($null -eq $setup -or $null -eq $setup.PSObject.Properties['SQLDataRoot']) { return '' }
    return [string] $setup.SQLDataRoot
}

<#
.SYNOPSIS
    Makes a local SQL Server Express instance available for bcdevenv create-env on a CI runner and
    points BCDEVENV_HOME at a folder the SQL service account can back up to.
.DESCRIPTION
    Returns the data home that is used. SQL Server cannot use files on a volume whose physical sector
    size is above 4 KB; on such a runner Install-SqlExpress.ps1 puts the instance's data files on a
    4 KB virtual disk, and the data home (where SQL Server writes the empty database's backup) is
    moved to the same volume, keeping its path below the drive root.
#>
function Initialize-BcDevEnvSqlServer {
    param(
        [string] $Instance = 'SQLEXPRESS',
        [string] $DataHome = 'C:\bcdevenv-home',
        [string] $InstallScript = ''
    )

    $serviceName = if ($Instance -eq 'MSSQLSERVER') { 'MSSQLSERVER' } else { "MSSQL`$$Instance" }
    if (-not (Get-Service -Name $serviceName -ErrorAction SilentlyContinue)) {
        if (-not $InstallScript -or -not (Test-Path -LiteralPath $InstallScript -PathType Leaf)) {
            throw "SQL Server service '$serviceName' not found and no SQL Server Express install script was given (or '$InstallScript' does not exist)."
        }
        Write-Host "SQL Server service '$serviceName' not found; installing SQL Server Express with '$InstallScript'."
        & $InstallScript -InstanceName $Instance | ForEach-Object { Write-Host $_ }
        if (-not (Get-Service -Name $serviceName -ErrorAction SilentlyContinue)) {
            throw "SQL Server Express setup finished but the service '$serviceName' does not exist."
        }
    }
    Set-Service -Name $serviceName -StartupType Automatic
    Start-Service -Name $serviceName
    $browser = Get-Service -Name 'SQLBrowser' -ErrorAction SilentlyContinue
    if ($browser) {
        Set-Service -Name 'SQLBrowser' -StartupType Automatic
        Start-Service -Name 'SQLBrowser'
    }

    try {
        $namespace = Get-CimInstance -Namespace 'ROOT\Microsoft\SqlServer' -ClassName '__NAMESPACE' -ErrorAction Stop |
            Where-Object { $_.Name -like 'ComputerManagement*' } |
            Sort-Object { [int]($_.Name -replace '\D', '') } -Descending |
            Select-Object -First 1
        if ($namespace) {
            $protocols = Get-CimInstance -Namespace "ROOT\Microsoft\SqlServer\$($namespace.Name)" -ClassName ServerNetworkProtocol -ErrorAction Stop |
                Where-Object { $_.InstanceName -eq $Instance -and $_.ProtocolName -in @('Tcp', 'Np') }
            $changed = $false
            foreach ($protocol in $protocols) {
                if (-not $protocol.Enabled) {
                    Invoke-CimMethod -InputObject $protocol -MethodName SetEnable | Out-Null
                    $changed = $true
                    Write-Host "Enabled SQL protocol '$($protocol.ProtocolName)' for '$Instance'."
                }
            }
            if ($changed) {
                Restart-Service -Name $serviceName -Force
                if ($browser) { Restart-Service -Name 'SQLBrowser' -Force }
            }
        }
    }
    catch {
        Write-Warning "Could not enable the SQL network protocols: $($_.Exception.Message). Shared memory connections may still work."
    }

    $homeSectorSize = Get-BcDevEnvVolumeSectorSize -Path $DataHome
    if ($homeSectorSize -gt 4096) {
        $dataRoot = Get-BcDevEnvSqlDataRoot -Instance $Instance
        $dataRootSectorSize = if ($dataRoot) { Get-BcDevEnvVolumeSectorSize -Path $dataRoot } else { 0 }
        if ($dataRootSectorSize -ge 1 -and $dataRootSectorSize -le 4096) {
            $homeRoot = [System.IO.Path]::GetPathRoot($DataHome)
            $relocated = [System.IO.Path]::Combine([System.IO.Path]::GetPathRoot($dataRoot), $DataHome.Substring($homeRoot.Length))
            Write-Host "The volume of '$DataHome' reports a physical sector size of $homeSectorSize bytes; using '$relocated' on the SQL Server data volume ($dataRootSectorSize bytes) instead."
            $DataHome = $relocated
        }
        else {
            Write-Warning "The volume of '$DataHome' reports a physical sector size of $homeSectorSize bytes, and the SQL Server data root '$dataRoot' is not on a volume with 4096 bytes or less; backing up to it may fail."
        }
    }

    New-Item -ItemType Directory -Path $DataHome -Force | Out-Null
    try {
        $acl = Get-Acl -LiteralPath $DataHome
        $everyone = New-Object System.Security.Principal.SecurityIdentifier ([System.Security.Principal.WellKnownSidType]::WorldSid, $null)
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule ($everyone, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
        Set-Acl -LiteralPath $DataHome -AclObject $acl
    }
    catch {
        Write-Warning "Could not open the ACL of '$DataHome' for the SQL service account: $($_.Exception.Message)"
    }
    $env:BCDEVENV_HOME = $DataHome
    Write-Host "SQL Server 'localhost\$Instance' is ready; BCDEVENV_HOME=$DataHome."
    return $DataHome
}

Export-ModuleMember -Function *-BcDevEnv*
