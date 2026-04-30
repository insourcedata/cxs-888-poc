# POC Store Agent Setup Guide

> Step-by-step guide for installing and testing the CXS data collector on a Wendy's store server.
> This is run by 888 IT via RDP into the store server.
> Last updated: 16 Apr 2026.

## What This Does

A PowerShell script runs on the store server, queries the local LS Central SQL Server for yesterday's transaction data, and sends it as JSON over HTTPS to the CXS collector API. A Windows Scheduled Task runs the script automatically at 02:00 every night.

No VPN, no firewall changes, no inbound ports — outbound HTTPS only.

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

| Store | SqlServer | Database | StoreCode | OracleCode | Status |
|-------|-----------|----------|-----------|------------|--------|
| FTI Complex (UAT) | `ITLAB-SVR-AZ\np-master` | NEWPOS | DK003 | 4058 | Verified |
| SM Marilao | `localhost` | WSMOD8 | S059 | 4020 | Pending SQL reachability test |
| Cubao | TBD | TBD | S002 | TBD | Pending 888 IT info |
| SM Clark | TBD | TBD | S085 | TBD | Pending 888 IT info |

> **Note:** The `install-cxs-collector.ps1` script handles all config — it copies `cxs-collector.ps1` to `C:\CXS\`, rewrites the `$Config` block with the store-specific values you pass as parameters, and registers the scheduled task. No manual editing of the script needed.

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

> **Option A (recommended):** Use `install-cxs-collector.ps1` (Step 12) — it copies the script, sets all config values, and registers the scheduled task in one go. Skip Steps 4-5 if using the installer.
>
> **Option B (manual):** Copy `cxs-collector.ps1` directly and edit the `$Config` block at the top for each store. The repo version has UAT config (DK003) pre-filled.

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

The script has two modes:

**Mode 1 — Daily (no arguments).** Queries yesterday only. This is what the scheduled task runs every night.

```powershell
cd C:\CXS
powershell -ExecutionPolicy Bypass -File .\cxs-collector.ps1
```

**Mode 2 — Backfill (`-StartDate` / `-EndDate`).** Walks a date range one day at a time, one POST per day. Use this for historical data or to re-sync a specific date.

```powershell
cd C:\CXS

# Sync a single specific date
powershell -ExecutionPolicy Bypass -File .\cxs-collector.ps1 -StartDate "2026-04-10" -EndDate "2026-04-10"

# Sync a range (e.g. all of March)
powershell -ExecutionPolicy Bypass -File .\cxs-collector.ps1 -StartDate "2026-03-01" -EndDate "2026-03-31"
```

Both modes are **idempotent** — safe to re-run. If the data already exists, duplicates are skipped.

**Validate — all must be true:**
- [ ] `headers: XX rows` — number > 0
- [ ] `sales: XX rows` — number > 0
- [ ] `payments: XX rows` — number > 0
- [ ] `POST ok: accepted`
- [ ] `=== CXS Sync Complete ===`
- [ ] No `ERROR` lines in the output

**If daily mode shows "no rows — skipping POST":** Yesterday had no transactions. Use backfill mode with a known-good date to test the pipeline end-to-end.

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

Once the manual test in Step 9 passes, register the Windows Scheduled Task. The installer copies a fresh `cxs-collector.ps1` to `C:\CXS\`, injects the per-store config into the `$Config` block via regex-replace, tests SQL + API connectivity once, and registers a task called `CXS Daily Sync` that runs daily at 02:00 as `SYSTEM` with 3 retries on failure.

Pick the section that matches the store you're installing on.

### 12a. Wendy's Store

Wendy's stores use the LS Central extension table format. `Brand`, `Company`, and `ExtGuid` all default to Wendy's values — pass only the per-store fields.

**UAT (DK003 / FTI Complex):**

```powershell
cd C:\CXS
powershell -ExecutionPolicy Bypass -File .\install-cxs-collector.ps1 `
    -ApiUrl     "https://888.insourcedata.org/api/collect" `
    -ApiKey     "e208da46d44dcd96f4ff1732f85ed306" `
    -SqlServer  "ITLAB-SVR-AZ\np-master" `
    -Database   "NEWPOS" `
    -StoreCode  "DK003" `
    -OracleCode "4058"
```

**Production stores (SQL Server on localhost — omit `-SqlServer`):**

```powershell
cd C:\CXS
powershell -ExecutionPolicy Bypass -File .\install-cxs-collector.ps1 `
    -ApiUrl     "https://888.insourcedata.org/api/collect" `
    -ApiKey     "e208da46d44dcd96f4ff1732f85ed306" `
    -Database   "WSMOD8" `
    -StoreCode  "S059" `
    -OracleCode "4020"
```

### 12b. Conti's Store

Conti's NOC database uses the older NAV-format table names (`[NOC$Transaction Header]`) instead of the LS Central extension format Wendy's uses (`[<Company>$LSC <Table>$<GUID>]`). Three additional flags switch the agent into NAV mode and tag payloads as `contis` so the server-side processor uses the right caches and normalisers:

- `-Brand "contis"` — sent in every payload; selects the Conti's outlet/product/tender caches server-side
- `-Company "NOC"` — the table-name prefix (everything before `$` in `NOC$Transaction Header`)
- `-ExtGuid ""` — empty string triggers NAV-format table names (no `$LSC` infix, no GUID suffix)

```powershell
cd C:\CXS
powershell -ExecutionPolicy Bypass -File .\install-cxs-collector.ps1 `
    -ApiUrl     "https://888.insourcedata.org/api/collect" `
    -ApiKey     "e208da46d44dcd96f4ff1732f85ed306" `
    -SqlServer  "SSTSERVER" `
    -Database   "NOCSSTDB" `
    -StoreCode  "NOCSST" `
    -OracleCode "" `
    -Brand      "contis" `
    -Company    "NOC" `
    -ExtGuid    ""
```

> **Finding `Company` for a Conti's instance.** Open SSMS, switch to the LS Central database, expand `Tables`, and look at any name like `<Prefix>$Transaction Header`. The prefix is your `Company` value. For NOC it's `NOC`; other Conti's environments may differ.
>
> **If a Conti's instance turns out to use LS Central extension tables** (e.g. `NOC$LSC Transaction Header$<guid>`), pass that GUID via `-ExtGuid` instead of `""`. The agent picks the right format based on whether `ExtGuid` is empty.

### Custom sync time (either brand)

Default is 02:00 AM. Add `-SyncTime` to stagger or pick a different hour. Both Wendy's and Conti's installs can run at the same time without conflict — they're on different machines, and the collector queues incoming payloads sequentially.

```powershell
# Sync at 3:30 AM instead of 2:00 AM
powershell -ExecutionPolicy Bypass -File .\install-cxs-collector.ps1 `
    -ApiUrl     "https://888.insourcedata.org/api/collect" `
    -ApiKey     "e208da46d44dcd96f4ff1732f85ed306" `
    -Database   "WSMOD8" `
    -StoreCode  "S059" `
    -OracleCode "4020" `
    -SyncTime   "3:30AM"
```

### Validate (PowerShell — same check for both brands)

```powershell
$task = Get-ScheduledTask -TaskName "CXS Daily Sync" -ErrorAction SilentlyContinue
if ($task) {
    $info = $task | Get-ScheduledTaskInfo
    Write-Host "Task Name:    $($task.TaskName)" -ForegroundColor Green
    Write-Host "State:        $($task.State)" -ForegroundColor Green
    Write-Host "Trigger:      $($task.Triggers[0].StartBoundary)" -ForegroundColor Green
    Write-Host "Run As:       $($task.Principal.UserId)" -ForegroundColor Green
    Write-Host "Last Run:     $($info.LastRunTime)" -ForegroundColor Green
    Write-Host "Last Result:  $($info.LastTaskResult)" -ForegroundColor Green
    Write-Host "Next Run:     $($info.NextRunTime)" -ForegroundColor Green
} else {
    Write-Host "ERROR: Scheduled task not found!" -ForegroundColor Red
}
```

- [ ] State is `Ready`
- [ ] Run As is `SYSTEM`
- [ ] Trigger shows the configured sync time (default 02:00)
- [ ] Next Run shows tomorrow's date at the configured time

### Validate (GUI alternative)

1. Press `Win + R`, type `taskschd.msc`, press Enter
2. In the left pane, click **Task Scheduler Library**
3. Find **CXS Daily Sync** in the list
4. Confirm: Status = `Ready`, Triggers = `Daily at 2:00 AM` (or your custom time), Run As User = `SYSTEM`
5. Right-click → **Run** to trigger it manually and confirm it works

---

## Step 13: Verify Automated Run (Next Day)

The morning after installation, check the log for the 02:00 run:

```powershell
Get-Content C:\CXS\logs\sync.log -Tail 30
```

**Validate:**
- [ ] Log shows `=== CXS Sync Start ===` and `=== CXS Sync Complete ===` with ~02:00 timestamp
- [ ] No `ERROR` lines between start and complete
- [ ] `POST ok: accepted` is present

If the log doesn't show a 02:00 run:

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
| `no rows — skipping POST` | Yesterday had no transactions | Use `-StartDate`/`-EndDate` to test a known-good date |
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
├── install-cxs-collector.ps1  # Installer for scheduled task (run once during setup)
└── logs\
    └── sync.log               # Sync logs (appended to daily)
```

---

## Daily Sync — How It Works

Once the scheduled task is installed, the store server automatically syncs data every night.

### What happens at 02:00

1. Windows Task Scheduler runs `cxs-collector.ps1` as SYSTEM
2. The script queries LS Central for **yesterday's** transactions (headers + sales + payments)
3. Builds a JSON payload and POSTs it to `https://888.insourcedata.org/api/collect`
4. The CXS collector receives, validates, and inserts the data into PostgreSQL
5. If the transaction already exists (re-run), it's skipped — no duplicates

The script is **stateless** — it always queries yesterday. No state files, no cursors, no "how far back" logic.

### Monitoring the daily sync

**On the store server** (RDP in, check the log):

```powershell
# Last 30 lines of the log
Get-Content C:\CXS\logs\sync.log -Tail 30

# Check last run time and result
Get-ScheduledTask -TaskName "CXS Daily Sync" | Get-ScheduledTaskInfo | Select-Object LastRunTime, LastTaskResult
```

- `LastTaskResult = 0` means success
- Any other value means failure — check the log for `ERROR` lines

**On the CXS dashboard** (web browser):

1. Sign in to `https://888.insourcedata.org`
2. Go to **Admin** (super_admin only)
3. Check the "Latest sync per store" table — each store should show `status: ok` with a recent date

### If a nightly sync fails

The failed day won't be automatically retried. To fill the gap, RDP into the store and run:

```powershell
cd C:\CXS

# Replay a single missed day
powershell -ExecutionPolicy Bypass -File .\cxs-collector.ps1 -StartDate "2026-04-14" -EndDate "2026-04-14"

# Replay a range of missed days
powershell -ExecutionPolicy Bypass -File .\cxs-collector.ps1 -StartDate "2026-04-14" -EndDate "2026-04-16"
```

Safe to re-run even if the day partially succeeded — duplicate transactions are skipped automatically.

### If you need to backfill historical data

For a new store that needs months of historical data loaded:

```powershell
cd C:\CXS

# Backfill all of Q1 2026 (walks day by day, one POST per day)
powershell -ExecutionPolicy Bypass -File .\cxs-collector.ps1 -StartDate "2026-01-01" -EndDate "2026-03-31"
```

If any day fails mid-backfill, the script stops and prints the exact command to resume from the failed day.

### Common issues with automated runs

| Symptom | Cause | Fix |
|---------|-------|-----|
| No 02:00 entry in log | Task didn't fire | Check `Get-ScheduledTask` state is `Ready` |
| `ERROR posting` in log | Network/API issue | Run Step 8 diagnostics (DNS → TCP → HTTPS) |
| `ERROR querying` in log | SQL Server down or unreachable | Check SQL Server service is running |
| Log shows success but no data on dashboard | Empty day (no transactions yesterday) | Normal — check a day you know has data |
| Task shows `LastTaskResult = 1` | Script exited with error | Read the full log: `Get-Content C:\CXS\logs\sync.log` |
