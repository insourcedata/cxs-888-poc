# Get-Logs.ps1 — Returns last N lines from agent log, sanitized
param($Params, $Config)

$lines = if ($Params -and $Params.PSObject.Properties['lines'] -and $Params.lines) { [Math]::Min([int]$Params.lines, 500) } else { 100 }
$logPath = $Config.LogFile

if (-not (Test-Path $logPath)) {
    return @{ logs = @("Log file not found: $logPath") }
}

$raw = Get-Content $logPath -Tail $lines -ErrorAction SilentlyContinue

# Sanitize sensitive data
$sanitizePatterns = @(
    '(?i)password\s*=\s*\S+',
    '(?i)Bearer\s+\S+',
    '(?i)apikey\s*=\s*\S+',
    '(?i)connection\s*string\s*[:=]\s*.+',
    # Redact any long hex/token-looking secret (API keys, hashes) generically —
    # do NOT hardcode a specific key prefix here (that itself leaks the key).
    '(?i)\b[0-9a-f]{32,}\b',
    '(?i)\b(?:tid|tsec)_[A-Za-z0-9_\-+]+'
)

$sanitized = $raw | ForEach-Object {
    $line = $_
    foreach ($pattern in $sanitizePatterns) {
        $line = $line -replace $pattern, '[REDACTED]'
    }
    $line
}

return @{ logs = @($sanitized) }
