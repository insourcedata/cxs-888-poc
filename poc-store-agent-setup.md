# POC Store Agent Setup — UAT Server

> Step-by-step guide for installing and testing the CXS data collector script on a Wendy's store server.
> This is run by 888 IT via RDP into the store server.

## What This Does

A PowerShell script runs on the store server, queries the local LS Central SQL Server for transaction data, and sends it as JSON over HTTPS to the CXS collector API. No VPN, no inbound ports — outbound HTTPS only.

---

## Pre-requisites

Before starting, confirm:

- [ ] RDP access to the store server
- [ ] Windows Server with PowerShell 5.1+ or 7.x
- [ ] SQL Server running with LS Central database
- [ ] Store server can reach the internet (outbound HTTPS port 443)
- [ ] `*.insourcedata.org` is **whitelisted** on the network firewall (FortiGate blocks it as "Unrated" by default)
- [ ] CXS API URL: `https://888.insourcedata.org/api/collect`
- [ ] CXS API Key: `065a4a89d962bfcb35ffa1bf757ac0f3d1b9276098b5514c207492cf333d3217`

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

**Validate:** The PowerShell window title shows `Administrator`.

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

## Step 4: Copy the Script

Save `cxs-collector.ps1` (provided by CXS) to `C:\CXS\` on the store server.

You can copy via:
- Paste content into Notepad → Save As `C:\CXS\cxs-collector.ps1`
- Email attachment (zip first — `.ps1` may be blocked)
- Teams / shared folder / USB drive

> **Note:** The script provided already has the UAT config (ITLAB-SVR-AZ\np-master, NEWPOS, DK003) pre-filled.
> No editing needed for UAT. For other stores, edit the `$Config` block at the top.

**Validate:**

```powershell
Test-Path "C:\CXS\cxs-collector.ps1"
```

Returns `True`.

---

## Step 5: Verify Config Values

```powershell
Select-String -Path "C:\CXS\cxs-collector.ps1" -Pattern "SqlServer|Database|StoreCode|OracleCode" | Select-Object -First 4
```

**Validate:** Should show:
```
SqlServer  = "ITLAB-SVR-AZ\np-master"
Database   = "NEWPOS"
StoreCode  = "DK003"
OracleCode = "4058"
```

If values are wrong, open `C:\CXS\cxs-collector.ps1` in Notepad and edit the `$Config` block.

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

If it fails, try: `Server=localhost\np-master` or `Server=EIGHT8ATE\np-master`

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

**Validate:** Number > 0 (UAT has ~18,997 total rows).

**Stop here if this fails.**

---

## Step 8: Test Network / API Connectivity

**8a. DNS + TCP:**

```powershell
Resolve-DnsName 888.insourcedata.org
Test-NetConnection 888.insourcedata.org -Port 443
```

**Validate:** DNS returns an IP, `TcpTestSucceeded : True`

**8b. HTTPS health check (PowerShell 7):**

```powershell
$h = @{ "Authorization" = "Bearer 065a4a89d962bfcb35ffa1bf757ac0f3d1b9276098b5514c207492cf333d3217" }
Invoke-WebRequest -Uri "https://888.insourcedata.org/api/collect/health" -Method GET -Headers $h -TimeoutSec 30 -SkipCertificateCheck
```

**Or with curl (works in both PS5.1 and PS7):**

```powershell
curl.exe -k https://888.insourcedata.org/api/collect/health -H "Authorization: Bearer 065a4a89d962bfcb35ffa1bf757ac0f3d1b9276098b5514c207492cf333d3217"
```

**Validate:** Returns `{"status":"ok"}` with Status 200.

If you get an HTML page with **"FortiGuard Intrusion Prevention — Access Blocked"**:
- The firewall is blocking `insourcedata.org` as "Unrated"
- Ask the network/security team to whitelist `*.insourcedata.org` on the FortiGate web filter
- **Stop here until whitelisted**

If you get **"PartialChain" certificate error**:
- Use `-SkipCertificateCheck` (PS7) or `curl.exe -k`
- The sync script handles this automatically — it's only a problem for manual tests

**Stop here if this fails.**

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
No new data since 2026-04-01 — skipping POST
```
Delete the state file to reset and retry:
```powershell
Remove-Item C:\CXS\last-sync.json -ErrorAction SilentlyContinue
```
Then re-run the script.

---

## Step 10: Verify Data Arrived on CXS Side

```powershell
$h = @{ "Authorization" = "Bearer 065a4a89d962bfcb35ffa1bf757ac0f3d1b9276098b5514c207492cf333d3217" }
Invoke-RestMethod -Uri "https://888.insourcedata.org/api/collect/status" -Method GET -Headers $h -SkipCertificateCheck
```

**Validate:**
- [ ] `processed` increased by 1
- [ ] `failed` did NOT increase
- [ ] `queued` is 0

Also check the sync state file:

```powershell
Get-Content C:\CXS\last-sync.json
```

**Validate:** `lastSyncDate` shows today's date and `storeCode` is `DK003`.

If `failed` increased, notify Arshath with the store code and timestamp.

---

## Step 11: Cross-Check Transaction Counts

Run in SSMS on the store server for the same date range:

```sql
SELECT COUNT(*) as txn_count,
       SUM([Net Amount]) as total_net
FROM [WENDYS PH$LSC Transaction Header$5ecfc871-5d82-43f1-9c54-59685e82318d]
WHERE [Transaction Type] = 2
AND [Date] > '2026-04-01'
```

**Validate:**
- [ ] `txn_count` approximately matches the `headers: N rows` from Step 9
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

---

## Known Issues

### FortiGate Firewall Blocking

888 store servers use FortiGate firewalls that block "Unrated" domains. `insourcedata.org` must be whitelisted before the script can reach the API. Symptoms:

- `curl.exe` returns HTML with "FortiGuard Intrusion Prevention — Access Blocked"
- `Invoke-WebRequest` times out or returns HTML instead of JSON

**Fix:** Ask the 888 network/security team to whitelist `*.insourcedata.org` on the FortiGate web filter.

### Certificate PartialChain Error

Windows Servers may be missing Cloudflare's root CA certificates. Symptoms:

- `Invoke-WebRequest` fails with "PartialChain" error

**Fix:** The sync script handles this automatically with `TrustAllCertsPolicy`. For manual tests, use `-SkipCertificateCheck` (PS7) or `curl.exe -k`.

---

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| FortiGuard "Access Blocked" HTML | Firewall blocking unrated domain | Whitelist `*.insourcedata.org` on FortiGate |
| `PartialChain` certificate error | Missing Cloudflare root CA | Script handles automatically; manual tests use `-SkipCertificateCheck` |
| `ERROR: ApiUrl or ApiKey is missing` | Config not updated | Edit `$Config` in `cxs-collector.ps1` (Step 5) |
| `ERROR querying headers` | SQL Server not reachable | Check SQL Server service, verify instance name and database |
| `ERROR posting data` / timeout | Can't reach CXS API | Run Step 8 diagnostics (DNS → TCP → HTTPS) |
| `No new data since ...` | Date range is empty | Delete `C:\CXS\last-sync.json` to reset |
| Script runs but 0 rows | Wrong database or table names | Verify in SSMS — check Company name and ExtGuid |
| `Unauthorized` (401) | API key mismatch | Verify the API key matches the one in this guide |
| `processed` count didn't increase | Collector accepted but processor failed | Notify Arshath — server-side processing issue |

---

## Logs Location

All logs are written to `C:\CXS\logs\sync.log`. Share this file with CXS (Arshath) if troubleshooting is needed.

---

## Files on Store Server

After setup, the store server should have:

```
C:\CXS\
├── cxs-collector.ps1          # Main sync script (pre-configured for this store)
├── install-cxs-collector.ps1  # Installer for scheduled task (optional)
├── last-sync.json             # Tracks last successful sync date
└── logs\
    └── sync.log               # Sync logs
```
