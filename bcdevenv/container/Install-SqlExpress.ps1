<#
.SYNOPSIS
    Installs a SQL Server Express instance (engine + Full-Text Search) from Microsoft's download, with retries.
.DESCRIPTION
    Used by the bcdevenv image (Dockerfile) and by the BCApps CI pipeline on the runner
    (build/scripts/BcDevEnvPipeline.psm1, Initialize-BcDevEnvSqlServer). It replaces
    'choco install sql-server-express', which depends on the Chocolatey feed and reported success
    when the feed failed. The Express with Advanced Services media (SQLEXPRADV) is used because BC
    creates text-optimized (full-text) indexes when a company is created; the basic SQLEXPR media
    has no Full-Text Search. Success is judged by the instance's service existing and starting, not by
    exit codes:
      - the installer is downloaded with retries and checked against its SHA256 hash;
      - setup is retried; a failed attempt prints the setup summary and the instance's ERRORLOG,
        and a half-installed instance is uninstalled before the next attempt.
    An instance whose service already exists and starts is left alone (a warning is printed when it
    has no Full-Text Search).
    Runs in Windows PowerShell 5.1 and PowerShell 7.
#>
[CmdletBinding()]
param(
    [string] $InstanceName = 'SQLEXPRESS',
    [string] $InstallerUrl = 'https://download.microsoft.com/download/3/8/d/38de7036-2433-4207-8eae-06e247e17b25/SQLEXPRADV_x64_ENU.exe',
    [string] $InstallerSha256 = '825B35D59DCADAF6EC5F086727B0032F239486DE8F9187B15DDAECAEE6E081FA',
    [string] $Features = 'SQLENGINE,FULLTEXT',
    [string] $WorkFolder = (Join-Path ([System.IO.Path]::GetTempPath()) 'bcdevenv-sqlexpress'),
    [ValidateRange(1, 10)] [int] $SetupAttempts = 3,
    [ValidateRange(1, 20)] [int] $DownloadAttempts = 5,
    [ValidateRange(0, 600)] [int] $RetryDelaySeconds = 15
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Version 2.0
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$serviceName = if ($InstanceName -eq 'MSSQLSERVER') { 'MSSQLSERVER' } else { "MSSQL`$$InstanceName" }
$fullTextServiceName = if ($InstanceName -eq 'MSSQLSERVER') { 'MSSQLFDLauncher' } else { "MSSQLFDLauncher`$$InstanceName" }

function Start-FullTextService {
    $service = Get-Service -Name $fullTextServiceName -ErrorAction SilentlyContinue
    if ($null -eq $service) {
        Write-Host "SQL Server Full-Text Search service '$fullTextServiceName' not found; company creation in Business Central needs Full-Text Search."
        return
    }
    try {
        Set-Service -Name $fullTextServiceName -StartupType Automatic
        if ($service.Status -ne 'Running') { Start-Service -Name $fullTextServiceName }
    }
    catch { Write-Host "Starting the SQL Server Full-Text Search service '$fullTextServiceName' failed: $($_.Exception.Message)" }
}

function Test-SqlInstanceRunning {
    $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    if ($null -eq $service) { return $false }
    try {
        if ($service.Status -ne 'Running') {
            Set-Service -Name $serviceName -StartupType Automatic
            Start-Service -Name $serviceName
        }
        $service.WaitForStatus('Running', [TimeSpan]::FromSeconds(120))
        return $true
    }
    catch {
        Write-Host "SQL Server service '$serviceName' exists but does not start: $($_.Exception.Message)"
        return $false
    }
}

function Test-SqlInstanceRegistered {
    $names = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL' -ErrorAction SilentlyContinue
    return ($null -ne $names -and $null -ne $names.PSObject.Properties[$InstanceName]) -or
        ($null -ne (Get-Service -Name $serviceName -ErrorAction SilentlyContinue))
}

function Invoke-Process([string] $FilePath, [string[]] $ArgumentList) {
    $process = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -Wait -PassThru -NoNewWindow
    return $process.ExitCode
}

function Save-Installer([string] $Path) {
    if ((Test-Path -LiteralPath $Path) -and (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -eq $InstallerSha256) {
        Write-Host "Reusing the verified SQL Server Express installer '$Path'."
        return
    }
    $delay = $RetryDelaySeconds
    for ($attempt = 1; ; $attempt++) {
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        try {
            Write-Host "Downloading SQL Server Express from '$InstallerUrl' (attempt $attempt of $DownloadAttempts)..."
            Invoke-WebRequest -Uri $InstallerUrl -OutFile $Path -UseBasicParsing -TimeoutSec 1800
            $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
            if ($hash -ne $InstallerSha256) {
                throw "The download ($((Get-Item -LiteralPath $Path).Length) bytes) has SHA256 $hash; expected $InstallerSha256."
            }
            return
        }
        catch {
            Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
            if ($attempt -ge $DownloadAttempts) {
                throw "Downloading SQL Server Express failed after $DownloadAttempts attempt(s): $($_.Exception.Message)"
            }
            Write-Host "Downloading SQL Server Express failed: $($_.Exception.Message) Retrying in $delay second(s)."
            Start-Sleep -Seconds $delay
            $delay = [Math]::Min($delay * 2, 300)
        }
    }
}

function Write-SetupDiagnostics {
    $sqlRoot = Join-Path $env:ProgramFiles 'Microsoft SQL Server'
    $summary = Get-ChildItem -Path (Join-Path $sqlRoot '*\Setup Bootstrap\Log\Summary.txt') -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($summary) {
        Write-Host "----- $($summary.FullName) -----"
        Get-Content -LiteralPath $summary.FullName -Tail 80 | ForEach-Object { Write-Host $_ }
    }
    $errorLog = Get-ChildItem -Path (Join-Path $sqlRoot "MSSQL*.$InstanceName\MSSQL\Log\ERRORLOG") -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($errorLog) {
        Write-Host "----- $($errorLog.FullName) (tail) -----"
        Get-Content -LiteralPath $errorLog.FullName -Tail 60 | ForEach-Object { Write-Host $_ }
    }
    # Setup's "Could not find the Database Engine startup handle" (0x851A0019) is often a disk that
    # reports a sector size above 4 KB; log the sector sizes for that diagnosis.
    try { & fsutil fsinfo sectorinfo C: 2>&1 | Select-String -Pattern 'PhysicalBytesPerSector' | ForEach-Object { Write-Host ([string]$_).Trim() } }
    catch { Write-Host "fsutil sectorinfo failed: $($_.Exception.Message)" }
}

function Remove-PartialInstance([string] $Setup) {
    Write-Host "Removing the half-installed SQL Server instance '$InstanceName' before retrying..."
    $exitCode = Invoke-Process $Setup @('/Q', '/ACTION=Uninstall', "/FEATURES=$Features", "/INSTANCENAME=$InstanceName")
    Write-Host "SQL Server setup /ACTION=Uninstall exited with code $exitCode."
    $instanceFolders = Get-ChildItem -Path (Join-Path (Join-Path $env:ProgramFiles 'Microsoft SQL Server') "MSSQL*.$InstanceName") -Directory -ErrorAction SilentlyContinue
    foreach ($folder in $instanceFolders) { Remove-Item -LiteralPath $folder.FullName -Recurse -Force -ErrorAction SilentlyContinue }
}

if (Test-SqlInstanceRunning) {
    Write-Host "SQL Server instance '$InstanceName' is already installed and running."
    Start-FullTextService
    return
}

New-Item -ItemType Directory -Path $WorkFolder -Force | Out-Null
$installer = Join-Path $WorkFolder ([System.IO.Path]::GetFileName(([uri] $InstallerUrl).AbsolutePath))
Save-Installer $installer

$media = Join-Path $WorkFolder 'media'
Remove-Item -LiteralPath $media -Recurse -Force -ErrorAction SilentlyContinue
$exitCode = Invoke-Process $installer @('/Q', "/x:`"$media`"")
$setup = Join-Path $media 'setup.exe'
if (-not (Test-Path -LiteralPath $setup)) {
    throw "Extracting the SQL Server Express installer failed (exit code $exitCode): '$setup' not found."
}

$installed = $false
$delay = $RetryDelaySeconds
for ($attempt = 1; $attempt -le $SetupAttempts; $attempt++) {
    if (Test-SqlInstanceRegistered) { Remove-PartialInstance $setup }
    Write-Host "Installing SQL Server Express instance '$InstanceName' (attempt $attempt of $SetupAttempts)..."
    $exitCode = Invoke-Process $setup @('/IACCEPTSQLSERVERLICENSETERMS', '/Q', '/ACTION=Install', "/FEATURES=$Features", "/INSTANCEID=$InstanceName", "/INSTANCENAME=$InstanceName", '/UPDATEENABLED=FALSE')
    Write-Host "SQL Server setup exited with code $exitCode."
    if (Test-SqlInstanceRunning) { $installed = $true; break }
    Write-Host "SQL Server instance '$InstanceName' is not running after setup attempt $attempt (exit code $exitCode)."
    Write-SetupDiagnostics
    if ($attempt -lt $SetupAttempts) {
        Start-Sleep -Seconds $delay
        $delay = [Math]::Min($delay * 2, 300)
    }
}
if (-not $installed) {
    throw "Installing SQL Server Express instance '$InstanceName' failed after $SetupAttempts attempt(s) (last setup exit code $exitCode); see the setup summary above."
}

Remove-Item -LiteralPath $WorkFolder -Recurse -Force -ErrorAction SilentlyContinue
Start-FullTextService
Write-Host "SQL Server Express instance '$InstanceName' is installed and running."
