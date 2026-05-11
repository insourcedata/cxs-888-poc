#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Updates installed CXS collector scripts to the latest version.

.DESCRIPTION
    Reads config from each installed cxs-collector script, copies the new
    version, re-injects the config, and optionally migrates to per-store
    paths (cxs-collector-{StoreCode}.ps1) and task names.

    Safe to run multiple times. Does not touch scheduled task timing.

.PARAMETER Migrate
    If set, migrates legacy single-file installs (C:\CXS\cxs-collector.ps1)
    to per-store format (C:\CXS\cxs-collector-{StoreCode}.ps1) and renames
    the scheduled task from "CXS Daily Sync" to "CXS Daily Sync - {StoreCode}".
#>

param(
    [switch]$Migrate
)

$InstallDir = "C:\CXS"
$SourceScript = Join-Path $PSScriptRoot "cxs-collector.ps1"

if (-not (Test-Path $SourceScript)) {
    Write-Host "ERROR: cxs-collector.ps1 not found in $PSScriptRoot" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "=== CXS Collector Updater ===" -ForegroundColor Cyan
Write-Host ""

# Find all installed collector scripts
$scripts = @()

# Check legacy single-file install
$legacyPath = Join-Path $InstallDir "cxs-collector.ps1"
if (Test-Path $legacyPath) {
    $scripts += $legacyPath
}

# Check per-store installs
$perStore = Get-ChildItem -Path $InstallDir -Filter "cxs-collector-*.ps1" -ErrorAction SilentlyContinue
if ($perStore) {
    $scripts += $perStore.FullName
}

if ($scripts.Count -eq 0) {
    Write-Host "No installed CXS collector scripts found in $InstallDir" -ForegroundColor Yellow
    exit 0
}

Write-Host "Found $($scripts.Count) installed script(s):" -ForegroundColor Green
$scripts | ForEach-Object { Write-Host "  $_" }
Write-Host ""

$newContent = Get-Content $SourceScript -Raw

foreach ($scriptPath in $scripts) {
    $fileName = Split-Path $scriptPath -Leaf
    Write-Host "--- Updating: $fileName ---"

    # Extract config values from installed script
    $oldContent = Get-Content $scriptPath -Raw

    $configValues = @{}
    $configKeys = @("ApiUrl", "ApiKey", "SqlServer", "Database", "Brand", "Company", "ExtGuid", "StoreCode", "OracleCode", "LogFile")
    foreach ($key in $configKeys) {
        if ($oldContent -match "$key\s*=\s*`"([^`"]*)`"") {
            $configValues[$key] = $matches[1]
        }
    }

    if (-not $configValues.StoreCode) {
        Write-Host "  [SKIP] Could not extract StoreCode from $fileName" -ForegroundColor Yellow
        continue
    }

    $storeCode = $configValues.StoreCode
    Write-Host "  Store: $storeCode"

    # Apply config to new script content
    $updated = $newContent
    foreach ($key in $configValues.Keys) {
        $val = $configValues[$key].Replace('$', '$$')
        $updated = $updated -replace "$key\s*=\s*`"[^`"]*`"", "$key     = `"$val`""
    }

    # Ensure log file is store-specific
    $updated = $updated -replace 'LogFile\s*=\s*"[^"]*"', "LogFile    = `"C:\CXS\logs\sync-$storeCode.log`""

    # Write updated script
    if ($Migrate -and $fileName -eq "cxs-collector.ps1") {
        # Migrate to per-store filename
        $newPath = Join-Path $InstallDir "cxs-collector-$storeCode.ps1"
        Set-Content -Path $newPath -Value $updated -Encoding UTF8
        Write-Host "  [OK] Written to: $newPath" -ForegroundColor Green

        # Migrate scheduled task
        $oldTask = Get-ScheduledTask -TaskName "CXS Daily Sync" -ErrorAction SilentlyContinue
        if ($oldTask) {
            $newTaskName = "CXS Daily Sync - $storeCode"
            $action = New-ScheduledTaskAction `
                -Execute "powershell.exe" `
                -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$newPath`"" `
                -WorkingDirectory $InstallDir

            # Preserve existing trigger and settings
            $trigger = $oldTask.Triggers[0]
            $principal = $oldTask.Principal
            $settings = $oldTask.Settings

            Unregister-ScheduledTask -TaskName "CXS Daily Sync" -Confirm:$false
            Register-ScheduledTask `
                -TaskName $newTaskName `
                -Action $action `
                -Trigger $trigger `
                -Principal $principal `
                -Settings $settings `
                -Description "CXS Dashboard - daily data sync for $storeCode" | Out-Null

            Write-Host "  [OK] Task migrated: 'CXS Daily Sync' -> '$newTaskName'" -ForegroundColor Green
        }

        # Remove legacy file
        Remove-Item $scriptPath -Force
        Write-Host "  [OK] Removed legacy: $fileName" -ForegroundColor Green
    }
    else {
        # In-place update
        Set-Content -Path $scriptPath -Value $updated -Encoding UTF8
        Write-Host "  [OK] Updated in-place: $fileName" -ForegroundColor Green

        # Update task action to point to current script path (in case path changed)
        $taskName = if ($fileName -match "cxs-collector-(.+)\.ps1") {
            "CXS Daily Sync - $($matches[1])"
        } else {
            "CXS Daily Sync"
        }
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($task) {
            $action = New-ScheduledTaskAction `
                -Execute "powershell.exe" `
                -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`"" `
                -WorkingDirectory $InstallDir
            Set-ScheduledTask -TaskName $taskName -Action $action | Out-Null
            Write-Host "  [OK] Task '$taskName' action updated" -ForegroundColor Green
        }
    }
}

Write-Host ""
Write-Host "=== Update Complete ===" -ForegroundColor Cyan
Write-Host ""
if ($Migrate) {
    Write-Host "Scripts migrated to per-store format. Each store now has its own" -ForegroundColor Green
    Write-Host "script file, scheduled task, and log file." -ForegroundColor Green
}
Write-Host ""
