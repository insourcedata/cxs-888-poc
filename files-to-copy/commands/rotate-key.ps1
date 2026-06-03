# Rotate-Key.ps1 - claims a new per-store API key via the collector's
# claim-key endpoint, writes it to cxs-agent.json atomically (temp+move,
# .bak backup), and returns { rotated = $true }.
#
# SECURITY: the new key value is NEVER logged, written to stdout, or
# included in the return object.  The result is stored in
# agent_commands.result in Postgres -- plaintext there would violate the
# no-plaintext-at-rest design.
#
# Runs inside a Start-Job child process.  Available: $Params, $Config.
# NOT available: Write-AgentLog, $AgentId, Send-CommandResult.
# TLS + AllowSelfSignedCert are already applied by the job wrapper.

param($Params, $Config)

# --- Validate params --------------------------------------------------------
$rotationId = if ($Params -and $Params.PSObject.Properties['rotationId']) { $Params.rotationId } else { $null }
if (-not $rotationId) {
    throw "rotate-key requires 'rotationId' parameter (GUID string)"
}

# --- Claim the new key ------------------------------------------------------
$claimUrl = $Config.ApiUrl -replace '/api/collect$', '/api/collect/claim-key'
$agentId  = "$($Config.Brand):$($Config.StoreCode)"

$body = @{
    agentId    = $agentId
    brand      = $Config.Brand
    storeCode  = $Config.StoreCode
    rotationId = $rotationId
} | ConvertTo-Json -Depth 5 -Compress

$headers = @{
    "Content-Type"  = "application/json"
    "Authorization" = "Bearer $($Config.ApiKey)"
}

$resp = Invoke-RestMethod -Uri $claimUrl -Method POST -Body $body -Headers $headers -TimeoutSec 30

$newKey = $resp.apiKey
if (-not $newKey) {
    throw "claim-key returned no key"
}

# --- Atomic write to config file --------------------------------------------
# Mirrors update-config.ps1: resolve path, .bak, .tmp, Move-Item.
$configFile = if ($env:CXS_CONFIG_FILE) { $env:CXS_CONFIG_FILE } else { "C:\CXS\config\cxs-agent.json" }

$obj = if (Test-Path $configFile) {
    Get-Content $configFile -Raw | ConvertFrom-Json
} else {
    [PSCustomObject]@{}
}

if ($obj.PSObject.Properties['ApiKey']) {
    $obj.ApiKey = $newKey
} else {
    $obj | Add-Member -NotePropertyName 'ApiKey' -NotePropertyValue $newKey -Force
}

$dir = Split-Path $configFile -Parent
if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

# Back up the current file, then write atomically via temp file + move.
if (Test-Path $configFile) { Copy-Item $configFile "$configFile.bak" -Force }
$tmp = "$configFile.tmp"
$obj | ConvertTo-Json -Depth 10 | Set-Content -Path $tmp -Encoding UTF8
Move-Item -Path $tmp -Destination $configFile -Force

# Success -- return ONLY the rotated flag (never the key value).
return @{ rotated = $true }
