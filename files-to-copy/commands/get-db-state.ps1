# Get-DbState.ps1 — Row counts for specified SQL tables
param($Params, $Config)

$tables = if ($Params -and $Params.PSObject.Properties['tables'] -and $Params.tables) { $Params.tables } else {
    @("Transaction Header", "Trans_ Sales Entry", "Trans_ Payment Entry")
}

$connString = "Server=$($Config.SqlServer);Database=$($Config.Database);Integrated Security=True;TrustServerCertificate=True;Connection Timeout=10;"
$results = @()

try {
    $conn = New-Object System.Data.SqlClient.SqlConnection($connString)
    $conn.Open()

    foreach ($tableName in $tables) {
        try {
            $cmd = $conn.CreateCommand()
            $safeName = $tableName -replace '\]', ']]'
            $cmd.CommandText = "SELECT COUNT(*) AS cnt FROM [$safeName]"
            $cmd.CommandTimeout = 60
            $count = $cmd.ExecuteScalar()
            $results += @{ name = $tableName; rowCount = $count }
        } catch {
            $results += @{ name = $tableName; error = $_.Exception.Message }
        }
    }

    $conn.Close()
} catch {
    return @{ tables = @(); error = $_.Exception.Message }
}

return @{ tables = $results }
