# New Store Install (store that never had an agent)

Use this when a store has **no agent at all** - nothing in `C:\CXS`, no
`cxs-agent.json`, never been set up before. (If the store already has an older
v1 agent, use `store-agent-v1-to-v2-upgrade.md` instead.)

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
Always copy to `C:\Temp\store-agent`, **NOT** into `C:\CXS`.

## Step 2 - Quick checks before installing

**SQL reachable** (use this store's server/database):
```powershell
$server = "WFTISERVER"; $database = "WFTIDB"
$cs = "Server=$server;Database=$database;Integrated Security=True;TrustServerCertificate=True;Connection Timeout=10;"
$c = New-Object System.Data.SqlClient.SqlConnection($cs); $c.Open(); "SQL OK"; $c.Close()
```

**Internet / API reachable:**
```powershell
Test-NetConnection 888.insourcedata.org -Port 443
curl.exe -k https://888.insourcedata.org/api/collect/health -H "Authorization: Bearer <API KEY>"
```
Want `TcpTestSucceeded : True` and `{"status":"ok"}`.

If you get a FortiGuard "Access Blocked" page, the firewall is blocking us -
ask the network team to whitelist `*.insourcedata.org`. If you get a certificate
`PartialChain` error, add `-AllowSelfSignedCert` to the install command in Step 3.
(Both are explained in `poc-store-agent-setup.md`, Step 8 / Known Issues.)

## Step 3 - Install (fill in this store's details)

Below is DK003 as the example. Change the values for the store you're on.
The API key is from Arshath.

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

**Conti's:** use `-Brand "contis"` and drop `-OracleCode`:
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

The installer copies the scripts into `C:\CXS`, writes the config, and creates
both scheduled tasks. It should end with `=== Installation Complete ===` and no
`[FAIL]` lines.

> Add `-SyncTime "3:30AM"` to override the default sync time (Wendy's 05:00,
> Conti's 02:00). Add `-AllowSelfSignedCert` only if Step 2 showed a certificate
> `PartialChain` error.

## Step 4 - Let SYSTEM into SQL Server (one-time, important)

The scheduled tasks run as `NT AUTHORITY\SYSTEM`, not your login. Even though
Step 2 worked for you, the nightly task will fail with
`Login failed for user 'NT AUTHORITY\SYSTEM'` unless you grant it read access.

Do **Step 12** in `poc-store-agent-setup.md` (grant `db_datareader` to SYSTEM, or
to the agent machine's computer account if SQL is on a different box). Skip this
and the agent looks fine today but stops syncing tomorrow.

## Step 5 - Check it worked

```powershell
$sc = (Get-Content C:\CXS\config\cxs-agent.json -Raw | ConvertFrom-Json).StoreCode
Get-ScheduledTask -TaskName "CXS Daily Sync - $sc","CXS Agent Heartbeat - $sc" | Select-Object TaskName, State
Start-Sleep 12
Get-Content C:\CXS\logs\agent.log -Tail 8
```

You want to see:
- Daily Sync task = **Ready**, Heartbeat task = **Running**
- A log line like `Heartbeat sent. SQL=True ...`
- The store shows up on the dashboard: **Admin -> Agent Fleet** (within ~5 min)

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

## Notes
- Copy files to `C:\Temp\store-agent`, never into `C:\CXS` (running from inside
  `C:\CXS` makes it copy files onto themselves).
- For full detail on any step - prerequisites, FortiGate, certificates, the
  SYSTEM/SQL grant, troubleshooting - see `poc-store-agent-setup.md`.
