# ---------------------------------------------------------------------------
# bcdevenv container image
#
# A plain Windows Server Core base + SQL Server Express installed in the image.
# We bring OUR OWN specified-version BC service-tier + web-client binaries and a
# database rebuilt from that same platform version, so the DB schema and the
# binaries can never drift.
#
# All in-image logic is the self-contained bcdevenv .NET CLI (no PowerShell
# scripts baked in). The build context (staged by 'bcdevenv build-image') holds:
#   db\<database>.bak          - the freshly built DB (.bak)
#   binaries\Service\*         - specified-version service tier binaries
#   binaries\WebClient\*       - specified-version web client binaries (optional)
#   apps\*.app                 - optional bake-time app packages
#   license\*.bclicense        - license (optional)
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
# 1. Install Chocolatey + SQL Server Express (engine only), with TCP enabled.
#    This mirrors the host CI setup (build/scripts/Initialize-SqlServer.ps1),
#    which is a proven-working install path.
# ---------------------------------------------------------------------------
RUN iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
RUN choco install sql-server-express -y --no-progress; if ($LASTEXITCODE -ne 0) { throw 'sql-server-express install failed' }

# The BC server + management tool are framework-dependent .NET 8 apps
# (Microsoft.NETCore.App 8.0 + Microsoft.AspNetCore.App 8.0), so the base image
# (Windows Server Core has no .NET) needs the ASP.NET Core 8 runtime before
# provisioning registers/starts the server instance.
# The BC server targets .NET 8 (ASP.NET Core 8) and the management tool
# (Microsoft.BusinessCentral.ManagementTool.exe) targets .NET 10
# (Microsoft.NETCore.App 10.0). The base image (Windows Server Core) has no .NET,
# so install both runtimes with Microsoft's canonical dotnet-install script into
# the default location the apphosts probe.
RUN Invoke-WebRequest -UseBasicParsing 'https://dot.net/v1/dotnet-install.ps1' -OutFile C:\dotnet-install.ps1; & C:\dotnet-install.ps1 -Channel 8.0 -Runtime aspnetcore -InstallDir 'C:\Program Files\dotnet'; if (-not (Test-Path 'C:\Program Files\dotnet\shared\Microsoft.AspNetCore.App')) { throw '.NET 8 runtime install failed' }
RUN & C:\dotnet-install.ps1 -Channel 10.0 -Runtime aspnetcore -InstallDir 'C:\Program Files\dotnet'; if (-not (Test-Path 'C:\Program Files\dotnet\shared\Microsoft.AspNetCore.App')) { throw '.NET 10 runtime install failed' }

# ---------------------------------------------------------------------------
# 2. Lay down the build context + stage the baked binaries.
# ---------------------------------------------------------------------------
WORKDIR C:/bcdevenv
COPY . C:/bcdevenv/

RUN if (Test-Path C:\bcdevenv\binaries\Service)   { robocopy C:\bcdevenv\binaries\Service   C:\bc\Service   /E /NFL /NDL /NJH /NJS | Out-Null; if ($LASTEXITCODE -ge 8) { exit 1 } }; exit 0
RUN if (Test-Path C:\bcdevenv\binaries\WebClient) { robocopy C:\bcdevenv\binaries\WebClient C:\bc\WebClient /E /NFL /NDL /NJH /NJS | Out-Null; if ($LASTEXITCODE -ge 8) { exit 1 } }; exit 0

# ---------------------------------------------------------------------------
# 3. Provision: start SQL + SQL Browser, then restore the DB, register +
#    configure the NST from the baked binaries, and install any bake-time apps.
# ---------------------------------------------------------------------------
RUN Start-Service 'MSSQL$SQLEXPRESS'; if (Get-Service SQLBrowser -ErrorAction SilentlyContinue) { Set-Service SQLBrowser -StartupType Automatic; Start-Service SQLBrowser }; Write-Host \"MGMT=$env:BCDEVENV_MGMT_DIR\"; Get-ChildItem C:\bc\Service\Admin -Filter *.psd1 -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name; & C:\bcdevenv\cli\bcdevenv.exe provision --context C:\bcdevenv; if ($LASTEXITCODE -ne 0) { throw 'provision failed' }

# ---------------------------------------------------------------------------
# 4. Runtime.
# ---------------------------------------------------------------------------
EXPOSE 7046 7048 7049 80
HEALTHCHECK --interval=15s --timeout=10s --start-period=180s --retries=30 \
    CMD sc query "MicrosoftDynamicsNavServer$BC" | findstr RUNNING || exit 1

ENTRYPOINT ["C:\\bcdevenv\\cli\\bcdevenv.exe", "serve"]
