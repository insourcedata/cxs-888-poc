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

.EXAMPLE
    .\install-cxs-collector.ps1 -ApiUrl "https://888.insourcedata.org/api/collect" -ApiKey "key123" -SqlServer "localhost" -Database "WSMOD8" -StoreCode "S059" -OracleCode "4020"

.EXAMPLE
    .\install-cxs-collector.ps1 -ApiUrl "https://888.insourcedata.org/api/collect" -ApiKey "key123" -SqlServer "ITLAB-SVR-AZ\np-master" -Database "NEWPOS" -StoreCode "DK003" -OracleCode "4058"
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
    [string]$OracleCode
)

$InstallDir = "C:\CXS"
$ScriptName = "cxs-collector.ps1"
$TaskName = "CXS Daily Sync"

Write-Host ""
Write-Host "=== CXS Collector Installer ===" -ForegroundColor Cyan
Write-Host ""

# 1. Create install directory
Write-Host "[1/5] Creating install directory: $InstallDir"
if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
}
New-Item -ItemType Directory -Path "$InstallDir\logs" -Force | Out-Null

# 2. Copy collector script and set configuration
Write-Host "[2/5] Installing collector script..."
$sourceScript = Join-Path $PSScriptRoot $ScriptName
if (-not (Test-Path $sourceScript)) {
    Write-Host "  ERROR: $ScriptName not found in $PSScriptRoot" -ForegroundColor Red
    exit 1
}

$scriptContent = Get-Content $sourceScript -Raw

# Replace configuration placeholders
$scriptContent = $scriptContent -replace 'ApiUrl\s*=\s*"[^"]*"', "ApiUrl     = `"$ApiUrl`""
$scriptContent = $scriptContent -replace 'ApiKey\s*=\s*"[^"]*"', "ApiKey     = `"$ApiKey`""
$scriptContent = $scriptContent -replace 'SqlServer\s*=\s*"[^"]*"', "SqlServer  = `"$SqlServer`""
$scriptContent = $scriptContent -replace 'Database\s*=\s*"[^"]*"', "Database   = `"$Database`""
$scriptContent = $scriptContent -replace 'StoreCode\s*=\s*"[^"]*"', "StoreCode  = `"$StoreCode`""
$scriptContent = $scriptContent -replace 'OracleCode\s*=\s*"[^"]*"', "OracleCode = `"$OracleCode`""

$destScript = Join-Path $InstallDir $ScriptName
Set-Content -Path $destScript -Value $scriptContent
Write-Host "  Installed to: $destScript" -ForegroundColor Green

# 3. Test SQL Server connection
Write-Host "[3/5] Testing SQL Server connection..."
try {
    $connString = "Server=$SqlServer;Database=$Database;Integrated Security=True;TrustServerCertificate=True;"
    $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
    $conn.Open()

    # Check for LS Central tables
    $cmd = $conn.CreateCommand()
    $cmd.CommandText = "SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME LIKE '%LSC Transaction Header%'"
    $tableCount = $cmd.ExecuteScalar()
    $conn.Close()

    if ($tableCount -gt 0) {
        Write-Host "  [OK] SQL Server connection: $SqlServer — $Database" -ForegroundColor Green
        Write-Host "  [OK] Tables found: $tableCount LS Central transaction table(s)" -ForegroundColor Green
    }
    else {
        Write-Host "  [WARN] Connected to SQL Server but no LS Central tables found" -ForegroundColor Yellow
        Write-Host "         Check that '$Database' is the correct database name" -ForegroundColor Yellow
    }
}
catch {
    Write-Host "  [FAIL] Could not connect to SQL Server: $_" -ForegroundColor Red
    Write-Host "         Make sure SQL Server is running and the database name is correct" -ForegroundColor Red
}

# 4. Test API connectivity
Write-Host "[4/5] Testing API connectivity..."
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
try {
    $testPayload = @{
        storeCode  = $StoreCode
        oracleCode = $OracleCode
        test       = $true
    } | ConvertTo-Json

    $headers = @{
        "Content-Type"  = "application/json"
        "Authorization" = "Bearer $ApiKey"
        "X-Store-Code"  = $StoreCode
    }

    $response = Invoke-RestMethod -Uri "$ApiUrl/health" -Method POST -Body $testPayload -Headers $headers -TimeoutSec 10
    Write-Host "  [OK] Test POST to $ApiUrl — 200 OK" -ForegroundColor Green
}
catch {
    Write-Host "  [WARN] Could not reach API: $_" -ForegroundColor Yellow
    Write-Host "         The script will still be installed — check network/firewall if this persists" -ForegroundColor Yellow
}

# 5. Register scheduled task
Write-Host "[5/5] Creating scheduled task: '$TaskName' ..."

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

# Daily at 2:00 AM
$trigger = New-ScheduledTaskTrigger -Daily -At "2:00AM"

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
    -Description "CXS Dashboard — daily data sync to collector API" | Out-Null

Write-Host "  [OK] Scheduled Task created: $TaskName — 2:00 AM daily" -ForegroundColor Green

# Done
Write-Host ""
Write-Host "=== Installation Complete ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "Files installed to: $InstallDir"
Write-Host "Scheduled task: '$TaskName' (daily at 2:00 AM)"
Write-Host "Logs: $InstallDir\logs\sync.log"
Write-Host ""
Write-Host "To run a sync manually:" -ForegroundColor Yellow
Write-Host "  powershell -File `"$destScript`"" -ForegroundColor Yellow
Write-Host ""
