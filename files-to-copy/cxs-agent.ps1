#Requires -Version 4.0
<#
.SYNOPSIS
    CXS Agent Heartbeat - sends periodic health + sync telemetry to the fleet dashboard.

.DESCRIPTION
    Runs as a persistent process (registered as a Windows scheduled task with
    "At startup" trigger). Every 5 minutes, collects system health, SQL Server
    connectivity, task scheduler state, and last sync summary, then POSTs to
    the collector's /api/collect/heartbeat endpoint.

    This script does NOT perform data syncs - cxs-collector.ps1 handles that
    separately. This script reports on the sync's outcomes.

.NOTES
    Install as scheduled task:
      schtasks /Create /TN "CXS Agent Heartbeat" /TR "powershell -ExecutionPolicy Bypass -File C:\CXS\cxs-agent.ps1" /SC ONSTART /RU SYSTEM
#>

Set-StrictMode -Version Latest

# --- Configuration ---------------------------------------------------------------
# Defaults - non-sensitive values only. Per-store overrides (and the API key)
# live in cxs-agent.json, which is gitignored and provisioned at install time.
$Config = @{
    ApiUrl              = "https://888.insourcedata.org/api/collect"
    ApiKey              = ""        # MUST come from config file or $env:CXS_API_KEY
    # Brand is REQUIRED - must be set in cxs-agent.json. Was "wendys"
    # by default until 2026-05-26; retired so Conti's installs that
    # copy-pasted the Wendy's config can't silently misfile heartbeats.
    Brand               = ""
    StoreCode           = ""
    SqlServer           = ""
    Database            = "NEWPOS"
    HeartbeatInterval   = 300       # seconds
    LogFile             = "C:\CXS\logs\agent.log"
    SyncSummaryFile     = "C:\CXS\state\last-sync.json"
    AllowSelfSignedCert = $false    # opt-in; logs a WARN when enabled
    CommandTimeoutSec   = 60        # wall-clock timeout for remote command handlers
}

# Merge config file values over defaults (if file is present)
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

# Allow $env:CXS_API_KEY to override (for local testing / containerised installs)
if ($env:CXS_API_KEY) { $Config.ApiKey = $env:CXS_API_KEY }

# Validate required fields - fail fast rather than booting with placeholders
if (-not $Config.ApiKey -or $Config.ApiKey.Length -lt 16) {
    Write-Host "ERROR: ApiKey is missing or too short. Set it in ${ConfigFile} or $env:CXS_API_KEY." -ForegroundColor Red
    exit 1
}
if (-not $Config.StoreCode) {
    Write-Host "ERROR: StoreCode is missing. Set it in ${ConfigFile}." -ForegroundColor Red
    exit 1
}
# Brand must be explicit - mirrors the same check in cxs-collector.ps1
# so a misconfigured agent fails the same way for both processes.
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
$Config.Brand = $BrandNormalized

$AgentVersion = "2.1.0"
$AgentId = "$($Config.Brand):$($Config.StoreCode)"

# --- TLS setup -------------------------------------------------------------------
# Force TLS 1.2 (Windows PowerShell 4.0/5.1 default to TLS 1.0 which most servers reject).
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# -UseBasicParsing exists on Invoke-RestMethod only in PS 5.0+ (PS 4.0 has it on
# Invoke-WebRequest but NOT Invoke-RestMethod). Splat it conditionally so the same
# call is valid on Windows PowerShell 4.0 and keeps the basic-parsing guard on 5.1
# (which also avoids the IE-engine parse error under the SYSTEM service account).
$CxsIrmArgs = @{}
if ((Get-Command Invoke-RestMethod).Parameters.ContainsKey('UseBasicParsing')) {
    $CxsIrmArgs['UseBasicParsing'] = $true
}

# Cert validation is ON by default. AllowSelfSignedCert is an explicit opt-in
# escape hatch for stores whose root-CA store is missing Cloudflare's chain -
# see install runbook. Never enable globally.
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
    Write-Host "WARN: AllowSelfSignedCert=true - TLS certificate validation is DISABLED." -ForegroundColor Yellow
}

# --- Logging ---------------------------------------------------------------------

function Write-AgentLog {
    param(
        [string]$Message,
        [ValidateSet("INFO","WARN","ERROR")]
        [string]$Level = "INFO",
        [string]$Component = "HEARTBEAT"
    )
    $ts = Get-Date -Format "yyyy-MM-ddTHH:mm:ss"
    $line = "[$ts] [$Level] [$Component] $Message"
    Write-Host $line

    # Best-effort file write: a transient lock (e.g. AV scan) or a perms/disk issue
    # on the log file must NEVER throw out of the agent's forever-loop and kill the
    # process. Console output above already happened; swallow file-write failures.
    try {
        $logDir = Split-Path $Config.LogFile -Parent
        if ($logDir -and -not (Test-Path $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        Add-Content -Path $Config.LogFile -Value $line -ErrorAction Stop
    } catch { }
}

# --- Helpers ---------------------------------------------------------------------

function Get-SystemHealth {
    $health = @{
        cpuPercent       = $null
        ramPercent       = $null
        diskFreeGb       = $null
        sqlConnected     = $false
        sqlServerVersion = $null
    }

    try {
        $cpu = Get-WmiObject Win32_Processor -ErrorAction Stop |
            Measure-Object -Property LoadPercentage -Average
        if ($null -ne $cpu.Average) {
            $health.cpuPercent = [math]::Round($cpu.Average, 1)
        }
    } catch {
        Write-AgentLog "WMI CPU query failed: $_" -Level "WARN"
    }

    try {
        $os = Get-WmiObject Win32_OperatingSystem -ErrorAction Stop
        if ($os) {
            $totalMB = [math]::Round($os.TotalVisibleMemorySize / 1024, 0)
            $freeMB  = [math]::Round($os.FreePhysicalMemory / 1024, 0)
            $health.ramPercent = [math]::Round((($totalMB - $freeMB) / $totalMB) * 100, 1)
        }
    } catch {
        Write-AgentLog "WMI memory query failed: $_" -Level "WARN"
    }

    try {
        $cDrive = Get-WmiObject Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction Stop
        if ($cDrive) {
            $health.diskFreeGb = [math]::Round($cDrive.FreeSpace / 1GB, 1)
        }
    } catch {
        Write-AgentLog "WMI disk query failed: $_" -Level "WARN"
    }

    try {
        $conn = New-Object System.Data.SqlClient.SqlConnection(
            "Server=$($Config.SqlServer);Database=$($Config.Database);Integrated Security=True;TrustServerCertificate=True;Connection Timeout=10;"
        )
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = "SELECT @@VERSION"
        $health.sqlServerVersion = ($cmd.ExecuteScalar() -split "`n")[0].Trim()
        $conn.Close()
        $health.sqlConnected = $true
    } catch {
        $health.sqlConnected = $false
        Write-AgentLog "SQL connectivity check failed: $($_.Exception.Message)" -Level "WARN"
    }

    return $health
}

function Get-TaskSchedulerState {
    $state = @{
        syncTaskEnabled = $null
        lastRunTime     = $null
        lastExitCode    = $null
        nextRunTime     = $null
        syncScheduleTime = $null
    }

    try {
        $task = Get-ScheduledTask -TaskName "CXS Daily Sync - $($Config.StoreCode)" -ErrorAction SilentlyContinue
        if (-not $task) {
            $task = Get-ScheduledTask -TaskName "CXS Daily Sync" -ErrorAction SilentlyContinue
        }
        if ($task) {
            $state.syncTaskEnabled = ($task.State -ne "Disabled")
            $info = $task | Get-ScheduledTaskInfo -ErrorAction Stop
            if ($info) {
                $state.lastRunTime = if ($info.LastRunTime) { $info.LastRunTime.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ") } else { $null }
                $state.lastExitCode = $info.LastTaskResult
                $state.nextRunTime = if ($info.NextRunTime) { $info.NextRunTime.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ") } else { $null }
            }
            # Read the actual schedule time from the first daily trigger so
            # the dashboard reflects what Task Scheduler is really configured
            # to do, not a hardcoded string.
            $trigger = $task.Triggers | Where-Object { $_.StartBoundary } | Select-Object -First 1
            if ($trigger) {
                try {
                    $dt = [DateTime]::Parse($trigger.StartBoundary)
                    $state.syncScheduleTime = $dt.ToString("HH:mm")
                } catch {
                    Write-AgentLog "Could not parse trigger StartBoundary '$($trigger.StartBoundary)': $_" -Level "WARN"
                }
            }
        }
    } catch {
        Write-AgentLog "Get-ScheduledTask failed: $_" -Level "WARN"
    }

    return $state
}

function Get-LastSyncSummary {
    if (-not (Test-Path $Config.SyncSummaryFile)) { return $null }

    try {
        $raw = Get-Content $Config.SyncSummaryFile -Raw -ErrorAction Stop
        if ($raw) {
            return $raw | ConvertFrom-Json
        }
    } catch {
        Write-AgentLog "Could not read sync summary file: $_" -Level "WARN"
    }

    return $null
}

# --- Heartbeat loop --------------------------------------------------------------

function Send-Heartbeat {
    $health = Get-SystemHealth
    $taskState = Get-TaskSchedulerState
    $lastSync = Get-LastSyncSummary

    $payload = @{
        agentId        = $AgentId
        storeCode      = $Config.StoreCode
        brand          = $Config.Brand
        agentVersion   = $AgentVersion
        hostname       = $env:COMPUTERNAME
        health         = $health
        taskScheduler  = $taskState
        lastSync       = $lastSync
        config         = @{
            heartbeatIntervalSec = $Config.HeartbeatInterval
            # Real scheduled time from Task Scheduler trigger; null if the
            # task can't be found. The dashboard should not invent a value.
            syncSchedule         = $taskState.syncScheduleTime
            collectorEndpoint    = $Config.ApiUrl
            dataDir              = "C:\CXS\Data"
        }
    }

    $json = $payload | ConvertTo-Json -Depth 10 -Compress
    $headers = @{
        "Content-Type"  = "application/json"
        "Authorization" = "Bearer $($Config.ApiKey)"
    }

    $heartbeatUrl = $Config.ApiUrl -replace '/api/collect$', '/api/collect/heartbeat'
    # Invoke-RestMethod throws on non-2xx; let the caller catch so the main
    # loop can adjust its backoff. Returns the parsed JSON response so the
    # caller can process pending commands.
    $response = Invoke-RestMethod @CxsIrmArgs -Uri $heartbeatUrl -Method POST -Body $json -Headers $headers -TimeoutSec 30

    Write-AgentLog "Heartbeat sent. SQL=$($health.sqlConnected) CPU=$($health.cpuPercent)%"

    return $response
}

# --- Command executor ------------------------------------------------------------

$ALLOWED_COMMANDS = @(
    'get-logs', 'get-db-state', 're-sync', 'update-config', 'set-sync-time',
    'get-config', 'test-connectivity', 'get-skip-report', 'rotate-key'
)

function Invoke-AgentCommand {
    param(
        [Parameter(Mandatory)] $Command
    )

    $commandId = $Command.id
    $commandType = $Command.type
    $params = $Command.params

    if ($commandType -notin $ALLOWED_COMMANDS) {
        Write-AgentLog "Rejected unknown command type: $commandType" -Level "WARN" -Component "COMMAND"
        Send-CommandResult -CommandId $commandId -Status "failed" -ErrorMessage "Unknown command type: $commandType"
        return
    }

    $scriptDir = Split-Path -Parent $PSCommandPath
    $handlerPath = Join-Path $scriptDir "commands\$commandType.ps1"

    if (-not (Test-Path $handlerPath)) {
        Write-AgentLog "Handler script not found: $handlerPath" -Level "ERROR" -Component "COMMAND"
        Send-CommandResult -CommandId $commandId -Status "failed" -ErrorMessage "Handler script not found: $handlerPath"
        return
    }

    $timeoutSec = [int]$Config.CommandTimeoutSec
    Write-AgentLog "Executing command: $commandType ($commandId) timeout=${timeoutSec}s" -Component "COMMAND"
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    # Run the handler inside a Start-Job so a hung handler (e.g. a dead SQL
    # connection with no timeout) never blocks the heartbeat loop longer than
    # $timeoutSec.  Start-Job spawns a child powershell process, so we pass
    # the handler path, params, and config explicitly via -ArgumentList.
    # The handler script receives them the same way it does in a direct call.
    $job = Start-Job -ScriptBlock {
        param($HandlerPath, $Params, $Config)
        $ErrorActionPreference = 'Stop'
        # Start-Job runs in a fresh PowerShell process that does NOT inherit the
        # parent's TLS/cert configuration. Re-apply it here so handlers that make
        # HTTPS calls (e.g. test-connectivity) don't fall back to TLS 1.0 on PS
        # 5.1 or lose the AllowSelfSignedCert bypass.
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
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
        }
        & $HandlerPath -Params $Params -Config $Config
    } -ArgumentList $handlerPath, $params, $Config

    try {
        $finished = $job | Wait-Job -Timeout $timeoutSec

        if ($null -eq $finished) {
            # Timeout - the job is still running; force-stop it.
            $stopwatch.Stop()
            $job | Stop-Job -PassThru | Remove-Job -Force
            $errorMsg = "Command timed out after ${timeoutSec}s"
            Write-AgentLog "Command $commandType timed out after ${timeoutSec}s ($commandId)" -Level "ERROR" -Component "COMMAND"
            Send-CommandResult -CommandId $commandId -Status "failed" -ErrorMessage $errorMsg -DurationMs $stopwatch.ElapsedMilliseconds
            return
        }

        # Job completed (success or failure) - collect output.
        $stopwatch.Stop()

        if ($finished.State -eq 'Failed') {
            $jobError = $finished.ChildJobs[0].JobStateInfo.Reason.Message
            if (-not $jobError) { $jobError = "Command handler failed (no details)" }
            $job | Remove-Job -Force
            Write-AgentLog "Command $commandType failed: $jobError" -Level "ERROR" -Component "COMMAND"
            Send-CommandResult -CommandId $commandId -Status "failed" -ErrorMessage $jobError -DurationMs $stopwatch.ElapsedMilliseconds
            return
        }

        $result = Receive-Job -Job $job -ErrorAction Stop
        $job | Remove-Job -Force

        # Special case: update-config mutates $Config inside the job's child
        # process, so the change is lost.  Re-apply it in the parent scope so
        # the in-memory config actually updates for subsequent heartbeats.
        # Guard uses .updated (dot-access) rather than -is [hashtable] because
        # Start-Job deserializes hashtables as PSCustomObject across the
        # process boundary - dot-access works on both types.
        if ($commandType -eq 'update-config' -and $null -ne $result -and $result.updated) {
            $Config[[string]$result.key] = $result.newValue
        }

        # rotate-key: the handler wrote the new key to disk inside a child
        # process (Start-Job), so the parent's in-memory $Config.ApiKey is
        # stale.  Re-read it from disk BEFORE Send-CommandResult so the
        # result POST authenticates with the NEW key - that triggers the
        # collector's issued->active flip immediately.
        if ($commandType -eq 'rotate-key' -and $null -ne $result -and $result.rotated) {
            try {
                $cf = if ($env:CXS_CONFIG_FILE) { $env:CXS_CONFIG_FILE } else { "C:\CXS\config\cxs-agent.json" }
                $reloaded = Get-Content $cf -Raw | ConvertFrom-Json
                if ($reloaded.ApiKey) { $Config.ApiKey = $reloaded.ApiKey }
                else { throw "reloaded config missing ApiKey" }
                Write-AgentLog "rotate-key: new key applied to in-memory config" -Component "COMMAND"
            } catch {
                Write-AgentLog "rotate-key: applied to disk but in-memory reload FAILED ($_). New key is on disk; restart the heartbeat task to load it." -Level "ERROR" -Component "COMMAND"
                Send-CommandResult -CommandId $commandId -Status "failed" -ErrorMessage "rotate-key: key written to disk but in-memory reload failed; agent still on old key until restart" -DurationMs $stopwatch.ElapsedMilliseconds
                return
            }
        }

        Write-AgentLog "Command $commandType completed in $($stopwatch.ElapsedMilliseconds)ms" -Component "COMMAND"
        Send-CommandResult -CommandId $commandId -Status "completed" -Result $result -DurationMs $stopwatch.ElapsedMilliseconds

    } catch {
        $stopwatch.Stop()
        # Receive-Job can throw if the handler threw an unhandled exception.
        $errorMsg = $_.Exception.Message
        try { $job | Remove-Job -Force } catch {}
        Write-AgentLog "Command $commandType failed: $errorMsg" -Level "ERROR" -Component "COMMAND"
        Send-CommandResult -CommandId $commandId -Status "failed" -ErrorMessage $errorMsg -DurationMs $stopwatch.ElapsedMilliseconds
    }
}

function Send-CommandResult {
    param(
        [Parameter(Mandatory)] [string]$CommandId,
        [Parameter(Mandatory)] [string]$Status,
        [object]$Result = $null,
        [string]$ErrorMessage = $null,
        [int]$DurationMs = 0
    )

    $payload = @{
        commandId  = $CommandId
        agentId    = $AgentId
        status     = $Status
        result     = $Result
        error      = $ErrorMessage
        executedAt = (Get-Date).ToUniversalTime().ToString("o")
        durationMs = $DurationMs
    }

    $json = $payload | ConvertTo-Json -Depth 10 -Compress
    $headers = @{
        "Content-Type"  = "application/json"
        "Authorization" = "Bearer $($Config.ApiKey)"
    }
    $callbackUrl = $Config.ApiUrl -replace '/api/collect$', '/api/collect/command-result'
    $maxAttempts = 3
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            Invoke-RestMethod @CxsIrmArgs -Uri $callbackUrl -Method POST -Body $json -Headers $headers -TimeoutSec 30 | Out-Null
            return
        } catch {
            if ($attempt -lt $maxAttempts) {
                Write-AgentLog "Command result delivery attempt $attempt failed, retrying in 5s: $_" -Level "WARN" -Component "COMMAND"
                Start-Sleep -Seconds 5
            } else {
                Write-AgentLog "Failed to send command result for $CommandId after $maxAttempts attempts: $_" -Level "ERROR" -Component "COMMAND"
            }
        }
    }
}

# --- Main loop -------------------------------------------------------------------

Write-AgentLog "CXS Agent starting. ID=$AgentId Version=$AgentVersion" -Component "SYSTEM"
Write-AgentLog "Heartbeat interval: $($Config.HeartbeatInterval)s" -Component "SYSTEM"

$MaxBackoffSec = 30 * 60   # 30 minutes
$ConsecutiveFailures = 0

while ($true) {
    # Outer guard: this agent is a forever-loop registered as a Scheduled Task that
    # does NOT auto-restart until the box reboots. Any unhandled error in an iteration
    # must never terminate the process, or the store goes silently dark. The inner
    # try/catch handles heartbeat failures with backoff; this outer one is the
    # last-resort net for everything else (logging, jitter math, Start-Sleep).
    try {
        $ok = $false
        try {
            $response = Send-Heartbeat
            $ok = $true

            # Process pending commands from server
            if ($response.commands -and $response.commands.Count -gt 0) {
                Write-AgentLog "Received $($response.commands.Count) command(s)" -Component "COMMAND"
                foreach ($cmd in $response.commands) {
                    Invoke-AgentCommand -Command $cmd
                }
            }
        } catch {
            Write-AgentLog "Heartbeat failed: $_" -Level "ERROR"
        }

        if ($ok) {
            $ConsecutiveFailures = 0
            $base = [int]$Config.HeartbeatInterval
        } else {
            $ConsecutiveFailures++
            # Exponential backoff capped at $MaxBackoffSec
            $backoff = [int]$Config.HeartbeatInterval * [Math]::Pow(2, [Math]::Min($ConsecutiveFailures, 5))
            $base = [Math]::Min([int]$backoff, $MaxBackoffSec)
            Write-AgentLog "Backing off ${base}s after $ConsecutiveFailures consecutive failures." -Level "WARN"
        }

        # Clamp to a sane floor (30s) so a misconfigured HeartbeatInterval (e.g. 0)
        # can't make Get-Random (equal min/max) or Start-Sleep throw and kill the loop.
        $base = [Math]::Max([int]$base, 30)

        # +/-10% jitter so 800 stores rebooting at the same time don't synchronize
        # their heartbeats and pile up on the collector.
        $jitterMax = [Math]::Max(1, [int]($base * 0.1))
        $jitter = Get-Random -Minimum (-$jitterMax) -Maximum $jitterMax
        Start-Sleep -Seconds ($base + $jitter)
    } catch {
        # Best-effort log, then pause and continue - never exit the loop.
        try { Write-AgentLog "Unexpected error in heartbeat loop: $_" -Level "ERROR" } catch { }
        Start-Sleep -Seconds 60
    }
}
