# POC Store Agent Setup — UAT Server

> Step-by-step guide for installing and testing the CXS data collector script on a Wendy's store server.
> This is run by 888 IT via RDP into the store server.

## What This Does

A PowerShell script runs on the store server, queries the local LS Central SQL Server for transaction data, and sends it as JSON over HTTPS to the CXS collector API. No VPN, no inbound ports — outbound HTTPS only.

---

## Pre-requisites

Before starting, confirm:

- [ ] RDP access to the store server
- [ ] Windows Server with PowerShell 5.1+ (pre-installed on all Windows Server 2016+)
- [ ] SQL Server running with LS Central database
- [ ] Store server can reach the internet (outbound HTTPS port 443)
- [ ] CXS API URL: `https://888.insourcedata.org/api/collect`
- [ ] CXS API Key: `065a4a89d962bfcb35ffa1bf757ac0f3d1b9276098b5514c207492cf333d3217`

Store-specific values needed:

| Value | Example (UAT — FTI Complex) | Where to Find |
|-------|----------------------------|---------------|
| SQL Server instance | `ITLAB-SVR-AZ\np-master` | SSMS title bar or connection dialog |
| Database name | `NEWPOS` | SSMS → Object Explorer → Databases |
| Store code | `DK003` | CXS store mapping (ask Arshath) |
| Oracle code | `4058` | LS Central `Store No_` column |
| Company name | `WENDYS PH` | SSMS → Tables prefix |
| ExtGuid | `5ecfc871-5d82-43f1-9c54-59685e82318d` | SSMS → Table name suffix |

**Store config reference:**

| Store | SqlServer | Database | StoreCode | OracleCode |
|-------|-----------|----------|-----------|------------|
| FTI Complex (UAT) | `ITLAB-SVR-AZ\np-master` | NEWPOS | DK003 | 4058 |
| SM Marilao | localhost | WSMOD8 | S059 | 4020 |
| Cubao | TBD | TBD | S002 | TBD |
| SM Clark | TBD | TBD | S085 | TBD |

---

## Step 1: RDP into the Store Server

Connect to the store server via Remote Desktop (e.g. `10.10.30.6` for UAT).

**Validate:** You are logged in and can see the Windows desktop.

---

## Step 2: Open PowerShell as Administrator

Right-click the Windows Start menu → **Windows PowerShell (Admin)**

**Validate:** The PowerShell window title shows `Administrator` and the prompt appears.

---

## Step 3: Create the CXS Directory

```powershell
New-Item -ItemType Directory -Path "C:\CXS" -Force
New-Item -ItemType Directory -Path "C:\CXS\logs" -Force
```

**Validate:**

```powershell
Test-Path "C:\CXS", "C:\CXS\logs"
```

Both return `True`.

---

## Step 4: Copy the Scripts

Copy these two files (provided by CXS) to `C:\CXS\` on the store server:

1. **`cxs-collector.ps1`** — the main sync script
2. **`install-cxs-collector.ps1`** — the installer (sets up scheduled task)

You can copy via:
- Email attachment (zip first — `.ps1` may be blocked)
- Teams / shared folder
- USB drive
- Paste content into Notepad → Save As `.ps1`

**Validate:**

```powershell
Get-ChildItem C:\CXS\*.ps1 | Select-Object Name, Length
```

Expected — both files present:
```
Name                        Length
----                        ------
cxs-collector.ps1             ~7KB
install-cxs-collector.ps1     ~5KB
```

---

## Step 5: Configure the Collector Script

Open `C:\CXS\cxs-collector.ps1` in Notepad or ISE. Update the `$Config` block at the top.

**For UAT (FTI Complex):**

```powershell
$Config = @{
    ApiUrl     = "https://888.insourcedata.org/api/collect"
    ApiKey     = "065a4a89d962bfcb35ffa1bf757ac0f3d1b9276098b5514c207492cf333d3217"
    SqlServer  = "ITLAB-SVR-AZ\np-master"
    Database   = "NEWPOS"
    Company    = "WENDYS PH"
    ExtGuid    = "5ecfc871-5d82-43f1-9c54-59685e82318d"
    StoreCode  = "DK003"
    OracleCode = "4058"
    StateFile  = "C:\CXS\last-sync.json"
    LogFile    = "C:\CXS\logs\sync.log"
}
```

Save the file.

**Validate:**

```powershell
Select-String -Path "C:\CXS\cxs-collector.ps1" -Pattern "SqlServer|Database|StoreCode|OracleCode" | Select-Object -First 4
```

Should show `ITLAB-SVR-AZ\np-master`, `NEWPOS`, `DK003`, `4058`.

---

## Step 6: Test SQL Server Connection

```powershell
$server = "ITLAB-SVR-AZ\np-master"
$database = "NEWPOS"

$connString = "Server=$server;Database=$database;Integrated Security=True;TrustServerCertificate=True;"
$conn = New-Object System.Data.SqlClient.SqlConnection($connString)
$conn.Open()
Write-Host "SQL Server connection: OK ($server / $database)" -ForegroundColor Green
$conn.Close()
```

**Validate:** You see:
```
SQL Server connection: OK (ITLAB-SVR-AZ\np-master / NEWPOS)
```

If it fails:
- Check SQL Server is running: `Get-Service MSSQL*`
- Verify the instance name in SSMS title bar (e.g. `EIGHT8ATE\np-master`)
- Try: `Server=localhost\np-master` or `Server=.\np-master`

**Stop here if this fails.**

---

## Step 7: Test LS Central Tables Exist

```powershell
$connString = "Server=$server;Database=$database;Integrated Security=True;TrustServerCertificate=True;"
$conn = New-Object System.Data.SqlClient.SqlConnection($connString)
$conn.Open()
$cmd = $conn.CreateCommand()
$cmd.CommandText = "SELECT COUNT(*) FROM [WENDYS PH`$LSC Transaction Header`$5ecfc871-5d82-43f1-9c54-59685e82318d] WHERE [Date] > '2026-03-01'"
$count = $cmd.ExecuteScalar()
Write-Host "Transaction rows since Mar 1: $count" -ForegroundColor Green
$conn.Close()
```

**Validate:** Number > 0 (UAT shows ~18,997 total rows).

If this fails:
- Check Company name and ExtGuid — look in SSMS under Tables for `WENDYS PH$LSC`
- The table may have a different ExtGuid on this server

**Stop here if this fails.**

---

## Step 8: Test Network / DNS / API Connectivity

Run all three checks in order:

**8a. DNS resolution:**

```powershell
Resolve-DnsName 888.insourcedata.org
```

**Validate:** Returns an IP address (Cloudflare). If it fails, DNS can't resolve our domain — ask the network team to allow DNS resolution for `888.insourcedata.org`, or try:

```powershell
# Test with Google DNS directly
Resolve-DnsName 888.insourcedata.org -Server 8.8.8.8
```

**Stop here if DNS fails.**

**8b. TCP connectivity:**

```powershell
Test-NetConnection 888.insourcedata.org -Port 443
```

**Validate:** `TcpTestSucceeded : True`

If `False`:
- Check proxy: `netsh winhttp show proxy`
- Ask network team to whitelist outbound HTTPS (port 443) to `888.insourcedata.org`

**Stop here if TCP fails.**

**8c. HTTPS API call (with TLS 1.2):**

```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
try {
    $h = @{ "Authorization" = "Bearer 065a4a89d962bfcb35ffa1bf757ac0f3d1b9276098b5514c207492cf333d3217" }
    $r = Invoke-WebRequest -Uri "https://888.insourcedata.org/api/collect/health" -Method POST -Headers $h -TimeoutSec 30
    Write-Host "API connection: OK (Status $($r.StatusCode))" -ForegroundColor Green
} catch {
    Write-Host "API connection: FAILED — $_" -ForegroundColor Red
}
```

**Validate:** `API connection: OK (Status 200)`

If timeout or fails:
- If DNS and TCP passed but HTTPS fails → likely TLS issue or firewall doing SSL inspection
- Check if there's a corporate proxy: `[System.Net.WebRequest]::DefaultWebProxy.GetProxy("https://888.insourcedata.org")`
- Try bypassing proxy: add `-Proxy ([System.Net.GlobalProxySelection]::GetEmptyWebProxy())` to the `Invoke-WebRequest` call
- Ask network team if there's a firewall or SSL inspection appliance blocking outbound HTTPS

**All three checks (DNS, TCP, HTTPS) must pass before proceeding.**

---

## Step 9: Run the First Sync

```powershell
cd C:\CXS
powershell -ExecutionPolicy Bypass -File .\cxs-collector.ps1
```

**Validate — all must be true:**
- [ ] `headers: XX rows` — number > 0
- [ ] `sales: XX rows` — number > 0
- [ ] `payments: XX rows` — number > 0
- [ ] `POST successful: accepted`
- [ ] `=== CXS Sync Complete ===`
- [ ] No `ERROR` lines in the output

**If no data:**
```
No new data since 2026-03-30 — skipping POST
```
Delete the state file to reset and retry:
```powershell
Remove-Item C:\CXS\last-sync.json -ErrorAction SilentlyContinue
```
Then re-run the script.

---

## Step 10: Verify Data Arrived on CXS Side

```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$h = @{ "Authorization" = "Bearer 065a4a89d962bfcb35ffa1bf757ac0f3d1b9276098b5514c207492cf333d3217" }
$s = Invoke-RestMethod -Uri "https://888.insourcedata.org/api/collect/status" -Method GET -Headers $h
Write-Host "Queued: $($s.queued)  Processed: $($s.processed)  Failed: $($s.failed)" -ForegroundColor Cyan
```

**Validate:**
- [ ] `Processed` increased by 1
- [ ] `Failed` did NOT increase
- [ ] `Queued` is 0

Also check the sync state file:

```powershell
Get-Content C:\CXS\last-sync.json
```

**Validate:** `lastSyncDate` shows today's date:
```json
{
  "lastSyncDate": "2026-04-06",
  "lastSyncTime": "2026-04-06 ...",
  "storeCode": "DK003"
}
```

If `Failed` increased, notify Arshath with the store code and timestamp.

---

## Step 11: Cross-Check Transaction Counts

Run in SSMS on the store server for the same date range:

```sql
SELECT COUNT(*) as txn_count,
       SUM([Net Amount]) as total_net
FROM [WENDYS PH$LSC Transaction Header$5ecfc871-5d82-43f1-9c54-59685e82318d]
WHERE [Transaction Type] = 2
AND [Date] > '2026-03-30'
```

**Validate:**
- [ ] `txn_count` matches the `headers: N rows` from Step 9 output
- [ ] `total_net` approximately matches what the CXS dashboard shows
- [ ] If counts differ significantly (>5%), notify Arshath with both numbers

---

## Step 12: Install Scheduled Task (Automated Daily Sync)

Once manual test is successful:

```powershell
cd C:\CXS
powershell -ExecutionPolicy Bypass -File .\install-cxs-collector.ps1 `
    -ApiUrl "https://888.insourcedata.org/api/collect" `
    -ApiKey "065a4a89d962bfcb35ffa1bf757ac0f3d1b9276098b5514c207492cf333d3217" `
    -SqlServer "ITLAB-SVR-AZ\np-master" `
    -Database "NEWPOS" `
    -StoreCode "DK003" `
    -OracleCode "4058"
```

For production stores using localhost, omit `-SqlServer` (defaults to `localhost`).

**Validate:**

```powershell
$task = Get-ScheduledTask -TaskName "CXS Daily Sync" -ErrorAction SilentlyContinue
if ($task) {
    Write-Host "Task Name:  $($task.TaskName)" -ForegroundColor Green
    Write-Host "State:      $($task.State)" -ForegroundColor Green
    Write-Host "Trigger:    $($task.Triggers[0].StartBoundary)" -ForegroundColor Green
    Write-Host "Run As:     $($task.Principal.UserId)" -ForegroundColor Green
} else {
    Write-Host "ERROR: Scheduled task not found!" -ForegroundColor Red
}
```

Expected:
```
Task Name:  CXS Daily Sync
State:      Ready
Trigger:    2026-04-06T02:00:00
Run As:     SYSTEM
```

- [ ] State is `Ready`
- [ ] Run As is `SYSTEM`
- [ ] Trigger shows 02:00 AM

---

## Step 13: Verify Automated Run (Next Day)

The morning after installation:

```powershell
Get-Content C:\CXS\last-sync.json
```

**Validate:** `lastSyncDate` should be today's date (updated by the 2 AM run).

Check log for errors:

```powershell
Get-Content C:\CXS\logs\sync.log -Tail 30
```

**Validate:**
- [ ] Log shows `=== CXS Sync Start ===` and `=== CXS Sync Complete ===` with 2 AM timestamp
- [ ] No `ERROR` lines between start and complete
- [ ] `POST successful: accepted` is present

If the log doesn't show a 2 AM run:

```powershell
Get-ScheduledTask -TaskName "CXS Daily Sync" | Get-ScheduledTaskInfo | Select-Object LastRunTime, LastTaskResult
```

- `LastTaskResult` of `0` = success
- Any other value = failure (check `C:\CXS\logs\sync.log`)

Also verify on the CXS side using the status endpoint (see Step 10).

---

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| `ERROR: ApiUrl or ApiKey is missing` | Config not updated | Edit `$Config` in `cxs-collector.ps1` (Step 5) |
| `ERROR querying headers` | SQL Server not reachable | Check SQL Server service, verify instance name and database |
| `ERROR posting data` / timeout | Can't reach CXS API | Run Step 8 diagnostics (DNS → TCP → HTTPS) |
| DNS fails (`Resolve-DnsName`) | Internal DNS can't resolve domain | Try `Resolve-DnsName 888.insourcedata.org -Server 8.8.8.8` or ask network team |
| TCP passes but HTTPS times out | TLS issue or SSL inspection | Ensure TLS 1.2 is forced, check for corporate proxy/firewall |
| `No new data since ...` | Date range is empty | Delete `C:\CXS\last-sync.json` to reset |
| Script runs but 0 rows | Wrong database or table names | Verify in SSMS — check Company name and ExtGuid |
| `Unauthorized` (401) | API key mismatch | Verify the API key in `$Config` matches the one in this guide |
| Scheduled task not running | Task disabled or SYSTEM can't access SQL | Check Task Scheduler, ensure SQL allows Windows Auth for SYSTEM |
| `processed` count didn't increase | Collector accepted but processor failed | Notify Arshath — server-side processing issue |

---

## Logs Location

All logs are written to `C:\CXS\logs\sync.log`. Share this file with CXS (Arshath) if troubleshooting is needed.

---

## Files on Store Server

After setup, the store server should have:

```
C:\CXS\
├── cxs-collector.ps1          # Main sync script
├── install-cxs-collector.ps1  # Installer (run once)
├── last-sync.json             # Tracks last successful sync date
└── logs\
    └── sync.log               # Sync logs
```
