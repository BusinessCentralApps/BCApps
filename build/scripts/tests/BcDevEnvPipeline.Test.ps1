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

    It "plans UnitTest runs in an initialized company without demo data, with an isolated and an isolation-disabled pass" {
        $plan = Get-BcDevEnvPipelinePlan -Settings (New-TestSettings @{ testType = 'UnitTest'; companyName = 'Empty Company'; country = 'w1' })
        $plan.Action | Should -Be 'Test'
        $plan.CompanyName | Should -Be 'Empty Company'
        $plan.EvaluationCompany | Should -BeFalse
        $plan.CompanyCodeunits | Should -Be @('2')
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
        $plan.CompanyCodeunits | Should -Be @('2')
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
        $arguments | Should -Not -Contain '--executor'
    }

    It "appends the altool executor options after the selection options" {
        $app = [pscustomobject]@{ Id = 'aaaa'; Name = 'Library Tests' }
        $pass = [pscustomobject]@{ TestType = 'IntegrationTest'; Isolation = 'None'; RunnerId = 130450 }
        $arguments = Get-BcDevEnvRunTestsArguments -ODataUrl 'http://localhost:7048/BC/ODataV4' -CompanyName 'CRONUS' -App $app -Pass $pass -DisabledTestsRoots @('C:\d\0') -ResultFile 'C:\r\1.xml' `
            -Executor 'altool' -AlToolPath 'C:\altool\altool.dll' -DotnetPath 'C:\Program Files\dotnet\dotnet.exe' -DevPort 7049 -ServerInstance 'BC' -AppTimeoutMinutes 90
        ($arguments -join ' ') | Should -Be 'run-tests --odata-url http://localhost:7048/BC/ODataV4 --service-name BcDevEnvTestRunner --company CRONUS --protocol per-codeunit --extension aaaa --app-name Library Tests --disabled-tests C:\d\0 --test-type IntegrationTest --required-test-isolation None --test-runner-codeunit-id 130450 --result-file C:\r\1.xml --suite-name BusinessCentral --timeout-minutes 60 --allow-failures --allow-empty --executor altool --altool C:\altool\altool.dll --dotnet C:\Program Files\dotnet\dotnet.exe --dev-port 7049 --server-instance BC --app-timeout-minutes 90 --permissions-mock on'
        $arguments | Should -Contain 'C:\Program Files\dotnet\dotnet.exe'
    }

    It "passes --permissions-mock off to the altool executor only" {
        $app = [pscustomobject]@{ Id = 'i'; Name = 'n' }
        $pass = [pscustomobject]@{ TestType = ''; Isolation = ''; RunnerId = 130450 }
        $off = Get-BcDevEnvRunTestsArguments -ODataUrl 'u' -CompanyName 'c' -App $app -Pass $pass -ResultFile 'r' -Executor 'altool' -AlToolPath 'a.dll' -PermissionsMock $false
        ($off -join ' ') | Should -BeLike '* --permissions-mock off'
        $odata = Get-BcDevEnvRunTestsArguments -ODataUrl 'u' -CompanyName 'c' -App $app -Pass $pass -ResultFile 'r' -Executor 'odata' -PermissionsMock $false
        $odata | Should -Not -Contain '--permissions-mock'
    }

    It "passes --state-probe on to the altool executor only when the probe is switched on" {
        $app = [pscustomobject]@{ Id = 'i'; Name = 'n' }
        $pass = [pscustomobject]@{ TestType = ''; Isolation = ''; RunnerId = 130450 }
        $on = Get-BcDevEnvRunTestsArguments -ODataUrl 'u' -CompanyName 'c' -App $app -Pass $pass -ResultFile 'r' -Executor 'altool' -AlToolPath 'a.dll' -StateProbe $true
        ($on -join ' ') | Should -BeLike '* --permissions-mock on --state-probe on'
        $off = Get-BcDevEnvRunTestsArguments -ODataUrl 'u' -CompanyName 'c' -App $app -Pass $pass -ResultFile 'r' -Executor 'altool' -AlToolPath 'a.dll'
        $off | Should -Not -Contain '--state-probe'
        $odata = Get-BcDevEnvRunTestsArguments -ODataUrl 'u' -CompanyName 'c' -App $app -Pass $pass -ResultFile 'r' -Executor 'odata' -StateProbe $true
        $odata | Should -Not -Contain '--state-probe'
    }

    It "requires the AL tool path for the altool executor and rejects unknown executors" {
        $app = [pscustomobject]@{ Id = 'i'; Name = 'n' }
        $pass = [pscustomobject]@{ TestType = ''; Isolation = ''; RunnerId = 130450 }
        { Get-BcDevEnvRunTestsArguments -ODataUrl 'u' -CompanyName 'c' -App $app -Pass $pass -ResultFile 'r' -Executor 'altool' } | Should -Throw '*needs -AlToolPath*'
        { Get-BcDevEnvRunTestsArguments -ODataUrl 'u' -CompanyName 'c' -App $app -Pass $pass -ResultFile 'r' -Executor 'webclient' } | Should -Throw
    }
}

Describe "Get-BcDevEnvTestExecutorSettings" {
    It "defaults to the altool executor with the pinned AL tool version (not 30.0.42.60748-beta) and 240 minutes" {
        $executor = Get-BcDevEnvTestExecutorSettings -Settings (New-TestSettings)
        $executor.Executor | Should -Be 'altool'
        $executor.AlToolVersion | Should -Be '30.0.44.47290-beta'
        $executor.AppTimeoutMinutes | Should -Be 240
        $executor.PermissionsMock | Should -BeTrue
        $executor.StateProbe | Should -BeFalse
    }

    It "reads bcdevenvTestStateProbe (boolean or on/off) and lets a non-empty input override it" {
        (Get-BcDevEnvTestExecutorSettings -Settings (New-TestSettings @{ bcdevenvTestStateProbe = $true })).StateProbe | Should -BeTrue
        (Get-BcDevEnvTestExecutorSettings -Settings (New-TestSettings @{ bcdevenvTestStateProbe = 'ON' })).StateProbe | Should -BeTrue
        (Get-BcDevEnvTestExecutorSettings -Settings (New-TestSettings @{ bcdevenvTestStateProbe = $false })).StateProbe | Should -BeFalse
        (Get-BcDevEnvTestExecutorSettings -Settings (New-TestSettings @{ bcdevenvTestStateProbe = $true }) -StateProbe ' off ').StateProbe | Should -BeFalse
        (Get-BcDevEnvTestExecutorSettings -Settings (New-TestSettings @{ bcdevenvTestStateProbe = $false }) -StateProbe 'true').StateProbe | Should -BeTrue
        (Get-BcDevEnvTestExecutorSettings -Settings (New-TestSettings @{ bcdevenvTestStateProbe = $true }) -StateProbe '').StateProbe | Should -BeTrue
    }

    It "reads bcdevenvTestPermissionsMock (boolean or on/off) and lets a non-empty input override it" {
        (Get-BcDevEnvTestExecutorSettings -Settings (New-TestSettings @{ bcdevenvTestPermissionsMock = $false })).PermissionsMock | Should -BeFalse
        (Get-BcDevEnvTestExecutorSettings -Settings (New-TestSettings @{ bcdevenvTestPermissionsMock = 'Off' })).PermissionsMock | Should -BeFalse
        (Get-BcDevEnvTestExecutorSettings -Settings (New-TestSettings @{ bcdevenvTestPermissionsMock = $true })).PermissionsMock | Should -BeTrue
        (Get-BcDevEnvTestExecutorSettings -Settings (New-TestSettings @{ bcdevenvTestPermissionsMock = $false }) -PermissionsMock ' on ').PermissionsMock | Should -BeTrue
        (Get-BcDevEnvTestExecutorSettings -Settings (New-TestSettings @{ bcdevenvTestPermissionsMock = $true }) -PermissionsMock 'false').PermissionsMock | Should -BeFalse
        (Get-BcDevEnvTestExecutorSettings -Settings (New-TestSettings @{ bcdevenvTestPermissionsMock = $false }) -PermissionsMock '').PermissionsMock | Should -BeFalse
    }

    It "reads the bcdevenv settings and lets non-empty inputs override them" {
        $settings = New-TestSettings @{ bcdevenvTestExecutor = 'OData'; bcdevenvAlToolVersion = '30.0.45.1'; bcdevenvAppTestTimeoutMinutes = 30 }
        $fromSettings = Get-BcDevEnvTestExecutorSettings -Settings $settings
        $fromSettings.Executor | Should -Be 'odata'
        $fromSettings.AlToolVersion | Should -Be '30.0.45.1'
        $fromSettings.AppTimeoutMinutes | Should -Be 30
        $fromInputs = Get-BcDevEnvTestExecutorSettings -Settings $settings -Executor ' AlTool ' -AlToolVersion '31.0.1.2-preview.1' -AppTimeoutMinutes '15'
        $fromInputs.Executor | Should -Be 'altool'
        $fromInputs.AlToolVersion | Should -Be '31.0.1.2-preview.1'
        $fromInputs.AppTimeoutMinutes | Should -Be 15
        (Get-BcDevEnvTestExecutorSettings -Settings $settings -Executor '' -AlToolVersion '' -AppTimeoutMinutes '').Executor | Should -Be 'odata'
    }

    It "rejects <Case>" -TestCases @(
        @{ Case = 'an unknown executor'; Arguments = @{ Executor = 'webclient' }; Message = "*Unknown test executor 'webclient'*" }
        @{ Case = 'an invalid AL tool version'; Arguments = @{ AlToolVersion = 'latest' }; Message = "*Invalid AL tool version 'latest'*" }
        @{ Case = 'a version with a path'; Arguments = @{ AlToolVersion = '30.0.44.1/../x' }; Message = '*Invalid AL tool version*' }
        @{ Case = 'a zero timeout'; Arguments = @{ AppTimeoutMinutes = '0' }; Message = "*Invalid test timeout '0'*" }
        @{ Case = 'a non-numeric timeout'; Arguments = @{ AppTimeoutMinutes = 'abc' }; Message = "*Invalid test timeout 'abc'*" }
        @{ Case = 'an invalid permissions mock switch'; Arguments = @{ PermissionsMock = 'yes' }; Message = "*Invalid permissions mock setting 'yes'*" }
        @{ Case = 'an invalid state probe switch'; Arguments = @{ StateProbe = 'maybe' }; Message = "*Invalid state probe setting 'maybe'*" }
    ) {
        param($Case, $Arguments, $Message)
        { Get-BcDevEnvTestExecutorSettings -Settings (New-TestSettings) @Arguments } | Should -Throw $Message
    }
}

Describe "Get-BcDevEnvAlToolPackageUrl" {
    It "returns the lower-case nuget.org flat container URL" {
        Get-BcDevEnvAlToolPackageUrl -Version '30.0.44.47290-Beta' | Should -Be 'https://api.nuget.org/v3-flatcontainer/microsoft.dynamics.businesscentral.development.tools/30.0.44.47290-beta/microsoft.dynamics.businesscentral.development.tools.30.0.44.47290-beta.nupkg'
    }
}

Describe "Find-BcDevEnvAlToolFolder" {
    BeforeEach {
        $package = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        function New-AlToolFramework([string] $Framework) {
            $folder = Join-Path $package "tools\$Framework\any"
            New-Item -ItemType Directory -Path $folder -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $folder 'altool.dll') -Value 'x'
            return $folder
        }
    }

    It "prefers tools\net10.0\any" {
        New-AlToolFramework 'net8.0' | Out-Null
        $expected = New-AlToolFramework 'net10.0'
        Find-BcDevEnvAlToolFolder -PackageDir $package | Should -Be $expected
    }

    It "falls back to the highest framework" {
        New-AlToolFramework 'net8.0' | Out-Null
        $expected = New-AlToolFramework 'net9.0'
        New-Item -ItemType Directory -Path (Join-Path $package 'tools\net11.0\any') -Force | Out-Null
        Find-BcDevEnvAlToolFolder -PackageDir $package | Should -Be $expected
    }

    It "fails when the package has no altool.dll" {
        New-Item -ItemType Directory -Path (Join-Path $package 'lib') -Force | Out-Null
        { Find-BcDevEnvAlToolFolder -PackageDir $package } | Should -Throw '*altool.dll*was not found*'
    }
}

Describe "Get-BcDevEnvAlToolReadinessScript" {
    BeforeAll {
        $shell = (Get-Process -Id $PID).Path
        $alTool = Join-Path $TestDrive "Contoso's altool.dll"
        Set-Content -LiteralPath $alTool -Value 'x'
        function Invoke-Probe([string] $Script) {
            $output = & $shell -NoProfile -NonInteractive -EncodedCommand (ConvertTo-BcDevEnvEncodedScript -Script $Script) 2>&1
            return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output | Out-String) }
        }
    }

    It "produces a parseable script with quoted paths" {
        $script = Get-BcDevEnvAlToolReadinessScript -AlToolPath $alTool -DotnetPath 'C:\Program Files\dotnet\dotnet.exe' -Port 7049
        $tokens = $null; $errors = $null
        [System.Management.Automation.Language.Parser]::ParseInput($script, [ref]$tokens, [ref]$errors) | Out-Null
        @($errors).Count | Should -Be 0
        $script | Should -Match ([regex]::Escape("'C:\Program Files\dotnet\dotnet.exe'"))
        $script | Should -Match ([regex]::Escape("Contoso''s altool.dll"))
    }

    It "fails when the AL tool is missing" {
        $result = Invoke-Probe (Get-BcDevEnvAlToolReadinessScript -AlToolPath (Join-Path $TestDrive 'missing.dll') -DotnetPath $shell -Port 1 -Attempts 1 -DelaySeconds 0)
        $result.ExitCode | Should -Be 1
        $result.Output | Should -Match 'Not found in the container'
    }

    It "succeeds when the port accepts connections and fails when it does not" {
        $listener = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback, 0)
        $listener.Start()
        try {
            $port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
            $open = Invoke-Probe (Get-BcDevEnvAlToolReadinessScript -AlToolPath $alTool -DotnetPath $shell -Port $port -Attempts 2 -DelaySeconds 0)
            $open.ExitCode | Should -Be 0
            $open.Output | Should -Match "port $port\) accepts connections"
        }
        finally { $listener.Stop() }
        $closed = Invoke-Probe (Get-BcDevEnvAlToolReadinessScript -AlToolPath $alTool -DotnetPath $shell -Port $port -Attempts 2 -DelaySeconds 0)
        $closed.ExitCode | Should -Be 1
        $closed.Output | Should -Match 'did not accept connections'
    }
}

Describe "RunBcDevEnvPipeline action contract" {
    It "maps every action input passed to the script onto a script parameter, including the test executor inputs" {
        $actionFolder = Join-Path $PSScriptRoot '../../../.github/actions/RunBcDevEnvPipeline'
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $actionFolder 'RunBcDevEnvPipeline.ps1'), [ref]$tokens, [ref]$errors)
        @($errors).Count | Should -Be 0
        $parameters = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        $action = Get-Content -Raw -LiteralPath (Join-Path $actionFolder 'action.yaml')
        $mapped = @([regex]::Matches($action, '(?m)^\s+(\w+)\s+=\s+\$env:_(\w+)\s*$') | ForEach-Object {
            [pscustomobject]@{ Parameter = $_.Groups[1].Value; Env = $_.Groups[2].Value }
        })
        @($mapped | ForEach-Object { $_.Parameter }) | Should -Contain 'TestExecutor'
        @($mapped | ForEach-Object { $_.Parameter }) | Should -Contain 'AlToolVersion'
        @($mapped | ForEach-Object { $_.Parameter }) | Should -Contain 'AppTestTimeoutMinutes'
        @($mapped | ForEach-Object { $_.Parameter }) | Should -Contain 'TestPermissionsMock'
        @($mapped | ForEach-Object { $_.Parameter }) | Should -Contain 'TestStateProbe'
        foreach ($entry in $mapped) {
            $parameters | Should -Contain $entry.Parameter
            $action | Should -Match ('(?m)^  {0}:\s*$' -f [regex]::Escape($entry.Env))
            $action | Should -Match ('(?m)^\s+_{0}:\s+\$\{{\{{ inputs\.{0} \}}\}}' -f [regex]::Escape($entry.Env))
        }
    }
}

Describe "Set-BcDevEnvRunnerPermissionsMock" {
    BeforeEach {
        $appJson = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.json')
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot '../../../bcdevenv/testrunner/app.json') -Destination $appJson
        $original = Get-Content -LiteralPath $appJson -Raw
        $mock = New-ManifestObject -Id '40860557-a18d-42ad-aecb-22b7dd80dc80' -Name 'Permissions Mock' -Version '30.0.1.2'
        $other = New-ManifestObject -Id '11111111-1111-1111-1111-111111111111' -Name 'Other'
    }

    It "leaves app.json unchanged when Permissions Mock is not installed" {
        Set-BcDevEnvRunnerPermissionsMock -AppJsonPath $appJson -Apps @($other) | Should -BeNullOrEmpty
        Set-BcDevEnvRunnerPermissionsMock -AppJsonPath $appJson -Apps @() | Should -BeNullOrEmpty
        Get-Content -LiteralPath $appJson -Raw | Should -Be $original
        (Get-Content -LiteralPath $appJson -Raw | ConvertFrom-Json).PSObject.Properties['preprocessorSymbols'] | Should -BeNullOrEmpty
    }

    It "adds the dependency and the BCDEVENV_PERMISSIONSMOCK symbol once, keeping the other dependencies" {
        $before = @((Get-Content -LiteralPath $appJson -Raw | ConvertFrom-Json).dependencies)
        (Set-BcDevEnvRunnerPermissionsMock -AppJsonPath $appJson -Apps @($other, $mock)).Name | Should -Be 'Permissions Mock'
        Set-BcDevEnvRunnerPermissionsMock -AppJsonPath $appJson -Apps @($mock) | Out-Null
        $json = Get-Content -LiteralPath $appJson -Raw | ConvertFrom-Json
        @($json.preprocessorSymbols) | Should -Be @('BCDEVENV_PERMISSIONSMOCK')
        $dependencies = @($json.dependencies)
        $dependencies.Count | Should -Be ($before.Count + 1)
        foreach ($dependency in $before) { @($dependencies.id) | Should -Contain $dependency.id }
        $added = @($dependencies | Where-Object { $_.id -eq '40860557-a18d-42ad-aecb-22b7dd80dc80' })
        $added.Count | Should -Be 1
        $added[0].name | Should -Be 'Permissions Mock'
        $added[0].publisher | Should -Be 'Microsoft'
        $added[0].version | Should -Be '30.0.1.2'
    }

    It "replaces an existing Permissions Mock dependency with the installed version" {
        $json = Get-Content -LiteralPath $appJson -Raw | ConvertFrom-Json
        $json | Add-Member -NotePropertyName 'dependencies' -NotePropertyValue @([pscustomobject]@{ id = '40860557-a18d-42ad-aecb-22b7dd80dc80'; name = 'Permissions Mock'; publisher = 'Microsoft'; version = '1.0.0.0' }) -Force
        Set-Content -LiteralPath $appJson -Value ($json | ConvertTo-Json -Depth 10)
        Set-BcDevEnvRunnerPermissionsMock -AppJsonPath $appJson -Apps @($mock) | Out-Null
        $dependencies = @((Get-Content -LiteralPath $appJson -Raw | ConvertFrom-Json).dependencies)
        $dependencies.Count | Should -Be 1
        $dependencies[0].version | Should -Be '30.0.1.2'
    }
}

Describe "Set-BcDevEnvRunnerApplicationTestLibrary" {
    BeforeEach {
        $appJson = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.json')
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot '../../../bcdevenv/testrunner/app.json') -Destination $appJson
        $original = Get-Content -LiteralPath $appJson -Raw
        $mock = New-ManifestObject -Id '40860557-a18d-42ad-aecb-22b7dd80dc80' -Name 'Permissions Mock' -Version '30.0.1.2'
        $library = New-ManifestObject -Id 'd852d5d2-a39d-4179-baeb-f99a19e32510' -Name 'Application Test Library' -Version '30.0.3.4'
        $other = New-ManifestObject -Id '11111111-1111-1111-1111-111111111111' -Name 'Other'
    }

    It "leaves app.json unchanged without Application Test Library" {
        Set-BcDevEnvRunnerApplicationTestLibrary -AppJsonPath $appJson -Apps @($other, $mock) | Should -BeNullOrEmpty
        Set-BcDevEnvRunnerApplicationTestLibrary -AppJsonPath $appJson -Apps @() | Should -BeNullOrEmpty
        Get-Content -LiteralPath $appJson -Raw | Should -Be $original
    }

    It "adds the dependency and the BCDEVENV_APPTESTLIB symbol without Permissions Mock" {
        $before = @((Get-Content -LiteralPath $appJson -Raw | ConvertFrom-Json).dependencies)
        Set-BcDevEnvRunnerPermissionsMock -AppJsonPath $appJson -Apps @($other, $library) | Should -BeNullOrEmpty
        (Set-BcDevEnvRunnerApplicationTestLibrary -AppJsonPath $appJson -Apps @($other, $library)).Name | Should -Be 'Application Test Library'
        $json = Get-Content -LiteralPath $appJson -Raw | ConvertFrom-Json
        @($json.preprocessorSymbols) | Should -Be @('BCDEVENV_APPTESTLIB')
        @($json.dependencies).Count | Should -Be ($before.Count + 1)
        @($json.dependencies | Where-Object { $_.id -eq '40860557-a18d-42ad-aecb-22b7dd80dc80' }).Count | Should -Be 0
    }

    It "adds the dependency and the BCDEVENV_APPTESTLIB symbol once, next to the Permissions Mock ones" {
        $before = @((Get-Content -LiteralPath $appJson -Raw | ConvertFrom-Json).dependencies)
        Set-BcDevEnvRunnerPermissionsMock -AppJsonPath $appJson -Apps @($other, $library, $mock) | Out-Null
        (Set-BcDevEnvRunnerApplicationTestLibrary -AppJsonPath $appJson -Apps @($other, $library, $mock)).Name | Should -Be 'Application Test Library'
        Set-BcDevEnvRunnerApplicationTestLibrary -AppJsonPath $appJson -Apps @($library, $mock) | Out-Null
        $json = Get-Content -LiteralPath $appJson -Raw | ConvertFrom-Json
        @($json.preprocessorSymbols) | Should -Be @('BCDEVENV_PERMISSIONSMOCK', 'BCDEVENV_APPTESTLIB')
        $dependencies = @($json.dependencies)
        $dependencies.Count | Should -Be ($before.Count + 2)
        foreach ($dependency in $before) { @($dependencies.id) | Should -Contain $dependency.id }
        @($dependencies | Where-Object { $_.id -eq '40860557-a18d-42ad-aecb-22b7dd80dc80' }).Count | Should -Be 1
        $added = @($dependencies | Where-Object { $_.id -eq 'd852d5d2-a39d-4179-baeb-f99a19e32510' })
        $added.Count | Should -Be 1
        $added[0].name | Should -Be 'Application Test Library'
        $added[0].publisher | Should -Be 'Microsoft'
        $added[0].version | Should -Be '30.0.3.4'
    }
}

Describe "Set-BcDevEnvRunnerSystemApplicationTestLibrary" {
    BeforeEach {
        $appJson = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.json')
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot '../../../bcdevenv/testrunner/app.json') -Destination $appJson
        $original = Get-Content -LiteralPath $appJson -Raw
        $applicationLibrary = New-ManifestObject -Id 'd852d5d2-a39d-4179-baeb-f99a19e32510' -Name 'Application Test Library' -Version '30.0.3.4'
        $library = New-ManifestObject -Id '9856ae4f-d1a7-46ef-89bb-6ef056398228' -Name 'System Application Test Library' -Version '30.0.5.6'
        $other = New-ManifestObject -Id '11111111-1111-1111-1111-111111111111' -Name 'Other'
    }

    It "leaves app.json unchanged without System Application Test Library" {
        Set-BcDevEnvRunnerSystemApplicationTestLibrary -AppJsonPath $appJson -Apps @($other, $applicationLibrary) | Should -BeNullOrEmpty
        Set-BcDevEnvRunnerSystemApplicationTestLibrary -AppJsonPath $appJson -Apps @() | Should -BeNullOrEmpty
        Get-Content -LiteralPath $appJson -Raw | Should -Be $original
    }

    It "adds the dependency and the BCDEVENV_SYSAPPTESTLIB symbol once, next to the other ones" {
        $before = @((Get-Content -LiteralPath $appJson -Raw | ConvertFrom-Json).dependencies)
        Set-BcDevEnvRunnerApplicationTestLibrary -AppJsonPath $appJson -Apps @($other, $library, $applicationLibrary) | Out-Null
        (Set-BcDevEnvRunnerSystemApplicationTestLibrary -AppJsonPath $appJson -Apps @($other, $library, $applicationLibrary)).Name | Should -Be 'System Application Test Library'
        Set-BcDevEnvRunnerSystemApplicationTestLibrary -AppJsonPath $appJson -Apps @($library) | Out-Null
        $json = Get-Content -LiteralPath $appJson -Raw | ConvertFrom-Json
        @($json.preprocessorSymbols) | Should -Be @('BCDEVENV_APPTESTLIB', 'BCDEVENV_SYSAPPTESTLIB')
        $dependencies = @($json.dependencies)
        $dependencies.Count | Should -Be ($before.Count + 2)
        foreach ($dependency in $before) { @($dependencies.id) | Should -Contain $dependency.id }
        $added = @($dependencies | Where-Object { $_.id -eq '9856ae4f-d1a7-46ef-89bb-6ef056398228' })
        $added.Count | Should -Be 1
        $added[0].name | Should -Be 'System Application Test Library'
        $added[0].publisher | Should -Be 'Microsoft'
        $added[0].version | Should -Be '30.0.5.6'
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

Describe "t2embed.dll" {
    BeforeAll {
        function New-T2EmbedZip {
            param([System.Collections.Specialized.OrderedDictionary] $Entries)
            $path = Join-Path $TestDrive "install-$([guid]::NewGuid().ToString('N')).zip"
            $archive = [System.IO.Compression.ZipFile]::Open($path, [System.IO.Compression.ZipArchiveMode]::Create)
            foreach ($name in $Entries.Keys) {
                $stream = $archive.CreateEntry($name, [System.IO.Compression.CompressionLevel]::Optimal).Open()
                $bytes = [byte[]]$Entries[$name]
                $stream.Write($bytes, 0, $bytes.Length)
                $stream.Dispose()
            }
            $archive.Dispose()
            return [System.IO.File]::ReadAllBytes($path)
        }

        $random = New-Object System.Random 7
        $script:dll = [byte[]]::new(50000)
        $random.NextBytes($script:dll)
        $script:dll[0] = 0x4D
        $script:dll[1] = 0x5A
        $script:otherDll = [byte[]]$script:dll.Clone()
        $script:otherDll[2] = [byte](($script:otherDll[2] + 1) % 256)
        $filler = [byte[]]::new(300000)
        $random.NextBytes($filler)
        $script:installZip = New-T2EmbedZip -Entries ([ordered]@{
                'install/filler.bin'         = $filler
                'install/t2embed.dll'        = $script:dll
                'Run/navinstall.ps1'         = [System.Text.Encoding]::UTF8.GetBytes('# navinstall')
            })
        $script:noDllZip = New-T2EmbedZip -Entries ([ordered]@{ 'install/readme.txt' = [byte[]](1, 2, 3) })
        $script:notPeZip = New-T2EmbedZip -Entries ([ordered]@{ 'install/t2embed.dll' = [System.Text.Encoding]::UTF8.GetBytes('<html>not found</html>') })
    }

    BeforeEach {
        Mock -ModuleName BcDevEnvPipeline Start-Sleep { }
        Mock -ModuleName BcDevEnvPipeline Invoke-WebRequest { throw 'The whole archive must not be downloaded.' }
        $script:served = $script:installZip
        $script:rangeRequests = 0
        $script:rangeBytes = 0
        Mock -ModuleName BcDevEnvPipeline Invoke-BcDevEnvHttpRangeRequest {
            $script:rangeRequests++
            $all = $script:served
            if ($null -eq $From) { $start = [Math]::Max(0, $all.Length - $To); $end = $all.Length - 1 }
            else { $start = $From; $end = [Math]::Min($To, $all.Length - 1) }
            $count = $end - $start + 1
            $script:rangeBytes += $count
            $bytes = [byte[]]::new($count)
            [System.Array]::Copy($all, $start, $bytes, 0, $count)
            [pscustomobject]@{ Bytes = $bytes; Offset = [long]$start; Length = [long]$all.Length }
        }
        $destination = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    }

    It "selects install/t2embed.dll, else any t2embed.dll entry" {
        Select-BcDevEnvT2EmbedEntry -EntryNames @('other/t2embed.dll', 'Install/T2EMBED.DLL') | Should -Be 'Install/T2EMBED.DLL'
        Select-BcDevEnvT2EmbedEntry -EntryNames @('install\t2embed.dll') | Should -Be 'install\t2embed.dll'
        Select-BcDevEnvT2EmbedEntry -EntryNames @('readme.txt', 'x/y/T2Embed.dll') | Should -Be 'x/y/T2Embed.dll'
        Select-BcDevEnvT2EmbedEntry -EntryNames @('install/t2embed.dll.bak', 'install/readme.txt') | Should -BeNullOrEmpty
        Select-BcDevEnvT2EmbedEntry -EntryNames @() | Should -BeNullOrEmpty
    }

    It "resolves the URL from the input, else the setting, else nav-docker-install.zip" {
        Get-BcDevEnvT2EmbedUrl -Settings ([pscustomobject]@{}) | Should -Be 'https://bcartifacts-exdbf9fwegejdqak.b02.azurefd.net/prerequisites/nav-docker-install.zip'
        Get-BcDevEnvT2EmbedUrl -Settings $null -Url ' ' | Should -BeLike '*/prerequisites/nav-docker-install.zip'
        $settings = [pscustomobject]@{ bcdevenvT2EmbedUrl = 'https://mirror.test/install.zip' }
        Get-BcDevEnvT2EmbedUrl -Settings $settings | Should -Be 'https://mirror.test/install.zip'
        Get-BcDevEnvT2EmbedUrl -Settings $settings -Url ' https://input.test/t2embed.dll ' | Should -Be 'https://input.test/t2embed.dll'
        { Get-BcDevEnvT2EmbedUrl -Settings $null -Url 'C:\t2embed.dll' } | Should -Throw '*Invalid t2embed.dll URL*'
        { Get-BcDevEnvT2EmbedUrl -Settings ([pscustomobject]@{ bcdevenvT2EmbedUrl = 'install.zip' }) } | Should -Throw '*Invalid t2embed.dll URL*'
    }

    It "reads only the t2embed.dll entry with range requests" {
        $path = Get-BcDevEnvT2Embed -Url 'https://example.test/prerequisites/nav-docker-install.zip?sv=secret' -Destination $destination 6>$null
        $path | Should -Be (Join-Path $destination 't2embed.dll')
        [System.IO.File]::ReadAllBytes($path) | Should -Be $script:dll
        Should -Invoke -ModuleName BcDevEnvPipeline Invoke-WebRequest -Times 0 -Exactly
        $script:rangeRequests | Should -Be 3
        $script:rangeBytes | Should -BeLessThan ($script:installZip.Length / 2)
        @(Get-ChildItem -LiteralPath $destination | ForEach-Object { $_.Name }) | Should -Be @('t2embed.dll')
    }

    It "downloads the whole archive when range requests fail, and deletes it afterwards" {
        Mock -ModuleName BcDevEnvPipeline Invoke-BcDevEnvHttpRangeRequest { throw [System.NotSupportedException]::new('HTTP 200') }
        Mock -ModuleName BcDevEnvPipeline Invoke-WebRequest { [System.IO.File]::WriteAllBytes($OutFile, $script:installZip) }
        $path = Get-BcDevEnvT2Embed -Url 'https://example.test/prerequisites/nav-docker-install.zip' -Destination $destination 6>$null
        [System.IO.File]::ReadAllBytes($path) | Should -Be $script:dll
        Should -Invoke -ModuleName BcDevEnvPipeline Invoke-WebRequest -Times 1 -Exactly
        @(Get-ChildItem -LiteralPath $destination | ForEach-Object { $_.Name }) | Should -Be @('t2embed.dll')
    }

    It "downloads a .dll URL as is" {
        Mock -ModuleName BcDevEnvPipeline Invoke-WebRequest { [System.IO.File]::WriteAllBytes($OutFile, $script:otherDll) }
        $path = Get-BcDevEnvT2Embed -Url 'https://mirror.test/files/T2Embed.dll' -Destination $destination 6>$null
        [System.IO.File]::ReadAllBytes($path) | Should -Be $script:otherDll
        $script:rangeRequests | Should -Be 0
        Should -Invoke -ModuleName BcDevEnvPipeline Invoke-WebRequest -Times 1 -Exactly
    }

    It "fails without retrying or downloading the whole archive when it has no t2embed.dll" {
        $script:served = $script:noDllZip
        { Get-BcDevEnvT2Embed -Url 'https://example.test/install.zip' -Destination $destination 6>$null } | Should -Throw '*has no t2embed.dll entry*'
        Should -Invoke -ModuleName BcDevEnvPipeline Invoke-WebRequest -Times 0 -Exactly
        Should -Invoke -ModuleName BcDevEnvPipeline Start-Sleep -Times 0 -Exactly
    }

    It "rejects a payload that is not a DLL" {
        $script:served = $script:notPeZip
        { Get-BcDevEnvT2Embed -Url 'https://example.test/install.zip' -Destination $destination 6>$null } | Should -Throw '*not a Windows DLL*'
        Test-Path -LiteralPath (Join-Path $destination 't2embed.dll') | Should -BeFalse

        Mock -ModuleName BcDevEnvPipeline Invoke-WebRequest { [System.IO.File]::WriteAllBytes($OutFile, [System.Text.Encoding]::UTF8.GetBytes('<html/>')) }
        { Get-BcDevEnvT2Embed -Url 'https://mirror.test/t2embed.dll' -Destination $destination 6>$null } | Should -Throw '*not a Windows DLL*'
        Test-Path -LiteralPath (Join-Path $destination 't2embed.dll') | Should -BeFalse
    }
}

Describe "Initialize-BcDevEnvSqlServer" {
    BeforeEach {
        $script:marker = Join-Path $TestDrive "sql-installed-$([guid]::NewGuid().ToString('N')).txt"
        $script:diagnosticsMarker = Join-Path $TestDrive "sql-diagnostics-$([guid]::NewGuid().ToString('N')).txt"
        $installScript = Join-Path $TestDrive 'Install-SqlExpress.ps1'
        Set-Content -LiteralPath $installScript -Value @(
            'param([string] $InstanceName, [switch] $DiagnosticsOnly)'
            "if (`$DiagnosticsOnly) { Set-Content -LiteralPath '$script:diagnosticsMarker' -Value `$InstanceName; return }"
            "Set-Content -LiteralPath '$script:marker' -Value `$InstanceName"
        )
        Mock -ModuleName BcDevEnvPipeline Get-Service { if (Test-Path -LiteralPath $script:marker) { [pscustomobject]@{ Name = $Name; Status = 'Running' } } }
        Mock -ModuleName BcDevEnvPipeline Set-Service { }
        Mock -ModuleName BcDevEnvPipeline Start-Service { }
        Mock -ModuleName BcDevEnvPipeline Restart-Service { }
        Mock -ModuleName BcDevEnvPipeline Get-CimInstance { @() }
        Mock -ModuleName BcDevEnvPipeline Set-Acl { }
        Mock -ModuleName BcDevEnvPipeline fsutil { @('PhysicalBytesPerSectorForAtomicity :                    4096', 'PhysicalBytesPerSectorForPerformance :                  4096') }
        Mock -ModuleName BcDevEnvPipeline Get-ItemProperty { }
        Mock -ModuleName BcDevEnvPipeline Test-BcDevEnvSqlConnection { $true }
        $previousHome = $env:BCDEVENV_HOME
    }

    AfterEach {
        $env:BCDEVENV_HOME = $previousHome
    }

    It "installs a missing instance with the install script" {
        $dataHome = Join-Path $TestDrive 'home'
        $result = Initialize-BcDevEnvSqlServer -Instance 'SQLEXPRESS' -DataHome $dataHome -InstallScript $installScript 6>$null
        $result | Should -Be $dataHome
        $env:BCDEVENV_HOME | Should -Be $dataHome
        Get-Content -LiteralPath $script:marker | Should -Be 'SQLEXPRESS'
        Should -Invoke -ModuleName BcDevEnvPipeline Start-Service -ParameterFilter { $Name -eq 'MSSQL$SQLEXPRESS' }
    }

    It "moves the data home to the SQL Server data volume when its own volume reports a sector size above 4 KB" {
        Set-Content -LiteralPath $script:marker -Value 'installed'
        Mock -ModuleName BcDevEnvPipeline fsutil {
            $size = if ($args[2] -eq 'S:') { 4096 } else { 8192 }
            @("PhysicalBytesPerSectorForAtomicity :                    $size", "PhysicalBytesPerSectorForPerformance :                  $size", 'FileSystemEffectivePhysicalBytesPerSectorForAtomicity : 4096')
        }
        Mock -ModuleName BcDevEnvPipeline Get-ItemProperty { [pscustomobject]@{ SQLEXPRESS = 'MSSQL16.SQLEXPRESS' } } -ParameterFilter { $Path -like '*Instance Names\SQL' }
        Mock -ModuleName BcDevEnvPipeline Get-ItemProperty { [pscustomobject]@{ SQLDataRoot = 'S:\SQLData\MSSQL16.SQLEXPRESS\MSSQL' } } -ParameterFilter { $Path -like '*\MSSQL16.SQLEXPRESS\Setup' }
        Mock -ModuleName BcDevEnvPipeline New-Item { } -ParameterFilter { "$Path" -like 'S:\*' }
        Mock -ModuleName BcDevEnvPipeline Get-Acl { [System.Security.AccessControl.DirectorySecurity]::new() }
        $result = Initialize-BcDevEnvSqlServer -Instance 'SQLEXPRESS' -DataHome 'C:\bcdevenv-home\env1' -InstallScript $installScript 6>$null
        $result | Should -Be 'S:\bcdevenv-home\env1'
        $env:BCDEVENV_HOME | Should -Be 'S:\bcdevenv-home\env1'
        Should -Invoke -ModuleName BcDevEnvPipeline New-Item -Times 1 -Exactly -ParameterFilter { "$Path" -eq 'S:\bcdevenv-home\env1' }
    }

    It "keeps the data home when the SQL Server data root is on the same large-sector volume" {
        Set-Content -LiteralPath $script:marker -Value 'installed'
        $dataHome = Join-Path $TestDrive 'home'
        Mock -ModuleName BcDevEnvPipeline fsutil { @('PhysicalBytesPerSectorForAtomicity :                    8192', 'PhysicalBytesPerSectorForPerformance :                  8192') }
        $result = Initialize-BcDevEnvSqlServer -Instance 'SQLEXPRESS' -DataHome $dataHome -InstallScript $installScript 6>$null 3>$null
        $result | Should -Be $dataHome
    }

    It "fails clearly when the instance is missing and there is no install script" {
        { Initialize-BcDevEnvSqlServer -Instance 'SQLEXPRESS' -DataHome (Join-Path $TestDrive 'home') -InstallScript (Join-Path $TestDrive 'missing.ps1') } |
            Should -Throw "*service 'MSSQL`$SQLEXPRESS' not found and no SQL Server Express install script*"
    }

    It "fails with the instance's diagnostics when its service does not start again after enabling the network protocols" {
        Set-Content -LiteralPath $script:marker -Value 'installed'
        $script:protocol = [Microsoft.Management.Infrastructure.CimInstance]::new('ServerNetworkProtocol')
        foreach ($property in @{ InstanceName = 'SQLEXPRESS'; ProtocolName = 'Tcp'; Enabled = $false }.GetEnumerator()) {
            $script:protocol.CimInstanceProperties.Add([Microsoft.Management.Infrastructure.CimProperty]::Create($property.Key, $property.Value, [Microsoft.Management.Infrastructure.CimFlags]::None))
        }
        Mock -ModuleName BcDevEnvPipeline Get-CimInstance { [pscustomobject]@{ Name = 'ComputerManagement16' } } -ParameterFilter { $ClassName -eq '__NAMESPACE' }
        Mock -ModuleName BcDevEnvPipeline Get-CimInstance { $script:protocol } -ParameterFilter { $ClassName -eq 'ServerNetworkProtocol' }
        Mock -ModuleName BcDevEnvPipeline Invoke-CimMethod { }
        Mock -ModuleName BcDevEnvPipeline Restart-Service { throw "Failed to start service 'SQL Server (SQLEXPRESS) (MSSQL`$SQLEXPRESS)'." } -ParameterFilter { $Name -eq 'MSSQL$SQLEXPRESS' }
        Mock -ModuleName BcDevEnvPipeline Test-BcDevEnvSqlConnection { $false }
        { Initialize-BcDevEnvSqlServer -Instance 'SQLEXPRESS' -DataHome (Join-Path $TestDrive 'home') -InstallScript $installScript 6>$null 3>$null } |
            Should -Throw "*SQL Server 'localhost\SQLEXPRESS' is not usable: restarting its service after enabling the network protocols failed: Failed to start service 'SQL Server (SQLEXPRESS)*"
        Should -Invoke -ModuleName BcDevEnvPipeline Invoke-CimMethod -Times 1 -Exactly
        Get-Content -LiteralPath $script:diagnosticsMarker | Should -Be 'SQLEXPRESS'
        $env:BCDEVENV_HOME | Should -Be $previousHome
    }

    It "fails with the instance's diagnostics when a running instance does not accept a connection" {
        Set-Content -LiteralPath $script:marker -Value 'installed'
        Mock -ModuleName BcDevEnvPipeline Test-BcDevEnvSqlConnection { $false }
        { Initialize-BcDevEnvSqlServer -Instance 'SQLEXPRESS' -DataHome (Join-Path $TestDrive 'home') -InstallScript $installScript 6>$null } |
            Should -Throw "*SQL Server 'localhost\SQLEXPRESS' is not usable: it does not accept a shared-memory connection*"
        Test-Path -LiteralPath $script:diagnosticsMarker | Should -BeTrue
    }
}

Describe "Test-BcDevEnvSqlConnection" {
    It "connects over shared memory and runs SELECT 1, retrying until the instance serves" {
        $script:connection = @{ Opens = 0; Strings = [System.Collections.Generic.List[string]]::new(); Queries = [System.Collections.Generic.List[string]]::new() }
        Mock -ModuleName BcDevEnvPipeline Start-Sleep { }
        Mock -ModuleName BcDevEnvPipeline New-Object {
            $script:connection.Strings.Add([string] @($ArgumentList)[0])
            $fake = [pscustomobject]@{ }
            $fake | Add-Member -MemberType ScriptMethod -Name Open -Value {
                $script:connection.Opens++
                if ($script:connection.Opens -lt 2) { throw 'A network-related or instance-specific error occurred (provider: Shared Memory Provider, error: 40)' }
            }
            $fake | Add-Member -MemberType ScriptMethod -Name CreateCommand -Value {
                $command = [pscustomobject]@{ CommandText = '' }
                $command | Add-Member -MemberType ScriptMethod -Name ExecuteScalar -Value { $script:connection.Queries.Add($this.CommandText); 1 }
                $command
            }
            $fake | Add-Member -MemberType ScriptMethod -Name Dispose -Value { }
            $fake
        } -ParameterFilter { $TypeName -eq 'System.Data.SqlClient.SqlConnection' }
        Test-BcDevEnvSqlConnection -Instance 'SQLEXPRESS' -Attempts 3 | Should -BeTrue
        $script:connection.Opens | Should -Be 2
        $script:connection.Strings[0] | Should -BeLike 'Data Source=lpc:.\SQLEXPRESS;Integrated Security=True;*'
        @($script:connection.Queries) | Should -Be @('SELECT 1')
        Should -Invoke -ModuleName BcDevEnvPipeline Start-Sleep -Times 1 -Exactly
    }

    It "returns false for an instance that does not exist" {
        Test-BcDevEnvSqlConnection -Instance 'BCDEVENVNOTEXISTING' -Attempts 1 6>$null | Should -BeFalse
    }
}

Describe "Get-BcDevEnvVolumeSectorSize" {
    It "returns the larger physical sector size of the path's volume and ignores the file system's effective size" {
        Mock -ModuleName BcDevEnvPipeline fsutil {
            @('LogicalBytesPerSector :                                 512',
              'PhysicalBytesPerSectorForAtomicity :                    4096',
              'PhysicalBytesPerSectorForPerformance :                  8192',
              'FileSystemEffectivePhysicalBytesPerSectorForAtomicity : 16384')
        }
        Get-BcDevEnvVolumeSectorSize -Path 'D:\a\BCApps' | Should -Be 8192
        Should -Invoke -ModuleName BcDevEnvPipeline fsutil -Times 1 -Exactly -ParameterFilter { ($args -join ' ') -eq 'fsinfo sectorinfo D:' }
    }

    It "returns 0 when fsutil does not report the sector size" {
        Mock -ModuleName BcDevEnvPipeline fsutil { 'Error:  The system cannot find the path specified.' }
        Get-BcDevEnvVolumeSectorSize -Path 'Q:\missing' | Should -Be 0
    }
}

Describe "Install-SqlExpress.ps1" {
    BeforeAll {
        $installSqlExpress = Join-Path $PSScriptRoot '../../../bcdevenv/container/Install-SqlExpress.ps1'
        $installerBytes = [System.Text.Encoding]::ASCII.GetBytes('fake SQLEXPR installer')
        $installerSha256 = [System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash($installerBytes)).Replace('-', '')
        $systemDrive = [System.IO.Path]::GetPathRoot($env:ProgramFiles).TrimEnd('\')
    }

    BeforeEach {
        # The mocks run inside Install-SqlExpress.ps1, whose $script: scope is its own, so the state is a
        # hashtable that the mock bodies find through the dynamic scope chain.
        # ExitCodes: setup's exit code per install run (default 0); the service runs from run SucceedsOnRun
        # and the engine accepts connections from run ConnectsFromRun.
        $sql = @{ SetupRuns = 0; SucceedsOnRun = 1; ConnectsFromRun = 1; Connects = 0; ExitCodes = @{ }; RegisteredAfterFailure = $false
            Processes = [System.Collections.Generic.List[string]]::new(); ConnectionStrings = [System.Collections.Generic.List[string]]::new()
            Sectors = @{ $systemDrive = 4096 }; VirtualDiskWorks = $true; DiskPart = [System.Collections.Generic.List[string]]::new() }
        $workFolder = Join-Path $TestDrive "sql-$([guid]::NewGuid().ToString('N'))"
        Mock Invoke-WebRequest { [System.IO.File]::WriteAllBytes($OutFile, $installerBytes) }
        Mock Start-Sleep { }
        Mock Set-Service { }
        Mock Start-Service { }
        Mock Get-WinEvent { }
        # Never touch a real SQL Server installation or disk of the machine that runs the tests.
        Mock Get-ChildItem { } -ParameterFilter { "$Path" -like '*Microsoft SQL Server*' -or "$Path" -like '*SQLData*' -or "$Path" -like '*SQLServer*' }
        Mock New-Object {
            $sql.Connects++
            $sql.ConnectionStrings.Add([string] @($ArgumentList)[0])
            $fake = [pscustomobject]@{ }
            if ($sql.SetupRuns -ge $sql.ConnectsFromRun) {
                $fake | Add-Member -MemberType ScriptMethod -Name Open -Value { }
            }
            else {
                $fake | Add-Member -MemberType ScriptMethod -Name Open -Value { throw 'A network-related or instance-specific error occurred while establishing a connection to SQL Server. (provider: Shared Memory Provider, error: 40 - Could not open a connection to SQL Server)' }
            }
            $fake | Add-Member -MemberType ScriptMethod -Name CreateCommand -Value {
                $command = [pscustomobject]@{ CommandText = '' }
                $command | Add-Member -MemberType ScriptMethod -Name ExecuteScalar -Value { if ($this.CommandText -ne 'SELECT 1') { throw "unexpected query '$($this.CommandText)'" }; 1 }
                $command
            }
            $fake | Add-Member -MemberType ScriptMethod -Name Dispose -Value { }
            $fake
        } -ParameterFilter { $TypeName -eq 'System.Data.SqlClient.SqlConnection' }
        Mock Get-PSDrive { @('C', 'D', 'S') | ForEach-Object { [pscustomobject]@{ Name = $_ } } }
        Mock fsutil {
            $size = $sql.Sectors[[string] $args[2]]
            if ($size) { @("PhysicalBytesPerSectorForAtomicity :                    $size", "PhysicalBytesPerSectorForPerformance :                  $size", 'FileSystemEffectivePhysicalBytesPerSectorForAtomicity : 4096') }
            else { 'Error:  The system cannot find the path specified.' }
        }
        Mock diskpart {
            $commands = @(Get-Content -LiteralPath $args[1])
            $sql.DiskPart.Add($commands -join '; ')
            foreach ($command in $commands) {
                if ($sql.VirtualDiskWorks -and $command -match '^assign letter=(\w)$') { $sql.Sectors["$($Matches[1]):"] = 4096 }
            }
        }
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
            $exitCode = 0
            if ($arguments -like '*/ACTION=Install*' -and $sql.ExitCodes.ContainsKey($sql.SetupRuns)) { $exitCode = $sql.ExitCodes[$sql.SetupRuns] }
            [pscustomobject]@{ ExitCode = $exitCode }
        }
        # Runs the script and returns its host output, also when it throws (the error is in $thrown).
        function Invoke-InstallSqlExpress([hashtable] $Parameters = @{ }) {
            $lines = [System.Collections.Generic.List[string]]::new()
            $script:thrown = ''
            try { & $installSqlExpress -WorkFolder $workFolder -InstallerSha256 $installerSha256 @Parameters 6>&1 | ForEach-Object { $lines.Add([string] $_) } }
            catch { $script:thrown = $_.Exception.Message }
            return ($lines -join "`n")
        }
    }

    It "leaves a running instance alone that accepts connections" {
        $sql.SetupRuns = 1
        & $installSqlExpress -WorkFolder $workFolder -InstallerSha256 $installerSha256 6>$null
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
        $sql.Processes.Count | Should -Be 0
        $sql.Connects | Should -Be 1
        $sql.ConnectionStrings[0] | Should -BeLike 'Data Source=lpc:.\SQLEXPRESS;Integrated Security=True;*'
        Should -Invoke Set-Service -Times 1 -Exactly -ParameterFilter { $Name -eq 'MSSQLFDLauncher$SQLEXPRESS' -and $StartupType -eq 'Automatic' }
    }

    It "installs again a running instance that does not accept connections" {
        $sql.SetupRuns = 1
        $sql.ConnectsFromRun = 2
        $output = Invoke-InstallSqlExpress @{ ConnectionTimeoutSeconds = 10 }
        $script:thrown | Should -BeNullOrEmpty
        $output | Should -BeLike "*SQL Server instance 'SQLEXPRESS' runs but does not accept connections; installing it again.*"
        $sql.Processes | Should -Contain 'setup.exe /Q /ACTION=Uninstall /FEATURES=SQLENGINE,FULLTEXT /INSTANCENAME=SQLEXPRESS'
        $sql.SetupRuns | Should -Be 2
        $output | Should -BeLike "*SQL Server Express instance 'SQLEXPRESS' is installed, running and accepting connections.*"
    }

    It "warns when a running instance has no Full-Text Search service" {
        $sql.SetupRuns = 1
        Mock Get-Service { } -ParameterFilter { $Name -like 'MSSQLFDLauncher*' }
        $output = & $installSqlExpress -WorkFolder $workFolder -InstallerSha256 $installerSha256 6>&1 | Out-String
        $output | Should -BeLike "*Full-Text Search service 'MSSQLFDLauncher`$SQLEXPRESS' not found*"
        Should -Invoke Set-Service -Times 0 -Exactly
    }

    It "downloads, extracts and installs engine and Full-Text Search, and checks that the engine accepts a connection" {
        & $installSqlExpress -WorkFolder $workFolder -InstallerSha256 $installerSha256 6>$null
        $sql.Processes[0] | Should -BeLike 'SQLEXPRADV_x64_ENU.exe /Q /x:*'
        $sql.Processes[1] | Should -BeLike 'setup.exe /IACCEPTSQLSERVERLICENSETERMS /Q /ACTION=Install /FEATURES=SQLENGINE,FULLTEXT /INSTANCEID=SQLEXPRESS /INSTANCENAME=SQLEXPRESS*'
        $sql.Processes.Count | Should -Be 2
        $sql.Connects | Should -Be 1
        Test-Path -LiteralPath $workFolder | Should -BeFalse
        Should -Invoke Set-Service -Times 1 -Exactly -ParameterFilter { $Name -eq 'MSSQLFDLauncher$SQLEXPRESS' -and $StartupType -eq 'Automatic' }
        $sql.Processes[1] | Should -Not -BeLike '*/INSTANCEDIR*'
        $sql.Processes[1] | Should -Not -BeLike '*/INSTALLSQLDATADIR*'
        Should -Invoke diskpart -Times 0 -Exactly
    }

    It "accepts setup's exit code 3010 (success, a reboot is required)" {
        $sql.ExitCodes[1] = 3010
        $output = Invoke-InstallSqlExpress
        $script:thrown | Should -BeNullOrEmpty
        $output | Should -BeLike '*SQL Server setup exited with code 3010 (0x00000BC2: success, a reboot is required).*'
        $sql.SetupRuns | Should -Be 1
    }

    It "fails an attempt whose setup exits with 0x851A001A although the service runs, prints the diagnostics and retries" {
        $sql.ExitCodes[1] = -2061893606
        $summary = Join-Path $TestDrive 'Summary.txt'
        Set-Content -LiteralPath $summary -Value 'Exit message: Wait on the Database Engine recovery handle failed.'
        $errorLog = Join-Path $TestDrive 'ERRORLOG'
        Set-Content -LiteralPath $errorLog -Value 'Error: 5178, Severity: 16, State: 1. Cannot use file ... sector size 4096 ... 8192.'
        Mock Get-ChildItem { Get-Item -LiteralPath $summary } -ParameterFilter { "$Path" -like '*\Setup Bootstrap\Log\Summary.txt' }
        Mock Get-ChildItem { Get-Item -LiteralPath $errorLog } -ParameterFilter { "$Path" -like '*\Microsoft SQL Server\MSSQL*.SQLEXPRESS\MSSQL\Log\ERRORLOG' }
        Mock Get-WinEvent { [pscustomobject]@{ TimeCreated = [datetime] '2026-01-02T03:04:05'; Id = 17204; Message = "FCB::Open failed:`r`n Could not open file master.mdf" } }
        $output = Invoke-InstallSqlExpress
        $script:thrown | Should -BeNullOrEmpty
        $output | Should -BeLike "*SQL Server setup attempt 1 of 3 for instance 'SQLEXPRESS' failed: setup exited with code -2061893606 (0x851A001A: Wait on the Database Engine recovery handle failed), although the service 'MSSQL`$SQLEXPRESS' runs.*"
        $output | Should -BeLike '*Exit message: Wait on the Database Engine recovery handle failed.*'
        $output | Should -BeLike '*Error: 5178, Severity: 16*'
        $output | Should -BeLike '*2026-01-02T03:04:05 event 17204: FCB::Open failed: Could not open file master.mdf*'
        # The service of the failed attempt runs, so the instance is uninstalled before the second attempt, which succeeds.
        $sql.SetupRuns | Should -Be 2
        $sql.Processes | Should -Contain 'setup.exe /Q /ACTION=Uninstall /FEATURES=SQLENGINE,FULLTEXT /INSTANCENAME=SQLEXPRESS'
        # A failed exit code fails the attempt without trying to connect.
        $sql.Connects | Should -Be 1
        $output | Should -BeLike "*SQL Server Express instance 'SQLEXPRESS' is installed, running and accepting connections.*"
    }

    It "fails an attempt whose instance runs after setup exits with 0 but does not accept a connection" {
        $sql.ConnectsFromRun = 99
        $output = Invoke-InstallSqlExpress @{ SetupAttempts = 1; ConnectionTimeoutSeconds = 20 }
        $script:thrown | Should -BeLike "Installing SQL Server Express instance 'SQLEXPRESS' failed after 1 attempt(s) (last attempt: the service 'MSSQL`$SQLEXPRESS' runs, but the engine does not accept a connection); see the setup diagnostics above."
        $output | Should -BeLike "*does not accept a connection (2 attempt(s)): A network-related or instance-specific error occurred*"
        $output | Should -BeLike "*No setup summary (Summary.txt) found under*"
        $output | Should -BeLike "*No ERRORLOG of instance 'SQLEXPRESS' found*"
        $sql.Connects | Should -Be 2
    }

    It "prints the diagnostics without downloading or installing with -DiagnosticsOnly" {
        $summary = Join-Path $TestDrive 'Summary.txt'
        Set-Content -LiteralPath $summary -Value 'Overall summary: Failed'
        Mock Get-ChildItem { Get-Item -LiteralPath $summary } -ParameterFilter { "$Path" -like '*\Setup Bootstrap\Log\Summary.txt' }
        $output = Invoke-InstallSqlExpress @{ DiagnosticsOnly = $true }
        $script:thrown | Should -BeNullOrEmpty
        $output | Should -BeLike '*Overall summary: Failed*'
        $output | Should -BeLike "*SQL Server instance 'SQLEXPRESS' is not registered.*"
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
        $sql.Processes.Count | Should -Be 0
        $sql.Connects | Should -Be 0
    }

    It "puts the instance and its data files on a 4 KB virtual disk when the Program Files volume reports a larger sector size" {
        $sql.Sectors[$systemDrive] = 8192
        $vhdx = Join-Path $TestDrive 'sqldata.vhdx'
        & $installSqlExpress -WorkFolder $workFolder -InstallerSha256 $installerSha256 -VirtualDiskPath $vhdx 6>$null
        $sql.DiskPart.Count | Should -Be 1
        $sql.DiskPart[0] | Should -Be "create vdisk file=`"$vhdx`" maximum=131072 type=expandable; select vdisk file=`"$vhdx`"; attach vdisk; create partition primary; format fs=ntfs quick label=`"bcdevenv-sql`"; assign letter=T"
        $sql.Processes[1] | Should -BeLike '* /ACTION=Install * /INSTANCEDIR="T:\SQLServer" /INSTALLSQLDATADIR="T:\SQLData"'
        $sql.SetupRuns | Should -Be 1
    }

    It "names the 8 KB-sector workaround in the error when setup fails on the virtual disk, with the ERRORLOG of its data directory" {
        $sql.Sectors[$systemDrive] = 8192
        $sql.ExitCodes[1] = -2061893606
        $vhdx = Join-Path $TestDrive 'sqldata.vhdx'
        $errorLog = Join-Path $TestDrive 'ERRORLOG'
        Set-Content -LiteralPath $errorLog -Value 'Error: 17204, Severity: 16, State: 1. FCB::Open failed'
        Mock Get-ChildItem { Get-Item -LiteralPath $errorLog } -ParameterFilter { "$Path" -like 'T:\SQLData\MSSQL*.SQLEXPRESS\MSSQL\Log\ERRORLOG' }
        $output = Invoke-InstallSqlExpress @{ VirtualDiskPath = $vhdx; SetupAttempts = 1 }
        $script:thrown | Should -BeLike "Installing SQL Server Express instance 'SQLEXPRESS' failed after 1 attempt(s) (last attempt: setup exited with code -2061893606 (0x851A001A: Wait on the Database Engine recovery handle failed), although the service 'MSSQL`$SQLEXPRESS' runs); see the setup diagnostics above. Note: the 8 KB-sector workaround was active: the volume of '*' reports 8192-byte physical sectors, so the instance ('T:\SQLServer') and its data files ('T:\SQLData') were put on the virtual disk volume T: (4096-byte sectors, '*sqldata.vhdx')."
        $output | Should -BeLike '*Error: 17204, Severity: 16*'
        $output | Should -BeLike "*Physical sector size of the volume of 'T:\SQLServer': 4096 bytes.*"
        $output | Should -BeLike "*Physical sector size of the volume of '*Microsoft SQL Server': 8192 bytes.*"
    }

    It "installs with the default data folder when the virtual disk cannot be created" {
        $sql.Sectors[$systemDrive] = 8192
        $sql.VirtualDiskWorks = $false
        $output = & $installSqlExpress -WorkFolder $workFolder -InstallerSha256 $installerSha256 -VirtualDiskPath (Join-Path $TestDrive 'sqldata.vhdx') 6>&1 | Out-String
        $output | Should -BeLike '*physical sector size of 8192 bytes*'
        $output | Should -BeLike '*WARNING: The SQL Server volume could not be created; installing with the default folders*'
        $sql.Processes[1] | Should -BeLike '* /ACTION=Install *'
        $sql.Processes[1] | Should -Not -BeLike '*/INSTANCEDIR*'
        $sql.Processes[1] | Should -Not -BeLike '*/INSTALLSQLDATADIR*'
    }

    It "uses an explicit data directory without probing the disk" {
        $sql.Sectors[$systemDrive] = 8192
        & $installSqlExpress -WorkFolder $workFolder -InstallerSha256 $installerSha256 -DataDirectory 'E:\SqlData' 6>$null
        $sql.Processes[1] | Should -BeLike '* /INSTALLSQLDATADIR="E:\SqlData"'
        $sql.Processes[1] | Should -Not -BeLike '*/INSTANCEDIR*'
        Should -Invoke diskpart -Times 0 -Exactly
    }

    It "passes an explicit instance directory to setup" {
        & $installSqlExpress -WorkFolder $workFolder -InstallerSha256 $installerSha256 -InstanceDirectory 'E:\SqlServer' 6>$null
        $sql.Processes[1] | Should -BeLike '* /UPDATEENABLED=FALSE /INSTANCEDIR="E:\SqlServer"'
    }

    It "uninstalls a half-installed instance before retrying setup" {
        $sql.SucceedsOnRun = 2
        $sql.ExitCodes[1] = -2061893607
        $sql.RegisteredAfterFailure = $true
        & $installSqlExpress -WorkFolder $workFolder -InstallerSha256 $installerSha256 6>$null
        $sql.SetupRuns | Should -Be 2
        $sql.Processes[2] | Should -Be 'setup.exe /Q /ACTION=Uninstall /FEATURES=SQLENGINE,FULLTEXT /INSTANCENAME=SQLEXPRESS'
        $sql.Processes[3] | Should -BeLike 'setup.exe /IACCEPTSQLSERVERLICENSETERMS * /ACTION=Install *'
    }

    It "fails after the last setup attempt when the service never runs" {
        $sql.SucceedsOnRun = 99
        { & $installSqlExpress -WorkFolder $workFolder -InstallerSha256 $installerSha256 -SetupAttempts 2 6>$null } |
            Should -Throw "*Installing SQL Server Express instance 'SQLEXPRESS' failed after 2 attempt(s) (last attempt: the service 'MSSQL`$SQLEXPRESS' does not run); see the setup diagnostics above."
        $sql.SetupRuns | Should -Be 2
        $sql.Connects | Should -Be 0
    }

    It "reports setup's failing exit code when the service never runs" {
        $sql.SucceedsOnRun = 99
        $sql.ExitCodes[1] = -2061893607
        { & $installSqlExpress -WorkFolder $workFolder -InstallerSha256 $installerSha256 -SetupAttempts 1 6>$null } |
            Should -Throw "*(last attempt: setup exited with code -2061893607 (0x851A0019: Could not find the Database Engine startup handle)); see the setup diagnostics above."
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
