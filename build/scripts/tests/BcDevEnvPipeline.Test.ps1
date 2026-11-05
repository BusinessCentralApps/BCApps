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
        "$warnings" | Should -BeLike "*licenseFileUrl*built-in license*"
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
