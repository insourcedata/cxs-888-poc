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
- **Certificate `PartialChain` error** -> the server is missing the collector's
  root CA in the **machine** certificate store. The installer now imports it
  automatically (Google Trust Services `GTS Root R4` into `LocalMachine\Root`), so
  this should self-resolve at Step 3. It matters because the heartbeat agent runs
  as `SYSTEM` and validates the certificate - if the import is skipped the install
  still looks fine but the agent silently never reports. `curl.exe -k` only skips
  the check for this manual test, not for the agent. Last-resort stopgap only:
  add `-AllowSelfSignedCert` to Step 3 (disables TLS validation - exposes the API
  key, use only if the CA import failed).

## Step 3 - Run the installer (fill in this store's details)

Below is DK003 as the example. Change the values for the store you're on.
The API key is from Arshath. The installer copies the scripts into `C:\CXS`,
writes the config, and creates both scheduled tasks in one go.

> **Execution policy / GPO note:** the commands set a Process-scope bypass
> (`Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force`) - it lasts
> only for this window and the installer's scheduled tasks carry their own
> `-ExecutionPolicy Bypass`. If scripts still won't run (`...running scripts is
> disabled on this system`), a Group Policy is enforcing a stricter policy at
> **MachinePolicy** scope, which a command-line bypass cannot override - run
> `Get-ExecutionPolicy -List` and ask the domain admin to relax it (e.g.
> `RemoteSigned`) for these store servers.

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

**Conti's:** use `-Brand "contis"` and drop `-OracleCode` (Conti's uses
NAV-format tables and a 02:00 sync time):
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

> **You no longer pass `-Company`.** The installer auto-discovers the LS Central
> company prefix straight from the store's own database (it probes `sys.tables`
> for the `Transaction Header` object) and prints e.g.
> `[AUTO] Detected company 'XXX' (NAV format) in <DB>`. This handles the fact that
> the franchises differ - NOC stores resolve to `NOC`, the **ACC franchise**
> (ACCAMF/ACCBBR/ACCVLS/ACCAMM) to its own company - so a wrong default can no
> longer ship a silently-failing "dark sync". It then verifies the real tables
> resolve before scheduling, aborting with a clear message if they don't.

Optional flags:
- `-SqlServer "localhost"` if SQL Server runs on this same box (you can also just
  omit `-SqlServer` for the Wendy's default).
- `-SyncTime "3:30AM"` to override the default sync time (Wendy's 05:00, Conti's 02:00).
- `-Company "<prefix>"` / `-ExtGuid "<guid>"` **only to override auto-discovery** -
  needed when one database hosts multiple companies (the installer lists the
  choices and aborts so you can pick) or when discovery can't reach SQL. See
  [Finding `-Company` and `-ExtGuid` manually](#finding--company-and--extguid-manually) below.
- `-AllowSelfSignedCert` only if Step 2 showed a certificate `PartialChain` error.

### Finding `-Company` and `-ExtGuid` manually

You only need this when the installer **aborts** instead of auto-detecting - either
`[FAIL] ... multiple company prefixes` (the database holds more than one company,
e.g. a live `WENDYS PH` plus a leftover `WENDYS_UAT...`) or `[FAIL] Could not verify
this store's transaction tables`. The values live in the store's own database; pick
them, then re-run the install command with `-Company`/`-ExtGuid` added.

**Anatomy of a table name** - read the two values straight off it:

```
WENDYS PH$LSC Transaction Header$5ecfc871-5d82-43f1-9c54-59685e82318d
└── Company ──┘     └ table ┘    └──────────── ExtGuid ─────────────┘
```

- `-Company` = everything **before** `$LSC` (or before the first `$` for Conti's NAV
  tables, which have no `LSC`/GUID - e.g. `NOC$Transaction Header` -> `-Company "NOC"`).
- `-ExtGuid` = the GUID **after** `Transaction Header$` (Conti's NAV = `-ExtGuid ""`).

**Ignore these decoys** - they also contain "Transaction Header" but are not the data table:
- `...$LSC Arch Transaction Header$...` - the archive table.
- `...$LSC Transaction Header$<guid>$ext` - a Business Central extension companion (has
  the `$ext` suffix; holds only extra fields, no sales rows).
- a UAT/test company (e.g. `WENDYS_UAT01312022`) - use the **production** company.

#### Option A - SSMS (recommended)

Open a New Query window **on the store's database** and run this. It lists every
matching table with its row count (no table scan), so the live one is obvious:

```sql
USE <Database>;   -- e.g. WSMAXDB1
SELECT t.name AS table_name, SUM(p.rows) AS row_count
FROM sys.tables t
JOIN sys.partitions p ON p.object_id = t.object_id AND p.index_id IN (0,1)
WHERE t.name LIKE '%Transaction Header%'
GROUP BY t.name
ORDER BY row_count DESC;
```

The right table is the one with the **highest row count** that starts with
`<Company>$LSC Transaction Header$<guid>` (not `Arch`, not `$ext`, not the UAT company).

#### Option B - PowerShell (no SSMS on the box)

Paste each line separately (keep the connection string on one line):

```powershell
$c = New-Object System.Data.SqlClient.SqlConnection("Server=<SqlServer>;Database=<Database>;Trusted_Connection=True;TrustServerCertificate=True;")
$c.Open()
$cmd = $c.CreateCommand()
$cmd.CommandText = "SELECT t.name, SUM(p.rows) rows FROM sys.tables t JOIN sys.partitions p ON p.object_id=t.object_id AND p.index_id IN (0,1) WHERE t.name LIKE '%Transaction Header%' GROUP BY t.name ORDER BY rows DESC"
$r = $cmd.ExecuteReader()
while ($r.Read()) { "{0}  rows={1}" -f $r['name'], $r['rows'] }
$c.Close()
```

#### Then re-run the install

Add the two values to the Step 3 command, e.g.:

```powershell
... -StoreCode "S014" -OracleCode "4007" `
    -Company "WENDYS PH" -ExtGuid "5ecfc871-5d82-43f1-9c54-59685e82318d"
```

Passing them explicitly **skips auto-discovery entirely**; the installer verifies that
exact table resolves, then schedules the tasks.

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

## Step 6 - First sync + loading history

**Confirm data flows (quick check).** Run the store's daily sync once - it pulls
**yesterday** and adds it (no special permission needed):
```powershell
C:\CXS\cxs-collector-DK003.ps1
```
Want `POST ok: accepted` (or `no rows — skipping POST` if yesterday had no sales).
Then check **Admin -> Store Syncs** on the dashboard - the store shows `status: ok`.

**Load history / fix a day - from the dashboard, not the box.** To pull a date
range (initial history, or to re-pull days that look wrong), the CXS team issues a
**Re-sync** from **Admin -> Agent Fleet -> [this store]** with the start/end dates.
The agent pulls those days on its next check-in and the dashboard **replaces** each
day with the fresh copy (so it's safe to re-issue). Do long ranges about a month at
a time.

> A date-range pull run directly on the box (`cxs-collector-<store>.ps1 -StartDate
> ... -EndDate ...`) is now **rejected** by the server unless a matching dashboard
> Re-sync authorized it - this stops a store from wiping its own history by
> accident. Always start backfills from the dashboard. See
> **`how-to-fix-a-stores-old-numbers.md`**.

The agent can only return what the store's POS still keeps - if older dates come
back empty (or a day shows `failed` with "no rows"), that data isn't on the POS
anymore.

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
| `PartialChain` certificate error | Box missing the collector root CA in the **machine** store; the SYSTEM agent validates certs | Installer auto-imports `GTS Root R4` into `LocalMachine\Root`; if it failed, re-run install/update. `curl.exe -k` only bypasses manual tests, not the agent. Stopgap: `-AllowSelfSignedCert` |
| `Login failed for user 'NT AUTHORITY\SYSTEM'` | SYSTEM has no SQL access | Do Step 4 |
| Heartbeat log shows `SQL=False` | Same as above | Do Step 4 |
| `ERROR querying headers` | SQL Server not reachable | Check the SQL service, instance name, and database |
| `ERROR posting data` / timeout | Can't reach the API | Re-run the Step 2 network checks |
| `no rows — skipping POST` | That day had no transactions | Try a date you know has sales |
| Install aborts: `multiple company prefixes` / `Could not verify ... transaction tables` | DB hosts >1 company (live + UAT), or discovery couldn't match the table | [Find `-Company`/`-ExtGuid` manually](#finding--company-and--extguid-manually) and re-run with them |
| Sync runs but 0 rows | Wrong database or table names | Re-check Brand / Database; for Conti's confirm Company/ExtGuid |
| `Unauthorized` (401) | Wrong API key | Confirm the key from Arshath |
| Store not on Agent Fleet | Heartbeat task not running, or SYSTEM can't reach the API | `Get-ScheduledTask "CXS Agent Heartbeat - <StoreCode>"` -> `Start-ScheduledTask`; read `C:\CXS\logs\agent-<StoreCode>.log` for the real error |
| `[WARN] Heartbeat ExecutionTimeLimit = 'PT72H'` at install | Task Scheduler kept its default 3-day limit (the zero TimeSpan didn't persist on this box); the agent gets force-stopped after ~72h uptime and stays dark until reboot | Installer now auto-repairs it via XML re-register. If it still warns, apply the manual fix below |

### Heartbeat 72-hour force-stop (ExecutionTimeLimit)

The heartbeat agent runs forever, so its task must have **no execution time limit**
(`PT0S`). On some boxes Task Scheduler keeps its default `PT72H` (3 days) and
force-stops the agent — the store goes dark until the next reboot. The installer
detects this and self-heals; if you ever need to fix it by hand, set `$tn` to the
store's heartbeat task and run:

```powershell
$tn  = "CXS Agent Heartbeat - <StoreCode>"
$xml = Export-ScheduledTask -TaskName $tn
$xml = $xml -replace '<ExecutionTimeLimit>[^<]*</ExecutionTimeLimit>','<ExecutionTimeLimit>PT0S</ExecutionTimeLimit>'
Register-ScheduledTask -TaskName $tn -Xml $xml -User "NT AUTHORITY\SYSTEM" -Force | Out-Null

(Get-ScheduledTask -TaskName $tn).Settings.ExecutionTimeLimit   # must print PT0S

Stop-ScheduledTask  -TaskName $tn      # restart so the running instance picks it up
Start-ScheduledTask -TaskName $tn
```

**GUI alternative:** Task Scheduler -> `CXS Agent Heartbeat - <StoreCode>` ->
Properties -> **Settings** tab -> uncheck **"Stop the task if it runs longer than"** -> OK.

## Notes
- Copy files to `C:\Temp\store-agent`, never into `C:\CXS`.
- Logs: daily sync `C:\CXS\logs\sync-<StoreCode>.log`, heartbeat `C:\CXS\logs\agent-<StoreCode>.log`.
  Send the relevant file to Arshath when troubleshooting.
