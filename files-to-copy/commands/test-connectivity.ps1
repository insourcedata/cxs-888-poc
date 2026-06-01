# Test-Connectivity.ps1 — Tests SQL Server and collector endpoint reachability
param($Params, $Config)

$result = @{ sql = @{}; collector = @{} }

# Test SQL
try {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $conn = New-Object System.Data.SqlClient.SqlConnection("Server=$($Config.SqlServer);Database=$($Config.Database);Integrated Security=True;TrustServerCertificate=True;Connection Timeout=10;")
    $conn.Open()
    $cmd = $conn.CreateCommand()
    $cmd.CommandText = "SELECT 1"
    $cmd.CommandTimeout = 10
    $cmd.ExecuteScalar() | Out-Null
    $conn.Close()
    $sw.Stop()
    $result.sql = @{ connected = $true; latencyMs = $sw.ElapsedMilliseconds }
} catch {
    $sw.Stop()
    $result.sql = @{ connected = $false; latencyMs = $sw.ElapsedMilliseconds; error = $_.Exception.Message }
}

# Test collector — use GET on the base /api/collect URL (any non-POST returns 405 or 200,
# confirming the server is reachable without triggering actual data processing)
try {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $testUrl = $Config.ApiUrl
    $resp = Invoke-WebRequest -Uri $testUrl -Method GET -TimeoutSec 10 -UseBasicParsing -ErrorAction Stop
    $sw.Stop()
    $result.collector = @{ reachable = $true; latencyMs = $sw.ElapsedMilliseconds; statusCode = $resp.StatusCode }
} catch {
    $sw.Stop()
    $statusCode = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { $null }
    # Any HTTP response (even 4xx/405) means the server is reachable
    if ($statusCode) {
        $result.collector = @{ reachable = $true; latencyMs = $sw.ElapsedMilliseconds; statusCode = $statusCode }
    } else {
        $result.collector = @{ reachable = $false; latencyMs = $sw.ElapsedMilliseconds; error = $_.Exception.Message }
    }
}

return $result
