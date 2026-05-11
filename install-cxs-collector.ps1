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
    The daily sync time in HH:mmAM/PM format (e.g. "2:00AM", "3:30AM"). Defaults to "2:00AM".

.PARAMETER Brand
    The brand for this install: "wendys" or "contis". Defaults to "wendys".

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

    [Parameter(Mandatory=$true)]
    [string]$OracleCode,

    [Parameter(Mandatory=$false)]
    [string]$SyncTime = "2:00AM",

    [Parameter(Mandatory=$false)]
    [ValidateSet("wendys", "contis")]
    [string]$Brand = "wendys",

    [Parameter(Mandatory=$false)]
    [string]$Company = "WENDYS PH",

    [Parameter(Mandatory=$false)]
    [string]$ExtGuid = "5ecfc871-5d82-43f1-9c54-59685e82318d"
)

$InstallDir = "C:\CXS"
$ScriptName = "cxs-collector-$StoreCode.ps1"
$TaskName   = "CXS Daily Sync - $StoreCode"

Write-Host ""
Write-Host "=== CXS Collector Installer ===" -ForegroundColor Cyan
Write-Host ""

# 1. Create install directory
Write-Host "[1/4] Creating install directory: $InstallDir"
if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
}
New-Item -ItemType Directory -Path "$InstallDir\logs" -Force | Out-Null

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

# 3. Test SQL + send install checkin to collector
Write-Host "[3/4] Testing SQL + sending install checkin..."
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
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
        "Server=$SqlServer;Database=$Database;Integrated Security=True;TrustServerCertificate=True;"
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
catch {}

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

# Remove existing task if present
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

# Done
Write-Host ""
Write-Host "=== Installation Complete ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "Store:          $StoreCode ($OracleCode)"
Write-Host "Brand:          $Brand"
Write-Host "Files:          $InstallDir\$ScriptName"
Write-Host "Scheduled task: '$TaskName' (daily at $SyncTime)"
Write-Host "Logs:           C:\CXS\logs\sync-$StoreCode.log"
Write-Host ""
Write-Host "To run a sync manually:" -ForegroundColor Yellow
Write-Host "  powershell -File `"$(Join-Path $InstallDir $ScriptName)`"" -ForegroundColor Yellow
Write-Host ""
