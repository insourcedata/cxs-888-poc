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
- [ ] SQL Server running on localhost with LS Central database
- [ ] Store server can reach the internet (outbound HTTPS port 443)
- [ ] CXS API URL: `https://888.insourcedata.org/api/collect`
- [ ] CXS API Key: `065a4a89d962bfcb35ffa1bf757ac0f3d1b9276098b5514c207492cf333d3217`

Store-specific values needed:

| Value | Example (SM Marilao) | Where to Find |
|-------|---------------------|---------------|
| SQL Server hostname | `localhost` | Usually localhost |
| Database name | `WSMOD8` | SSMS → Databases list |
| Store code | `S059` | LS Central store setup |
| Oracle code | `4020` | Wendy's mapping |
| Company name | `WENDYS PH` | SSMS → LS Central tables prefix |
| ExtGuid | `5ecfc871-5d82-43f1-9c54-59685e82318d` | LS Central table suffix |

---

## Step 1: Create the CXS Directory

Open PowerShell **as Administrator** on the store server:

```powershell
# Create directory structure
New-Item -ItemType Directory -Path "C:\CXS" -Force
New-Item -ItemType Directory -Path "C:\CXS\logs" -Force
```

**Validate:** Confirm directories were created:

```powershell
Test-Path "C:\CXS", "C:\CXS\logs"
```

Expected output — both should return `True`:
```
True
True
```

---

## Step 2: Copy the Scripts

Copy these two files to `C:\CXS\` on the store server:

1. **`cxs-collector.ps1`** — the main sync script
2. **`install-cxs-collector.ps1`** — the installer (sets up scheduled task)

You can copy via:
- USB drive
- Shared folder
- Direct paste into Notepad and save as `.ps1`

**Validate:** Confirm both scripts exist:

```powershell
Get-ChildItem C:\CXS\*.ps1 | Select-Object Name, Length
```

Expected output:
```
Name                        Length
----                        ------
cxs-collector.ps1             ~6KB
install-cxs-collector.ps1     ~5KB
```

Both files must be present before continuing.

---

## Step 3: Configure the Collector Script

Open `C:\CXS\cxs-collector.ps1` in Notepad or ISE. Update the `$Config` block at the top:

```powershell
$Config = @{
    # CXS collector endpoint
    ApiUrl     = "https://888.insourcedata.org/api/collect"
    ApiKey     = "065a4a89d962bfcb35ffa1bf757ac0f3d1b9276098b5514c207492cf333d3217"

    # SQL Server — Windows Auth, no password needed
    SqlServer  = "localhost"                 # ← Change if named instance (e.g. "SERVERNAME\INSTANCE")
    Database   = "WSMOD8"                    # ← Change per store

    # LS Central table identifiers
    Company    = "WENDYS PH"
    ExtGuid    = "5ecfc871-5d82-43f1-9c54-59685e82318d"

    # Store identifier
    StoreCode  = "S059"                      # ← Change per store
    OracleCode = "4020"                      # ← Change per store

    # Leave these as-is
    StateFile  = "C:\CXS\last-sync.json"
    LogFile    = "C:\CXS\logs\sync.log"
}
```

**Values to change per store:**

| Store | SqlServer | Database | StoreCode | OracleCode |
|-------|-----------|----------|-----------|------------|
| FTI Complex (UAT) | `ITLAB-SVR-AZ\np-master` | NEWPOS | DK003 | 4058 |
| SM Marilao | localhost | WSMOD8 | S059 | 4020 |
| Cubao | TBD | TBD | S002 | TBD |
| SM Clark | TBD | TBD | S085 | TBD |

Save the file.

**Validate:** Confirm the config was saved correctly:

```powershell
Select-String -Path "C:\CXS\cxs-collector.ps1" -Pattern "ApiUrl|Database|StoreCode|OracleCode" | Select-Object -First 4
```

Expected output — should show your store's values (not `CHANGE_ME`):
```
ApiUrl     = "https://888.insourcedata.org/api/collect"
Database   = "WSMOD8"
StoreCode  = "S059"
OracleCode = "4020"
```

---

## Step 4: Verify SQL Server Connectivity

Test that we can reach the database (replace server and database with your store's values):

```powershell
# Change these to match your store
$server = "ITLAB-SVR-AZ\np-master"   # or "localhost" for production stores
$database = "NEWPOS"                  # or "WSMOD8" etc.

$connString = "Server=$server;Database=$database;Integrated Security=True;TrustServerCertificate=True;"
$conn = New-Object System.Data.SqlClient.SqlConnection($connString)
$conn.Open()
Write-Host "SQL Server connection: OK ($server / $database)" -ForegroundColor Green
$conn.Close()
```

**Validate:** You should see:
```
SQL Server connection: OK (ITLAB-SVR-AZ\np-master / NEWPOS)
```

If this fails:
- Check SQL Server is running: `Get-Service MSSQL*`
- Check database name in SSMS
- Try `Server=.\SQLEXPRESS` or the full `SERVERNAME\INSTANCE` if not on default instance
- Check the instance name in SSMS title bar (e.g. `EIGHT8ATE\np-master`)

**Do not proceed until this step passes.**

---

## Step 5: Verify LS Central Tables Exist

```powershell
# Use the same server/database from Step 4
$connString = "Server=$server;Database=$database;Integrated Security=True;TrustServerCertificate=True;"
$conn = New-Object System.Data.SqlClient.SqlConnection($connString)
$conn.Open()

$cmd = $conn.CreateCommand()
$cmd.CommandText = "SELECT TOP 1 * FROM [WENDYS PH`$LSC Transaction Header`$5ecfc871-5d82-43f1-9c54-59685e82318d]"
$adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
$dt = New-Object System.Data.DataTable
[void]$adapter.Fill($dt)

Write-Host "Transaction Header table: OK ($($dt.Rows.Count) row returned)" -ForegroundColor Green
$conn.Close()
```

**Validate:** You should see:
```
Transaction Header table: OK (1 row returned)
```

If it says `0 rows`, the table exists but may be empty — check the date range or confirm transactions exist in SSMS.

If this fails:
- The Company name or ExtGuid may be different — check in SSMS under Tables
- Look for tables starting with `WENDYS PH$LSC`

**Do not proceed until this step passes.**

---

## Step 6: Verify Internet / API Connectivity

```powershell
# Test HTTPS connectivity to CXS collector
try {
    $headers = @{ "Authorization" = "Bearer 065a4a89d962bfcb35ffa1bf757ac0f3d1b9276098b5514c207492cf333d3217" }
    $response = Invoke-WebRequest -Uri "https://888.insourcedata.org/api/collect/health" -Method POST -Headers $headers -TimeoutSec 10
    Write-Host "API connection: OK (Status $($response.StatusCode))" -ForegroundColor Green
} catch {
    Write-Host "API connection: FAILED — $_" -ForegroundColor Red
    Write-Host "Check: Can this server reach the internet?" -ForegroundColor Yellow
}
```

**Validate:** You should see:
```
API connection: OK (Status 200)
```

If this fails:
- Check if the server has internet access: `Test-NetConnection google.com -Port 443`
- Check if there's a proxy: `netsh winhttp show proxy`
- Ask network team if outbound HTTPS (port 443) is allowed

**Do not proceed until this step passes.** All three checks (SQL, tables, API) must pass before running the sync.

---

## Step 7: Run the Script Manually (First Test)

```powershell
cd C:\CXS
powershell -ExecutionPolicy Bypass -File .\cxs-collector.ps1
```

**Validate — Expected output (success):**
```
[2026-04-07 14:30:00] === CXS Sync Start ===
[2026-04-07 14:30:00] Store: S059 (4020)
[2026-04-07 14:30:00] Server: localhost / WSMOD8
[2026-04-07 14:30:00] Sync range: 2026-03-31 to 2026-04-07
[2026-04-07 14:30:01]   Querying headers ...
[2026-04-07 14:30:03]     headers: 245 rows
[2026-04-07 14:30:03]   Querying sales ...
[2026-04-07 14:30:08]     sales: 1820 rows
[2026-04-07 14:30:08]   Querying payments ...
[2026-04-07 14:30:10]     payments: 312 rows
[2026-04-07 14:30:10] Total rows: 2377
[2026-04-07 14:30:10] Sending to https://888.insourcedata.org/api/collect ...
[2026-04-07 14:30:12] POST successful: accepted
[2026-04-07 14:30:12] Last sync updated to: 2026-04-07
[2026-04-07 14:30:12] === CXS Sync Complete ===
```

Check for these **pass criteria**:
- [ ] Row counts > 0 for headers, sales, payments
- [ ] `POST successful: accepted` (not `ERROR posting data`)
- [ ] `Last sync updated to:` line appears
- [ ] No `ERROR` lines in the output

**If no data:**
```
No new data since 2026-03-31 — skipping POST
```
This means the date range has no transactions. Delete the state file to reset and retry:
```powershell
Remove-Item C:\CXS\last-sync.json -ErrorAction SilentlyContinue
```

---

## Step 8: Validate Data on CXS Side

After the script runs successfully, confirm data arrived by checking the collector status:

```powershell
$headers = @{ "Authorization" = "Bearer 065a4a89d962bfcb35ffa1bf757ac0f3d1b9276098b5514c207492cf333d3217" }
$status = Invoke-RestMethod -Uri "https://888.insourcedata.org/api/collect/status" -Method GET -Headers $headers
$status | ConvertTo-Json
```

**Validate:** Check the response:

```json
{
  "queued": 0,
  "processed": 1,
  "failed": 0,
  "processing": false
}
```

- [ ] `processed` count increased by 1 compared to before Step 7
- [ ] `failed` count did NOT increase
- [ ] `queued` is 0 (payload was picked up and processed)

If `failed` increased, the payload was received but processing failed — notify Arshath with the store code and timestamp.

Also verify the state file was updated:

```powershell
Get-Content C:\CXS\last-sync.json
```

Expected:
```json
{
  "lastSyncDate": "2026-04-07",
  "lastSyncTime": "2026-04-07 14:30:12",
  "storeCode": "S059"
}
```

---

## Step 9: Cross-Check Transaction Counts

To validate data accuracy, run this in SSMS on the store server for the same date range:

```sql
-- Count transactions for a specific date
SELECT COUNT(*) as txn_count,
       SUM([Net Amount]) as total_net
FROM [WENDYS PH$LSC Transaction Header$5ecfc871-5d82-43f1-9c54-59685e82318d]
WHERE [Transaction Type] = 2
AND [Date] > '2026-04-01'
```

**Validate:** Compare these numbers with what the CXS dashboard shows for the same store and date range:

- [ ] Transaction count from SSMS matches the `headers: N rows` from Step 7 output
- [ ] Total net amount from SSMS approximately matches dashboard total for the same period
- [ ] If counts differ significantly (>5%), notify Arshath with both numbers

---

## Step 10: Install Scheduled Task (Automated Daily Sync)

Once manual test is successful, install the scheduled task for automatic daily sync:

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

This will:
- Register a Windows Scheduled Task named `CXS Daily Sync`
- Run daily at **2:00 AM**
- Run as SYSTEM (no login required)
- Auto-restart on failure (3 retries, 10-minute intervals)

**Validate:** Confirm the task was created and is ready:

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
Trigger:    2026-04-07T02:00:00
Run As:     SYSTEM
```

- [ ] State is `Ready`
- [ ] Run As is `SYSTEM`
- [ ] Trigger shows 02:00 AM

---

## Step 11: Verify Automated Run (Next Day)

The morning after installation, check that the 2 AM sync ran:

```powershell
# Check last sync state
Get-Content C:\CXS\last-sync.json
```

**Validate:** The `lastSyncDate` should be today's date (updated by the 2 AM run):

```json
{
  "lastSyncDate": "2026-04-08",
  "lastSyncTime": "2026-04-08 02:00:15",
  "storeCode": "S059"
}
```

Check the sync log for errors:

```powershell
# Last 30 lines of log
Get-Content C:\CXS\logs\sync.log -Tail 30
```

**Validate:**
- [ ] Log shows `=== CXS Sync Start ===` and `=== CXS Sync Complete ===` with today's 2 AM timestamp
- [ ] No `ERROR` lines between start and complete
- [ ] `POST successful: accepted` is present

If the log doesn't show a 2 AM run, check the scheduled task history:

```powershell
Get-ScheduledTask -TaskName "CXS Daily Sync" | Get-ScheduledTaskInfo | Select-Object LastRunTime, LastTaskResult
```

- `LastTaskResult` of `0` = success
- Any other value = failure (check `C:\CXS\logs\sync.log` for details)

Also verify on the CXS side using the status endpoint (see Step 8) and confirm with Arshath that overnight data arrived in the dashboard.

---

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| `ERROR: ApiUrl or ApiKey is missing` | Config not updated | Edit `$Config` in `cxs-collector.ps1` (Step 3) |
| `ERROR querying headers` | SQL Server not reachable | Check SQL Server service is running, verify database name |
| `ERROR posting data` | Can't reach CXS API | Check internet connectivity (Step 6) |
| `No new data since ...` | Date range is empty | Delete `C:\CXS\last-sync.json` to reset, or check if store has transactions |
| Script runs but 0 rows | Wrong database or table names | Verify in SSMS — check Company name and ExtGuid |
| `Unauthorized` (401) | API key mismatch | Verify the API key in `$Config` matches the one in this guide |
| Scheduled task not running | Task disabled or SYSTEM can't access SQL | Check Task Scheduler, ensure SQL allows Windows Auth for SYSTEM |
| `processed` count didn't increase | Collector accepted but processor failed | Check with Arshath — `docker compose logs collector` on server |

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
