#Requires -Version 5.1
<#
.SYNOPSIS
    CXS Store Data Collector — queries local LS Central SQL Server and sends data to CXS dashboard.

.DESCRIPTION
    Runs on each Wendy's store server. Queries the local LS Central SQL Server
    (Windows Auth) and POSTs the results as JSON to the CXS collector API.

    No VPN, no firewall changes, no inbound ports. Outbound HTTPS only.

    TWO MODES:

    1. DAILY SYNC (default, no args) — for the Windows Scheduled Task.
       Queries exactly one day's worth of data: yesterday.
       One POST. No state file — yesterday is always deterministic.

    2. BACKFILL (-StartDate -EndDate) — for manual backfills / gap recovery.
       Walks the range one day at a time, one POST per day. If a day fails,
       the script stops and logs which day failed. Safe to re-run — the
       collector's processor is idempotent (same data won't be inserted twice).

.PARAMETER StartDate
    Optional. Backfill mode lower bound (inclusive). Format: yyyy-MM-dd.
    Must be supplied together with -EndDate.

.PARAMETER EndDate
    Optional. Backfill mode upper bound (inclusive). Format: yyyy-MM-dd.
    Must be supplied together with -StartDate.

.EXAMPLE
    # Daily sync — runs by scheduled task at 02:00, queries yesterday only
    .\cxs-collector.ps1

.EXAMPLE
    # Backfill January 2026 one day at a time
    .\cxs-collector.ps1 -StartDate "2026-01-01" -EndDate "2026-01-31"

.EXAMPLE
    # Re-sync a single day (e.g. after a failed overnight run)
    .\cxs-collector.ps1 -StartDate "2026-04-09" -EndDate "2026-04-09"

.NOTES
    Language: PowerShell 5.1 (pre-installed on all Windows Server)
    Auth:     Windows Authentication to local SQL Server
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

# Validate param pairing — backfill needs both or neither
if (($StartDate -and -not $EndDate) -or ($EndDate -and -not $StartDate)) {
    Write-Host "ERROR: -StartDate and -EndDate must be supplied together (backfill mode)." -ForegroundColor Red
    Write-Host "       Omit both for daily sync mode (queries yesterday)." -ForegroundColor Red
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

    $logDir = Split-Path $Config.LogFile -Parent
    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    Add-Content -Path $Config.LogFile -Value $line
}

function Get-TableFullName {
    param([string]$TableName)
    return "[$($Config.Company)`$LSC $TableName`$$($Config.ExtGuid)]"
}

# ─── Per-day sync ───────────────────────────────────────────────────────────────
# Queries all three LS tables for a single date, builds the payload, POSTs.
# Returns $true on success (HTTP 200), $false on any failure.

function Invoke-DaySync {
    param([string]$Day)

    $connString = "Server=$($Config.SqlServer);Database=$($Config.Database);Integrated Security=True;TrustServerCertificate=True;"

    $payload = @{
        storeCode  = $Config.StoreCode
        oracleCode = $Config.OracleCode
        syncDate   = $Day
        tables     = @{}
    }

    $totalRows = 0

    foreach ($table in $Tables) {
        $fullName = Get-TableFullName -TableName $table.Name
        $query = "SELECT * FROM $fullName WHERE [Date] = '$Day'"

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
                        # Skip binary columns (e.g. rowversion/timestamp)
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
        }
        catch {
            Write-Log "  [$Day] ERROR querying $($table.Alias): $_"
            return $false
        }
    }

    if ($totalRows -eq 0) {
        Write-Log "  [$Day] no rows — skipping POST"
        return $true  # empty day is a "success" — don't want to block the backfill loop
    }

    Write-Log ("  [$Day] {0} headers, {1} sales, {2} payments — POSTing…" -f `
        $payload.tables.headers.Count, $payload.tables.sales.Count, $payload.tables.payments.Count)

    try {
        $json = $payload | ConvertTo-Json -Depth 10 -Compress
        $headers = @{
            "Content-Type"  = "application/json"
            "Authorization" = "Bearer $($Config.ApiKey)"
            "X-Store-Code"  = $Config.StoreCode
        }

        $response = Invoke-RestMethod -Uri $Config.ApiUrl -Method POST -Body $json -Headers $headers -TimeoutSec 120

        Write-Log "  [$Day] POST ok: $($response.status)"
        return $true
    }
    catch {
        Write-Log "  [$Day] ERROR posting: $_"
        return $false
    }
}

# ─── Main ───────────────────────────────────────────────────────────────────────

function Invoke-Sync {
    Write-Log "=== CXS Sync Start ==="
    Write-Log "Store:  $($Config.StoreCode) ($($Config.OracleCode))"
    Write-Log "Server: $($Config.SqlServer) / $($Config.Database)"

    # Figure out which days to sync
    if ($StartDate) {
        # Backfill mode
        try {
            $start = [DateTime]::ParseExact($StartDate, "yyyy-MM-dd", $null)
            $end   = [DateTime]::ParseExact($EndDate,   "yyyy-MM-dd", $null)
        }
        catch {
            Write-Log "ERROR: -StartDate / -EndDate must be in yyyy-MM-dd format."
            return
        }

        if ($end -lt $start) {
            Write-Log "ERROR: -EndDate ($EndDate) is before -StartDate ($StartDate)."
            return
        }

        $days = @()
        $cursor = $start
        while ($cursor -le $end) {
            $days += $cursor.ToString("yyyy-MM-dd")
            $cursor = $cursor.AddDays(1)
        }

        Write-Log "Mode: BACKFILL — $($days.Count) day(s) from $StartDate to $EndDate"
    }
    else {
        # Daily sync mode — yesterday only
        $yesterday = (Get-Date).Date.AddDays(-1).ToString("yyyy-MM-dd")
        $days = @($yesterday)
        Write-Log "Mode: DAILY — syncing yesterday ($yesterday)"
    }

    # Walk days in order, stop on first failure
    $succeeded = 0
    $failed    = $null
    foreach ($day in $days) {
        $ok = Invoke-DaySync -Day $day
        if (-not $ok) {
            $failed = $day
            break
        }
        $succeeded++
    }

    if ($failed) {
        Write-Log "=== CXS Sync FAILED on $failed (completed $succeeded/$($days.Count) days) ==="
        Write-Log "Re-run with: .\cxs-collector.ps1 -StartDate `"$failed`" -EndDate `"$($days[-1])`""
        exit 1
    }

    Write-Log "=== CXS Sync Complete — $succeeded/$($days.Count) days ok ==="
}

# Run
Invoke-Sync
