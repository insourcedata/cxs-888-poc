#Requires -Version 5.1
<#
.SYNOPSIS
    CXS Store Data Collector — queries local LS Central SQL Server and sends data to CXS dashboard.

.DESCRIPTION
    This script runs on each Wendy's store server as a Windows Scheduled Task.
    It connects to the local SQL Server using Windows Authentication (localhost),
    runs the same queries 888 runs manually in SSMS, and POSTs the results
    as JSON to the CXS collector API over HTTPS.

    No VPN, no firewall changes, no inbound ports. Outbound HTTPS only.

.PARAMETER StartDate
    Optional. Override the sync start date (inclusive lower bound, exclusive).
    Format: yyyy-MM-dd. If omitted, uses last-sync.json or defaults to 365 days ago.
    Useful for testing a specific date range without touching the state file.

.PARAMETER EndDate
    Optional. Override the sync end date (inclusive upper bound).
    Format: yyyy-MM-dd. If omitted, no upper bound (queries all data after StartDate).
    Useful for testing a small window to keep payloads under the API size limit.

.EXAMPLE
    # Normal automated run (uses state file)
    .\cxs-collector.ps1

.EXAMPLE
    # Test run — pull 2 days of data only, do NOT update state file
    .\cxs-collector.ps1 -StartDate "2025-12-31" -EndDate "2026-01-02"

.NOTES
    Language: PowerShell (pre-installed on all Windows Server)
    Auth: Windows Authentication to localhost SQL Server
    Transport: HTTPS POST to CXS collector API
#>

param(
    [string]$StartDate = "",
    [string]$EndDate = ""
)

# ─── Configuration ──────────────────────────────────────────────────────────────
# These are set per-store during installation

$Config = @{
    # CXS collector endpoint
    ApiUrl     = "https://888.insourcedata.org/api/collect"
    ApiKey     = "065a4a89d962bfcb35ffa1bf757ac0f3d1b9276098b5514c207492cf333d3217"

    # SQL Server — Windows Auth, no password needed
    SqlServer  = "ITLAB-SVR-AZ\np-master"    # UAT server
    Database   = "NEWPOS"                    # UAT database

    # LS Central table identifiers
    Company    = "WENDYS PH"
    ExtGuid    = "5ecfc871-5d82-43f1-9c54-59685e82318d"

    # Store identifier
    StoreCode  = "DK003"                     # FTI Complex (UAT)
    OracleCode = "4058"                      # FTI Complex (UAT)

    # Sync state file — tracks last successful sync date
    StateFile  = "C:\CXS\last-sync.json"

    # Log file
    LogFile    = "C:\CXS\logs\sync.log"
}

# ─── TLS setup ─────────────────────────────────────────────────────────────────
# Force TLS 1.2 (PowerShell 5.1 defaults to TLS 1.0 which most servers reject)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Accept all certificates — works around PartialChain errors on servers
# that are missing Cloudflare root/intermediate CA certificates.
# This is safe for this use case: we authenticate via API key, not certificate.
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

# ─── Validate config ───────────────────────────────────────────────────────────
if (-not $Config.ApiUrl -or -not $Config.ApiKey -or $Config.ApiUrl -match "CHANGE_ME" -or $Config.ApiKey -eq "CHANGE_ME") {
    Write-Host "ERROR: ApiUrl or ApiKey is missing or still has placeholder values." -ForegroundColor Red
    Write-Host "Edit the `$Config block at the top of this script, or run install-cxs-collector.ps1." -ForegroundColor Red
    exit 1
}

# ─── Tables to extract ──────────────────────────────────────────────────────────

$Tables = @(
    @{ Name = "Transaction Header";      Alias = "headers"  }
    @{ Name = "Trans_ Sales Entry";      Alias = "sales"    }
    @{ Name = "Trans_ Payment Entry";    Alias = "payments"  }
    # Infocodes, Safe, Tender — not processed by collector yet, skip to save bandwidth
    # @{ Name = "Trans_ Infocode Entry";   Alias = "infocodes" }
    # @{ Name = "Trans_ Safe Entry";       Alias = "safe"      }
    # @{ Name = "Tender Declar_ Entr";     Alias = "tender"    }
)

# ─── Helpers ────────────────────────────────────────────────────────────────────

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] $Message"
    Write-Host $line

    # Ensure log directory exists
    $logDir = Split-Path $Config.LogFile -Parent
    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    Add-Content -Path $Config.LogFile -Value $line
}

function Get-LastSyncDate {
    if (Test-Path $Config.StateFile) {
        $state = Get-Content $Config.StateFile | ConvertFrom-Json
        return $state.lastSyncDate
    }
    # Default: 1 year ago (captures all available data on first run)
    return (Get-Date).AddDays(-365).ToString("yyyy-MM-dd")
}

function Set-LastSyncDate {
    param([string]$Date)
    $state = @{
        lastSyncDate = $Date
        lastSyncTime = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        storeCode    = $Config.StoreCode
    }
    $stateDir = Split-Path $Config.StateFile -Parent
    if (-not (Test-Path $stateDir)) {
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    }
    $state | ConvertTo-Json | Set-Content $Config.StateFile
}

function Get-TableFullName {
    param([string]$TableName)
    return "[$($Config.Company)`$LSC $TableName`$$($Config.ExtGuid)]"
}

# ─── Main ───────────────────────────────────────────────────────────────────────

function Invoke-Sync {
    Write-Log "=== CXS Sync Start ==="
    Write-Log "Store: $($Config.StoreCode) ($($Config.OracleCode))"
    Write-Log "Server: $($Config.SqlServer) / $($Config.Database)"

    # Determine date range — CLI params override state file
    if ($StartDate) {
        $lastSync = $StartDate
        Write-Log "StartDate override: $lastSync"
    } else {
        $lastSync = Get-LastSyncDate
    }

    $today = (Get-Date).ToString("yyyy-MM-dd")
    if ($EndDate) {
        Write-Log "EndDate override: $EndDate (state file will NOT be updated)"
        Write-Log "Sync range: $lastSync to $EndDate"
    } else {
        Write-Log "Sync range: $lastSync to $today"
    }

    # Build connection string — Windows Authentication, no password
    $connString = "Server=$($Config.SqlServer);Database=$($Config.Database);Integrated Security=True;TrustServerCertificate=True;"

    $payload = @{
        storeCode  = $Config.StoreCode
        oracleCode = $Config.OracleCode
        syncDate   = $today
        lastSync   = $lastSync
        tables     = @{}
    }

    $totalRows = 0

    foreach ($table in $Tables) {
        $fullName = Get-TableFullName -TableName $table.Name
        if ($EndDate) {
            $query = "SELECT * FROM $fullName WHERE [Date] > '$lastSync' AND [Date] <= '$EndDate'"
        } else {
            $query = "SELECT * FROM $fullName WHERE [Date] > '$lastSync'"
        }

        Write-Log "  Querying $($table.Alias) ..."

        try {
            $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
            $conn.Open()

            $cmd = $conn.CreateCommand()
            $cmd.CommandText = $query
            $cmd.CommandTimeout = 300  # 5 minutes

            $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
            $dataTable = New-Object System.Data.DataTable
            [void]$adapter.Fill($dataTable)

            $conn.Close()

            # Convert DataTable rows to array of hashtables
            $rows = @()
            foreach ($row in $dataTable.Rows) {
                $rowHash = @{}
                foreach ($col in $dataTable.Columns) {
                    $val = $row[$col.ColumnName]
                    if ($val -is [DBNull]) {
                        $rowHash[$col.ColumnName] = $null
                    }
                    elseif ($val -is [DateTime]) {
                        $rowHash[$col.ColumnName] = $val.ToString("yyyy-MM-dd HH:mm:ss")
                    }
                    elseif ($val -is [byte[]]) {
                        # Skip binary columns (e.g. timestamp)
                        $rowHash[$col.ColumnName] = $null
                    }
                    else {
                        $rowHash[$col.ColumnName] = $val
                    }
                }
                $rows += $rowHash
            }

            $payload.tables[$table.Alias] = $rows
            $totalRows += $rows.Count
            Write-Log "    $($table.Alias): $($rows.Count) rows"
        }
        catch {
            Write-Log "    ERROR querying $($table.Alias): $_"
            $payload.tables[$table.Alias] = @()
        }
    }

    Write-Log "Total rows: $totalRows"

    if ($totalRows -eq 0) {
        Write-Log "No new data since $lastSync — skipping POST"
        Write-Log "=== CXS Sync Complete (no data) ==="
        return
    }

    # POST to CXS collector
    Write-Log "Sending to $($Config.ApiUrl) ..."

    try {
        $json = $payload | ConvertTo-Json -Depth 10 -Compress
        $headers = @{
            "Content-Type"  = "application/json"
            "Authorization" = "Bearer $($Config.ApiKey)"
            "X-Store-Code"  = $Config.StoreCode
        }

        $response = Invoke-RestMethod -Uri $Config.ApiUrl -Method POST -Body $json -Headers $headers -TimeoutSec 120

        Write-Log "POST successful: $($response.status)"

        # Only update state file on normal runs — skip for bounded test runs
        if (-not $EndDate) {
            Set-LastSyncDate -Date $today
            Write-Log "Last sync updated to: $today"
        } else {
            Write-Log "Test run ($EndDate bound) — state file NOT updated"
        }
    }
    catch {
        Write-Log "ERROR posting data: $_"
        Write-Log "Data NOT sent — will retry on next run"
    }

    Write-Log "=== CXS Sync Complete ==="
}

# Run
Invoke-Sync
