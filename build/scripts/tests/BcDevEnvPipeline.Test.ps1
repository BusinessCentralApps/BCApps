$errorActionPreference = "Stop"; $ProgressPreference = "SilentlyContinue"; Set-StrictMode -Version 2.0

Import-Module (Join-Path $PSScriptRoot '../BcDevEnvPipeline.psm1') -Force

BeforeAll {
    Add-Type -AssemblyName System.IO.Compression

    function New-TestApp {
        param(
            [Parameter(Mandatory = $true)] [string] $Folder,
            [Parameter(Mandatory = $true)] [string] $Id,
            [Parameter(Mandatory = $true)] [string] $Name,
            [string] $Version = '1.0.0.0',
            [string] $Publisher = 'Microsoft',
            [string] $Application = '',
            [object[]] $Dependencies = @(),
            [string] $FileName = ''
        )

        New-Item -ItemType Directory -Path $Folder -Force | Out-Null
        if (-not $FileName) { $FileName = "$($Publisher)_$($Name)_$Version.app" }
        $dependencyXml = ($Dependencies | ForEach-Object { "<Dependency Id=`"$($_.Id)`" Name=`"$($_.Name)`" Publisher=`"Microsoft`" MinVersion=`"$($_.MinVersion)`" />" }) -join ''
        $applicationAttribute = if ($Application) { " Application=`"$Application`"" } else { '' }
        $manifest = "<?xml version=`"1.0`" encoding=`"utf-8`"?><Package xmlns=`"http://schemas.microsoft.com/navx/2015/manifest`"><App Id=`"$Id`" Name=`"$Name`" Publisher=`"$Publisher`" Version=`"$Version`"$applicationAttribute /><Dependencies>$dependencyXml</Dependencies></Package>"

        $zipStream = New-Object System.IO.MemoryStream
        $archive = New-Object System.IO.Compression.ZipArchive ($zipStream, [System.IO.Compression.ZipArchiveMode]::Create, $true)
        $entry = $archive.CreateEntry('NavxManifest.xml')
        $writer = New-Object System.IO.StreamWriter ($entry.Open())
        $writer.Write($manifest)
        $writer.Dispose()
        $archive.Dispose()

        $header = [byte[]](@(0x4E, 0x41, 0x56, 0x58) + (@(0) * 36))
        $path = Join-Path $Folder $FileName
        [System.IO.File]::WriteAllBytes($path, [byte[]]($header + $zipStream.ToArray()))
        $zipStream.Dispose()
        return $path
    }

    function New-TestSettings {
        param([hashtable] $Values = @{})
        $settings = [ordered]@{ workspaceCompilation = [pscustomobject]@{ enabled = $true } }
        foreach ($key in $Values.Keys) { $settings[$key] = $Values[$key] }
        return [pscustomobject]$settings
    }

    function New-ManifestObject {
        param([string] $Id, [string] $Name, [string] $Version = '1.0.0.0', [object[]] $Dependencies = @(), [string] $Kind = 'App')
        return [pscustomobject]@{ Path = "C:\apps\$Name.app"; Id = $Id; Name = $Name; Publisher = 'Microsoft'; Version = [version]$Version; Application = ''; Dependencies = $Dependencies; Kind = $Kind; Wrapped = $false; Source = 'project' }
    }

    function New-Dependency {
        param([string] $Id, [string] $Name, [string] $MinVersion = '1.0.0.0')
        return [pscustomobject]@{ Id = $Id; Name = $Name; Publisher = 'Microsoft'; MinVersion = [version]$MinVersion }
    }
}

Describe "Get-BcDevEnvSetting" {
    It "reads PSCustomObject and dictionary settings case-insensitively and falls back to the default" {
        $object = [pscustomobject]@{ TestType = 'UnitTest'; nothing = $null }
        Get-BcDevEnvSetting -Settings $object -Name 'testType' | Should -Be 'UnitTest'
        Get-BcDevEnvSetting -Settings $object -Name 'nothing' -Default 'd' | Should -Be 'd'
        Get-BcDevEnvSetting -Settings $object -Name 'missing' -Default 3 | Should -Be 3
        Get-BcDevEnvSetting -Settings @{ Country = 'dk' } -Name 'country' | Should -Be 'dk'
        Get-BcDevEnvSetting -Settings $null -Name 'x' -Default 'n' | Should -Be 'n'
    }
}

Describe "Get-BcDevEnvPipelinePlan" {
    It "skips projects that do not publish apps, before any other validation" {
        $plan = Get-BcDevEnvPipelinePlan -Settings ([pscustomobject]@{ doNotPublishApps = $true; testType = 'Legacy' }) -Project 'build/projects/Apps W1'
        $plan.Action | Should -Be 'Skip'
    }

    It "requires workspace compilation" {
        { Get-BcDevEnvPipelinePlan -Settings ([pscustomobject]@{ testType = 'UnitTest' }) } | Should -Throw '*workspaceCompilation.enabled*'
    }

    It "rejects Legacy, RU and unknown test types with a clear reason" {
        { Get-BcDevEnvPipelinePlan -Settings (New-TestSettings @{ testType = 'Legacy'; bucketNumber = 1 }) } | Should -Throw "*testType 'Legacy'*"
        { Get-BcDevEnvPipelinePlan -Settings (New-TestSettings @{ testType = 'Performance' }) } | Should -Throw "*testType 'Performance'*"
        { Get-BcDevEnvPipelinePlan -Settings (New-TestSettings @{ testType = 'UnitTest'; projectsToTest = @('build/projects/Apps RU') }) } | Should -Throw '*RU projects*'
        { Get-BcDevEnvPipelinePlan -Settings (New-TestSettings @{ testType = 'UnitTest'; projectName = 'Test Apps (RU)' }) } | Should -Throw '*RU projects*'
    }

    It "plans UnitTest runs in an empty company with an isolated and an isolation-disabled pass" {
        $plan = Get-BcDevEnvPipelinePlan -Settings (New-TestSettings @{ testType = 'UnitTest'; companyName = 'Empty Company'; country = 'w1' })
        $plan.Action | Should -Be 'Test'
        $plan.CompanyName | Should -Be 'Empty Company'
        $plan.EvaluationCompany | Should -BeFalse
        @($plan.CompanyCodeunits).Count | Should -Be 0
        @($plan.Passes).Count | Should -Be 2
        $plan.Passes[0].Isolation | Should -Be 'None'
        $plan.Passes[0].RunnerId | Should -Be 130450
        $plan.Passes[1].Isolation | Should -Be 'Disabled'
        $plan.Passes[1].RunnerId | Should -Be 130451
        $plan.ServerSettings | Should -Contain 'EnableTaskScheduler=false'
    }

    It "prepares Contoso setup data for IntegrationTest and only adds the second pass with clean codeunit execution" {
        $plan = Get-BcDevEnvPipelinePlan -Settings (New-TestSettings @{ testType = 'IntegrationTest'; companyName = 'My Company' })
        $plan.CompanyCodeunits | Should -Be @('2', '5193:CreateSetupDemoData', '5691')
        @($plan.Passes).Count | Should -Be 1
        $plan = Get-BcDevEnvPipelinePlan -Settings (New-TestSettings @{ testType = 'IntegrationTest'; enableCleanTestCodeunitExecution = $true })
        @($plan.Passes).Count | Should -Be 2
    }

    It "prepares an evaluation company with all demo data and the task scheduler for Uncategorized" {
        $plan = Get-BcDevEnvPipelinePlan -Settings (New-TestSettings @{ testType = 'Uncategorized'; enableTaskScheduler = $true })
        $plan.EvaluationCompany | Should -BeTrue
        $plan.CompanyName | Should -Be 'CRONUS International Ltd.'
        $plan.CompanyCodeunits | Should -Be @('2', '5193:CreateAllDemoData', '5140:DeleteWarehouseEmployee', '5691')
        $plan.ServerSettings | Should -Contain 'EnableTaskScheduler=true'
    }

    It "runs a single untyped pass when no test type is configured and maps base to w1" {
        $plan = Get-BcDevEnvPipelinePlan -Settings (New-TestSettings @{ country = 'base' })
        $plan.Country | Should -Be 'w1'
        @($plan.Passes).Count | Should -Be 1
        $plan.Passes[0].TestType | Should -Be ''
        $plan.Passes[0].Isolation | Should -Be ''
    }

    It "provisions without testing when doNotRunTests is set" {
        $plan = Get-BcDevEnvPipelinePlan -Settings (New-TestSettings @{ testType = 'UnitTest'; doNotRunTests = $true })
        $plan.Action | Should -Be 'ProvisionOnly'
        @($plan.Passes).Count | Should -Be 0
    }
}

Describe "Get-BcDevEnvResourceNames" {
    It "creates docker-safe, run-unique names" {
        $names = Get-BcDevEnvResourceNames -Project 'build/projects/Test Apps W1' -BuildMode 'IntegrationTests' -RunId '123' -RunAttempt '2'
        $names.ContainerName | Should -Be 'bcdevenv-test-apps-w1-integrationtests-123-2'
        $names.ImageTag | Should -Be 'bcdevenv-algo:test-apps-w1-integrationtests-123-2'
        $names.ImageTag | Should -Match '^[a-z0-9-]+:[a-z0-9_.-]+$'
        (Get-BcDevEnvResourceNames -Project '.').ContainerName | Should -Be 'bcdevenv-root-default-0-1'
    }
}

Describe "Resolve-BcDevEnvLicense" {
    BeforeEach {
        $destination = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    }

    It "warns and returns null when the secret is missing" {
        $result = Resolve-BcDevEnvLicense -SecretsJson '{}' -SecretName 'licenseFileUrl' -Destination $destination -WarningVariable warnings -WarningAction SilentlyContinue
        $result | Should -BeNullOrEmpty
        "$warnings" | Should -BeLike "*licenseFileUrl*CRONUS license of the AL-Go application artifact*"
        "$warnings" | Should -Not -BeLike "*built-in*"
        $result = Resolve-BcDevEnvLicense -SecretsJson '' -Destination $destination -WarningAction SilentlyContinue
        $result | Should -BeNullOrEmpty
    }

    It "restores a gzip+base64 xml license as .bclicense without logging the value" {
        $licenseBytes = [System.Text.Encoding]::UTF8.GetBytes('<?xml version="1.0"?><License />')
        $buffer = New-Object System.IO.MemoryStream
        $gzip = New-Object System.IO.Compression.GZipStream ($buffer, [System.IO.Compression.CompressionMode]::Compress, $true)
        $gzip.Write($licenseBytes, 0, $licenseBytes.Length)
        $gzip.Dispose()
        $value = [System.Convert]::ToBase64String($buffer.ToArray())
        $secrets = @{ MyLicense = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($value)) } | ConvertTo-Json

        $output = Resolve-BcDevEnvLicense -SecretsJson $secrets -SecretName 'MyLicense' -Destination $destination 6>&1
        $path = @($output | Where-Object { $_ -is [string] })[-1]
        [System.IO.Path]::GetExtension($path) | Should -Be '.bclicense'
        [System.IO.File]::ReadAllBytes($path) | Should -Be $licenseBytes
        ($output | ForEach-Object { "$_" }) -join "`n" | Should -Not -Match ([regex]::Escape($value))
    }

    It "copies a license file referenced by path and detects a binary .flf license" {
        $source = Join-Path $TestDrive 'source.flf'
        [System.IO.File]::WriteAllBytes($source, [byte[]](0x01, 0x02, 0x03))
        $secrets = @{ licenseFileUrl = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($source)) } | ConvertTo-Json
        $path = Resolve-BcDevEnvLicense -SecretsJson $secrets -Destination $destination 6>$null
        [System.IO.Path]::GetExtension($path) | Should -Be '.flf'
        [System.IO.File]::ReadAllBytes($path) | Should -Be ([byte[]](0x01, 0x02, 0x03))
    }

    It "fails clearly for values that are not a URL, gzip license or file" {
        $secrets = @{ licenseFileUrl = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes('not-a-license')) } | ConvertTo-Json
        { Resolve-BcDevEnvLicense -SecretsJson $secrets -Destination $destination } | Should -Throw "*neither an http(s) URL*"
    }
}

Describe "Read-BcDevEnvAppList and Resolve-BcDevEnvAppEntries" {
    It "reads AL-Go app list files and literal arrays, and ignores missing values" {
        $file = Join-Path $TestDrive 'installApps.json'
        Set-Content -LiteralPath $file -Value '["C:\\a.app", "(C:\\b.app)"]'
        Read-BcDevEnvAppList $file | Should -Be @('C:\a.app', '(C:\b.app)')
        Read-BcDevEnvAppList '["x.app"]' | Should -Be @('x.app')
        @(Read-BcDevEnvAppList '').Count | Should -Be 0
        @(Read-BcDevEnvAppList (Join-Path $TestDrive 'missing.json') 6>$null).Count | Should -Be 0
    }

    It "expands folders and keeps the AL-Go 'do not run tests' marker" {
        $folder = Join-Path $TestDrive 'deps'
        New-TestApp -Folder $folder -Id ([guid]::NewGuid()) -Name 'A' | Out-Null
        New-TestApp -Folder (Join-Path $folder 'sub') -Id ([guid]::NewGuid()) -Name 'B' | Out-Null
        $entries = @(Resolve-BcDevEnvAppEntries -Entries @("($folder)") -Kind TestApp)
        $entries.Count | Should -Be 2
        $entries | ForEach-Object { $_.Wrapped | Should -BeTrue; $_.Kind | Should -Be 'TestApp' }
    }

    It "rejects URLs and entries without apps" {
        { Resolve-BcDevEnvAppEntries -Entries @('https://example.com/a.app') -Kind App } | Should -Throw '*is a URL*'
        { Resolve-BcDevEnvAppEntries -Entries @((Join-Path $TestDrive 'nothing.app')) -Kind App } | Should -Throw '*does not resolve*'
    }
}

Describe "Read-BcDevEnvAppManifest" {
    It "reads the identity and dependencies, adding the implicit Application dependency" {
        $dependencyId = [guid]::NewGuid().ToString()
        $path = New-TestApp -Folder (Join-Path $TestDrive 'manifest') -Id 'AAAAAAAA-0000-0000-0000-000000000001' -Name 'My App' -Version '27.1.0.5' -Application '27.0.0.0' -Dependencies @([pscustomobject]@{ Id = $dependencyId; Name = 'Dep'; MinVersion = '26.0.0.0' })
        $manifest = Read-BcDevEnvAppManifest -Path $path
        $manifest.Id | Should -Be 'aaaaaaaa-0000-0000-0000-000000000001'
        $manifest.Name | Should -Be 'My App'
        $manifest.Version | Should -Be ([version]'27.1.0.5')
        @($manifest.Dependencies).Count | Should -Be 2
        $manifest.Dependencies[0].Id | Should -Be $dependencyId.ToLowerInvariant()
        $manifest.Dependencies[0].MinVersion | Should -Be ([version]'26.0.0.0')
        $manifest.Dependencies[1].Id | Should -Be 'c1335042-3002-4257-bf8a-75c898ccb1b8'
    }

    It "fails for files without a zip payload" {
        $path = Join-Path $TestDrive 'broken.app'
        [System.IO.File]::WriteAllBytes($path, [byte[]](1..64))
        { Read-BcDevEnvAppManifest -Path $path } | Should -Throw '*not a readable .app package*'
    }
}

Describe "Get-BcDevEnvAppsNotToPublish" {
    It "adds the project override's additional apps to the native defaults without running the override" {
        $project = Join-Path $TestDrive 'Test Apps IN'
        New-Item -ItemType Directory -Path (Join-Path $project '.AL-Go') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $project '.AL-Go/PublishBcContainerApp.ps1') -Value @'
Param([Hashtable]$parameters)
throw "must not run"
. (Join-Path $PSScriptRoot "../../../scripts/PublishBcContainerApp.ps1") -parameters $parameters -AdditionalAppsNotToPublish @("Contoso Coffee Demo Dataset (IN)")
'@
        $names = Get-BcDevEnvAppsNotToPublish -ProjectPath $project
        $names | Should -Contain 'Library - No Transactions'
        $names | Should -Contain 'Prevent Metadata Updates Library'
        $names | Should -Contain 'Contoso Coffee Demo Dataset (IN)'
        @(Get-BcDevEnvAppsNotToPublish -ProjectPath (Join-Path $TestDrive 'none')).Count | Should -Be 2
    }
}

Describe "Get-BcDevEnvOrderedApps and Get-BcDevEnvDependencyClosure" {
    It "orders dependencies first, keeps the input order otherwise and keeps the highest duplicate" {
        $base = New-ManifestObject -Id 'base' -Name 'Base'
        $test = New-ManifestObject -Id 'test' -Name 'Tests' -Dependencies @(New-Dependency 'lib' 'Lib') -Kind TestApp
        $lib = New-ManifestObject -Id 'lib' -Name 'Lib' -Dependencies @(New-Dependency 'base' 'Base')
        $other = New-ManifestObject -Id 'other' -Name 'Other'
        $newerBase = New-ManifestObject -Id 'base' -Name 'Base' -Version '2.0.0.0'
        $ordered = @(Get-BcDevEnvOrderedApps -Apps @($test, $other, $lib, $base, $newerBase) 6>$null)
        ($ordered | ForEach-Object { $_.Name }) | Should -Be @('Base', 'Lib', 'Tests', 'Other')
        $ordered[0].Version | Should -Be ([version]'2.0.0.0')
    }

    It "lists every missing or too-old dependency, because the database starts empty" {
        $a = New-ManifestObject -Id 'a' -Name 'A' -Dependencies @((New-Dependency 'missing' 'Missing'), (New-Dependency 'b' 'B' '5.0.0.0'))
        $b = New-ManifestObject -Id 'b' -Name 'B'
        { Get-BcDevEnvOrderedApps -Apps @($a, $b) } | Should -Throw "*'Missing'*not in the install set*'B' >= 5.0.0.0*1.0.0.0*"
    }

    It "detects cycles" {
        $a = New-ManifestObject -Id 'a' -Name 'A' -Dependencies @(New-Dependency 'b' 'B')
        $b = New-ManifestObject -Id 'b' -Name 'B' -Dependencies @(New-Dependency 'a' 'A')
        { Get-BcDevEnvOrderedApps -Apps @($a, $b) } | Should -Throw '*dependency cycle*'
    }

    It "returns the dependency closure in install order" {
        $base = New-ManifestObject -Id 'base' -Name 'Base'
        $lib = New-ManifestObject -Id 'lib' -Name 'Lib' -Dependencies @(New-Dependency 'base' 'Base')
        $other = New-ManifestObject -Id 'other' -Name 'Other'
        $closure = @(Get-BcDevEnvDependencyClosure -OrderedApps @($base, $other, $lib) -RootIds @('LIB'))
        ($closure | ForEach-Object { $_.Name }) | Should -Be @('Base', 'Lib')
        { Get-BcDevEnvDependencyClosure -OrderedApps @($base) -RootIds @('nope') } | Should -Throw '*not in the install set*'
    }
}

Describe "Get-BcDevEnvInstallSet" {
    It "combines project build artifacts and dependency apps, excluding apps that must not be published" {
        $project = Join-Path $TestDrive 'project'
        $deps = Join-Path $TestDrive 'dependencies'
        $baseId = [guid]::NewGuid().ToString()
        $baseApp = New-TestApp -Folder $deps -Id $baseId -Name 'Base'
        $libraryId = [guid]::NewGuid().ToString()
        New-TestApp -Folder (Join-Path $project '.buildartifacts/Apps') -Id $libraryId -Name 'Library' -Dependencies @([pscustomobject]@{ Id = $baseId; Name = 'Base'; MinVersion = '1.0.0.0' }) | Out-Null
        New-TestApp -Folder (Join-Path $project '.buildartifacts/TestApps') -Id ([guid]::NewGuid()) -Name 'Library Tests' -Dependencies @([pscustomobject]@{ Id = $libraryId; Name = 'Library'; MinVersion = '1.0.0.0' }) | Out-Null
        New-TestApp -Folder (Join-Path $project '.buildartifacts/TestApps') -Id ([guid]::NewGuid()) -Name 'Library - No Transactions' | Out-Null
        $installApps = Join-Path $TestDrive 'installApps.json'
        ConvertTo-Json -InputObject @($baseApp) | Set-Content -LiteralPath $installApps

        $set = Get-BcDevEnvInstallSet -ProjectPath $project -InstallAppsJson $installApps -InstallTestAppsJson ''
        ($set.Apps | ForEach-Object { $_.Name }) | Should -Be @('Base', 'Library', 'Library Tests')
        ($set.Apps | ForEach-Object { $_.Kind }) | Should -Be @('App', 'App', 'TestApp')
        @($set.Excluded).Count | Should -Be 1
        $set.Excluded[0].Name | Should -Be 'Library - No Transactions'
    }
}

Describe "Get-BcDevEnvTestAppSelection" {
    BeforeAll {
        $apps = @(
            (New-ManifestObject -Id 'a' -Name 'App'),
            (New-ManifestObject -Id 't1' -Name 'Own Tests' -Kind TestApp),
            ((New-ManifestObject -Id 't2' -Name 'Dependency Tests' -Kind TestApp) | ForEach-Object { $_.Wrapped = $true; $_ })
        )
    }

    It "runs the project's and unwrapped test apps, or all with runTestsInAllInstalledTestApps" {
        $project = Join-Path $TestDrive 'plain'
        New-Item -ItemType Directory -Path $project -Force | Out-Null
        $selected = @(Get-BcDevEnvTestAppSelection -InstalledApps $apps -ProjectPath $project -Plan ([pscustomobject]@{ RunTestsInAllInstalledTestApps = $false }))
        ($selected | ForEach-Object { $_.Name }) | Should -Be @('Own Tests')
        $selected = @(Get-BcDevEnvTestAppSelection -InstalledApps $apps -ProjectPath $project -Plan ([pscustomobject]@{ RunTestsInAllInstalledTestApps = $true }))
        ($selected | ForEach-Object { $_.Name }) | Should -Be @('Own Tests', 'Dependency Tests')
    }

    It "uses the native BCApps test dispatch for Invoke-PerProjectTestRun projects" {
        $project = Join-Path $TestDrive 'native'
        New-Item -ItemType Directory -Path (Join-Path $project '.AL-Go') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $project '.AL-Go/RunTestsInBcContainer.ps1') -Value 'Invoke-PerProjectTestRun -parameters $parameters'
        Mock -ModuleName BcDevEnvPipeline Get-BcDevEnvNativeTestAppNames { @('Dependency Tests', 'Not Installed') }
        $plan = [pscustomobject]@{ Country = 'w1'; TestType = 'UnitTest'; BucketNumber = 0; RunTestsInAllInstalledTestApps = $false }
        $selected = @(Get-BcDevEnvTestAppSelection -InstalledApps $apps -ProjectPath $project -Plan $plan)
        ($selected | ForEach-Object { $_.Name }) | Should -Be @('Dependency Tests')
        Should -Invoke -ModuleName BcDevEnvPipeline Get-BcDevEnvNativeTestAppNames -Times 1 -ParameterFilter { $Country -eq 'w1' -and $TestType -eq 'UnitTest' -and ($InstalledAppNames -contains 'Own Tests') }
    }
}

Describe "Get-BcDevEnvNativeTestAppNames" {
    It "returns no apps when none of the expected test apps is installed" {
        @(Get-BcDevEnvNativeTestAppNames -Country 'w1' -TestType 'UnitTest' -InstalledAppNames @('Not A BCApps Test App')).Count | Should -Be 0
    }
}

Describe "Get-BcDevEnvDisabledTestsRoots" {
    It "finds DisabledTests folders like the native pipeline, skipping .git and the tool folder" {
        $base = Join-Path $TestDrive 'repo'
        foreach ($folder in @('src/DisabledTests/App_One', 'src/Apps/W1/X/DisabledTests', '.git/DisabledTests', 'bcdevenv/DisabledTests', 'src/DisabledTests/Nested/DisabledTests')) {
            New-Item -ItemType Directory -Path (Join-Path $base $folder) -Force | Out-Null
        }
        $roots = @(Get-BcDevEnvDisabledTestsRoots -BaseFolder $base)
        $roots.Count | Should -Be 2
        $roots | Should -Contain ([System.IO.Path]::GetFullPath((Join-Path $base 'src/DisabledTests')))
        $roots | Should -Contain ([System.IO.Path]::GetFullPath((Join-Path $base 'src/Apps/W1/X/DisabledTests')))
    }

    It "finds the real repository DisabledTests folder" {
        $repo = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        (Get-BcDevEnvDisabledTestsRoots -BaseFolder $repo) | Should -Contain (Join-Path $repo 'src\DisabledTests')
    }
}

Describe "Get-BcDevEnvReadinessScript and ConvertTo-BcDevEnvEncodedScript" {
    It "produces a parseable probe that checks for the required metadata and round-trips through -EncodedCommand" {
        $script = Get-BcDevEnvReadinessScript -ODataUrl 'http://localhost:7048/BC/ODataV4/' -RequiredText "BcDevEnvTestRunner_PrepareTests"
        $script | Should -Match ([regex]::Escape("'http://localhost:7048/BC/ODataV4/`$metadata'"))
        $script | Should -Match 'BcDevEnvTestRunner_PrepareTests'
        $tokens = $null; $errors = $null
        [System.Management.Automation.Language.Parser]::ParseInput($script, [ref]$tokens, [ref]$errors) | Out-Null
        @($errors).Count | Should -Be 0
        $encoded = ConvertTo-BcDevEnvEncodedScript -Script $script
        [System.Text.Encoding]::Unicode.GetString([System.Convert]::FromBase64String($encoded)) | Should -Be $script
    }

    It "quotes typographic and plain single quotes in literals" {
        $q = [char]0x2018
        $script = Get-BcDevEnvReadinessScript -ODataUrl "http://x/Contoso's$q" -RequiredText ''
        $tokens = $null; $errors = $null
        [System.Management.Automation.Language.Parser]::ParseInput($script, [ref]$tokens, [ref]$errors) | Out-Null
        @($errors).Count | Should -Be 0
        $script | Should -Match ([regex]::Escape("'http://x/Contoso''s$q$q/`$metadata'"))
    }

    It "accepts any metadata when no text is required" {
        $script = Get-BcDevEnvReadinessScript -ODataUrl 'http://localhost:7048/BC/ODataV4' -RequiredText '' -Attempts 1 -DelaySeconds 0
        $script | Should -Match ([regex]::Escape("if (-not '' -or"))
    }
}

Describe "Get-BcDevEnvRunTestsArguments" {
    It "passes the app, pass, disabled tests and strict per-codeunit options" {
        $app = [pscustomobject]@{ Id = 'aaaa'; Name = 'Library Tests' }
        $pass = [pscustomobject]@{ TestType = 'UnitTest'; Isolation = 'Disabled'; RunnerId = 130451 }
        $arguments = Get-BcDevEnvRunTestsArguments -ODataUrl 'http://localhost:7048/BC/ODataV4' -CompanyName 'Empty Company' -App $app -Pass $pass -DisabledTestsRoots @('C:\d\0', 'C:\d\1') -ResultFile 'C:\r\1.xml'
        ($arguments -join ' ') | Should -Be 'run-tests --odata-url http://localhost:7048/BC/ODataV4 --service-name BcDevEnvTestRunner --company Empty Company --protocol per-codeunit --extension aaaa --app-name Library Tests --disabled-tests C:\d\0 --disabled-tests C:\d\1 --test-type UnitTest --required-test-isolation Disabled --test-runner-codeunit-id 130451 --result-file C:\r\1.xml --suite-name BusinessCentral --timeout-minutes 60 --allow-failures --allow-empty'
        $arguments | Where-Object { [string]::IsNullOrEmpty($_) } | Should -BeNullOrEmpty
    }

    It "omits the test type and isolation for untyped passes" {
        $arguments = Get-BcDevEnvRunTestsArguments -ODataUrl 'u' -CompanyName 'c' -App ([pscustomobject]@{ Id = 'i'; Name = 'n' }) -Pass ([pscustomobject]@{ TestType = ''; Isolation = ''; RunnerId = 130450 }) -ResultFile 'r'
        $arguments | Should -Not -Contain '--test-type'
        $arguments | Should -Not -Contain '--required-test-isolation'
        $arguments | Should -Not -Contain '--disabled-tests'
    }
}

Describe "Merge-BcDevEnvJUnitResults and Get-BcDevEnvTestGateFailures" {
    BeforeAll {
        $first = Join-Path $TestDrive 'first.xml'
        Set-Content -LiteralPath $first -Encoding UTF8 -Value @'
<?xml version="1.0" encoding="utf-8"?>
<testsuites name="BusinessCentral" tests="3" failures="1" skipped="1">
  <testsuite name="130001 Tests" tests="3" failures="1" skipped="1" time="1.5">
    <properties><property name="appName" value="Library Tests" /><property name="extensionId" value="aaaa" /></properties>
    <testcase classname="130001 Tests" name="Passes" time="0.5" />
    <testcase classname="130001 Tests" name="Fails" time="1"><failure message="boom" /></testcase>
    <testcase classname="130001 Tests" name="Disabled" time="0"><skipped message="Disabled by DisabledTests" /></testcase>
  </testsuite>
</testsuites>
'@
        $second = Join-Path $TestDrive 'second.xml'
        Set-Content -LiteralPath $second -Encoding UTF8 -Value @'
<testsuite name="130002 More" tests="1" time="0.25"><testcase classname="130002 More" name="Ok" time="0.25" /></testsuite>
'@
    }

    It "merges all suites, recomputes the totals and keeps the AL-Go suite properties" {
        $outputs = @((Join-Path $TestDrive 'out/TestResults.xml'), (Join-Path $TestDrive 'out/.buildartifacts/TestResults.xml'))
        $counts = Merge-BcDevEnvJUnitResults -InputFiles @($first, $second) -OutputFiles $outputs
        $counts.Tests | Should -Be 4
        $counts.Failures | Should -Be 1
        $counts.Skipped | Should -Be 1
        foreach ($output in $outputs) {
            [xml]$merged = Get-Content -LiteralPath $output -Raw
            $merged.testsuites.tests | Should -Be '4'
            $merged.testsuites.time | Should -Be '1.75'
            @($merged.testsuites.testsuite).Count | Should -Be 2
            $merged.SelectSingleNode("//property[@name='appName']").value | Should -Be 'Library Tests'
            [System.IO.File]::ReadAllBytes($output)[0] | Should -Be ([byte][char]'<')
        }
        (Get-BcDevEnvJUnitSummary -Path $outputs[0]).Tests | Should -Be 4
    }

    It "fails on runner errors, test failures and runs that executed nothing" {
        $passing = [pscustomobject]@{ Tests = 5; Failures = 0; Errors = 0; Skipped = 1 }
        @(Get-BcDevEnvTestGateFailures -SelectedAppCount 2 -Counts $passing).Count | Should -Be 0
        @(Get-BcDevEnvTestGateFailures -SelectedAppCount 2 -Counts ([pscustomobject]@{ Tests = 5; Failures = 1; Errors = 1; Skipped = 0 })) | Should -BeLike '*2 of 5 test(s) failed*'
        @(Get-BcDevEnvTestGateFailures -SelectedAppCount 2 -Counts ([pscustomobject]@{ Tests = 3; Failures = 0; Errors = 0; Skipped = 3 })) | Should -BeLike '*no test was executed*'
        $failures = @(Get-BcDevEnvTestGateFailures -SelectedAppCount 1 -Counts $passing -InfrastructureErrors @('Library Tests: exit code 3'))
        $failures.Count | Should -Be 1
        $failures[0] | Should -BeLike '*runner/infrastructure*Library Tests: exit code 3*'
    }
}

Describe "Get-BcDevEnvPlatformLayout and Find-BcDevEnvAlc" {
    It "locates the platform files and extracts the win32 compiler" {
        $platform = Join-Path $TestDrive 'platform'
        $vsixContent = Join-Path $TestDrive 'vsix'
        foreach ($folder in @('ModernDev/program files/Microsoft Dynamics NAV/270/AL Development Environment', 'ServiceTier/program files/Microsoft Dynamics NAV/270/Service', 'Other')) {
            New-Item -ItemType Directory -Path (Join-Path $platform $folder) -Force | Out-Null
        }
        Set-Content (Join-Path $platform 'Other/System.app') 'x'
        Set-Content (Join-Path $platform 'ModernDev/program files/Microsoft Dynamics NAV/270/AL Development Environment/System.app') 'x'
        Set-Content (Join-Path $platform 'ServiceTier/program files/Microsoft Dynamics NAV/270/Service/Microsoft.Dynamics.Nav.Server.exe') 'x'
        foreach ($folder in @('extension/bin/linux', 'extension/bin/win32')) {
            New-Item -ItemType Directory -Path (Join-Path $vsixContent $folder) -Force | Out-Null
        }
        Set-Content (Join-Path $vsixContent 'extension/bin/linux/alc.exe') 'x'
        Set-Content (Join-Path $vsixContent 'extension/bin/win32/alc.exe') 'x'
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::CreateFromDirectory($vsixContent, (Join-Path $platform 'ModernDev/program files/Microsoft Dynamics NAV/270/AL Development Environment/ALLanguage.vsix'))

        $layout = Get-BcDevEnvPlatformLayout -PlatformDir $platform
        $layout.SystemApp | Should -BeLike '*ModernDev*System.app'
        $layout.ServiceDir | Should -BeLike '*\Service'
        $alc = Find-BcDevEnvAlc -VsixPath $layout.Vsix -Destination (Join-Path $TestDrive 'alc')
        $alc | Should -BeLike '*\win32\alc.exe'
    }

    It "explains which platform file is missing" {
        { Get-BcDevEnvPlatformLayout -PlatformDir (New-Item -ItemType Directory -Path (Join-Path $TestDrive 'empty') -Force).FullName } | Should -Throw '*System.app*'
    }
}

Describe "Get-BcDevEnvDockerEngineState" {
    BeforeAll {
        # Mock needs an existing command; stub the docker CLI on machines without Docker.
        if (-not (Get-Command -Name 'docker' -ErrorAction SilentlyContinue)) { function global:docker { } }
    }

    AfterAll {
        if (Test-Path -LiteralPath 'function:global:docker') { Remove-Item -LiteralPath 'function:global:docker' }
    }

    It "returns the engine OS type and version when docker info answers" {
        Mock -ModuleName BcDevEnvPipeline docker { $global:LASTEXITCODE = 0; 'windows|27.5.1' }
        $state = Get-BcDevEnvDockerEngineState
        $state.OSType | Should -Be 'windows'
        $state.ServerVersion | Should -Be '27.5.1'
    }

    It "reports the docker info error when the engine is not reachable" {
        Mock -ModuleName BcDevEnvPipeline docker { $global:LASTEXITCODE = 1; 'failed to connect to the docker API at npipe:////./pipe/docker_engine' }
        $state = Get-BcDevEnvDockerEngineState
        $state.OSType | Should -BeNullOrEmpty
        $state.Error | Should -BeLike '*exited with code 1*npipe:////./pipe/docker_engine*'
    }
}

Describe "Wait-BcDevEnvDockerEngine" {
    BeforeEach {
        $script:dockerStatus = 'Running'
        $script:engineOSType = 'windows'
        Mock -ModuleName BcDevEnvPipeline Get-Command { [pscustomobject]@{ Name = 'docker.exe' } } -ParameterFilter { $Name -eq 'docker' }
        Mock -ModuleName BcDevEnvPipeline Get-Service { if ($script:dockerStatus) { [pscustomobject]@{ Name = 'docker'; Status = $script:dockerStatus } } }
        Mock -ModuleName BcDevEnvPipeline Start-Service { $script:dockerStatus = 'Running' }
        Mock -ModuleName BcDevEnvPipeline Start-Sleep { }
        Mock -ModuleName BcDevEnvPipeline Get-BcDevEnvDockerEngineState {
            if ($script:engineOSType) { [pscustomobject]@{ OSType = $script:engineOSType; ServerVersion = '27.5.1'; Error = '' } }
            else { [pscustomobject]@{ OSType = $null; ServerVersion = $null; Error = 'docker info exited with code 1: failed to connect to the docker API' } }
        }
    }

    It "returns immediately when the engine is running" {
        (Wait-BcDevEnvDockerEngine).OSType | Should -Be 'windows'
        Should -Invoke -ModuleName BcDevEnvPipeline Start-Service -Times 0 -Exactly
    }

    It "starts a stopped Docker service and waits for the engine" {
        $script:dockerStatus = 'Stopped'
        (Wait-BcDevEnvDockerEngine).OSType | Should -Be 'windows'
        Should -Invoke -ModuleName BcDevEnvPipeline Start-Service -Times 1 -Exactly -ParameterFilter { $Name -eq 'docker' }
    }

    It "fails with the last docker error when the engine does not answer in time" {
        $script:engineOSType = $null
        { Wait-BcDevEnvDockerEngine -TimeoutSeconds 0 } | Should -Throw '*did not become ready within 0 seconds*status: Running*failed to connect to the docker API*'
    }

    It "fails clearly when the Docker service is missing" {
        $script:dockerStatus = $null
        { Wait-BcDevEnvDockerEngine } | Should -Throw "*Docker engine service 'docker' is not installed*"
    }

    It "fails clearly when the docker CLI is missing" {
        Mock -ModuleName BcDevEnvPipeline Get-Command { } -ParameterFilter { $Name -eq 'docker' }
        { Wait-BcDevEnvDockerEngine } | Should -Throw '*docker CLI is not available*'
    }

    It "rejects an engine that runs Linux containers" {
        $script:engineOSType = 'linux'
        { Wait-BcDevEnvDockerEngine } | Should -Throw '*runs linux containers*needs windows containers*'
    }
}

Describe "Invoke-BcDevEnvWithRetry" {
    BeforeEach {
        Mock -ModuleName BcDevEnvPipeline Start-Sleep { }
        $script:calls = 0
    }

    It "returns the result of the first successful attempt" {
        Invoke-BcDevEnvWithRetry -Description 'Work' -ScriptBlock { param($attempt) "done $attempt" } | Should -Be 'done 1'
        Should -Invoke -ModuleName BcDevEnvPipeline Start-Sleep -Times 0 -Exactly
    }

    It "retries with exponential backoff until an attempt succeeds" {
        $result = Invoke-BcDevEnvWithRetry -Description 'Work' -InitialDelaySeconds 10 -ScriptBlock {
            $script:calls++
            if ($script:calls -lt 3) { throw "transient $script:calls" }
            'ok'
        } 6>$null
        $result | Should -Be 'ok'
        $script:calls | Should -Be 3
        Should -Invoke -ModuleName BcDevEnvPipeline Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 10 }
        Should -Invoke -ModuleName BcDevEnvPipeline Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 20 }
    }

    It "fails with the description, the attempt count and the last error" {
        { Invoke-BcDevEnvWithRetry -Description 'Downloading X' -MaxAttempts 2 -ScriptBlock { $script:calls++; throw 'The response ended prematurely.' } 6>$null } |
            Should -Throw 'Downloading X failed after 2 attempt(s): The response ended prematurely.'
        $script:calls | Should -Be 2
    }
}

Describe "Save-BcDevEnvDownload" {
    BeforeAll {
        $zipSource = Join-Path $TestDrive 'source.zip'
        $archive = [System.IO.Compression.ZipFile]::Open($zipSource, [System.IO.Compression.ZipArchiveMode]::Create)
        $writer = New-Object System.IO.StreamWriter ($archive.CreateEntry('a.txt').Open())
        $writer.Write('content')
        $writer.Dispose()
        $archive.Dispose()
        $script:zipBytes = [System.IO.File]::ReadAllBytes($zipSource)
    }

    BeforeEach {
        Mock -ModuleName BcDevEnvPipeline Start-Sleep { }
        $script:downloads = 0
        $outFile = Join-Path $TestDrive "download-$([guid]::NewGuid().ToString('N'))\platform.zip"
    }

    It "deletes a truncated zip and downloads it again" {
        Mock -ModuleName BcDevEnvPipeline Invoke-WebRequest {
            $script:downloads++
            $bytes = if ($script:downloads -eq 1) { $script:zipBytes[0..20] } else { $script:zipBytes }
            [System.IO.File]::WriteAllBytes($OutFile, [byte[]]$bytes)
        }
        $path = Save-BcDevEnvDownload -Uri 'https://example.test/platform?sv=secret' -OutFile $outFile -ValidateZip 6>$null
        $path | Should -Be (Get-Item -LiteralPath $outFile).FullName
        [System.IO.File]::ReadAllBytes($outFile) | Should -Be $script:zipBytes
        $script:downloads | Should -Be 2
    }

    It "retries a failed request and removes the partial file after the last attempt" {
        Mock -ModuleName BcDevEnvPipeline Invoke-WebRequest {
            [System.IO.File]::WriteAllBytes($OutFile, [byte[]](1, 2, 3))
            throw 'One or more errors occurred. (The response ended prematurely. (ResponseEnded))'
        }
        { Save-BcDevEnvDownload -Uri 'https://example.test/platform' -OutFile $outFile -MaxAttempts 3 -Description 'Downloading the platform' 6>$null } |
            Should -Throw 'Downloading the platform failed after 3 attempt(s):*ResponseEnded*'
        Should -Invoke -ModuleName BcDevEnvPipeline Invoke-WebRequest -Times 3 -Exactly
        Test-Path -LiteralPath $outFile | Should -BeFalse
    }

    It "rejects a download whose SHA256 does not match" {
        Mock -ModuleName BcDevEnvPipeline Invoke-WebRequest { [System.IO.File]::WriteAllBytes($OutFile, [byte[]](1, 2, 3)) }
        { Save-BcDevEnvDownload -Uri 'https://example.test/x.exe' -OutFile $outFile -Sha256 ('0' * 64) -MaxAttempts 2 6>$null } |
            Should -Throw '*failed after 2 attempt(s):*has SHA256*expected 0000*'
        Test-Path -LiteralPath $outFile | Should -BeFalse
    }
}

Describe "Get-BcDevEnvApplicationArtifactUrl" {
    It "prefers the URL resolved by AL-Go's DetermineArtifactUrl" {
        Get-BcDevEnvApplicationArtifactUrl -ResolvedArtifactUrl ' https://bcinsider-fvh2ekdjecfjd6gk.b02.azurefd.net/sandbox/30.0.57476.0/base ' -Settings ([pscustomobject]@{ artifact = 'bcartifacts/onprem/1.0.0.0/w1/latest' }) |
            Should -Be 'https://bcinsider-fvh2ekdjecfjd6gk.b02.azurefd.net/sandbox/30.0.57476.0/base'
    }

    It "derives <Expected> from artifact '<Artifact>' and country '<Country>'" -TestCases @(
        @{ Artifact = 'bcinsider/Sandbox/30.0.57476.0//latest'; Country = 'base'; Expected = 'https://bcinsider-fvh2ekdjecfjd6gk.b02.azurefd.net/sandbox/30.0.57476.0/base' }
        @{ Artifact = 'bcinsider/Sandbox/30.0.57476.0//latest'; Country = ''; Expected = 'https://bcinsider-fvh2ekdjecfjd6gk.b02.azurefd.net/sandbox/30.0.57476.0/base' }
        @{ Artifact = 'bcinsider/Sandbox/30.0.57476.0//latest'; Country = 'DK'; Expected = 'https://bcinsider-fvh2ekdjecfjd6gk.b02.azurefd.net/sandbox/30.0.57476.0/dk' }
        @{ Artifact = 'bcartifacts/OnPrem/26.5.38752.40000/de/first'; Country = 'base'; Expected = 'https://bcartifacts-exdbf9fwegejdqak.b02.azurefd.net/onprem/26.5.38752.40000/de' }
        @{ Artifact = 'https://example.test/sandbox/1.2.3.4/us?sv=x'; Country = ''; Expected = 'https://example.test/sandbox/1.2.3.4/us?sv=x' }
    ) {
        param($Artifact, $Country, $Expected)
        Get-BcDevEnvApplicationArtifactUrl -ResolvedArtifactUrl '' -Settings ([pscustomobject]@{ artifact = $Artifact; country = $Country }) | Should -Be $Expected
    }

    It "resolves a partial version from the artifact index (<Select>)" -TestCases @(
        @{ Select = 'latest'; Expected = '30.10.2.0' }
        @{ Select = 'first'; Expected = '30.0.9.0' }
    ) {
        param($Select, $Expected)
        Mock -ModuleName BcDevEnvPipeline Invoke-RestMethod {
            @('29.9.1.0', '30.0.9.0', '30.10.2.0', '30.2.1.0', '300.0.0.0') | ForEach-Object { [pscustomobject]@{ Version = $_; CreationTime = '2025-01-01' } }
        } -ParameterFilter { "$Uri" -eq 'https://bcinsider-fvh2ekdjecfjd6gk.b02.azurefd.net/sandbox/indexes/base.json' }
        Get-BcDevEnvApplicationArtifactUrl -Settings ([pscustomobject]@{ artifact = "bcinsider/sandbox/30//$Select" }) |
            Should -Be "https://bcinsider-fvh2ekdjecfjd6gk.b02.azurefd.net/sandbox/$Expected/base"
    }

    It "fails clearly for an unsupported or missing artifact setting" {
        { Get-BcDevEnvApplicationArtifactUrl -Settings ([pscustomobject]@{ artifact = 'bcpublicpreview/sandbox/30.0.1.2/us/latest' }) } | Should -Throw "*storage account 'bcpublicpreview' is not supported*"
        { Get-BcDevEnvApplicationArtifactUrl -Settings ([pscustomobject]@{ artifact = '' }) } | Should -Throw "*'artifact' setting '' is not a URL*"
    }
}

Describe "Select-BcDevEnvArtifactLicenseEntry" {
    It "uses the manifest's licenseFile" {
        Select-BcDevEnvArtifactLicenseEntry -EntryNames @('manifest.json', 'Cronus.bclicense', 'Master.bclicense') -ManifestJson '{"licenseFile":"Master.bclicense"}' |
            Should -Be 'Master.bclicense'
    }

    It "falls back to Cronus.bclicense, matching case-insensitively and by file name" {
        Select-BcDevEnvArtifactLicenseEntry -EntryNames @('manifest.json', 'CRONUS.BCLICENSE') -ManifestJson '{"version":"30.0"}' | Should -Be 'CRONUS.BCLICENSE'
        Select-BcDevEnvArtifactLicenseEntry -EntryNames @('ServiceTier/Service/Cronus.bclicense') -ManifestJson 'not json' 6>$null | Should -Be 'ServiceTier/Service/Cronus.bclicense'
        Select-BcDevEnvArtifactLicenseEntry -EntryNames @('Cronus.flf', 'EULA.html') | Should -Be 'Cronus.flf'
    }

    It "fails when the artifact has no license" {
        { Select-BcDevEnvArtifactLicenseEntry -EntryNames @('manifest.json', 'EULA.html') -ManifestJson '{"licenseFile":"Other.bclicense"}' } |
            Should -Throw '*has no license entry (looked for: Other.bclicense, Cronus.bclicense, Cronus.flf)*'
    }
}

Describe "Get-BcDevEnvCrc32" {
    It "computes the standard CRC-32" {
        Get-BcDevEnvCrc32 -Bytes ([System.Text.Encoding]::ASCII.GetBytes('123456789')) | Should -Be 3421780262
        Get-BcDevEnvCrc32 -Bytes @() | Should -Be 0
    }
}

Describe "Get-BcDevEnvArtifactLicense" {
    BeforeAll {
        function New-ArtifactZip {
            param([System.Collections.Specialized.OrderedDictionary] $Entries, [int] $Fillers = 0)
            $path = Join-Path $TestDrive "artifact-$([guid]::NewGuid().ToString('N')).zip"
            $archive = [System.IO.Compression.ZipFile]::Open($path, [System.IO.Compression.ZipArchiveMode]::Create)
            for ($i = 0; $i -lt $Fillers; $i++) { $archive.CreateEntry(('filler/entry-{0:D5}-{1}.txt' -f $i, ('x' * 40))).Open().Dispose() }
            foreach ($name in $Entries.Keys) {
                $stream = $archive.CreateEntry($name, [System.IO.Compression.CompressionLevel]::Optimal).Open()
                $bytes = [byte[]]$Entries[$name]
                $stream.Write($bytes, 0, $bytes.Length)
                $stream.Dispose()
            }
            $archive.Dispose()
            return [System.IO.File]::ReadAllBytes($path)
        }

        $script:license = [System.Text.Encoding]::UTF8.GetBytes('<?xml version="1.0"?><License>' + ('CRONUS ' * 500) + '</License>')
        $random = New-Object System.Random 42
        $script:demoDatabase = [byte[]]::new(200000)
        $random.NextBytes($script:demoDatabase)
        $entries = [ordered]@{
            'Demo Database BC (30-0).bak' = $script:demoDatabase
            'Cronus.bclicense'            = $script:license
            'Master.bclicense'            = [System.Text.Encoding]::UTF8.GetBytes('master')
            'manifest.json'               = [System.Text.Encoding]::UTF8.GetBytes('{"version":"30.0.57476.0","licenseFile":"Cronus.bclicense"}')
        }
        $script:artifactZip = New-ArtifactZip -Entries $entries
        $script:largeDirectoryZip = New-ArtifactZip -Entries $entries -Fillers 1500
        $script:noLicenseZip = New-ArtifactZip -Entries ([ordered]@{ 'EULA.html' = [byte[]](1, 2, 3); 'manifest.json' = [System.Text.Encoding]::UTF8.GetBytes('{}') })
    }

    BeforeEach {
        Mock -ModuleName BcDevEnvPipeline Start-Sleep { }
        Mock -ModuleName BcDevEnvPipeline Invoke-WebRequest { throw 'The whole artifact must not be downloaded.' }
        $script:served = $script:artifactZip
        $script:rangeRequests = 0
        Mock -ModuleName BcDevEnvPipeline Invoke-BcDevEnvHttpRangeRequest {
            $script:rangeRequests++
            $all = $script:served
            if ($null -eq $From) { $start = [Math]::Max(0, $all.Length - $To); $end = $all.Length - 1 }
            else { $start = $From; $end = [Math]::Min($To, $all.Length - 1) }
            $count = $end - $start + 1
            $bytes = [byte[]]::new($count)
            [System.Array]::Copy($all, $start, $bytes, 0, $count)
            [pscustomobject]@{ Bytes = $bytes; Offset = [long]$start; Length = [long]$all.Length }
        }
        $destination = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    }

    It "reads only the manifest's license entry with range requests" {
        $path = Get-BcDevEnvArtifactLicense -ArtifactUrl 'https://example.test/sandbox/30.0.57476.0/base?sv=secret' -Destination $destination 6>$null
        $path | Should -Be (Join-Path $destination 'Cronus.bclicense')
        [System.IO.File]::ReadAllBytes($path) | Should -Be $script:license
        Should -Invoke -ModuleName BcDevEnvPipeline Invoke-WebRequest -Times 0 -Exactly
        @(Get-ChildItem -LiteralPath $destination).Count | Should -Be 1
    }

    It "fetches a central directory that does not fit in the tail range" {
        $script:served = $script:largeDirectoryZip
        $path = Get-BcDevEnvArtifactLicense -ArtifactUrl 'https://example.test/sandbox/30.0.57476.0/base' -Destination $destination 6>$null
        [System.IO.File]::ReadAllBytes($path) | Should -Be $script:license
        $script:rangeRequests | Should -Be 6
    }

    It "downloads the whole artifact when range requests fail, and deletes it afterwards" {
        Mock -ModuleName BcDevEnvPipeline Invoke-BcDevEnvHttpRangeRequest { throw [System.NotSupportedException]::new('HTTP 200') }
        Mock -ModuleName BcDevEnvPipeline Invoke-WebRequest { [System.IO.File]::WriteAllBytes($OutFile, $script:artifactZip) }
        $path = Get-BcDevEnvArtifactLicense -ArtifactUrl 'https://example.test/sandbox/30.0.57476.0/base' -Destination $destination 6>$null
        [System.IO.File]::ReadAllBytes($path) | Should -Be $script:license
        Should -Invoke -ModuleName BcDevEnvPipeline Invoke-WebRequest -Times 1 -Exactly
        @(Get-ChildItem -LiteralPath $destination | ForEach-Object { $_.Name }) | Should -Be @('Cronus.bclicense')
    }

    It "detects a corrupted entry by its CRC-32" {
        $directory = Get-BcDevEnvRemoteZipDirectory -Uri 'https://example.test/a'
        $entry = $directory.Entries | Where-Object { $_.Name -eq 'Master.bclicense' }
        $entry.Crc32 = $entry.Crc32 -bxor 1
        { Read-BcDevEnvRemoteZipEntry -Uri 'https://example.test/a' -Entry $entry } | Should -Throw "*'Master.bclicense' failed its CRC-32 check*"
    }

    It "fails without downloading the whole artifact when it has no license" {
        $script:served = $script:noLicenseZip
        { Get-BcDevEnvArtifactLicense -ArtifactUrl 'https://example.test/sandbox/30.0.57476.0/base' -Destination $destination 6>$null } | Should -Throw '*has no license entry*'
        Should -Invoke -ModuleName BcDevEnvPipeline Invoke-WebRequest -Times 0 -Exactly
    }
}

Describe "Initialize-BcDevEnvSqlServer" {
    BeforeEach {
        $script:marker = Join-Path $TestDrive "sql-installed-$([guid]::NewGuid().ToString('N')).txt"
        $installScript = Join-Path $TestDrive 'Install-SqlExpress.ps1'
        Set-Content -LiteralPath $installScript -Value "param([string] `$InstanceName) Set-Content -LiteralPath '$script:marker' -Value `$InstanceName"
        Mock -ModuleName BcDevEnvPipeline Get-Service { if (Test-Path -LiteralPath $script:marker) { [pscustomobject]@{ Name = $Name; Status = 'Running' } } }
        Mock -ModuleName BcDevEnvPipeline Set-Service { }
        Mock -ModuleName BcDevEnvPipeline Start-Service { }
        Mock -ModuleName BcDevEnvPipeline Restart-Service { }
        Mock -ModuleName BcDevEnvPipeline Get-CimInstance { @() }
        Mock -ModuleName BcDevEnvPipeline Set-Acl { }
        $previousHome = $env:BCDEVENV_HOME
    }

    AfterEach {
        $env:BCDEVENV_HOME = $previousHome
    }

    It "installs a missing instance with the install script" {
        Initialize-BcDevEnvSqlServer -Instance 'SQLEXPRESS' -DataHome (Join-Path $TestDrive 'home') -InstallScript $installScript 6>$null | Out-Null
        Get-Content -LiteralPath $script:marker | Should -Be 'SQLEXPRESS'
        Should -Invoke -ModuleName BcDevEnvPipeline Start-Service -ParameterFilter { $Name -eq 'MSSQL$SQLEXPRESS' }
    }

    It "fails clearly when the instance is missing and there is no install script" {
        { Initialize-BcDevEnvSqlServer -Instance 'SQLEXPRESS' -DataHome (Join-Path $TestDrive 'home') -InstallScript (Join-Path $TestDrive 'missing.ps1') } |
            Should -Throw "*service 'MSSQL`$SQLEXPRESS' not found and no SQL Server Express install script*"
    }
}

Describe "Install-SqlExpress.ps1" {
    BeforeAll {
        $installSqlExpress = Join-Path $PSScriptRoot '../../../bcdevenv/container/Install-SqlExpress.ps1'
        $installerBytes = [System.Text.Encoding]::ASCII.GetBytes('fake SQLEXPR installer')
        $installerSha256 = [System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash($installerBytes)).Replace('-', '')
    }

    BeforeEach {
        # The mocks run inside Install-SqlExpress.ps1, whose $script: scope is its own, so the state is a
        # hashtable that the mock bodies find through the dynamic scope chain.
        $sql = @{ SetupRuns = 0; SucceedsOnRun = 1; RegisteredAfterFailure = $false; Processes = [System.Collections.Generic.List[string]]::new() }
        $workFolder = Join-Path $TestDrive "sql-$([guid]::NewGuid().ToString('N'))"
        Mock Invoke-WebRequest { [System.IO.File]::WriteAllBytes($OutFile, $installerBytes) }
        Mock Start-Sleep { }
        Mock Set-Service { }
        Mock Start-Service { }
        # Never touch a real SQL Server installation of the machine that runs the tests.
        Mock Get-ChildItem { } -ParameterFilter { "$Path" -like '*Microsoft SQL Server*' }
        Mock Get-Service {
            if ($sql.SetupRuns -ge $sql.SucceedsOnRun -and $sql.SetupRuns -gt 0) {
                $service = [pscustomobject]@{ Name = $Name; Status = 'Running' }
                $service | Add-Member -MemberType ScriptMethod -Name WaitForStatus -Value { param($status, $timeout) }
                $service
            }
        }
        Mock Get-ItemProperty { if ($sql.RegisteredAfterFailure -and $sql.SetupRuns -gt 0) { [pscustomobject]@{ SQLEXPRESS = 'MSSQL16.SQLEXPRESS' } } }
        Mock Start-Process {
            $arguments = @($ArgumentList) -join ' '
            $sql.Processes.Add("$([System.IO.Path]::GetFileName($FilePath)) $arguments")
            if ($FilePath -like '*SQLEXPRADV_x64_ENU.exe') {
                $media = ($arguments -replace '^.*/x:"([^"]+)".*$', '$1')
                New-Item -ItemType Directory -Path $media -Force | Out-Null
                Set-Content -LiteralPath (Join-Path $media 'setup.exe') -Value 'setup'
            }
            elseif ($arguments -like '*/ACTION=Install*') { $sql.SetupRuns++ }
            [pscustomobject]@{ ExitCode = if ($arguments -like '*/ACTION=Install*') { -2061893607 } else { 0 } }
        }
    }

    It "leaves a running instance alone" {
        $sql.SetupRuns = 1
        & $installSqlExpress -WorkFolder $workFolder -InstallerSha256 $installerSha256 6>$null
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
        $sql.Processes.Count | Should -Be 0
        Should -Invoke Set-Service -Times 1 -Exactly -ParameterFilter { $Name -eq 'MSSQLFDLauncher$SQLEXPRESS' -and $StartupType -eq 'Automatic' }
    }

    It "warns when a running instance has no Full-Text Search service" {
        $sql.SetupRuns = 1
        Mock Get-Service { } -ParameterFilter { $Name -like 'MSSQLFDLauncher*' }
        $output = & $installSqlExpress -WorkFolder $workFolder -InstallerSha256 $installerSha256 6>&1 | Out-String
        $output | Should -BeLike "*Full-Text Search service 'MSSQLFDLauncher`$SQLEXPRESS' not found*"
        Should -Invoke Set-Service -Times 0 -Exactly
    }

    It "downloads, extracts and installs engine and Full-Text Search, judging success by the service and not by the exit code" {
        & $installSqlExpress -WorkFolder $workFolder -InstallerSha256 $installerSha256 6>$null
        $sql.Processes[0] | Should -BeLike 'SQLEXPRADV_x64_ENU.exe /Q /x:*'
        $sql.Processes[1] | Should -BeLike 'setup.exe /IACCEPTSQLSERVERLICENSETERMS /Q /ACTION=Install /FEATURES=SQLENGINE,FULLTEXT /INSTANCEID=SQLEXPRESS /INSTANCENAME=SQLEXPRESS*'
        $sql.Processes.Count | Should -Be 2
        Test-Path -LiteralPath $workFolder | Should -BeFalse
        Should -Invoke Set-Service -Times 1 -Exactly -ParameterFilter { $Name -eq 'MSSQLFDLauncher$SQLEXPRESS' -and $StartupType -eq 'Automatic' }
    }

    It "uninstalls a half-installed instance before retrying setup" {
        $sql.SucceedsOnRun = 2
        $sql.RegisteredAfterFailure = $true
        & $installSqlExpress -WorkFolder $workFolder -InstallerSha256 $installerSha256 6>$null
        $sql.SetupRuns | Should -Be 2
        $sql.Processes[2] | Should -Be 'setup.exe /Q /ACTION=Uninstall /FEATURES=SQLENGINE,FULLTEXT /INSTANCENAME=SQLEXPRESS'
        $sql.Processes[3] | Should -BeLike 'setup.exe /IACCEPTSQLSERVERLICENSETERMS * /ACTION=Install *'
    }

    It "fails after the last setup attempt when the service never runs" {
        $sql.SucceedsOnRun = 99
        { & $installSqlExpress -WorkFolder $workFolder -InstallerSha256 $installerSha256 -SetupAttempts 2 6>$null } |
            Should -Throw "*Installing SQL Server Express instance 'SQLEXPRESS' failed after 2 attempt(s) (last setup exit code -2061893607)*"
        $sql.SetupRuns | Should -Be 2
    }

    It "retries the download and rejects an installer with the wrong hash" {
        { & $installSqlExpress -WorkFolder $workFolder -InstallerSha256 ('0' * 64) -DownloadAttempts 2 6>$null } |
            Should -Throw '*Downloading SQL Server Express failed after 2 attempt(s)*expected 0000*'
        Should -Invoke Invoke-WebRequest -Times 2 -Exactly
    }
}

Describe "Workflow runner settings" {
    It "selects windows-2022 for the build jobs of <File> in BusinessCentralApps/BCApps" -TestCases @(
        @{ File = 'CICD.settings.json' }
        @{ File = 'Pull Request Build.settings.json' }
    ) {
        param($File)
        # AL-Go's ReadSettings matches the 'repositories' condition against the repository name without the owner,
        # and the workflow settings file is merged after the project settings (which set gitHubRunner: GitHub-BCAppsPL).
        $repoName = 'BusinessCentralApps/BCApps'
        $repoName = $repoName.Substring($repoName.LastIndexOf('/') + 1)
        $settings = Get-Content -Raw -Path (Join-Path $PSScriptRoot "../../../.github/$File") | ConvertFrom-Json
        $runners = @($settings.conditionalSettings | Where-Object {
            $_.PSObject.Properties.Name -contains 'repositories' -and
            $_.settings.PSObject.Properties.Name -contains 'gitHubRunner' -and
            @($_.repositories | Where-Object { $repoName -like $_ }).Count -gt 0
        } | ForEach-Object { $_.settings.gitHubRunner })
        $runners | Should -Be @('windows-2022')
    }
}
