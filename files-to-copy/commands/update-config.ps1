# Update-Config.ps1 - updates an allowed agent config key and PERSISTS it to
# cxs-agent.json (atomic write + .bak backup) so the change survives an agent
# restart. Only allow-listed keys are accepted.
param($Params, $Config)

$safeKeys = @("HeartbeatInterval", "CommandTimeoutSec")
$key   = if ($Params -and $Params.PSObject.Properties['key'])   { $Params.key }   else { $null }
$value = if ($Params -and $Params.PSObject.Properties['value']) { $Params.value } else { $null }

if (-not $key)        { throw "update-config requires 'key' parameter" }
if ($null -eq $value) { throw "update-config requires 'value' parameter" }
if ($key -notin $safeKeys) {
    throw "Config key '$key' is not remotely updatable. Allowed: $($safeKeys -join ', ')"
}

# Validate / clamp per key so a bad value can't break the agent.
switch ($key) {
    "HeartbeatInterval" { $value = [Math]::Max(30, [Math]::Min(3600, [int]$value)) }
    "CommandTimeoutSec" { $value = [Math]::Max(10, [Math]::Min(300,  [int]$value)) }
}

$oldValue = $Config[$key]
$Config[$key] = $value   # in-memory for the current process

# Persist to the config file so the change survives a restart.
$configFile = if ($env:CXS_CONFIG_FILE) { $env:CXS_CONFIG_FILE } else { "C:\CXS\config\cxs-agent.json" }
try {
    $obj = if (Test-Path $configFile) {
        Get-Content $configFile -Raw | ConvertFrom-Json
    } else {
        [PSCustomObject]@{}
    }
    if ($obj.PSObject.Properties[$key]) {
        $obj.$key = $value
    } else {
        $obj | Add-Member -NotePropertyName $key -NotePropertyValue $value -Force
    }

    $dir = Split-Path $configFile -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    # Back up the current file, then write atomically via temp file + move.
    if (Test-Path $configFile) { Copy-Item $configFile "$configFile.bak" -Force }
    $tmp = "$configFile.tmp"
    $obj | ConvertTo-Json -Depth 10 | Set-Content -Path $tmp -Encoding UTF8
    Move-Item -Path $tmp -Destination $configFile -Force

    return @{
        updated   = $true
        key       = $key
        oldValue  = $oldValue
        newValue  = $value
        persisted = $true
    }
} catch {
    # In-memory update already applied; report that persistence failed so the
    # operator knows it will revert on restart.
    return @{
        updated      = $true
        key          = $key
        oldValue     = $oldValue
        newValue     = $value
        persisted    = $false
        persistError = $_.Exception.Message
    }
}
