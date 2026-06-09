#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installs the CXS Store Data Collector as a Windows Scheduled Task.

.DESCRIPTION
    888 IT runs this script on each store server. It:
    1. Copies the collector script to C:\CXS\
    2. Registers a Windows Scheduled Task (daily at 2am)
    3. Tests the local SQL Server connection
    4. Sends a test payload to the CXS API

.PARAMETER ApiUrl
    The CXS collector API endpoint URL.

.PARAMETER ApiKey
    The API key for authenticating with the CXS collector.

.PARAMETER SqlServer
    The SQL Server hostname or instance name (e.g. localhost, .\SQLEXPRESS, SERVERNAME\INSTANCE).

.PARAMETER Database
    The SQL Server database name (e.g. WSMOD8, NEWPOS).

.PARAMETER StoreCode
    The store S-code or DK-code (e.g. S059, DK003).

.PARAMETER OracleCode
    The store Oracle code (e.g. 4020, 4058).

.PARAMETER SyncTime
    The daily sync time in HH:mmAM/PM format (e.g. "5:00AM", "2:00AM").
    If omitted, defaults by brand per the May 2026 alignment:
      Wendy's -> 5:00AM (24-hour stores close out the previous day)
      Conti's -> 2:00AM (existing schedule)
    Pass -SyncTime explicitly to override.

.PARAMETER Brand
    REQUIRED. The brand for this install: "wendys" or "contis". No default -
    the installer will prompt (interactive) or fail (non-interactive) if
    omitted, so a copy-pasted Conti's install can't silently land as Wendy's.

.PARAMETER Company
    The LS Central company name as it appears in the SQL table prefix
    (e.g. "WENDYS PH", "CONTIS"). Defaults to "WENDYS PH".

.PARAMETER ExtGuid
    The LS Central table extension GUID for this installation. Defaults to
    Wendy's UAT GUID. Pass an empty string ("") for installs that use the
    NAV/legacy table naming format ([<Company>$<Table>]) instead of the
    LS Central extension format ([<Company>$LSC <Table>$<GUID>]) - e.g.
    Conti's NOC database.

.EXAMPLE
    Wendy's store (default brand/Company/ExtGuid):
    .\install-cxs-collector.ps1 -ApiUrl "https://888.insourcedata.org/api/collect" -ApiKey "key123" -SqlServer "localhost" -Database "WSMOD8" -StoreCode "S059" -OracleCode "4020"

.EXAMPLE
    Wendy's UAT (custom SQL Server, sync time):
    .\install-cxs-collector.ps1 -ApiUrl "https://888.insourcedata.org/api/collect" -ApiKey "key123" -SqlServer "ITLAB-SVR-AZ\np-master" -Database "NEWPOS" -StoreCode "DK003" -OracleCode "4058" -SyncTime "3:00AM"

.EXAMPLE
    # Wendy's install (defaults to 5:00AM per MOM 2026-05-20)
    .\install-cxs-collector.ps1 -Brand wendys -ApiUrl "..." -ApiKey "..." -SqlServer "..." -Database "NEWPOS" -StoreCode "DK003" -OracleCode "4058"

.EXAMPLE
    # Conti's install (defaults to 2:00AM)
    .\install-cxs-collector.ps1 -Brand contis -ApiUrl "..." -ApiKey "..." -SqlServer "..." -Database "NEWPOS" -StoreCode "NOCSST" -Company "NOC" -ExtGuid ""

.EXAMPLE
    Conti's NOC store install (NAV-format tables - pass empty ExtGuid):
    .\install-cxs-collector.ps1 -ApiUrl "https://888.insourcedata.org/api/collect" -ApiKey "key123" -SqlServer "SSTSERVER" -Database "NOCSSTDB" -StoreCode "NOCSST" -OracleCode "5001" -Brand "contis" -Company "NOC" -ExtGuid ""
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$ApiUrl,

    [Parameter(Mandatory=$true)]
    [string]$ApiKey,

    [Parameter(Mandatory=$false)]
    [string]$SqlServer = "localhost",

    [Parameter(Mandatory=$true)]
    [string]$Database,

    [Parameter(Mandatory=$true)]
    [string]$StoreCode,

    # OracleCode is metadata only - Wendy's uses it (e.g. 4058), Conti's doesn't.
    # Non-mandatory + AllowEmptyString so Conti's installs can pass "" or omit.
    [Parameter(Mandatory=$false)]
    [AllowEmptyString()]
    [string]$OracleCode = "",

    # Default-by-brand resolved below (Wendy's 5:00AM, Conti's 2:00AM)
    # per MOM 2026-05-20. Empty string here means "use brand default."
    [Parameter(Mandatory=$false)]
    [string]$SyncTime = "",

    # Brand is REQUIRED - no default. Was defaulting to "wendys" until
    # 2026-05-26; retired because the installer is run manually by IT
    # and a copy-pasted Conti's install with a forgotten -Brand flag
    # would silently provision the agent as Wendy's. Now PowerShell
    # prompts (or fails in non-interactive mode) if it's not passed.
    [Parameter(Mandatory=$true)]
    [ValidateSet("wendys", "contis")]
    [string]$Brand,

    # Company and ExtGuid default from the Brand below. Pass them explicitly to
    # override (e.g. a Conti's environment whose company prefix is not "NOC",
    # or a Wendy's install that uses a different LS Central extension GUID).
    [Parameter(Mandatory=$false)]
    [string]$Company,

    # ExtGuid empty string => NAV-format table names (Conti's NOC).
    # AllowEmptyString is required because [string] params silently reject "" by default.
    [Parameter(Mandatory=$false)]
    [AllowEmptyString()]
    [string]$ExtGuid,

    # TLS certificate validation is ON by default. Pass -AllowSelfSignedCert to
    # disable cert checks for stores whose root-CA store is missing the issuer
    # chain (e.g. Cloudflare). Never enable unless strictly required - disabling
    # TLS validation exposes the bearer token to MITM interception.
    [switch]$AllowSelfSignedCert
)

# --- PowerShell version pre-flight (supports 4.0+; fail loudly, never silently dark) ---
$psv = $PSVersionTable.PSVersion
if ([version]("{0}.{1}" -f $psv.Major, $psv.Minor) -lt [version]"4.0") {
    Write-Host "ERROR: PowerShell $psv detected. This installer requires PowerShell 4.0 or later (install WMF 4.0+ and re-run)." -ForegroundColor Red
    exit 1
}
if ($psv.Major -lt 5) {
    Write-Host "[NOTE] Running on PowerShell $psv (4.x). Supported; 5.1 is recommended. Confirm a heartbeat appears after install." -ForegroundColor Yellow
}

# --- Brand-driven defaults -------------------------------------------------------
# Each brand has its conventional Company and ExtGuid. The user can override either
# by passing -Company / -ExtGuid explicitly; otherwise they pick up these defaults.

$BrandDefaults = @{
    wendys = @{ Company = "WENDYS PH"; ExtGuid = "5ecfc871-5d82-43f1-9c54-59685e82318d"; SyncTime = "5:00AM" }
    contis = @{ Company = "NOC";       ExtGuid = "";                                     SyncTime = "2:00AM" }
}

if (-not $PSBoundParameters.ContainsKey('Company')) {
    $Company = $BrandDefaults[$Brand].Company
}
if (-not $PSBoundParameters.ContainsKey('ExtGuid')) {
    $ExtGuid = $BrandDefaults[$Brand].ExtGuid
}
# Brand-default sync time: Wendy's 5:00AM, Conti's 2:00AM (MOM 2026-05-20)
if ([string]::IsNullOrWhiteSpace($SyncTime)) {
    $SyncTime = $BrandDefaults[$Brand].SyncTime
}

$InstallDir = "C:\CXS"
$ScriptName = "cxs-collector-$StoreCode.ps1"
$TaskName   = "CXS Daily Sync - $StoreCode"
$HeartbeatTaskName = "CXS Agent Heartbeat - $StoreCode"

function Ensure-CollectorRootTrusted {
    # Repair/prevent the PartialChain TLS failure that silently kills the SYSTEM
    # heartbeat agent on freshly-provisioned boxes whose LocalMachine Root store
    # lacks the collector's CA. Imports the pinned Google Trust Services
    # "GTS Root R4" root (the collector's chain anchor) into LocalMachine\Root so
    # the SYSTEM agent's TLS validation SUCCEEDS without disabling it. Idempotent,
    # thumbprint-pinned, never weakens TLS.
    param([Parameter(Mandatory)][string]$ScriptRoot)
    $thumb = '77D30367B5E00C15F60C3861DF7CE13B92464D47'   # GTS Root R4 (self-signed, pki.goog)
    try {
        if (Test-Path "Cert:\LocalMachine\Root\$thumb") {
            Write-Host "  [OK] Collector root CA already trusted in the machine store (GTS Root R4)." -ForegroundColor Green
            return
        }
        $certPath = Join-Path $ScriptRoot "certs\gts-root-r4.crt"
        if (-not (Test-Path $certPath)) {
            Write-Host "  [WARN] Bundled root CA not found at $certPath - cannot auto-trust. If the box hits PartialChain, re-run with -AllowSelfSignedCert." -ForegroundColor Yellow
            return
        }
        $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 $certPath
        if ($cert.Thumbprint -ne $thumb) {
            Write-Host "  [WARN] Bundled root CA thumbprint mismatch (got $($cert.Thumbprint)); refusing to import." -ForegroundColor Red
            return
        }
        $store = New-Object System.Security.Cryptography.X509Certificates.X509Store('Root','LocalMachine')
        $store.Open('ReadWrite'); $store.Add($cert); $store.Close()
        Write-Host "  [OK] Imported collector root CA into LocalMachine\Root (GTS Root R4) - SYSTEM can now validate the collector cert." -ForegroundColor Green
    } catch {
        Write-Host "  [WARN] Could not import the collector root CA: $_" -ForegroundColor Yellow
        Write-Host "         If the SYSTEM heartbeat then fails with PartialChain, re-run with -AllowSelfSignedCert as a stopgap." -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "=== CXS Collector Installer ===" -ForegroundColor Cyan
Write-Host ""

# 1. Create install directory
Write-Host "[1/4] Creating install directory: $InstallDir"
if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
}
New-Item -ItemType Directory -Path "$InstallDir\logs" -Force | Out-Null
New-Item -ItemType Directory -Path "$InstallDir\config" -Force | Out-Null

# 2. Copy collector script and set configuration
Write-Host "[2/4] Installing collector script..."
$sourceScript = Join-Path $PSScriptRoot "cxs-collector.ps1"
if (-not (Test-Path $sourceScript)) {
    Write-Host "  ERROR: cxs-collector.ps1 not found in $PSScriptRoot" -ForegroundColor Red
    exit 1
}

$scriptContent = Get-Content $sourceScript -Raw

# Replace configuration placeholders
$scriptContent = $scriptContent -replace 'ApiUrl\s*=\s*"[^"]*"', "ApiUrl     = `"$ApiUrl`""
$scriptContent = $scriptContent -replace 'ApiKey\s*=\s*"[^"]*"', "ApiKey     = `"$ApiKey`""
$scriptContent = $scriptContent -replace 'SqlServer\s*=\s*"[^"]*"', "SqlServer  = `"$SqlServer`""
$scriptContent = $scriptContent -replace 'Database\s*=\s*"[^"]*"', "Database   = `"$Database`""
$scriptContent = $scriptContent -replace 'Brand\s*=\s*"[^"]*"', "Brand      = `"$Brand`""
$scriptContent = $scriptContent -replace 'Company\s*=\s*"[^"]*"', "Company    = `"$Company`""
$scriptContent = $scriptContent -replace 'ExtGuid\s*=\s*"[^"]*"', "ExtGuid    = `"$ExtGuid`""
$scriptContent = $scriptContent -replace 'StoreCode\s*=\s*"[^"]*"', "StoreCode  = `"$StoreCode`""
$scriptContent = $scriptContent -replace 'OracleCode\s*=\s*"[^"]*"', "OracleCode = `"$OracleCode`""
$scriptContent = $scriptContent -replace 'LogFile\s*=\s*"[^"]*"', "LogFile    = `"C:\CXS\logs\sync-$StoreCode.log`""
# Point this store's collector at its own per-store agent config so a box hosting
# >1 store doesn't have every collector overlay the same shared cxs-agent.json
# (issue #53). Rewrites both the config-path default and the doc comment.
$scriptContent = $scriptContent -replace 'cxs-agent\.json', "cxs-agent-$StoreCode.json"

$destScript = Join-Path $InstallDir $ScriptName
Set-Content -Path $destScript -Value $scriptContent -Encoding UTF8
Write-Host "  Installed to: $destScript" -ForegroundColor Green

# Copy command handler scripts
$commandsSrc = Join-Path $PSScriptRoot "commands"
$commandsDst = Join-Path $InstallDir "commands"
if (Test-Path $commandsSrc) {
    if (-not (Test-Path $commandsDst)) { New-Item -ItemType Directory -Path $commandsDst | Out-Null }
    Copy-Item "$commandsSrc\*.ps1" $commandsDst -Force
    Write-Host "  Installed command handlers to: $commandsDst" -ForegroundColor Green
}

# Copy heartbeat agent script
$agentSource = Join-Path $PSScriptRoot "cxs-agent.ps1"
if (-not (Test-Path $agentSource)) {
    Write-Host "  ERROR: cxs-agent.ps1 not found in $PSScriptRoot" -ForegroundColor Red
    exit 1
}
Copy-Item $agentSource (Join-Path $InstallDir "cxs-agent.ps1") -Force
Write-Host "  Installed agent to: $InstallDir\cxs-agent.ps1" -ForegroundColor Green

# Write agent config file (per-store so multiple stores on one box don't collide - issue #53)
$agentConfig = @{
    ApiUrl    = $ApiUrl
    ApiKey    = $ApiKey
    Brand     = $Brand
    StoreCode = $StoreCode
    SqlServer = $SqlServer
    Database  = $Database
    Company   = $Company
    AllowSelfSignedCert = [bool]$AllowSelfSignedCert
    # Per-store log + sync-summary paths so heartbeat agents and daily syncs on a
    # multi-store box don't overwrite each other's files.
    LogFile             = "C:\CXS\logs\agent-$StoreCode.log"
    SyncSummaryFile     = "C:\CXS\state\last-sync-$StoreCode.json"
}
$agentConfigPath = Join-Path $InstallDir "config\cxs-agent-$StoreCode.json"
$agentConfig | ConvertTo-Json -Depth 5 | Set-Content -Path $agentConfigPath -Encoding UTF8
Write-Host "  Agent config written to: $agentConfigPath" -ForegroundColor Green

# 3. Test SQL + send install checkin to collector
Write-Host "[3/4] Testing SQL + sending install checkin..."
Write-Host "  Ensuring the collector root CA is trusted in the machine store..."
Ensure-CollectorRootTrusted -ScriptRoot $PSScriptRoot
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# -UseBasicParsing exists on Invoke-RestMethod only in PS 5.0+ (PS 4.0 has it on
# Invoke-WebRequest but NOT Invoke-RestMethod). Splat it conditionally so this
# checkin POST is valid on Windows PowerShell 4.0 and keeps the guard on 5.1.
$CxsIrmArgs = @{}
if ((Get-Command Invoke-RestMethod).Parameters.ContainsKey('UseBasicParsing')) {
    $CxsIrmArgs['UseBasicParsing'] = $true
}
if ($AllowSelfSignedCert) {
    if (-not ([System.Management.Automation.PSTypeName]'TrustAllCertsPolicy').Type) {
        Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(
        ServicePoint srvPoint, X509Certificate certificate,
        WebRequest request, int certificateProblem) { return true; }
}
"@
    }
    [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
    Write-Host "WARN: AllowSelfSignedCert - TLS certificate validation is DISABLED." -ForegroundColor Yellow
}

$checkin = @{
    storeCode    = $StoreCode
    brand        = $Brand
    event        = "install"
    agentVersion = "2.0"
    hostname     = $env:COMPUTERNAME
    osVersion    = [System.Environment]::OSVersion.VersionString
    psVersion    = $PSVersionTable.PSVersion.ToString()
    runAsUser    = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    sqlServer    = $SqlServer
    sqlDatabase  = $Database
}

# Test SQL as current user
try {
    $testConn = New-Object System.Data.SqlClient.SqlConnection(
        "Server=$SqlServer;Database=$Database;Integrated Security=True;TrustServerCertificate=True;Connection Timeout=10;"
    )
    $testConn.Open()
    $testConn.Close()
    $checkin.sqlConnectable = $true
    Write-Host "  [OK] SQL Server connection: $SqlServer - $Database" -ForegroundColor Green
}
catch {
    $checkin.sqlConnectable = $false
    $checkin.sqlError = $_.Exception.Message
    Write-Host "  [FAIL] SQL Server: $_" -ForegroundColor Red
}

# Verify the ACTUAL transaction tables this store will query exist AND expose the
# [Date] column the daily sync filters on. We probe each real object name (built
# from -Company / -ExtGuid exactly like the collector's Get-TableFullName) with
# `SELECT TOP (1) [Date] FROM <table>`. That resolves BOTH the object name
# (Invalid object name => wrong -Company / -ExtGuid) and the [Date] column
# (Invalid column name => non-standard schema) - the two failure modes - WITHOUT
# scanning: a `WHERE [Date] = <day>` count would scan a large entry table and could
# blow past the timeout, false-failing a perfectly healthy store on this hard gate.
# So a real misconfig fails LOUDLY at install instead of going silently dark at 2am.
#   (2026-06 ACCAMF/ACCBBR: the contis brand-default Company=NOC built `NOC$...`
#    names that don't exist in the ACC franchise DBs. The old INFORMATION_SCHEMA LIKE
#    check passed because *some* "Transaction Header" existed, so the misconfig shipped
#    unnoticed and the nightly sync failed silently with zero data sent.)
$tableErrors   = @()
$logicalTables = @("Transaction Header", "Trans_ Sales Entry", "Trans_ Payment Entry")
try {
    $testConn2 = New-Object System.Data.SqlClient.SqlConnection(
        "Server=$SqlServer;Database=$Database;Integrated Security=True;TrustServerCertificate=True;Connection Timeout=10;"
    )
    $testConn2.Open()
    foreach ($t in $logicalTables) {
        # Mirror collector Get-TableFullName: empty ExtGuid => NAV [Company$Table];
        # otherwise LS Central [Company$LSC Table$ExtGuid].
        if ([string]::IsNullOrWhiteSpace($ExtGuid)) { $full = "[$Company`$$t]" }
        else { $full = "[$Company`$LSC $t`$$ExtGuid]" }
        try {
            $cmd = $testConn2.CreateCommand()
            $cmd.CommandText = "SELECT TOP (1) [Date] FROM $full"
            $cmd.CommandTimeout = 30
            [void]$cmd.ExecuteScalar()
            Write-Host "  [OK] Verified $full (object + [Date] column resolve)" -ForegroundColor Green
        }
        catch {
            $tableErrors += "$full  ->  $($_.Exception.Message)"
        }
    }
    $testConn2.Close()
}
catch {
    $tableErrors += "SQL connection for table verification failed: $($_.Exception.Message)"
}

# Send checkin
try {
    $checkinUrl = "$ApiUrl" -replace '/api/collect$', '/api/collect/checkin'
    $json = $checkin | ConvertTo-Json -Depth 5 -Compress
    $headers = @{
        "Content-Type"  = "application/json"
        "Authorization" = "Bearer $ApiKey"
    }
    $response = Invoke-RestMethod @CxsIrmArgs -Uri $checkinUrl -Method POST -Body $json -Headers $headers -TimeoutSec 15
    Write-Host "  [OK] Install checkin sent to collector" -ForegroundColor Green
}
catch {
    Write-Host "  [WARN] Could not send checkin: $_" -ForegroundColor Yellow
    Write-Host "         The agent will still be installed - check network if this persists" -ForegroundColor Yellow
}

# Abort BEFORE scheduling if the store's real tables couldn't be verified - a store
# that can't query its own POS tables must not be left with a nightly task that fails
# silently (the ACCAMF/ACCBBR dark-sync class). The install checkin above already
# recorded the attempt; fix -Company / -ExtGuid and re-run.
if ($tableErrors.Count -gt 0) {
    Write-Host ""
    Write-Host "  [FAIL] Could not verify this store's transaction tables - install aborted:" -ForegroundColor Red
    foreach ($e in $tableErrors) { Write-Host "         $e" -ForegroundColor Red }
    Write-Host ""
    Write-Host "  The daily sync would fail silently with -Company '$Company' / -ExtGuid '$ExtGuid'." -ForegroundColor Yellow
    Write-Host "  Find the store's real table prefix, then re-run with the correct -Company (and -ExtGuid):" -ForegroundColor Yellow
    Write-Host "      SELECT name FROM sys.tables WHERE name LIKE '%Transaction Header%';" -ForegroundColor Yellow
    exit 1
}

# 4. Register scheduled task
Write-Host "[4/4] Creating scheduled task: '$TaskName' ..."

# Remove legacy fleet-wide "CXS Daily Sync" task (no store-code suffix).
# This bare task was created by v1 installs and causes duplicate nightly payloads
# when it runs alongside the new per-store task. Uses exact-name match + equality
# guard so it cannot accidentally remove "CXS Daily Sync - <StoreCode>" tasks.
$legacyTask = Get-ScheduledTask -TaskName "CXS Daily Sync" -ErrorAction SilentlyContinue |
              Where-Object { $_.TaskName -eq "CXS Daily Sync" }
if ($legacyTask) {
    Unregister-ScheduledTask -TaskName "CXS Daily Sync" -Confirm:$false
    Write-Host "  Removed legacy fleet-wide task 'CXS Daily Sync'" -ForegroundColor Yellow
}

# Remove existing per-store task if present
$existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existingTask) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "  Removed existing task"
}

$action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$destScript`"" `
    -WorkingDirectory $InstallDir

# Daily at the configured time (default 2:00 AM)
$trigger = New-ScheduledTaskTrigger -Daily -At $SyncTime

# Run as SYSTEM so it works even when no one is logged in
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 10)

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $settings `
    -Description "CXS Dashboard - daily data sync to collector API" | Out-Null

Write-Host "  [OK] Scheduled Task created: $TaskName - daily at $SyncTime" -ForegroundColor Green

# Register heartbeat agent scheduled task
Write-Host "  Creating heartbeat task: '$HeartbeatTaskName' ..."

$existingHeartbeat = Get-ScheduledTask -TaskName $HeartbeatTaskName -ErrorAction SilentlyContinue
if ($existingHeartbeat) {
    Stop-ScheduledTask -TaskName $HeartbeatTaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $HeartbeatTaskName -Confirm:$false
    Write-Host "  Removed existing heartbeat task"
}

# Per-store heartbeat launcher (issue #53): a tiny generated wrapper that sets the
# store-scoped CXS_CONFIG_FILE, then runs the SHARED cxs-agent.ps1 via the call
# operator. Using a wrapper (not an inline -Command) keeps -File exit-code
# semantics and avoids fragile quote-nesting inside the scheduled-task argument.
$hbLauncherPath = Join-Path $InstallDir "cxs-agent-$StoreCode.ps1"
$hbLauncher = @"
# Auto-generated per-store launcher for the CXS heartbeat agent (issue #53). Do not edit.
`$env:CXS_CONFIG_FILE = "$InstallDir\config\cxs-agent-$StoreCode.json"
& "`$PSScriptRoot\cxs-agent.ps1"
exit `$LASTEXITCODE
"@
Set-Content -Path $hbLauncherPath -Value $hbLauncher -Encoding UTF8
Write-Host "  Heartbeat launcher written: $hbLauncherPath" -ForegroundColor Green

$hbAction = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$hbLauncherPath`"" `
    -WorkingDirectory $InstallDir

$hbTrigger = New-ScheduledTaskTrigger -AtStartup

$hbPrincipal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

# The heartbeat agent is a persistent forever-loop. Without -ExecutionTimeLimit,
# New-ScheduledTaskSettingsSet defaults to PT72H, so Task Scheduler force-stops it
# after 3 days and it stays dark until reboot/reinstall (the -AtStartup trigger only
# re-runs at boot; -RestartCount covers action failures, not a time-limit stop).
# [TimeSpan]::Zero => PT0S = "run indefinitely". The daily collector task is
# short-lived, so it intentionally keeps the default limit.
$hbSettings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 10)

Register-ScheduledTask `
    -TaskName $HeartbeatTaskName `
    -Action $hbAction `
    -Trigger $hbTrigger `
    -Principal $hbPrincipal `
    -Settings $hbSettings `
    -Description "CXS Agent - heartbeat and command execution for $StoreCode" | Out-Null

Start-ScheduledTask -TaskName $HeartbeatTaskName
Write-Host "  [OK] Heartbeat task created and started: $HeartbeatTaskName" -ForegroundColor Green

# Read-back self-check: confirm Task Scheduler actually persisted the unlimited
# ExecutionTimeLimit. Some Server 2012 / PS 4.0 CIM paths can drop a zero TimeSpan
# to a finite default; a finite PTnn here means the 3-day force-stop bug silently
# survived and the store would go dark again in ~3 days. Good = PT0S or empty/null.
try {
    $hbEtl = (Get-ScheduledTask -TaskName $HeartbeatTaskName).Settings.ExecutionTimeLimit
    if ([string]::IsNullOrEmpty($hbEtl) -or $hbEtl -eq "PT0S") {
        Write-Host "  [OK] Heartbeat ExecutionTimeLimit = '$hbEtl' (no 3-day force-stop)." -ForegroundColor Green
    } else {
        Write-Host "  [WARN] Heartbeat ExecutionTimeLimit = '$hbEtl' (expected PT0S/none) - Task Scheduler may force-stop the agent after that limit, taking the store dark. Verify: Export-ScheduledTask -TaskName '$HeartbeatTaskName'" -ForegroundColor Red
    }
} catch {
    Write-Host "  [WARN] Could not read back heartbeat ExecutionTimeLimit: $($_.Exception.Message)" -ForegroundColor Yellow
}

# Verify the heartbeat actually works in the SYSTEM context (the agent's real
# context - different cert/proxy than the interactive operator). A green install
# checkin does NOT prove this, so confirm against the agent's own log and warn
# loudly instead of leaving the store silently dark.
Write-Host "  Verifying heartbeat in the SYSTEM context..."
$agentLog = "C:\CXS\logs\agent-$StoreCode.log"
$deadline = (Get-Date).AddSeconds(45); $hbOk = $false; $hbErr = $null
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 5
    if (Test-Path $agentLog) {
        $tail = Get-Content $agentLog -Tail 40 -ErrorAction SilentlyContinue
        if ($tail -match 'Heartbeat sent') { $hbOk = $true; break }
        $m = $tail | Select-String 'PartialChain|establish trust|SSL/TLS|\b407\b|Unauthorized|Unable to connect|timed out' | Select-Object -Last 1
        if ($m) { $hbErr = $m.ToString().Trim() }
    }
}
if ($hbOk) {
    Write-Host "  [OK] SYSTEM-context heartbeat confirmed - store is reporting." -ForegroundColor Green
} else {
    Write-Host "  [WARN] Heartbeat NOT confirmed as SYSTEM within 45s - this store will not report." -ForegroundColor Red
    if ($hbErr) { Write-Host "         Agent log: $hbErr" -ForegroundColor Red }
    Write-Host "         Check: Get-Content $agentLog -Tail 60 ; certutil -store Root ; netsh winhttp show proxy" -ForegroundColor Yellow
    Write-Host "         Stopgap: re-run with -AllowSelfSignedCert." -ForegroundColor Yellow
}

# Done
Write-Host ""
Write-Host "=== Installation Complete ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "Store:          $StoreCode ($OracleCode)"
Write-Host "Brand:          $Brand"
Write-Host "Files:          $InstallDir\$ScriptName"
Write-Host "Agent:          $InstallDir\cxs-agent.ps1 (via launcher $InstallDir\cxs-agent-$StoreCode.ps1)"
Write-Host "Agent config:   $InstallDir\config\cxs-agent-$StoreCode.json"
Write-Host "Scheduled task: '$TaskName' (daily at $SyncTime)"
Write-Host "Heartbeat task: '$HeartbeatTaskName' (at startup)"
Write-Host "Logs:           sync C:\CXS\logs\sync-$StoreCode.log  |  agent C:\CXS\logs\agent-$StoreCode.log"
Write-Host ""
Write-Host "To run a sync manually:" -ForegroundColor Yellow
Write-Host "  powershell -File `"$(Join-Path $InstallDir $ScriptName)`"" -ForegroundColor Yellow
Write-Host ""
