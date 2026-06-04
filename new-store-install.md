# New Store Install (store that never had an agent)

Use this when a store has **no agent at all** - nothing in `C:\CXS`, no
`cxs-agent.json`, never been set up before.

Do every step on the store server, in **PowerShell as Administrator**.

The scripts in `files-to-copy/` are plain text and won't get scrambled when
copied. **Copy the whole folder** - do NOT paste file contents one at a time.

---

## Step 1 - Get the clean files onto the server

1. Download the repo from GitHub: green **Code** button -> **Download ZIP**.
   (Downloading keeps the files exact - this is the safe way.)
2. Unzip it. Inside is a folder called **`files-to-copy`**.
3. On the store server, copy that whole **`files-to-copy`** folder to
   **`C:\Temp\store-agent`** (so you have
   `C:\Temp\store-agent\install-cxs-collector.ps1`, etc.).

Do NOT open the scripts in Word/Notepad to copy them - just copy the folder.
Always copy to `C:\Temp\store-agent`, **NOT** into `C:\CXS` (running from inside
`C:\CXS` makes it copy files onto themselves).

## Step 2 - Quick checks before installing

**SQL reachable** (use this store's server/database):
```powershell
$server = "WFTISERVER"; $database = "WFTIDB"
$cs = "Server=$server;Database=$database;Integrated Security=True;TrustServerCertificate=True;Connection Timeout=10;"
$c = New-Object System.Data.SqlClient.SqlConnection($cs); $c.Open(); "SQL OK"; $c.Close()
```
Want to see `SQL OK`. If it fails, fix SQL reachability (instance name / database)
before going further.

**Internet / API reachable:**
```powershell
Test-NetConnection 888.insourcedata.org -Port 443
curl.exe -k https://888.insourcedata.org/api/collect/health -H "Authorization: Bearer <API KEY>"
```
Want `TcpTestSucceeded : True` and `{"status":"ok"}`.

- **FortiGuard "Access Blocked" HTML** -> the FortiGate firewall is blocking us.
  Ask the 888 network/security team to whitelist `*.insourcedata.org` on the
  FortiGate web filter. Stop until that's done.
- **Certificate `PartialChain` error** -> the server is missing Cloudflare's root
  CA. The agent handles this automatically at runtime; for manual tests use
  `curl.exe -k`. If the installer itself complains, add `-AllowSelfSignedCert` to
  the command in Step 3.

## Step 3 - Run the installer (fill in this store's details)

Below is DK003 as the example. Change the values for the store you're on.
The API key is from Arshath. The installer copies the scripts into `C:\CXS`,
writes the config, and creates both scheduled tasks in one go.

**Wendy's:**
```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force

C:\Temp\store-agent\install-cxs-collector.ps1 `
    -Brand      "wendys" `
    -ApiUrl     "https://888.insourcedata.org/api/collect" `
    -ApiKey     "<API KEY>" `
    -SqlServer  "WFTISERVER" `
    -Database   "WFTIDB" `
    -StoreCode  "DK003" `
    -OracleCode "4058"
```

**Conti's:** use `-Brand "contis"` and drop `-OracleCode` (Conti's defaults to
Company `NOC`, NAV-format tables, and a 02:00 sync time):
```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force

C:\Temp\store-agent\install-cxs-collector.ps1 `
    -Brand      "contis" `
    -ApiUrl     "https://888.insourcedata.org/api/collect" `
    -ApiKey     "<API KEY>" `
    -SqlServer  "SSTSERVER" `
    -Database   "NOC<...>DB" `
    -StoreCode  "NOCXYZ"
```

It should end with `=== Installation Complete ===` and no `[FAIL]` lines.

Optional flags:
- `-SqlServer "localhost"` if SQL Server runs on this same box (you can also just
  omit `-SqlServer` for the Wendy's default).
- `-SyncTime "3:30AM"` to override the default sync time (Wendy's 05:00, Conti's 02:00).
- `-AllowSelfSignedCert` only if Step 2 showed a certificate `PartialChain` error.

## Step 4 - Let SYSTEM into SQL Server (one-time, important)

The scheduled tasks run as `NT AUTHORITY\SYSTEM`, not your login. SQL Server
treats those as different accounts - your login can connect (which is why Step 2
worked), but `SYSTEM` usually can't until you grant it. **Skip this and the agent
looks fine today but the nightly sync fails tomorrow** with:

```
Login failed for user 'NT AUTHORITY\SYSTEM'.
```

Open SSMS and pick the case that matches where SQL Server runs.

### 4a. SQL Server is on the SAME machine as the agent (most common)

Connected to the local SQL instance, replace `<DB>` with this store's database
(e.g. `WFTIDB`, `WSMOD8`, `NOCSSTDB`) and run:

```sql
-- Idempotent: safe to re-run.
USE master;
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'NT AUTHORITY\SYSTEM')
    CREATE LOGIN [NT AUTHORITY\SYSTEM] FROM WINDOWS;
GO

USE <DB>;
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'NT AUTHORITY\SYSTEM')
    CREATE USER [NT AUTHORITY\SYSTEM] FOR LOGIN [NT AUTHORITY\SYSTEM];
ALTER ROLE db_datareader ADD MEMBER [NT AUTHORITY\SYSTEM];
GO
```

`db_datareader` is enough - the agent only reads, never writes.

### 4b. SQL Server is on a DIFFERENT machine from the agent

Cross-machine, SQL sees the agent as the **agent machine's computer account**
(`<DOMAIN>\<HOSTNAME>$`, note the trailing `$`). On the agent machine, get that name:

```powershell
"$env:USERDOMAIN\$env:COMPUTERNAME$"
```

Then in SSMS connected to the SQL Server box, replace `DOMAIN\AGENTHOST$` with that
value and `<DB>` with the database name:

```sql
USE master;
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'DOMAIN\AGENTHOST$')
    CREATE LOGIN [DOMAIN\AGENTHOST$] FROM WINDOWS;
GO

USE <DB>;
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'DOMAIN\AGENTHOST$')
    CREATE USER [DOMAIN\AGENTHOST$] FOR LOGIN [DOMAIN\AGENTHOST$];
ALTER ROLE db_datareader ADD MEMBER [DOMAIN\AGENTHOST$];
GO
```

## Step 5 - Check it worked

The installer names this store's files per-store (`cxs-agent-<StoreCode>.json`,
`agent-<StoreCode>.log`). Set `$sc` to the StoreCode you installed in Step 3,
then run the rest as-is:

```powershell
$sc = "DK003"   # <-- change to the StoreCode you installed in Step 3

Get-ScheduledTask -TaskName "CXS Daily Sync - $sc","CXS Agent Heartbeat - $sc" `
    -ErrorAction SilentlyContinue | Select-Object TaskName, State
Start-ScheduledTask -TaskName "CXS Agent Heartbeat - $sc" -ErrorAction SilentlyContinue
Start-Sleep -Seconds 30
$log = "C:\CXS\logs\agent-$sc.log"
if (Test-Path $log) { Get-Content $log -Tail 20 }
else { "No log yet at $log - the heartbeat task may not be running." }
```

You want to see:
- Daily Sync task = **Ready**, Heartbeat task = **Running**
- A log line like `Heartbeat sent. SQL=True ...`
- The store shows up on the dashboard: **Admin -> Agent Fleet** (within ~5 min)

If the log only shows `CXS Agent starting` (no `Heartbeat sent` yet), wait a
minute and re-run the last two lines - the first heartbeat can take a moment.

If you instead see `Heartbeat failed: ...` in the log, the agent is running but
can't reach the API - the error text says why (firewall, proxy, certificate, or
a wrong API key). The scheduled task runs as `NT AUTHORITY\SYSTEM`, so a network
path that works from your own login may still be blocked for SYSTEM.

If the log says `SQL=False`, SYSTEM still can't get into SQL - redo Step 4.

## Step 6 - First sync + backfill

Pull a known-good day to confirm data flows end to end (use a recent date that
has sales):
```powershell
C:\CXS\cxs-collector-DK003.ps1 -StartDate "2026-06-01" -EndDate "2026-06-01"
```
Want `POST ok: accepted`. Then check **Admin -> Store Syncs** on the dashboard -
the store should show `status: ok` with that date.

To pull history, give a date range (one POST per day, safe to re-run -
duplicates are skipped):
```powershell
C:\CXS\cxs-collector-DK003.ps1 -StartDate "2025-01-01" -EndDate "2025-03-31"
```
The agent can only return what the store's POS still keeps - if older dates come
back empty, that data isn't on the POS anymore.

---

## Store details (fill in as you go)

| Store | Brand | SqlServer | Database | StoreCode | OracleCode |
|-------|-------|-----------|----------|-----------|------------|
| FTI / DK003 | wendys | WFTISERVER | WFTIDB | DK003 | 4058 |
|       |       |           |          |           |            |

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| FortiGuard "Access Blocked" HTML | Firewall blocking unrated domain | Whitelist `*.insourcedata.org` on FortiGate |
| `PartialChain` certificate error | Missing Cloudflare root CA | Agent handles it at runtime; manual tests use `curl.exe -k`; installer can take `-AllowSelfSignedCert` |
| `Login failed for user 'NT AUTHORITY\SYSTEM'` | SYSTEM has no SQL access | Do Step 4 |
| Heartbeat log shows `SQL=False` | Same as above | Do Step 4 |
| `ERROR querying headers` | SQL Server not reachable | Check the SQL service, instance name, and database |
| `ERROR posting data` / timeout | Can't reach the API | Re-run the Step 2 network checks |
| `no rows — skipping POST` | That day had no transactions | Try a date you know has sales |
| Sync runs but 0 rows | Wrong database or table names | Re-check Brand / Database; for Conti's confirm Company/ExtGuid |
| `Unauthorized` (401) | Wrong API key | Confirm the key from Arshath |
| Store not on Agent Fleet | Heartbeat task not running, or SYSTEM can't reach the API | `Get-ScheduledTask "CXS Agent Heartbeat - <StoreCode>"` -> `Start-ScheduledTask`; read `C:\CXS\logs\agent-<StoreCode>.log` for the real error |

## Notes
- Copy files to `C:\Temp\store-agent`, never into `C:\CXS`.
- Logs: daily sync `C:\CXS\logs\sync-<StoreCode>.log`, heartbeat `C:\CXS\logs\agent-<StoreCode>.log`.
  Send the relevant file to Arshath when troubleshooting.
