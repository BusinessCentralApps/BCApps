<#
.SYNOPSIS
    Building blocks for the bcdevenv-based replacement of AL-Go's RunPipeline action
    (.github/actions/RunBcDevEnvPipeline).

.DESCRIPTION
    The pipeline takes the apps already compiled by AL-Go's CompileApps action (workspace
    compilation), creates an EMPTY-database Business Central container with the bcdevenv CLI
    from the BCPlatform version pinned in build/Packages.json, installs the project's apps and
    test apps into it and runs the tests through the BcDevEnvTestRunner OData service, honoring
    the DisabledTests folders (src/DisabledTests) before execution.

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
      UnitTest / none : empty company.
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
    When the secret is absent or empty a warning is written and $null is returned: the container
    then uses the platform's built-in license. The secret value is never written to the log.
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
        Write-Warning "No license secret '$SecretName' is available. The container uses the platform's built-in license; if publishing, installing or running tests needs more, provide a license through the '$SecretName' secret (or map another secret with the AL-Go licenseFileUrlSecretName setting)."
        return $null
    }

    [byte[]] $bytes = $null
    $source = ''
    if ($value -match '^https?://') {
        $source = 'URL'
        $download = Join-Path $Destination "license-download-$([guid]::NewGuid().ToString('N')).tmp"
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
        try {
            Invoke-WebRequest -Uri $value -OutFile $download -UseBasicParsing -TimeoutSec 300 | Out-Null
        }
        catch {
            throw "Could not download the license referenced by secret '$SecretName' ($($_.Exception.GetType().Name))."
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
    Builds the bcdevenv run-tests arguments for one app and one test pass.
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
        [int] $TimeoutMinutes = 60
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
    return $arguments
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
    Makes a local SQL Server Express instance available for bcdevenv create-env on a CI runner and
    points BCDEVENV_HOME at a folder the SQL service account can back up to.
#>
function Initialize-BcDevEnvSqlServer {
    param(
        [string] $Instance = 'SQLEXPRESS',
        [string] $DataHome = 'C:\bcdevenv-home'
    )

    $serviceName = if ($Instance -eq 'MSSQLSERVER') { 'MSSQLSERVER' } else { "MSSQL`$$Instance" }
    if (-not (Get-Service -Name $serviceName -ErrorAction SilentlyContinue)) {
        Write-Host "SQL Server service '$serviceName' not found; installing SQL Server Express (Chocolatey)."
        Invoke-BcDevEnvNativeCommand -FilePath 'choco' -Arguments @('install', 'sql-server-express', '--no-progress', '-y') -Description 'choco install sql-server-express' | Out-Null
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
