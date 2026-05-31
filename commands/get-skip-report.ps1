# Get-SkipReport.ps1 — Detailed skip breakdown for a specific sync date
param($Params, $Config)

$date = if ($Params -and $Params.PSObject.Properties['date']) { $Params.date } else { $null }
if (-not $date) {
    $date = (Get-Date).AddDays(-1).ToString("yyyy-MM-dd")
}

$stateDir = Split-Path $Config.SyncSummaryFile
$reportPath = Join-Path $stateDir "skip-report-$date.json"

if (Test-Path $reportPath) {
    $report = Get-Content $reportPath -Raw | ConvertFrom-Json
    return @{
        date       = $date
        totalRows  = $report.totalRows
        sent       = $report.sent
        skipped    = $report.skipped
        skipReasons = $report.skipReasons
    }
}

# Fallback: read from last-sync summary if date matches
if (Test-Path $Config.SyncSummaryFile) {
    $summary = Get-Content $Config.SyncSummaryFile -Raw | ConvertFrom-Json
    if ($summary.syncDate -eq $date) {
        return @{
            date       = $date
            totalRows  = ($summary.rowsSent + $summary.rowsSkipped)
            sent       = $summary.rowsSent
            skipped    = $summary.rowsSkipped
            skipReasons = $summary.skipReasons
        }
    }
}

return @{ date = $date; error = "No skip report available for $date" }
