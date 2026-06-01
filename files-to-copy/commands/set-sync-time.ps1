# Set-SyncTime.ps1 - reschedules the nightly "CXS Daily Sync" task to a new
# time. Expects $Params.time as 24-hour HH:MM (e.g. "04:30"). Returns the old
# and new time plus the task's next run so the dashboard can confirm.
param($Params, $Config)

$time = if ($Params -and $Params.PSObject.Properties['time']) { $Params.time } else { $null }
if (-not $time) { throw "set-sync-time requires 'time' parameter (HH:MM, 24-hour)" }
if ($time -notmatch '^([01][0-9]|2[0-3]):[0-5][0-9]$') {
    throw "time must be HH:MM in 24-hour format (got '$time')"
}

# Prefer the per-store task name; fall back to the legacy bare name.
$storeCode = $Config.StoreCode
$taskName  = "CXS Daily Sync - $storeCode"
$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if (-not $task) {
    $taskName = "CXS Daily Sync"
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
}
if (-not $task) {
    throw "Daily sync task not found (looked for 'CXS Daily Sync - $storeCode' and 'CXS Daily Sync')"
}

# Read the current trigger time for the old -> new report.
$oldTime = $null
$trigger = $task.Triggers | Where-Object { $_.StartBoundary } | Select-Object -First 1
if ($trigger) {
    try { $oldTime = ([DateTime]::Parse($trigger.StartBoundary)).ToString("HH:mm") } catch {}
}

# Build a fresh daily trigger at the requested time and apply it. Set-ScheduledTask
# only replaces the trigger; the action, principal (SYSTEM), and settings are kept.
$newTrigger = New-ScheduledTaskTrigger -Daily -At $time
Set-ScheduledTask -TaskName $taskName -Trigger $newTrigger | Out-Null

# Read back the next run time for confirmation.
$nextRun = $null
try {
    $info = Get-ScheduledTask -TaskName $taskName | Get-ScheduledTaskInfo
    if ($info -and $info.NextRunTime) { $nextRun = $info.NextRunTime.ToString("o") }
} catch {}

return @{
    updated = $true
    task    = $taskName
    oldTime = $oldTime
    newTime = $time
    nextRun = $nextRun
}
