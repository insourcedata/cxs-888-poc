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

function Ensure-CollectorRootTrusted {
    # Repair/prevent the PartialChain TLS failure that silently kills the SYSTEM
    # heartbeat agent on freshly-provisioned boxes whose LocalMachine Root store
    # lacks the collector's CA. Imports the pinned Google Trust Services
    # "GTS Root R4" root (the collector's chain anchor) into LocalMachine\Root so
    # the SYSTEM agent's TLS validation SUCCEEDS without disabling it. Idempotent,
    # thumbprint-pinned, never weakens TLS.
    param([Parameter(Mandatory)][string]$ScriptRoot)
    $thumb = '77D30367B5E00C15F60C3861DF7CE13B92464D47'   # GTS Root R4 (self-signed, pki.goog)
    try {
        if (Test-Path "Cert:\LocalMachine\Root\$thumb") {
            Write-Host "  [OK] Collector root CA already trusted in the machine store (GTS Root R4)." -ForegroundColor Green
            return
        }
        $certPath = Join-Path $ScriptRoot "certs\gts-root-r4.crt"
        if (-not (Test-Path $certPath)) {
            Write-Host "  [WARN] Bundled root CA not found at $certPath - cannot auto-trust. If the box hits PartialChain, re-run with -AllowSelfSignedCert." -ForegroundColor Yellow
            return
        }
        $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 $certPath
        if ($cert.Thumbprint -ne $thumb) {
            Write-Host "  [WARN] Bundled root CA thumbprint mismatch (got $($cert.Thumbprint)); refusing to import." -ForegroundColor Red
            return
        }
        $store = New-Object System.Security.Cryptography.X509Certificates.X509Store('Root','LocalMachine')
        $store.Open('ReadWrite'); $store.Add($cert); $store.Close()
        Write-Host "  [OK] Imported collector root CA into LocalMachine\Root (GTS Root R4) - SYSTEM can now validate the collector cert." -ForegroundColor Green
    } catch {
        Write-Host "  [WARN] Could not import the collector root CA: $_" -ForegroundColor Yellow
        Write-Host "         If the SYSTEM heartbeat then fails with PartialChain, re-run with -AllowSelfSignedCert as a stopgap." -ForegroundColor Yellow
    }
}

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

# Multi-store is now supported (issue #53): each store gets its own per-store agent
# config (cxs-agent-<StoreCode>.json) and a generated per-store heartbeat launcher
# that pins CXS_CONFIG_FILE, so every store reports under its own identity even when
# several share one box.
if ($scripts.Count -gt 1) {
    Write-Host "[INFO] Multiple store collector scripts detected ($($scripts.Count)) - multi-store mode." -ForegroundColor Cyan
    Write-Host "[INFO] Each store gets its own cxs-agent-<StoreCode>.json and heartbeat launcher," -ForegroundColor Cyan
    Write-Host "[INFO] so all stores report under their own identity." -ForegroundColor Cyan
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

Write-Host "  Ensuring the collector root CA is trusted in the machine store..."
Ensure-CollectorRootTrusted -ScriptRoot $PSScriptRoot
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
    # Point this store's collector at its own per-store agent config (issue #53).
    $updated = $updated -replace 'cxs-agent\.json', "cxs-agent-$storeCode.json"

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

    # Write agent config from extracted values (per-store path - issue #53)
    $agentCfg = @{}
    $agentKeys = @("ApiUrl", "ApiKey", "SqlServer", "Database", "Brand", "Company", "StoreCode")
    foreach ($key in $agentKeys) {
        if ($configValues.ContainsKey($key)) {
            $agentCfg[$key] = $configValues[$key]
        }
    }
    # Per-store log + sync-summary paths so multi-store boxes don't collide.
    $agentCfg["LogFile"] = "C:\CXS\logs\agent-$storeCode.log"
    $agentCfg["SyncSummaryFile"] = "C:\CXS\state\last-sync-$storeCode.json"
    $agentConfigPath = Join-Path $InstallDir "config\cxs-agent-$storeCode.json"
    # Preserve AllowSelfSignedCert (agent-only setting, not in the collector script
    # we extract from). Read the per-store file if present, else fall back to the
    # legacy shared cxs-agent.json so a single-store box migrating to per-store
    # config keeps its TLS-bypass opt-in rather than silently re-enabling validation.
    $legacyAgentConfigPath = Join-Path $InstallDir "config\cxs-agent.json"
    $prevAgentConfigPath = if (Test-Path $agentConfigPath) { $agentConfigPath }
                           elseif (Test-Path $legacyAgentConfigPath) { $legacyAgentConfigPath }
                           else { $null }
    if ($prevAgentConfigPath) {
        try {
            $existingAgentCfg = Get-Content $prevAgentConfigPath -Raw | ConvertFrom-Json
            if ($null -ne $existingAgentCfg.AllowSelfSignedCert) {
                $agentCfg["AllowSelfSignedCert"] = [bool]$existingAgentCfg.AllowSelfSignedCert
            }
            # Preserve a rotated per-store ApiKey. After a dashboard Admit/rotate the
            # live key lives in THIS agent config; the collector script we extract
            # from still has the OLD enrollment key baked in. Without this, re-running
            # the updater would overwrite the rotated key with the stale one and (once
            # shared-key enforcement is on) knock the store offline. To deliberately
            # set a new key, re-run the installer (-ApiKey) or rotate from the dashboard.
            if ($existingAgentCfg.ApiKey -and "$($existingAgentCfg.ApiKey)".Length -ge 16) {
                $agentCfg["ApiKey"] = $existingAgentCfg.ApiKey
            }
        } catch {
            Write-Host "  [WARN] Could not read existing agent config to preserve AllowSelfSignedCert/ApiKey: $_" -ForegroundColor Yellow
        }
    }
    $agentCfg | ConvertTo-Json -Depth 5 | Set-Content -Path $agentConfigPath -Encoding UTF8
    Write-Host "  [OK] Agent config written for $storeCode`: $agentConfigPath" -ForegroundColor Green

    # Seed the per-store last-sync summary from the legacy shared file so the first
    # heartbeat after upgrade doesn't report "no last sync" until the next daily run
    # (issue #53). Only safe on a single-store box: there the legacy last-sync.json
    # unambiguously belongs to this store. On a (previously broken) multi-store box
    # the shared file's owner is ambiguous, so skip and let each daily run populate
    # its own per-store file. Copy (not move) to preserve rollback.
    if ($scripts.Count -eq 1) {
        $legacySummary  = Join-Path $InstallDir "state\last-sync.json"
        $perStoreSummary = Join-Path $InstallDir "state\last-sync-$storeCode.json"
        if ((Test-Path $legacySummary) -and -not (Test-Path $perStoreSummary)) {
            try {
                New-Item -ItemType Directory -Path (Split-Path $perStoreSummary -Parent) -Force | Out-Null
                Copy-Item $legacySummary $perStoreSummary -Force
                Write-Host "  [OK] Seeded per-store last-sync summary: $perStoreSummary" -ForegroundColor Green
            } catch {
                Write-Host "  [WARN] Could not seed per-store last-sync summary: $_" -ForegroundColor Yellow
            }
        }
    }

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

    # Per-store heartbeat launcher (issue #53): sets store-scoped CXS_CONFIG_FILE,
    # then runs the shared cxs-agent.ps1. A wrapper (not an inline -Command) keeps
    # -File exit-code semantics and avoids quote-nesting inside the task argument.
    $hbLauncherPath = Join-Path $InstallDir "cxs-agent-$storeCode.ps1"
    $hbLauncher = @"
# Auto-generated per-store launcher for the CXS heartbeat agent (issue #53). Do not edit.
`$env:CXS_CONFIG_FILE = "$InstallDir\config\cxs-agent-$storeCode.json"
& "`$PSScriptRoot\cxs-agent.ps1"
exit `$LASTEXITCODE
"@
    Set-Content -Path $hbLauncherPath -Value $hbLauncher -Encoding UTF8
    Write-Host "  [OK] Heartbeat launcher written: $hbLauncherPath" -ForegroundColor Green

    $hbAction = New-ScheduledTaskAction `
        -Execute "powershell.exe" `
        -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$hbLauncherPath`"" `
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

    # Verify the heartbeat actually works in the SYSTEM context (the agent's real
    # context - different cert/proxy than the interactive operator). A green install
    # checkin does NOT prove this, so confirm against the agent's own log and warn
    # loudly instead of leaving the store silently dark.
    Write-Host "  Verifying heartbeat in the SYSTEM context..."
    $agentLog = "C:\CXS\logs\agent-$storeCode.log"
    $deadline = (Get-Date).AddSeconds(45); $hbOk = $false; $hbErr = $null
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 5
        if (Test-Path $agentLog) {
            $tail = Get-Content $agentLog -Tail 40 -ErrorAction SilentlyContinue
            if ($tail -match 'Heartbeat sent') { $hbOk = $true; break }
            $m = $tail | Select-String 'PartialChain|establish trust|SSL/TLS|\b407\b|Unauthorized|Unable to connect|timed out' | Select-Object -Last 1
            if ($m) { $hbErr = $m.ToString().Trim() }
        }
    }
    if ($hbOk) {
        Write-Host "  [OK] SYSTEM-context heartbeat confirmed - store is reporting." -ForegroundColor Green
    } else {
        Write-Host "  [WARN] Heartbeat NOT confirmed as SYSTEM within 45s - this store will not report." -ForegroundColor Red
        if ($hbErr) { Write-Host "         Agent log: $hbErr" -ForegroundColor Red }
        Write-Host "         Check: Get-Content $agentLog -Tail 60 ; certutil -store Root ; netsh winhttp show proxy" -ForegroundColor Yellow
        Write-Host "         Stopgap: re-run with -AllowSelfSignedCert." -ForegroundColor Yellow
    }
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
