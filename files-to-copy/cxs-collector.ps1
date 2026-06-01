#Requires -Version 5.1
<#
.SYNOPSIS
    CXS Store Data Collector - queries local LS Central SQL Server and sends data to CXS dashboard.

.DESCRIPTION
    Runs on each Wendy's store server. Queries the local LS Central SQL Server
    (Windows Auth) and POSTs the results as JSON to the CXS collector API.

    No VPN, no firewall changes, no inbound ports. Outbound HTTPS only.

    TWO MODES:

    1. DAILY SYNC (default, no args) - for the Windows Scheduled Task.
       Queries exactly one day's worth of data: yesterday.
       One POST. No state file - yesterday is always deterministic.

    2. BACKFILL (-StartDate -EndDate) - for manual backfills / gap recovery.
       Walks the range one day at a time, one POST per day. If a day fails,
       the script stops and logs which day failed. Safe to re-run - the
       collector's processor is idempotent (same data won't be inserted twice).

.PARAMETER StartDate
    Optional. Backfill mode lower bound (inclusive). Format: yyyy-MM-dd.
    Must be supplied together with -EndDate.

.PARAMETER EndDate
    Optional. Backfill mode upper bound (inclusive). Format: yyyy-MM-dd.
    Must be supplied together with -StartDate.

.EXAMPLE
    # Daily sync - runs by scheduled task at the brand-default time
    # (Wendy's 05:00, Conti's 02:00 per MOM 2026-05-20). Queries yesterday only.
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

# --- Configuration --------------------------------------------------------------
# Defaults — non-sensitive values only. The API key and per-store fields
# (StoreCode, OracleCode, SqlServer, etc.) MUST be provisioned via the
# cxs-agent.json config file at install time. The file is gitignored.

$Config = @{
    # CXS collector endpoint
    ApiUrl     = "https://888.insourcedata.org/api/collect"
    ApiKey     = ""                           # MUST come from config file or $env:CXS_API_KEY

    # SQL Server - Windows Auth, no password needed
    SqlServer  = ""                           # per-store
    Database   = "NEWPOS"

    # Brand - "wendys" or "contis". Picks the right caches/normalisers
    # server-side when the payload lands. REQUIRED — must be set in the
    # per-store config file. The default is intentionally empty (was
    # "wendys" until 2026-05-26) so a Conti's install that copy-pasted
    # the Wendy's config can't silently misfile its data; the validation
    # block below hard-fails the script if Brand is unset or unknown.
    Brand      = ""

    # LS Central table identifiers - vary by brand/installation
    Company    = "WENDYS PH"
    ExtGuid    = "5ecfc871-5d82-43f1-9c54-59685e82318d"

    # Store identifier
    StoreCode  = ""                           # per-store
    OracleCode = ""                           # per-store

    # Log file
    LogFile    = "C:\CXS\logs\sync.log"

    # Cert handling — opt-in trust-all, off by default
    AllowSelfSignedCert = $false
}

# Merge config file values over defaults
$ConfigFile = if ($env:CXS_CONFIG_FILE) { $env:CXS_CONFIG_FILE } else { "C:\CXS\config\cxs-agent.json" }
if (Test-Path $ConfigFile) {
    try {
        $fileConfig = Get-Content $ConfigFile -Raw | ConvertFrom-Json
        foreach ($prop in $fileConfig.PSObject.Properties) {
            $Config[$prop.Name] = $prop.Value
        }
    } catch {
        Write-Host "ERROR: Failed to parse config file ${ConfigFile}: $_" -ForegroundColor Red
        exit 1
    }
}

if ($env:CXS_API_KEY) { $Config.ApiKey = $env:CXS_API_KEY }

# --- TLS setup -----------------------------------------------------------------
# Force TLS 1.2 (PowerShell 5.1 defaults to TLS 1.0 which most servers reject)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Cert validation is ON by default. AllowSelfSignedCert is an explicit
# escape hatch for installs whose root-CA store is missing Cloudflare's chain.
if ($Config.AllowSelfSignedCert) {
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
    Write-Host "WARN: AllowSelfSignedCert=true — TLS certificate validation is DISABLED." -ForegroundColor Yellow
}

# --- Agent version ----------------------------------------------------------------
$AgentVersion = "2.0"

# --- Telemetry --------------------------------------------------------------------

function Send-Checkin {
    param(
        [string]$Event,
        [string]$ErrorMessage = ""
    )

    $checkin = @{
        storeCode    = $Config.StoreCode
        brand        = $Config.Brand
        event        = $Event
        agentVersion = $AgentVersion
        hostname     = $env:COMPUTERNAME
        osVersion    = [System.Environment]::OSVersion.VersionString
        psVersion    = $PSVersionTable.PSVersion.ToString()
        runAsUser    = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        sqlServer    = $Config.SqlServer
        sqlDatabase  = $Config.Database
    }

    # System resources
    try {
        $cDrive = Get-WmiObject Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction SilentlyContinue
        if ($cDrive) {
            $checkin.diskFreeGb  = [math]::Round($cDrive.FreeSpace / 1GB, 1).ToString()
            $checkin.diskTotalGb = [math]::Round($cDrive.Size / 1GB, 1).ToString()
        }

        $os = Get-WmiObject Win32_OperatingSystem -ErrorAction SilentlyContinue
        if ($os) {
            $checkin.ramFreeGb  = [math]::Round(($os.FreePhysicalMemory / 1MB), 1).ToString()
            $checkin.ramTotalGb = [math]::Round(($os.TotalVisibleMemorySize / 1MB), 1).ToString()
            $lastBoot = $os.ConvertToDateTime($os.LastBootUpTime)
            $checkin.lastRebootAt = $lastBoot.ToString("yyyy-MM-dd HH:mm:ss")
            $uptime = (Get-Date) - $lastBoot
            $checkin.systemUptime = "{0}d {1}h {2}m" -f $uptime.Days, $uptime.Hours, $uptime.Minutes
        }

        $cpu = Get-WmiObject Win32_Processor -ErrorAction SilentlyContinue | Measure-Object -Property LoadPercentage -Average
        if ($null -ne $cpu.Average) {
            $checkin.cpuUsagePercent = [int]$cpu.Average
        }
    }
    catch {}

    # Test SQL connectivity
    try {
        $testConn = New-Object System.Data.SqlClient.SqlConnection(
            "Server=$($Config.SqlServer);Database=$($Config.Database);Integrated Security=True;TrustServerCertificate=True;Connection Timeout=10;"
        )
        $testConn.Open()
        $testConn.Close()
        $checkin.sqlConnectable = $true
        $checkin.sqlError = $null
    }
    catch {
        $checkin.sqlConnectable = $false
        $checkin.sqlError = $_.Exception.Message
    }

    # Scheduled task status
    try {
        $taskName = "CXS Daily Sync"
        # Check store-specific task name first (v2.0+), fall back to legacy
        $task = Get-ScheduledTask -TaskName "CXS Daily Sync - $($Config.StoreCode)" -ErrorAction SilentlyContinue
        if (-not $task) {
            $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        }
        if ($task) {
            $checkin.taskExists = $true
            $info = $task | Get-ScheduledTaskInfo -ErrorAction SilentlyContinue
            if ($info) {
                $checkin.taskLastRun = if ($info.LastRunTime) { $info.LastRunTime.ToString("yyyy-MM-dd HH:mm:ss") } else { $null }
                $checkin.taskLastResult = $info.LastTaskResult
            }
        }
        else {
            $checkin.taskExists = $false
        }
    }
    catch {
        $checkin.taskExists = $null
    }

    # Last 5 lines of sync log — sanitised to strip connection strings,
    # credentials, and Authorization headers before shipping over the wire.
    if (Test-Path $Config.LogFile) {
        try {
            $tail = (Get-Content $Config.LogFile -Tail 5) -join "`n"
            $tail = $tail -replace '(?i)(Server|Database|User Id|Password)\s*=\s*[^;]*;?', '$1=***;'
            $tail = $tail -replace '(?i)Authorization\s*:\s*Bearer\s+\S+', 'Authorization: Bearer ***'
            $checkin.syncLogTail = $tail
        }
        catch {
            Write-Log "  [checkin] Failed to read log tail: $_"
        }
    }

    if ($ErrorMessage) {
        $checkin.errorMessage = $ErrorMessage
    }

    # Send checkin — best-effort, don't block sync on telemetry failure
    try {
        $json = $checkin | ConvertTo-Json -Depth 5 -Compress
        $hdrs = @{
            "Content-Type"  = "application/json"
            "Authorization" = "Bearer $($Config.ApiKey)"
        }
        # Derive checkin URL from ApiUrl
        $checkinUrl = $Config.ApiUrl -replace '/api/collect$', '/api/collect/checkin'
        Invoke-RestMethod -Uri $checkinUrl -Method POST -Body $json -Headers $hdrs -TimeoutSec 15 | Out-Null
    }
    catch {
        Write-Log "  [checkin] Failed to send telemetry: $_"
    }
}

# --- Validate config -----------------------------------------------------------
if (-not $Config.ApiUrl -or $Config.ApiUrl -match "CHANGE_ME") {
    Write-Host "ERROR: ApiUrl is missing or still has placeholder values." -ForegroundColor Red
    Write-Host "Set ApiUrl in ${ConfigFile}." -ForegroundColor Red
    exit 1
}
if (-not $Config.ApiKey -or $Config.ApiKey.Length -lt 16) {
    Write-Host "ERROR: ApiKey is missing or too short. Set it in ${ConfigFile} or $env:CXS_API_KEY." -ForegroundColor Red
    exit 1
}
if (-not $Config.StoreCode -or -not $Config.SqlServer) {
    Write-Host "ERROR: StoreCode and SqlServer must be set in ${ConfigFile}." -ForegroundColor Red
    exit 1
}
# Brand must be explicit. The collector-side fallback ("wendys" if
# missing) is being retired — agents must declare their brand at
# install time so a misconfigured store never silently misfiles its
# data under the wrong brand's outlets.
$KnownBrands = @("wendys", "contis")
if (-not $Config.Brand) {
    Write-Host "ERROR: Brand is missing. Set it to one of: $($KnownBrands -join ', ') in ${ConfigFile}." -ForegroundColor Red
    exit 1
}
$BrandNormalized = $Config.Brand.ToString().Trim().ToLower()
if ($KnownBrands -notcontains $BrandNormalized) {
    Write-Host "ERROR: Brand '$($Config.Brand)' is not recognised. Must be one of: $($KnownBrands -join ', '). Update ${ConfigFile}." -ForegroundColor Red
    exit 1
}
# Persist the normalized form so every downstream payload + checkin
# carries the canonical lowercase value.
$Config.Brand = $BrandNormalized

# Validate param pairing - backfill needs both or neither
if (($StartDate -and -not $EndDate) -or ($EndDate -and -not $StartDate)) {
    Write-Host "ERROR: -StartDate and -EndDate must be supplied together (backfill mode)." -ForegroundColor Red
    Write-Host "       Omit both for daily sync mode (queries yesterday)." -ForegroundColor Red
    exit 1
}

# --- Tables to extract ----------------------------------------------------------

$Tables = @(
    @{ Name = "Transaction Header";      Alias = "headers"  }
    @{ Name = "Trans_ Sales Entry";      Alias = "sales"    }
    @{ Name = "Trans_ Payment Entry";    Alias = "payments"  }
    # Infocodes, Safe, Tender - not processed by collector yet, skip to save bandwidth
    # @{ Name = "Trans_ Infocode Entry";   Alias = "infocodes" }
    # @{ Name = "Trans_ Safe Entry";       Alias = "safe"      }
    # @{ Name = "Tender Declar_ Entr";     Alias = "tender"    }
)

# --- Helpers --------------------------------------------------------------------

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
    # Two table-name conventions seen in the field:
    #   LS Central extension tables (Wendy's UAT): [<Company>$LSC <Table>$<ExtGuid>]
    #   NAV / legacy LS (Conti's NOC):             [<Company>$<Table>]
    # Empty ExtGuid -> NAV format. Wendy's keeps its GUID and gets the LS path.
    if ([string]::IsNullOrWhiteSpace($Config.ExtGuid)) {
        return "[$($Config.Company)`$$TableName]"
    }
    return "[$($Config.Company)`$LSC $TableName`$$($Config.ExtGuid)]"
}

# --- Per-day sync ---------------------------------------------------------------
# Queries all three LS tables for a single date, builds the payload, POSTs.
# Returns $true on success (HTTP 200), $false on any failure.

function Invoke-DaySync {
    param(
        [string]$Day,
        # "daily" — Scheduled-Task run with no args; collector cross-
        # checks each row's transactionDate against syncDate and flags
        # rows that fall outside a tolerance window.
        # "backfill" — operator deliberately ran -StartDate/-EndDate;
        # collector skips the cross-check (the date range is intentional).
        [ValidateSet("daily", "backfill")]
        [string]$Mode
    )

    $syncStart = Get-Date

    $connString = "Server=$($Config.SqlServer);Database=$($Config.Database);Integrated Security=True;TrustServerCertificate=True;"

    $payload = @{
        brand      = $Config.Brand
        storeCode  = $Config.StoreCode
        oracleCode = $Config.OracleCode
        syncDate   = $Day
        mode       = $Mode
        tables     = @{}
    }

    $totalRows = 0
    $skippedRows = 0
    $skipReasons = @{}

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
        Write-Log "  [$Day] no rows - skipping POST"

        # The only Phase 1 skip type. Row-level skip detection (null txn
        # number, zero amount, etc.) is deferred to Phase 2 — when added,
        # increment $skippedRows + push to $skipReasons inside the row loop
        # above. Until then the dashboard's "skipped" column is only
        # populated for no_data days, which is what the user sees.
        if (-not $skipReasons["no_data"]) { $skipReasons["no_data"] = @{ reason = "no_data"; count = 0; sampleRows = @() } }
        $skipReasons["no_data"].count++

        # Still emit the sync summary so the heartbeat agent reports the
        # no-data day, not yesterday's stale row.
        $summaryDir = Split-Path $Config.LogFile -Parent | Split-Path -Parent | Join-Path -ChildPath "state"
        if (-not (Test-Path $summaryDir)) { New-Item -ItemType Directory -Path $summaryDir -Force | Out-Null }
        $summary = @{
            syncDate              = $Day
            rowsSent              = 0
            rowsSkipped           = $skippedRows
            rowsFailed            = 0
            skipReasons           = @($skipReasons.Values)
            processingWindowStart = $syncStart.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
            processingWindowEnd   = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
            durationMs            = [int]((Get-Date) - $syncStart).TotalMilliseconds
        }
        $summary | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $summaryDir "last-sync.json") -Force

        return $true  # empty day is a "success" - don't want to block the backfill loop
    }

    Write-Log ("  [$Day] {0} headers, {1} sales, {2} payments - POSTing..." -f `
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

        # Write sync summary for heartbeat agent
        $summaryDir = Split-Path $Config.LogFile -Parent | Split-Path -Parent | Join-Path -ChildPath "state"
        if (-not (Test-Path $summaryDir)) { New-Item -ItemType Directory -Path $summaryDir -Force | Out-Null }
        $summary = @{
            syncDate                = $Day
            rowsSent                = $totalRows
            rowsSkipped             = $skippedRows
            rowsFailed              = 0
            skipReasons             = @($skipReasons.Values)
            processingWindowStart   = $syncStart.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
            processingWindowEnd     = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
            durationMs              = [int]((Get-Date) - $syncStart).TotalMilliseconds
        }
        $summary | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $summaryDir "last-sync.json") -Force

        return $true
    }
    catch {
        Write-Log "  [$Day] ERROR posting: $_"
        return $false
    }
}

# --- Main -----------------------------------------------------------------------

function Invoke-Sync {
    Write-Log "=== CXS Sync Start ==="
    Write-Log "Store:  $($Config.StoreCode) ($($Config.OracleCode))"
    Write-Log "Server: $($Config.SqlServer) / $($Config.Database)"

    # Pre-flight telemetry
    Send-Checkin -Event "sync_start"

    # Figure out which days to sync. $SyncMode is sent in every payload
    # so the collector knows whether to enforce transactionDate-vs-
    # syncDate tolerance (daily) or skip the check (backfill — the
    # operator deliberately chose the date range).
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

        $SyncMode = "backfill"
        Write-Log "Mode: BACKFILL - $($days.Count) day(s) from $StartDate to $EndDate"
    }
    else {
        # Daily sync mode - yesterday only
        $yesterday = (Get-Date).Date.AddDays(-1).ToString("yyyy-MM-dd")
        $days = @($yesterday)
        $SyncMode = "daily"
        Write-Log "Mode: DAILY - syncing yesterday ($yesterday)"
    }

    # Walk days in order, stop on first failure
    $succeeded = 0
    $failed    = $null
    foreach ($day in $days) {
        $ok = Invoke-DaySync -Day $day -Mode $SyncMode
        if (-not $ok) {
            $failed = $day
            break
        }
        $succeeded++
    }

    if ($failed) {
        Write-Log "=== CXS Sync FAILED on $failed (completed $succeeded/$($days.Count) days) ==="
        Write-Log "Re-run with: .\cxs-collector.ps1 -StartDate `"$failed`" -EndDate `"$($days[-1])`""
        Send-Checkin -Event "sync_error" -ErrorMessage "Failed on $failed after $succeeded/$($days.Count) days"
        exit 1
    }

    Write-Log "=== CXS Sync Complete - $succeeded/$($days.Count) days ok ==="
    Send-Checkin -Event "sync_complete"
}

# Run
Invoke-Sync
