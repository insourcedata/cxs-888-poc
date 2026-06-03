# Store Agent v1 to v2 Upgrade Runbook

*Audience: Wendy's IT, Conti's IT. Last updated: May 2026.*

This guide walks an IT operator through upgrading an existing v1 CXS
store agent to v2. The v2 agent adds a persistent heartbeat process
and remote command execution on top of the existing nightly sync.

**What v2 adds (on top of v1):**
- A heartbeat agent (`cxs-agent.ps1`) that sends health/status every
  5 minutes so the central dashboard shows the store as Online.
- Remote command execution: the CXS admin team can issue diagnostic
  commands (test connectivity, pull logs, trigger re-sync, etc.)
  from the central dashboard without needing RDP access.
- A per-store config file that both the heartbeat and the daily sync
  read (`C:\CXS\config\cxs-agent-<StoreCode>.json` as of this release -
  see "What's new" below). One server can now host multiple stores.

**What does NOT change:**
- The nightly sync behavior is unchanged. The collector script
  (`cxs-collector-<StoreCode>.ps1`) still runs on its existing
  schedule and pushes the same payload.
- Transaction data filing, database queries, and log locations are
  unaffected.
- The daily sync task timing is preserved by the updater ("Does not
  touch scheduled task timing").

---

## What's new in this update (multi-store support)

This release lets **one server host more than one store** cleanly. Before, every
store on a box shared a single `cxs-agent.json`, so the last store installed
"won" and the others reported under the wrong identity. Now each store gets:

- its own config file: **`C:\CXS\config\cxs-agent-<StoreCode>.json`**
- its own launcher: `C:\CXS\cxs-agent-<StoreCode>.ps1` (a tiny generated file the
  heartbeat task runs; it points the shared agent at that store's config)
- its own logs: `C:\CXS\logs\agent-<StoreCode>.log` and `sync-<StoreCode>.log`

> **Read this:** wherever the rest of this guide says `cxs-agent.json`, on this
> release it is **`cxs-agent-<StoreCode>.json`** (one per store). The migration
> steps below are otherwise identical - the updater produces the per-store files
> for you automatically.

**Single-store servers:** nothing changes for you except the filename now carries
the store code. Just run the updater (Section 3) as normal.

**Servers that will host a second store:** first run the updater on the existing
store (Section 3), then install the additional store with
`install-cxs-collector.ps1` exactly as in **`new-store-install.md`**, using that
store's own StoreCode / SqlServer / Database. The two stores are fully
independent.

The old shared `C:\CXS\config\cxs-agent.json` is intentionally left in place
(harmless) so the previous setup keeps working during the change.

---

## 1. Pre-flight: identify your current install type

Before upgrading, determine which v1 install variant is on the store
machine. Open an elevated PowerShell and Task Scheduler and check:

| Check | Legacy single-file (v1a) | Per-store (v1b) |
|---|---|---|
| Collector script | `C:\CXS\cxs-collector.ps1` (no store code in filename) | `C:\CXS\cxs-collector-<StoreCode>.ps1` |
| Scheduled task name | `CXS Daily Sync` (no suffix) | `CXS Daily Sync - <StoreCode>` |
| Heartbeat task | None | None |
| `cxs-agent.json` | Does not exist | Does not exist |

```powershell
# Quick check from PowerShell:
Test-Path "C:\CXS\cxs-collector.ps1"       # True => legacy single-file
Get-ChildItem "C:\CXS\cxs-collector-*.ps1"  # Any results => per-store
schtasks /Query /TN "CXS Daily Sync" 2>$null
schtasks /Query /TN "CXS Daily Sync - <StoreCode>" 2>$null
```

This determines whether you need the `-Migrate` flag in step 3.

### Prerequisites

- **Windows Server 2016+ or Windows 10+** with PowerShell 5.1+.
- **Local administrator rights** (the updater registers a scheduled
  task running as SYSTEM).
- **Outbound HTTPS** to `https://888.insourcedata.org` (same as v1).
- **Backup** your existing config by noting the values baked into your
  current collector script (ApiUrl, ApiKey, SqlServer, Database,
  StoreCode, Brand, Company, etc.). The updater extracts these
  automatically, but having them on hand is good practice:
  ```powershell
  # Read from the installed script:
  Select-String -Path "C:\CXS\cxs-collector*.ps1" -Pattern '(ApiUrl|ApiKey|SqlServer|Database|StoreCode|Brand|Company|ExtGuid)\s*='
  ```

---

## 2. Pull the updated files onto the store box

### 2a. Download the files from the repo (the safe way)

Download the `cxs-888-poc` repo as a ZIP - do **not** copy/paste the
script text into Notepad/Word/email. Pasting re-encodes the files and
breaks them ("Unexpected token" errors when you run them). A ZIP download
keeps every file exact.

1. On GitHub, open the `cxs-888-poc` repo.
2. Click the green **Code** button -> **Download ZIP**.
3. Unzip it. Inside is a folder called **`files-to-copy`** - that holds
   all the scripts you need.

### 2b. Put the files on the store machine (in a temp folder, NOT C:\CXS)

Copy the whole **`files-to-copy`** folder onto the store machine as
**`C:\Temp\store-agent`** (so you have
`C:\Temp\store-agent\update-cxs-collector.ps1`, etc.).

> **Do NOT copy the files into `C:\CXS`.** Running the updater from inside
> `C:\CXS` makes it copy files onto themselves and throws errors. Always
> run it from a separate folder like `C:\Temp\store-agent`; it writes what
> it needs into `C:\CXS` for you.

The folder must contain all of these (the updater needs them together):

| File / folder | Purpose |
|---|---|
| `update-cxs-collector.ps1` | The updater script you will run |
| `cxs-collector.ps1` | New collector template (updater injects config into this) |
| `cxs-agent.ps1` | Heartbeat agent (copied to `C:\CXS\`) |
| `commands\*.ps1` | 7 remote command handlers (copied to `C:\CXS\commands\`) |

> **Important:** Do not copy only the updater. It exits with an error
> if `cxs-collector.ps1` is missing from the same directory, and the
> heartbeat agent and command handlers will not be deployed.

### 2c. Do NOT delete or change the old files in C:\CXS

> **This is the step that has broken stores.** Leave everything already in
> `C:\CXS` exactly as it is. The updater **reads your existing API key and
> config out of the old `C:\CXS\cxs-collector*.ps1`** to carry it into v2.
> If you delete or overwrite those old files first, the API key and store
> settings are gone and the agent cannot be configured.
>
> The updater removes and renames the old files **itself** as part of the
> migration. Your only job is to put the new files in `C:\Temp\store-agent`
> and run the updater - it handles the rest.

---

## 3. Run the updater

Open an **elevated** PowerShell prompt (Run as Administrator), then
`cd` to the folder where you placed the files and allow scripts to run
for this session:

```powershell
cd C:\Temp\store-agent
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
```

(`-Scope Process` only affects this PowerShell window and reverts when you
close it - nothing permanent changes on the box. Without it you may get a
"not digitally signed" error.)

**If you have a legacy single-file install (v1a):**

```powershell
.\update-cxs-collector.ps1 -Migrate
```

The `-Migrate` flag:
- Renames `C:\CXS\cxs-collector.ps1` to
  `C:\CXS\cxs-collector-<StoreCode>.ps1`.
- Renames the scheduled task from `CXS Daily Sync` to
  `CXS Daily Sync - <StoreCode>` (preserving trigger settings).
- Removes the legacy single-file `cxs-collector.ps1`.

**If you already have a per-store install (v1b):**

```powershell
.\update-cxs-collector.ps1
```

No `-Migrate` needed. The updater performs an in-place update of the
existing per-store script.

### What the updater does automatically

Regardless of `-Migrate`, the updater now performs these v2 steps:

1. **Extracts config** from the installed `cxs-collector-<StoreCode>.ps1`
   (keys: `ApiUrl`, `ApiKey`, `SqlServer`, `Database`, `Brand`,
   `Company`, `StoreCode`).
2. **Writes `C:\CXS\config\cxs-agent.json`** with the extracted values.
3. **Copies `cxs-agent.ps1`** to `C:\CXS\`.
4. **Copies command handlers** (`commands\*.ps1`) to `C:\CXS\commands\`.
5. **Registers and starts** a scheduled task named
   `CXS Agent Heartbeat - <StoreCode>` (`/SC ONSTART /RU SYSTEM`).
   If the task already exists, it is stopped, removed, and re-created.
6. **Removes the legacy fleet-wide `CXS Daily Sync` task** (the bare
   task with no store-code suffix) if it exists and a per-store
   `CXS Daily Sync - <StoreCode>` replacement is registered. This
   prevents duplicate nightly payloads.

---

## 4. Verify `cxs-agent.json`

After the updater finishes, confirm the generated config file contains
the correct values:

```powershell
Get-Content "C:\CXS\config\cxs-agent.json"
```

Expected keys:

```json
{
  "ApiUrl": "https://888.insourcedata.org/api/collect",
  "ApiKey": "<your store API key>",
  "Brand": "wendys",
  "StoreCode": "DK003",
  "SqlServer": "localhost",
  "Database": "NEWPOS",
  "Company": "WENDYS PH"
}
```

> **Critical: verify `Brand` is present and correct.** If your v1
> collector was installed before 2026-05-26, it may not have had a
> `Brand` value baked in. In that case the generated json will be
> missing `Brand`, and the heartbeat agent will **refuse to start**
> with the error:
> `ERROR: Brand is missing. Set it to one of: wendys, contis`.
>
> If `Brand` is missing, edit the file manually:
> ```powershell
> # Open in notepad:
> notepad C:\CXS\config\cxs-agent.json
> # Add "Brand": "wendys" (or "contis") and save.
> # Then restart the heartbeat task:
> Start-ScheduledTask -TaskName "CXS Agent Heartbeat - <StoreCode>"
> ```

---

## 5. Verify the upgrade

### 5a. Heartbeat task is running

Open Task Scheduler and confirm:

- `CXS Agent Heartbeat - <StoreCode>` exists with trigger **At startup**
  and status **Running**.
- `CXS Daily Sync - <StoreCode>` exists with its original daily
  trigger (time unchanged).
- The bare `CXS Daily Sync` task (no suffix) is **gone**.

The updater calls `Start-ScheduledTask` immediately after registering
the heartbeat task, so it starts without a reboot despite the
`AtStartup` trigger.

### 5b. Store shows Online in the dashboard

Within 5 minutes of the heartbeat starting, the store should appear as
**Online** (green) in the Agent Fleet view at `/admin/fleet`.

If the store does not appear:
- Check `C:\CXS\logs\agent.log` for errors.
- Confirm outbound HTTPS to `https://888.insourcedata.org` is open.
- Verify `cxs-agent.json` has a valid `ApiKey` (at least 16
  characters).

### 5c. Issue a test command

Ask your CXS admin contact to send a `test-connectivity` command from
the fleet dashboard (`/admin/fleet/<agentId>` > Commands panel). The
result should show:

- **SQL: connected** with a latency value.
- **Collector: reachable** with an HTTP status code.

This confirms end-to-end: heartbeat reaching the server, server
queuing a command, agent executing it, and result posted back.

### 5d. Confirm nightly sync is unaffected

The daily sync task timing is **not changed** by the updater. Verify
by checking the task's next-run time in Task Scheduler. If you want
to do a manual test sync:

```powershell
cd C:\CXS
.\cxs-collector-<StoreCode>.ps1
```

---

## 6. Rollback to v1

If you need to revert to v1 (heartbeat-only removal -- the daily sync
is not affected):

```powershell
# 1. Stop and remove the heartbeat task
Stop-ScheduledTask -TaskName "CXS Agent Heartbeat - <StoreCode>" -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName "CXS Agent Heartbeat - <StoreCode>" -Confirm:$false

# 2. Remove v2-only files
Remove-Item "C:\CXS\cxs-agent.ps1" -Force
Remove-Item "C:\CXS\commands" -Recurse -Force
Remove-Item "C:\CXS\config\cxs-agent.json" -Force
```

The daily sync continues to work exactly as before via
`CXS Daily Sync - <StoreCode>`.

> **Note:** If you used `-Migrate`, the per-store task rename
> (`CXS Daily Sync` to `CXS Daily Sync - <StoreCode>`) and the
> per-store script rename (`cxs-collector.ps1` to
> `cxs-collector-<StoreCode>.ps1`) are **not** reverted. This is
> functionally equivalent to the v1 sync behavior -- the only
> difference is the naming convention. There is no need to revert it.

---

## Quick reference

| Item | Path / name |
|---|---|
| Updater script | `update-cxs-collector.ps1` (run from source folder) |
| Agent config | `C:\CXS\config\cxs-agent.json` |
| Heartbeat agent | `C:\CXS\cxs-agent.ps1` |
| Command handlers | `C:\CXS\commands\*.ps1` |
| Heartbeat log | `C:\CXS\logs\agent.log` |
| Sync log | `C:\CXS\logs\sync-<StoreCode>.log` |
| Heartbeat task | `CXS Agent Heartbeat - <StoreCode>` (at startup, SYSTEM) |
| Daily sync task | `CXS Daily Sync - <StoreCode>` (daily, unchanged) |
| Fleet dashboard | `/admin/fleet` |
