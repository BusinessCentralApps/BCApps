<#
.SYNOPSIS
    Installs a SQL Server Express instance (engine + Full-Text Search) from Microsoft's download, with retries.
.DESCRIPTION
    Used by the bcdevenv image (Dockerfile) and by the BCApps CI pipeline on the runner
    (build/scripts/BcDevEnvPipeline.psm1, Initialize-BcDevEnvSqlServer). It replaces
    'choco install sql-server-express', which depends on the Chocolatey feed and reported success
    when the feed failed. The Express with Advanced Services media (SQLEXPRADV) is used because BC
    creates text-optimized (full-text) indexes when a company is created; the basic SQLEXPR media
    has no Full-Text Search.
      - the installer is downloaded with retries and checked against its SHA256 hash;
      - a setup attempt succeeds only when setup exits with 0 or 3010 (success, reboot required),
        the instance's service runs AND the engine accepts a shared-memory connection (SELECT 1).
        A running service alone is not enough: after a failed configuration (for example setup's
        0x851A001A, "Wait on the Database Engine recovery handle failed") the service can report
        Running and still not serve, or stop again at its next start;
      - setup is retried; every failed attempt prints the setup summary, the instance's ERRORLOG
        (found through its startup parameters, under the default root, the instance directory and
        the data directory, or as setup's copy), the instance's SQL Server errors in the Application
        event log, its file layout and the volumes' sector sizes; a half-installed instance is
        uninstalled before the next attempt.
    An instance whose service already runs and accepts connections is left alone (a warning is
    printed when it has no Full-Text Search). -DiagnosticsOnly prints the diagnostics and exits.

    SQL Server cannot use database files on a volume whose physical sector size is above 4 KB
    (error 5178, "... originally formatted with sector size 4096 and is now on a volume with sector
    size 8192"), which some hosted runners' system disks report. The documented registry workaround
    (ForcedPhysicalSectorSizeInBytes) only applies after a reboot, so when the Program Files volume
    reports more than 4096 bytes and no -DataDirectory is given, the instance is put on an
    expandable VHDX volume (4 KB physical sectors) created with diskpart: its binaries, including
    the Resource database (mssqlsystemresource, in MSSQL\Binn, which cannot be moved after setup),
    through /INSTANCEDIR, and all its data files (system and user databases, tempdb, logs, backups,
    ERRORLOG) through /INSTALLSQLDATADIR, whose subfolders are the defaults of the other data
    directories. Only the shared features stay in Program Files. The mitigation is best effort:
    when the virtual disk cannot be created (for example inside a container), setup runs with the
    default folders.
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
    # Setup's /INSTALLSQLDATADIR; when empty the default (Program Files) is used, or the VHDX volume
    # when the Program Files volume reports a physical sector size above 4 KB. Given, the volume is not probed.
    [string] $DataDirectory = '',
    # Setup's /INSTANCEDIR (the instance's binaries, including the Resource database); when empty the
    # default (Program Files) is used, or the VHDX volume of the sector size mitigation.
    [string] $InstanceDirectory = '',
    [switch] $NoSectorSizeMitigation,
    # The VHDX file of the sector size mitigation; when empty it goes to the fixed drive with the most free space.
    [string] $VirtualDiskPath = '',
    [ValidateRange(8, 2048)] [int] $VirtualDiskSizeGB = 128,
    # About how long to wait for the engine to accept a connection once its service runs.
    [ValidateRange(0, 600)] [int] $ConnectionTimeoutSeconds = 90,
    # Only print the diagnostics of the instance (setup summary, ERRORLOG, event log, layout) and exit.
    [switch] $DiagnosticsOnly
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Version 2.0
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$serviceName = if ($InstanceName -eq 'MSSQLSERVER') { 'MSSQLSERVER' } else { "MSSQL`$$InstanceName" }
$fullTextServiceName = if ($InstanceName -eq 'MSSQLSERVER') { 'MSSQLFDLauncher' } else { "MSSQLFDLauncher`$$InstanceName" }
# Setup's exit codes of success: 0, and 3010 (success, a reboot is required).
$successExitCodes = @(0, 3010)
# The 64-bit Program Files, where SQL Server installs, also when this runs in a 32-bit process.
$programFiles = if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }
$sqlDataDirectory = $DataDirectory
$sqlInstanceDirectory = $InstanceDirectory
# Describes the active sector size mitigation, for the final error; empty when it is not active.
$sectorMitigation = ''

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

function Format-SetupExitCode([int] $ExitCode) {
    if ($ExitCode -eq 0) { return '0' }
    $meaning = switch ($ExitCode) {
        3010 { 'success, a reboot is required' }
        (-2061893607) { 'Could not find the Database Engine startup handle' }
        (-2061893606) { 'Wait on the Database Engine recovery handle failed' }
        default { '' }
    }
    $hex = '0x{0:X8}' -f $ExitCode
    if ($meaning) { return "$ExitCode ($hex`: $meaning)" }
    return "$ExitCode ($hex)"
}

function Get-SetupFailureReason([int] $ExitCode, [bool] $ServiceRunning, [bool] $Connected) {
    # Empty when the attempt succeeded: an exit code of success, a running service and an engine
    # that accepts a connection. The connection is only tested after an exit code of success.
    if ($successExitCodes -notcontains $ExitCode) {
        $service = if ($ServiceRunning) { ", although the service '$serviceName' runs" } else { '' }
        return "setup exited with code $(Format-SetupExitCode $ExitCode)$service"
    }
    if (-not $ServiceRunning) { return "the service '$serviceName' does not run" }
    if (-not $Connected) { return "the service '$serviceName' runs, but the engine does not accept a connection" }
    return ''
}

function Invoke-DiskPart([string[]] $Commands) {
    $scriptFile = Join-Path $WorkFolder 'diskpart.txt'
    Set-Content -LiteralPath $scriptFile -Value $Commands -Encoding Ascii
    try { & diskpart /s $scriptFile 2>&1 | ForEach-Object { Write-Host "  diskpart: $_" } }
    catch { Write-Host "diskpart failed: $($_.Exception.Message)" }
    Remove-Item -LiteralPath $scriptFile -Force -ErrorAction SilentlyContinue
}

function New-SqlVolume {
    # Creates, attaches and formats the VHDX; returns its drive root, path and sector size, or $null.
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
        Write-Host 'No free drive letter for the SQL Server volume.'
        return $null
    }
    if (Test-Path -LiteralPath $vhdx) {
        Invoke-DiskPart @("select vdisk file=`"$vhdx`"", 'detach vdisk noerr')
        Remove-Item -LiteralPath $vhdx -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $vhdx) {
            Write-Host "The virtual disk '$vhdx' already exists and cannot be removed."
            return $null
        }
    }
    Write-Host "Creating the expandable virtual disk '$vhdx' (up to $VirtualDiskSizeGB GB) as ${letter}: for the SQL Server instance and its data files..."
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
        return $null
    }
    Write-Host "The SQL Server volume ${letter}: reports a physical sector size of $size bytes."
    return [pscustomobject]@{ Root = "${letter}:"; Path = $vhdx; SectorSize = $size }
}

function Resolve-SqlLayout {
    # Sets the instance and data directories of setup, and the sector size mitigation when it is active.
    if ($DataDirectory) { return }
    $sectorSize = Get-VolumePhysicalSectorSize $programFiles
    if ($sectorSize -le 4096) { return }
    $problem = "The volume of '$programFiles' reports a physical sector size of $sectorSize bytes; SQL Server cannot use database files on volumes above 4096 bytes."
    if ($NoSectorSizeMitigation) {
        Write-Host "WARNING: $problem -NoSectorSizeMitigation is set; installing with the default folders."
        return
    }
    Write-Host "$problem Putting the instance and its data files on a virtual disk instead."
    $volume = New-SqlVolume
    if ($null -eq $volume) {
        Write-Host 'WARNING: The SQL Server volume could not be created; installing with the default folders, which is likely to fail on this volume.'
        return
    }
    $script:sqlDataDirectory = "$($volume.Root)\SQLData"
    if (-not $InstanceDirectory) { $script:sqlInstanceDirectory = "$($volume.Root)\SQLServer" }
    $script:sectorMitigation = "the 8 KB-sector workaround was active: the volume of '$programFiles' reports $sectorSize-byte physical sectors, so the instance ('$script:sqlInstanceDirectory') and its data files ('$script:sqlDataDirectory') were put on the virtual disk volume $($volume.Root) ($($volume.SectorSize)-byte sectors, '$($volume.Path)')"
}

function Get-InstanceRoots {
    $roots = @(Join-Path $programFiles 'Microsoft SQL Server') + @(@($sqlInstanceDirectory, $sqlDataDirectory) | Where-Object { $_ })
    return @($roots | Select-Object -Unique)
}

function Get-InstanceRegistryKey {
    $names = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL' -ErrorAction SilentlyContinue
    if ($null -eq $names -or $null -eq $names.PSObject.Properties[$InstanceName]) { return '' }
    return "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$($names.$InstanceName)"
}

function Get-InstanceStartupParameters {
    # The instance's registry startup parameters (-d master data, -e ERRORLOG, -l master log, ...).
    $key = Get-InstanceRegistryKey
    if (-not $key) { return @() }
    $parameters = Get-ItemProperty -Path "$key\MSSQLServer\Parameters" -ErrorAction SilentlyContinue
    if ($null -eq $parameters) { return @() }
    return @($parameters.PSObject.Properties | Where-Object { $_.Name -like 'SQLArg*' } | Sort-Object -Property Name | ForEach-Object { [string] $_.Value })
}

function Write-InstanceLayout {
    # Where the instance's binaries (SQLBinRoot, with the Resource database), data and startup files
    # are, with the physical sector sizes of their volumes.
    $key = Get-InstanceRegistryKey
    if (-not $key) {
        Write-Host "SQL Server instance '$InstanceName' is not registered."
        return
    }
    Write-Host "SQL Server instance '$InstanceName' layout ($key):"
    $setupKey = Get-ItemProperty -Path "$key\Setup" -ErrorAction SilentlyContinue
    foreach ($name in @('SQLBinRoot', 'SQLDataRoot')) {
        if ($null -ne $setupKey -and $null -ne $setupKey.PSObject.Properties[$name]) {
            $path = [string] $setupKey.$name
            Write-Host "  $name`: $path ($(Get-VolumePhysicalSectorSize $path)-byte physical sectors)"
        }
    }
    foreach ($parameter in Get-InstanceStartupParameters) {
        $path = if ($parameter -match '^-[del](.+)$') { $Matches[1] } else { '' }
        $sectors = if ($path) { " ($(Get-VolumePhysicalSectorSize $path)-byte physical sectors)" } else { '' }
        Write-Host "  startup parameter: $parameter$sectors"
    }
}

function Write-SqlEventLogErrors {
    $provider = if ($InstanceName -eq 'MSSQLSERVER') { 'MSSQLSERVER' } else { "MSSQL`$$InstanceName" }
    try {
        $entries = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = $provider; Level = @(1, 2) } -MaxEvents 15 -ErrorAction Stop)
    }
    catch { return }
    if ($entries.Count -eq 0) { return }
    Write-Host "----- Application event log errors of '$provider' (newest first) -----"
    foreach ($entry in $entries) {
        $message = ([string] $entry.Message -replace '\s+', ' ').Trim()
        Write-Host "$($entry.TimeCreated.ToString('s')) event $($entry.Id): $message"
    }
}

function Write-SetupDiagnostics {
    # Best effort: a failure here must not hide the setup failure it describes.
    try { Write-SetupDiagnosticsCore }
    catch { Write-Host "Collecting the SQL Server diagnostics failed: $($_.Exception.Message)" }
}

function Write-SetupDiagnosticsCore {
    $sqlRoot = Join-Path $programFiles 'Microsoft SQL Server'
    $summary = Get-ChildItem -Path (Join-Path $sqlRoot '*\Setup Bootstrap\Log\Summary.txt') -ErrorAction SilentlyContinue |
        Sort-Object -Property LastWriteTime -Descending | Select-Object -First 1
    if ($summary) {
        Write-Host "----- $($summary.FullName) -----"
        Get-Content -LiteralPath $summary.FullName -Tail 80 | ForEach-Object { Write-Host $_ }
    }
    else { Write-Host "No setup summary (Summary.txt) found under '$sqlRoot'." }

    $errorLogs = @()
    foreach ($parameter in Get-InstanceStartupParameters) {
        if ($parameter -match '^-e(.+)$') { $errorLogs += @(Get-Item -LiteralPath $Matches[1] -ErrorAction SilentlyContinue) }
    }
    $roots = Get-InstanceRoots
    foreach ($root in $roots) {
        # Not Join-Path, which fails when the root's drive is gone (for example a detached virtual disk).
        $errorLogs += @(Get-ChildItem -Path ([System.IO.Path]::Combine($root, "MSSQL*.$InstanceName\MSSQL\Log\ERRORLOG")) -ErrorAction SilentlyContinue)
    }
    # Setup copies the ERRORLOG of a failed engine configuration into its log folder.
    $errorLogs += @(Get-ChildItem -Path (Join-Path $sqlRoot '*\Setup Bootstrap\Log\*\SQLServer_ERRORLOG*') -ErrorAction SilentlyContinue)
    $errorLog = $errorLogs | Where-Object { $null -ne $_ } | Sort-Object -Property LastWriteTime -Descending | Select-Object -First 1
    if ($errorLog) {
        Write-Host "----- $($errorLog.FullName) (tail) -----"
        Get-Content -LiteralPath $errorLog.FullName -Tail 80 | ForEach-Object { Write-Host $_ }
    }
    else { Write-Host "No ERRORLOG of instance '$InstanceName' found (searched its startup parameters, $($roots -join ', ') and the setup logs)." }

    Write-SqlEventLogErrors
    Write-InstanceLayout
    # Setup's "Could not find the Database Engine startup handle" (0x851A0019) and "Wait on the
    # Database Engine recovery handle failed" (0x851A001A) are often a volume that reports a sector
    # size above 4 KB; log the sector sizes for that diagnosis.
    foreach ($root in $roots) {
        Write-Host "Physical sector size of the volume of '$root': $(Get-VolumePhysicalSectorSize $root) bytes."
    }
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

function Test-SqlConnection {
    # SELECT 1 over shared memory with the current Windows identity (setup makes the installing user
    # a sysadmin of an Express instance). A login failure also proves that the engine serves.
    $server = if ($InstanceName -eq 'MSSQLSERVER') { 'lpc:.' } else { "lpc:.\$InstanceName" }
    $connectionString = "Data Source=$server;Integrated Security=True;Pooling=False;Connect Timeout=5"
    $attempts = [Math]::Max(1, [int] [Math]::Ceiling($ConnectionTimeoutSeconds / 10))
    $lastError = ''
    for ($attempt = 1; $attempt -le $attempts; $attempt++) {
        $connection = $null
        try {
            $connection = New-Object -TypeName System.Data.SqlClient.SqlConnection -ArgumentList $connectionString
            $connection.Open()
            $command = $connection.CreateCommand()
            $command.CommandText = 'SELECT 1'
            [void] $command.ExecuteScalar()
            Write-Host "SQL Server instance '$InstanceName' accepts connections."
            return $true
        }
        catch {
            $number = 0
            $lastError = $_.Exception.Message
            for ($exception = $_.Exception; $null -ne $exception; $exception = $exception.InnerException) {
                $lastError = $exception.Message
                if ($exception.GetType().Name -eq 'SqlException') { $number = $exception.Number; break }
            }
            if (@(18456, 18452, 4060) -contains $number) {
                Write-Host "SQL Server instance '$InstanceName' serves, but rejected the login of the current user: $lastError"
                return $true
            }
        }
        finally {
            if ($null -ne $connection) { $connection.Dispose() }
        }
        if ($attempt -lt $attempts) { Start-Sleep -Seconds 5 }
    }
    Write-Host "SQL Server instance '$InstanceName' does not accept a connection ($attempts attempt(s)): $lastError"
    return $false
}

function Test-SqlInstanceRegistered {
    return ('' -ne (Get-InstanceRegistryKey)) -or ($null -ne (Get-Service -Name $serviceName -ErrorAction SilentlyContinue))
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

function Remove-PartialInstance([string] $Setup) {
    Write-Host "Removing the half-installed SQL Server instance '$InstanceName' before retrying..."
    $exitCode = Invoke-Process $Setup @('/Q', '/ACTION=Uninstall', "/FEATURES=$Features", "/INSTANCENAME=$InstanceName")
    Write-Host "SQL Server setup /ACTION=Uninstall exited with code $(Format-SetupExitCode $exitCode)."
    foreach ($root in Get-InstanceRoots) {
        $instanceFolders = Get-ChildItem -Path ([System.IO.Path]::Combine($root, "MSSQL*.$InstanceName")) -Directory -ErrorAction SilentlyContinue
        foreach ($folder in $instanceFolders) { Remove-Item -LiteralPath $folder.FullName -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

if ($DiagnosticsOnly) {
    Write-SetupDiagnostics
    return
}

if (Test-SqlInstanceRunning) {
    if (Test-SqlConnection) {
        Write-Host "SQL Server instance '$InstanceName' is already installed, running and accepting connections."
        Start-FullTextService
        return
    }
    Write-Host "SQL Server instance '$InstanceName' runs but does not accept connections; installing it again."
    Write-SetupDiagnostics
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

Resolve-SqlLayout
$setupArguments = @('/IACCEPTSQLSERVERLICENSETERMS', '/Q', '/ACTION=Install', "/FEATURES=$Features", "/INSTANCEID=$InstanceName", "/INSTANCENAME=$InstanceName", '/UPDATEENABLED=FALSE')
if ($sqlInstanceDirectory) {
    Write-Host "The instance goes to '$sqlInstanceDirectory'."
    $setupArguments += "/INSTANCEDIR=`"$sqlInstanceDirectory`""
}
if ($sqlDataDirectory) {
    Write-Host "The instance's data files go to '$sqlDataDirectory'."
    $setupArguments += "/INSTALLSQLDATADIR=`"$sqlDataDirectory`""
}
$installed = $false
$failure = ''
$delay = $RetryDelaySeconds
for ($attempt = 1; $attempt -le $SetupAttempts; $attempt++) {
    if (Test-SqlInstanceRegistered) { Remove-PartialInstance $setup }
    Write-Host "Installing SQL Server Express instance '$InstanceName' (attempt $attempt of $SetupAttempts)..."
    $exitCode = Invoke-Process $setup $setupArguments
    Write-Host "SQL Server setup exited with code $(Format-SetupExitCode $exitCode)."
    $running = Test-SqlInstanceRunning
    $connected = $running -and ($successExitCodes -contains $exitCode) -and (Test-SqlConnection)
    $failure = Get-SetupFailureReason -ExitCode $exitCode -ServiceRunning $running -Connected $connected
    if (-not $failure) { $installed = $true; break }
    Write-Host "SQL Server setup attempt $attempt of $SetupAttempts for instance '$InstanceName' failed: $failure."
    Write-SetupDiagnostics
    if ($attempt -lt $SetupAttempts) {
        Start-Sleep -Seconds $delay
        $delay = [Math]::Min($delay * 2, 300)
    }
}
if (-not $installed) {
    $message = "Installing SQL Server Express instance '$InstanceName' failed after $SetupAttempts attempt(s) (last attempt: $failure); see the setup diagnostics above."
    if ($sectorMitigation) { $message += " Note: $sectorMitigation." }
    throw $message
}

Remove-Item -LiteralPath $WorkFolder -Recurse -Force -ErrorAction SilentlyContinue
Start-FullTextService
if ($sectorMitigation) { Write-InstanceLayout }
Write-Host "SQL Server Express instance '$InstanceName' is installed, running and accepting connections."
