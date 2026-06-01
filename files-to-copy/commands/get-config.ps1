# Get-Config.ps1 - Returns current agent config (sensitive fields redacted)
param($Params, $Config)

return @{
    config = @{
        brand              = $Config.Brand
        storeCode          = $Config.StoreCode
        sqlServer          = $Config.SqlServer
        database           = $Config.Database
        heartbeatInterval  = $Config.HeartbeatInterval
        syncSchedule       = if ($Config.SyncSchedule) { $Config.SyncSchedule } else { "02:00" }
        collectorEndpoint  = $Config.ApiUrl
        logFile            = $Config.LogFile
        apiKey             = "[REDACTED]"
    }
}
