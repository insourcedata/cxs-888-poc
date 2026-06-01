# Update-Config.ps1 - Updates agent config in memory (restricted to safe keys).
# NOTE: Change is in-memory only - persists until agent restarts, then reverts
# to hardcoded $Config values.
param($Params, $Config)

$safeKeys = @("HeartbeatInterval")
$key = if ($Params -and $Params.PSObject.Properties['key']) { $Params.key } else { $null }
$value = if ($Params -and $Params.PSObject.Properties['value']) { $Params.value } else { $null }

if (-not $key) {
    throw "update-config requires 'key' parameter"
}
if ($null -eq $value) {
    throw "update-config requires 'value' parameter"
}

if ($key -notin $safeKeys) {
    throw "Config key '$key' is not remotely updatable. Allowed: $($safeKeys -join ', ')"
}

$oldValue = $Config[$key]
if ($key -eq "HeartbeatInterval") {
    $value = [Math]::Max(30, [Math]::Min(3600, [int]$value))
}
$Config[$key] = $value

return @{
    updated  = $true
    key      = $key
    oldValue = $oldValue
    newValue = $value
}
