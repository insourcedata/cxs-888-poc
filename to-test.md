# PowerShell    

$h = @{ "Authorization" = "Bearer 065a4a89d962bfcb35ffa1bf757ac0f3d1b9276098b5514c207492cf333d3217" }
    Invoke-WebRequest -Uri "https://888.insourcedata.org/api/collect/health" -Method GET -Headers $h -TimeoutSec 30 -SkipCertificateCheck            


# curl (built intoWindows)                                                                                                                                                                

curl.exe -k https://888.insourcedata.org/api/collect/health -H "Authorization: Bearer 065a4a89d962bfcb35ffa1bf757ac0f3d1b9276098b5514c207492cf333d3217"  