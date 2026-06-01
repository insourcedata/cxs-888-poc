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

# The v2 heartbeat agent uses a single config (C:\CXS\config\cxs-agent.json) and a
# single agent script per machine. If this box hosts more than one store, each
# per-store heartbeat task would overwrite that one config - only the last store
# processed would report correctly. Warn loudly rather than silently misconfigure.
if ($scripts.Count -gt 1) {
    Write-Host "[WARN] Multiple store collector scripts detected on this machine." -ForegroundColor Yellow
    Write-Host "[WARN] The v2 heartbeat agent supports ONE store identity per machine; the" -ForegroundColor Yellow
    Write-Host "[WARN] last store processed will own cxs-agent.json. For multi-store servers," -ForegroundColor Yellow
    Write-Host "[WARN] contact support before relying on heartbeats/remote commands." -ForegroundColor Yellow
    Write-Host ""
}

$newContent = Get-Content $SourceScript -Raw
New-Item -ItemType Directory -Path "$InstallDir\config" -Force | Out-Null

# Deploy the heartbeat agent BEFORE registering/starting its scheduled task.
# Previously this copy ran AFTER the per-store loop, so a first upgrade started
# the task pointing at a cxs-agent.ps1 that didn't exist yet (it would error and
# only retry on the task's restart policy). Copy first; if the source is missing,
# skip the heartbeat task entirely rather than start a task that launches nothing.
$agentSource = Join-Path $PSScriptRoot "cxs-agent.ps1"
$agentDeployed = $false
if (Test-Path $agentSource) {
    Copy-Item $agentSource (Join-Path $InstallDir "cxs-agent.ps1") -Force
    Write-Host "[OK] Agent script deployed: $InstallDir\cxs-agent.ps1" -ForegroundColor Green
    $agentDeployed = $true
} else {
    Write-Host "[WARN] cxs-agent.ps1 not found in $PSScriptRoot - heartbeat agent will NOT be deployed or started" -ForegroundColor Yellow
}
Write-Host ""

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

    # Write agent config from extracted values
    $agentCfg = @{}
    $agentKeys = @("ApiUrl", "ApiKey", "SqlServer", "Database", "Brand", "Company", "StoreCode")
    foreach ($key in $agentKeys) {
        if ($configValues.ContainsKey($key)) {
            $agentCfg[$key] = $configValues[$key]
        }
    }
    $agentConfigPath = Join-Path $InstallDir "config\cxs-agent.json"
    # Preserve AllowSelfSignedCert from the existing agent config. It is an
    # agent-only setting (not present in the collector script we extract from),
    # so regenerating the config from collector values alone would silently drop
    # it and re-enable TLS validation on stores that opted into the bypass.
    if (Test-Path $agentConfigPath) {
        try {
            $existingAgentCfg = Get-Content $agentConfigPath -Raw | ConvertFrom-Json
            if ($null -ne $existingAgentCfg.AllowSelfSignedCert) {
                $agentCfg["AllowSelfSignedCert"] = [bool]$existingAgentCfg.AllowSelfSignedCert
            }
        } catch {
            Write-Host "  [WARN] Could not read existing cxs-agent.json to preserve AllowSelfSignedCert: $_" -ForegroundColor Yellow
        }
    }
    $agentCfg | ConvertTo-Json -Depth 5 | Set-Content -Path $agentConfigPath -Encoding UTF8
    Write-Host "  [OK] Agent config written for $storeCode`: $agentConfigPath" -ForegroundColor Green

    # Register heartbeat task (idempotent) - only if the agent was deployed,
    # otherwise we'd start a task that launches a non-existent script.
    if (-not $agentDeployed) {
        Write-Host "  [WARN] Skipping heartbeat task for $storeCode (cxs-agent.ps1 not deployed)" -ForegroundColor Yellow
        continue
    }
    $hbTaskName = "CXS Agent Heartbeat - $storeCode"
    $existingHb = Get-ScheduledTask -TaskName $hbTaskName -ErrorAction SilentlyContinue
    if ($existingHb) {
        Stop-ScheduledTask -TaskName $hbTaskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $hbTaskName -Confirm:$false
        Write-Host "  Removed existing heartbeat task: $hbTaskName"
    }

    $hbAction = New-ScheduledTaskAction `
        -Execute "powershell.exe" `
        -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$InstallDir\cxs-agent.ps1`"" `
        -WorkingDirectory $InstallDir

    $hbTrigger = New-ScheduledTaskTrigger -AtStartup

    $hbPrincipal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

    $hbSettings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -RestartCount 3 `
        -RestartInterval (New-TimeSpan -Minutes 10)

    Register-ScheduledTask `
        -TaskName $hbTaskName `
        -Action $hbAction `
        -Trigger $hbTrigger `
        -Principal $hbPrincipal `
        -Settings $hbSettings `
        -Description "CXS Agent - heartbeat and command execution for $storeCode" | Out-Null

    Start-ScheduledTask -TaskName $hbTaskName
    Write-Host "  [OK] Heartbeat task created and started: $hbTaskName" -ForegroundColor Green
}

# Remove legacy fleet-wide "CXS Daily Sync" task if a per-store replacement exists.
# The bare task (no " - <StoreCode>" suffix) was created by v1 installs and causes
# duplicate nightly payloads when running alongside the new per-store task.
# Guard: only remove if at least one per-store "CXS Daily Sync - *" task is
# registered, so a pure-legacy install (no per-store task yet) keeps working.
# The -Migrate path above already handles its own removal (with settings-preserving
# rename), so this block is a no-op in that case - the bare task is already gone.
$legacyBareTask = Get-ScheduledTask -TaskName "CXS Daily Sync" -ErrorAction SilentlyContinue |
                  Where-Object { $_.TaskName -eq "CXS Daily Sync" }
if ($legacyBareTask) {
    $perStoreReplacement = Get-ScheduledTask -TaskName "CXS Daily Sync - *" -ErrorAction SilentlyContinue
    if ($perStoreReplacement) {
        Unregister-ScheduledTask -TaskName "CXS Daily Sync" -Confirm:$false
        Write-Host "  [OK] Removed legacy fleet-wide task 'CXS Daily Sync' (per-store replacement exists)" -ForegroundColor Yellow
    }
}

# Copy command handler scripts
$commandsSrc = Join-Path $PSScriptRoot "commands"
$commandsDst = Join-Path $InstallDir "commands"
if (Test-Path $commandsSrc) {
    if (-not (Test-Path $commandsDst)) { New-Item -ItemType Directory -Path $commandsDst | Out-Null }
    Copy-Item "$commandsSrc\*.ps1" $commandsDst -Force
    Write-Host "  [OK] Command handlers updated in: $commandsDst" -ForegroundColor Green
}

# (heartbeat agent is deployed before the loop now - see $agentDeployed above)
Write-Host ""
Write-Host "=== Update Complete ===" -ForegroundColor Cyan
Write-Host ""
if ($Migrate) {
    Write-Host "Scripts migrated to per-store format. Each store now has its own" -ForegroundColor Green
    Write-Host "script file, scheduled task, and log file." -ForegroundColor Green
}
Write-Host ""
