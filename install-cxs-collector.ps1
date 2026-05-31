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
      Wendy's → 5:00AM (24-hour stores close out the previous day)
      Conti's → 2:00AM (existing schedule)
    Pass -SyncTime explicitly to override.

.PARAMETER Brand
    REQUIRED. The brand for this install: "wendys" or "contis". No default —
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

    # OracleCode is metadata only — Wendy's uses it (e.g. 4058), Conti's doesn't.
    # Non-mandatory + AllowEmptyString so Conti's installs can pass "" or omit.
    [Parameter(Mandatory=$false)]
    [AllowEmptyString()]
    [string]$OracleCode = "",

    # Default-by-brand resolved below (Wendy's 5:00AM, Conti's 2:00AM)
    # per MOM 2026-05-20. Empty string here means "use brand default."
    [Parameter(Mandatory=$false)]
    [string]$SyncTime = "",

    # Brand is REQUIRED — no default. Was defaulting to "wendys" until
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
    # chain (e.g. Cloudflare). Never enable unless strictly required — disabling
    # TLS validation exposes the bearer token to MITM interception.
    [switch]$AllowSelfSignedCert
)

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

# Write agent config file
$agentConfig = @{
    ApiUrl    = $ApiUrl
    ApiKey    = $ApiKey
    Brand     = $Brand
    StoreCode = $StoreCode
    SqlServer = $SqlServer
    Database  = $Database
    Company   = $Company
    AllowSelfSignedCert = [bool]$AllowSelfSignedCert
}
$agentConfigPath = Join-Path $InstallDir "config\cxs-agent.json"
$agentConfig | ConvertTo-Json -Depth 5 | Set-Content -Path $agentConfigPath -Encoding UTF8
Write-Host "  Agent config written to: $agentConfigPath" -ForegroundColor Green

# 3. Test SQL + send install checkin to collector
Write-Host "[3/4] Testing SQL + sending install checkin..."
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
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
    Write-Host "WARN: AllowSelfSignedCert — TLS certificate validation is DISABLED." -ForegroundColor Yellow
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

# Check for tables (both LS Central and NAV format)
try {
    $testConn2 = New-Object System.Data.SqlClient.SqlConnection(
        "Server=$SqlServer;Database=$Database;Integrated Security=True;TrustServerCertificate=True;Connection Timeout=10;"
    )
    $testConn2.Open()
    $cmd = $testConn2.CreateCommand()
    $cmd.CommandText = "SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME LIKE '%Transaction Header%'"
    $tableCount = $cmd.ExecuteScalar()
    $testConn2.Close()
    if ($tableCount -gt 0) {
        Write-Host "  [OK] Found $tableCount transaction table(s)" -ForegroundColor Green
    }
    else {
        Write-Host "  [WARN] No transaction tables found - check database name" -ForegroundColor Yellow
    }
}
catch {
    # Don't swallow silently — surface the table check failure (was an empty catch).
    Write-Host "  [WARN] Could not verify transaction tables: $($_.Exception.Message)" -ForegroundColor Yellow
}

# Send checkin
try {
    $checkinUrl = "$ApiUrl" -replace '/api/collect$', '/api/collect/checkin'
    $json = $checkin | ConvertTo-Json -Depth 5 -Compress
    $headers = @{
        "Content-Type"  = "application/json"
        "Authorization" = "Bearer $ApiKey"
    }
    $response = Invoke-RestMethod -Uri $checkinUrl -Method POST -Body $json -Headers $headers -TimeoutSec 15
    Write-Host "  [OK] Install checkin sent to collector" -ForegroundColor Green
}
catch {
    Write-Host "  [WARN] Could not send checkin: $_" -ForegroundColor Yellow
    Write-Host "         The agent will still be installed - check network if this persists" -ForegroundColor Yellow
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

$hbAction = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$InstallDir\cxs-agent.ps1`"" `
    -WorkingDirectory $InstallDir

$hbTrigger = New-ScheduledTaskTrigger -AtStartup

$hbPrincipal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

$hbSettings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
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

# Done
Write-Host ""
Write-Host "=== Installation Complete ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "Store:          $StoreCode ($OracleCode)"
Write-Host "Brand:          $Brand"
Write-Host "Files:          $InstallDir\$ScriptName"
Write-Host "Agent:          $InstallDir\cxs-agent.ps1"
Write-Host "Agent config:   $InstallDir\config\cxs-agent.json"
Write-Host "Scheduled task: '$TaskName' (daily at $SyncTime)"
Write-Host "Heartbeat task: '$HeartbeatTaskName' (at startup)"
Write-Host "Logs:           C:\CXS\logs\sync-$StoreCode.log"
Write-Host ""
Write-Host "To run a sync manually:" -ForegroundColor Yellow
Write-Host "  powershell -File `"$(Join-Path $InstallDir $ScriptName)`"" -ForegroundColor Yellow
Write-Host ""
