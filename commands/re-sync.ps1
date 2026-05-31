# Invoke-ReSync.ps1 — Queues a re-sync for specified date range.
# NOTE: This spawns cxs-collector.ps1 in background and returns immediately.
# The command row will show "completed" meaning "spawn succeeded", not "sync finished".
# Actual sync progress is visible via lastSync in subsequent heartbeats.
param($Params, $Config)

$startDate = if ($Params -and $Params.PSObject.Properties['startDate']) { $Params.startDate } else { $null }
$endDate = if ($Params -and $Params.PSObject.Properties['endDate']) { $Params.endDate } else { $null }

if (-not $startDate -or -not $endDate) {
    throw "re-sync requires startDate and endDate parameters"
}

# Validate date format
try {
    $startDt = [DateTime]::ParseExact($startDate, "yyyy-MM-dd", $null)
    $endDt = [DateTime]::ParseExact($endDate, "yyyy-MM-dd", $null)
} catch {
    throw "Invalid date format. Use YYYY-MM-DD."
}

# Validate range: a wide range would spawn an unbounded fire-and-forget
# backfill. Cap it (mirrors the server-side cap in admin-router issueCommand).
$MaxRangeDays = 90
if ($endDt -lt $startDt) {
    throw "endDate must be on or after startDate."
}
if (($endDt - $startDt).TotalDays -gt $MaxRangeDays) {
    throw "re-sync range cannot exceed $MaxRangeDays days."
}

# Spawn cxs-collector in background — don't await
# Installer writes store-specific scripts as cxs-collector-{StoreCode}.ps1
$scriptDir = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$collectorPath = Join-Path $scriptDir "cxs-collector-$($Config.StoreCode).ps1"

# Fallback to plain name for legacy single-file installs
if (-not (Test-Path $collectorPath)) {
    $collectorPath = Join-Path $scriptDir "cxs-collector.ps1"
}

if (-not (Test-Path $collectorPath)) {
    throw "Collector script not found. Tried cxs-collector-$($Config.StoreCode).ps1 and cxs-collector.ps1 in $scriptDir"
}

Start-Process powershell -ArgumentList @(
    "-ExecutionPolicy", "Bypass",
    "-File", $collectorPath,
    "-StartDate", $startDate,
    "-EndDate", $endDate
) -WindowStyle Hidden

return @{ status = "queued"; startDate = $startDate; endDate = $endDate }
