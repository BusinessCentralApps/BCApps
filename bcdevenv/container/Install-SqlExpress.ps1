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

    SQL Server cannot use database files on a volume whose physical sector size is above 4 KB
    ("... originally formatted with sector size 4096 and is now on a volume with sector size 8192"),
    which some hosted runners' system disks report. The documented registry workaround
    (ForcedPhysicalSectorSizeInBytes) only applies after a reboot, so when the Program Files volume
    reports more than 4096 bytes and no -DataDirectory is given, the instance's data files are put
    on an expandable VHDX volume (4 KB physical sectors) created with diskpart and passed to setup
    as /INSTALLSQLDATADIR. The mitigation is best effort: when the virtual disk cannot be created
    (for example inside a container), setup runs with the default data folder.
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
    [ValidateRange(0, 600)] [int] $RetryDelaySeconds = 15,
    # Setup's /INSTALLSQLDATADIR; when empty the default (Program Files) is used, or a VHDX volume
    # when the Program Files volume reports a physical sector size above 4 KB.
    [string] $DataDirectory = '',
    [switch] $NoSectorSizeMitigation,
    # The VHDX file of the sector size mitigation; when empty it goes to the fixed drive with the most free space.
    [string] $VirtualDiskPath = '',
    [ValidateRange(8, 2048)] [int] $VirtualDiskSizeGB = 128
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Version 2.0
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$serviceName = if ($InstanceName -eq 'MSSQLSERVER') { 'MSSQLSERVER' } else { "MSSQL`$$InstanceName" }
$fullTextServiceName = if ($InstanceName -eq 'MSSQLSERVER') { 'MSSQLFDLauncher' } else { "MSSQLFDLauncher`$$InstanceName" }
$sqlDataDirectory = ''

function Get-VolumePhysicalSectorSize([string] $Path) {
    # The larger of the volume's physical sector sizes for atomicity and performance; 0 when unknown.
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

function Invoke-DiskPart([string[]] $Commands) {
    $scriptFile = Join-Path $WorkFolder 'diskpart.txt'
    Set-Content -LiteralPath $scriptFile -Value $Commands -Encoding Ascii
    try { & diskpart /s $scriptFile 2>&1 | ForEach-Object { Write-Host "  diskpart: $_" } }
    catch { Write-Host "diskpart failed: $($_.Exception.Message)" }
    Remove-Item -LiteralPath $scriptFile -Force -ErrorAction SilentlyContinue
}

function New-SqlDataVolume {
    $vhdx = $VirtualDiskPath
    if (-not $vhdx) {
        $hostDrive = $null
        try {
            $hostDrive = Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction Stop |
                Sort-Object -Property FreeSpace -Descending | Select-Object -First 1 -ExpandProperty DeviceID
        }
        catch { Write-Host "Listing the fixed drives failed: $($_.Exception.Message)" }
        if (-not $hostDrive) { $hostDrive = $env:SystemDrive }
        $vhdx = "$hostDrive\bcdevenv-sqldata-$InstanceName.vhdx"
    }
    $usedLetters = @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | ForEach-Object { $_.Name.ToUpperInvariant() })
    $letter = @('S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z', 'R', 'Q', 'P', 'O', 'N') | Where-Object { $usedLetters -notcontains $_ } | Select-Object -First 1
    if (-not $letter) {
        Write-Host 'No free drive letter for the SQL Server data volume.'
        return ''
    }
    if (Test-Path -LiteralPath $vhdx) {
        Invoke-DiskPart @("select vdisk file=`"$vhdx`"", 'detach vdisk noerr')
        Remove-Item -LiteralPath $vhdx -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $vhdx) {
            Write-Host "The virtual disk '$vhdx' already exists and cannot be removed."
            return ''
        }
    }
    Write-Host "Creating the expandable virtual disk '$vhdx' (up to $VirtualDiskSizeGB GB) as ${letter}: for the SQL Server data files..."
    Invoke-DiskPart @(
        "create vdisk file=`"$vhdx`" maximum=$($VirtualDiskSizeGB * 1024) type=expandable",
        "select vdisk file=`"$vhdx`"",
        'attach vdisk',
        'create partition primary',
        'format fs=ntfs quick label="bcdevenv-sql"',
        "assign letter=$letter"
    )
    $size = Get-VolumePhysicalSectorSize "${letter}:\"
    if ($size -lt 1 -or $size -gt 4096) {
        Write-Host "The virtual disk volume ${letter}: is not usable (physical sector size: $(if ($size -gt 0) { $size } else { 'unknown' }))."
        if (Test-Path -LiteralPath $vhdx) {
            Invoke-DiskPart @("select vdisk file=`"$vhdx`"", 'detach vdisk noerr')
            Remove-Item -LiteralPath $vhdx -Force -ErrorAction SilentlyContinue
        }
        return ''
    }
    Write-Host "The SQL Server data volume ${letter}: reports a physical sector size of $size bytes."
    return "${letter}:\SQLData"
}

function Resolve-SqlDataDirectory {
    if ($DataDirectory) { return $DataDirectory }
    $sectorSize = Get-VolumePhysicalSectorSize $env:ProgramFiles
    if ($sectorSize -le 4096) { return '' }
    $problem = "The volume of '$env:ProgramFiles' reports a physical sector size of $sectorSize bytes; SQL Server cannot use database files on volumes above 4096 bytes."
    if ($NoSectorSizeMitigation) {
        Write-Host "WARNING: $problem -NoSectorSizeMitigation is set; installing with the default data folder."
        return ''
    }
    Write-Host "$problem Putting the instance's data files on a virtual disk instead."
    $directory = New-SqlDataVolume
    if (-not $directory) {
        Write-Host 'WARNING: The SQL Server data volume could not be created; installing with the default data folder, which is likely to fail on this volume.'
    }
    return $directory
}

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
    $instanceRoots = @($sqlRoot) + @($sqlDataDirectory | Where-Object { $_ })
    $errorLog = $instanceRoots | ForEach-Object { Get-ChildItem -Path (Join-Path $_ "MSSQL*.$InstanceName\MSSQL\Log\ERRORLOG") -ErrorAction SilentlyContinue } | Select-Object -First 1
    if ($errorLog) {
        Write-Host "----- $($errorLog.FullName) (tail) -----"
        Get-Content -LiteralPath $errorLog.FullName -Tail 60 | ForEach-Object { Write-Host $_ }
    }
    # Setup's "Could not find the Database Engine startup handle" (0x851A0019) is often a disk that
    # reports a sector size above 4 KB; log the sector sizes for that diagnosis.
    foreach ($root in $instanceRoots) {
        Write-Host "Physical sector size of the volume of '$root': $(Get-VolumePhysicalSectorSize $root) bytes."
    }
}

function Remove-PartialInstance([string] $Setup) {
    Write-Host "Removing the half-installed SQL Server instance '$InstanceName' before retrying..."
    $exitCode = Invoke-Process $Setup @('/Q', '/ACTION=Uninstall', "/FEATURES=$Features", "/INSTANCENAME=$InstanceName")
    Write-Host "SQL Server setup /ACTION=Uninstall exited with code $exitCode."
    $instanceRoots = @(Join-Path $env:ProgramFiles 'Microsoft SQL Server') + @($sqlDataDirectory | Where-Object { $_ })
    foreach ($root in $instanceRoots) {
        $instanceFolders = Get-ChildItem -Path (Join-Path $root "MSSQL*.$InstanceName") -Directory -ErrorAction SilentlyContinue
        foreach ($folder in $instanceFolders) { Remove-Item -LiteralPath $folder.FullName -Recurse -Force -ErrorAction SilentlyContinue }
    }
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
$sqlDataDirectory = Resolve-SqlDataDirectory
$setupArguments = @('/IACCEPTSQLSERVERLICENSETERMS', '/Q', '/ACTION=Install', "/FEATURES=$Features", "/INSTANCEID=$InstanceName", "/INSTANCENAME=$InstanceName", '/UPDATEENABLED=FALSE')
if ($sqlDataDirectory) {
    Write-Host "The instance's data files go to '$sqlDataDirectory'."
    $setupArguments += "/INSTALLSQLDATADIR=`"$sqlDataDirectory`""
}
$delay = $RetryDelaySeconds
for ($attempt = 1; $attempt -le $SetupAttempts; $attempt++) {
    if (Test-SqlInstanceRegistered) { Remove-PartialInstance $setup }
    Write-Host "Installing SQL Server Express instance '$InstanceName' (attempt $attempt of $SetupAttempts)..."
    $exitCode = Invoke-Process $setup $setupArguments
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
