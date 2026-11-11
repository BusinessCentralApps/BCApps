# ---------------------------------------------------------------------------
# bcdevenv container image
#
# A plain Windows Server Core base + SQL Server Express installed in the image.
# We bring OUR OWN specified-version BC service-tier + web-client binaries and a
# database rebuilt from that same platform version, so the DB schema and the
# binaries can never drift.
#
# In-image provisioning logic is the self-contained bcdevenv .NET CLI; the only
# script is the SQL Server Express setup. The build context (staged by
# 'bcdevenv build-image') holds:
#   Install-SqlExpress.ps1     - SQL Server Express setup (shared with the CI runner)
#   db\<database>.bak          - the freshly built DB (.bak)
#   binaries\Service\*         - specified-version service tier binaries
#   binaries\WebClient\*       - specified-version web client binaries (optional)
#   apps\*.app                 - optional bake-time app packages
#   license\*.bclicense        - license (required when apps are baked into an empty create-env DB)
#   system32\*                 - optional DLLs copied into System32 when missing (e.g. t2embed.dll)
#   build-manifest.json        - DB name, country, instance, credential type, apps
#   cli\*                      - the self-contained bcdevenv CLI (provision + serve)
#
# Windows containers only. The base image OS version must match the host kernel
# (ltsc2022 <-> Windows Server 2022 / windows-2022 runner).
# ---------------------------------------------------------------------------

ARG BASE_IMAGE=mcr.microsoft.com/windows/servercore:ltsc2022
FROM ${BASE_IMAGE}

SHELL ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", "$ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue';"]

# The bcdevenv CLI reads these; provision/serve honour them.
# NB: ENV values are escape-processed by Docker, so backslashes must be doubled.
ENV BCDEVENV_SQL_SERVER=localhost
ENV BCDEVENV_SQL_INSTANCE=SQLEXPRESS
ENV BCDEVENV_MGMT_DIR=C:\\bc\\Service\\Admin
ENV BCDEVENV_INSTANCE=BC

# ---------------------------------------------------------------------------
# 1. SQL Server Express (engine + Full-Text Search, which BC's text-optimized
#    indexes need when a company is created), installed by Install-SqlExpress.ps1 from
#    Microsoft's download: SHA256-checked and retried, success judged by the
#    instance service starting (not by exit codes), a failed setup diagnosed,
#    cleaned up and retried. The same script installs SQL on the CI runner. It
#    is copied on its own so this layer stays cached across contexts.
# ---------------------------------------------------------------------------
COPY Install-SqlExpress.ps1 C:/bcdevenv-setup/
RUN & C:\bcdevenv-setup\Install-SqlExpress.ps1 -InstanceName SQLEXPRESS -WorkFolder C:\bcdevenv-setup\sqlexpress; exit 0

# The BC server targets .NET 8 (ASP.NET Core 8) and the management tool
# (Microsoft.BusinessCentral.ManagementTool.exe) targets .NET 10
# (Microsoft.NETCore.App 10.0). The base image (Windows Server Core) has no .NET,
# so install both runtimes with Microsoft's canonical dotnet-install script into
# the default location the apphosts probe. Retried (the script download itself
# has no retry), and verified by the installed runtime version folder.
RUN foreach ($channel in '8.0', '10.0') { \
      $installed = $false; \
      for ($attempt = 1; $attempt -le 5 -and -not $installed; $attempt++) { \
        try { \
          Invoke-WebRequest -UseBasicParsing 'https://dot.net/v1/dotnet-install.ps1' -OutFile C:\dotnet-install.ps1; \
          & C:\dotnet-install.ps1 -Channel $channel -Runtime aspnetcore -InstallDir 'C:\Program Files\dotnet'; \
          $installed = Test-Path ('C:\Program Files\dotnet\shared\Microsoft.AspNetCore.App\' + $channel.Split('.')[0] + '.*'); \
        } catch { Write-Host ('dotnet-install ' + $channel + ' attempt ' + $attempt + ' failed: ' + $_) }; \
        if (-not $installed) { Start-Sleep -Seconds (15 * $attempt) } \
      }; \
      if (-not $installed) { throw ('ASP.NET Core ' + $channel + ' runtime install failed') } \
    }; \
    Remove-Item C:\dotnet-install.ps1 -Force

# ---------------------------------------------------------------------------
# 2. Lay down the build context + stage the baked binaries.
# ---------------------------------------------------------------------------
WORKDIR C:/bcdevenv
COPY . C:/bcdevenv/

RUN if (Test-Path C:\bcdevenv\binaries\Service)   { robocopy C:\bcdevenv\binaries\Service   C:\bc\Service   /E /NFL /NDL /NJH /NJS | Out-Null; if ($LASTEXITCODE -ge 8) { exit 1 } }; exit 0
RUN if (Test-Path C:\bcdevenv\binaries\WebClient) { robocopy C:\bcdevenv\binaries\WebClient C:\bc\WebClient /E /NFL /NDL /NJH /NJS | Out-Null; if ($LASTEXITCODE -ge 8) { exit 1 } }; exit 0

# System DLLs the base image lacks (build-image --system32-file), copied into System32 only
# when missing, like the official images (nav-docker navinstall.ps1), and checked afterwards.
# Windows Server Core has no t2embed.dll (font embedding): without it the server's report
# rendering fails with "Unable to load DLL 'T2Embed'" when a report is saved as PDF.
RUN $system32 = Join-Path $env:SystemRoot 'System32'; \
    if (Test-Path C:\bcdevenv\system32) { \
      foreach ($file in Get-ChildItem C:\bcdevenv\system32 -File) { \
        $target = Join-Path $system32 $file.Name; \
        if (Test-Path $target) { Write-Host ($target + ' already exists; kept.') } else { Copy-Item $file.FullName $target; Write-Host ('Copied ' + $file.Name + ' to ' + $target) }; \
        if (-not (Test-Path $target -PathType Leaf)) { throw ($target + ' is missing after the copy.') } \
      } \
    }; \
    if (-not (Test-Path (Join-Path $system32 't2embed.dll') -PathType Leaf)) { Write-Host 'WARNING: C:\Windows\System32\t2embed.dll is missing; rendering reports as PDF fails (Unable to load DLL T2Embed). Pass build-image --system32-file with the path of a t2embed.dll.' }

# ---------------------------------------------------------------------------
# 3. Provision: start SQL (+ Full-Text Search) + SQL Browser, then restore the DB, register +
#    configure the NST from the baked binaries, and install any bake-time apps.
# ---------------------------------------------------------------------------
RUN Start-Service 'MSSQL$SQLEXPRESS'; if (Get-Service 'MSSQLFDLauncher$SQLEXPRESS' -ErrorAction SilentlyContinue) { Start-Service 'MSSQLFDLauncher$SQLEXPRESS' }; if (Get-Service SQLBrowser -ErrorAction SilentlyContinue) { Set-Service SQLBrowser -StartupType Automatic; Start-Service SQLBrowser }; Write-Host \"MGMT=$env:BCDEVENV_MGMT_DIR\"; Get-ChildItem C:\bc\Service\Admin -Filter *.psd1 -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name; & C:\bcdevenv\cli\bcdevenv.exe provision --context C:\bcdevenv; if ($LASTEXITCODE -ne 0) { throw 'provision failed' }

# ---------------------------------------------------------------------------
# 4. Runtime.
# ---------------------------------------------------------------------------
EXPOSE 7046 7048 7049 80
HEALTHCHECK --interval=15s --timeout=10s --start-period=180s --retries=30 \
    CMD sc query "MicrosoftDynamicsNavServer$BC" | findstr RUNNING || exit 1

ENTRYPOINT ["C:\\bcdevenv\\cli\\bcdevenv.exe", "serve"]
