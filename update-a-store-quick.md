# Quick: Update a Store That Is Already Running

For a store that is **already Online** on the dashboard (it already has the
agent). This brings its agent up to the **latest version (v2.1)** — so the CXS
team can both **rotate that store's key** and **re-sync / correct its history**
from the dashboard. **No downtime, safe to run anytime.**

- Brand-new machine instead (nothing in `C:\CXS` yet)? Use **`new-store-install.md`**.
- Hit a snag, or it's a very old single-file install? Use the full guide
  **`store-agent-v1-to-v2-upgrade.md`**.

Do everything on the store server, in **PowerShell as Administrator**.

## 1. Get the files (never copy/paste the script text)

1. On GitHub, open the **cxs-888-poc** page -> green **Code** button -> **Download ZIP**.
2. Unzip it. Inside is a folder called **`files-to-copy`**.
3. Copy that whole **`files-to-copy`** folder to **`C:\Temp\store-agent`** (NOT into `C:\CXS`).

Copying the whole folder keeps the scripts exact. Pasting text into Notepad or
email corrupts them.

## 2. Run the updater

```powershell
cd C:\Temp\store-agent
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
.\update-cxs-collector.ps1
```

Wait for it to finish with no red **[FAIL]** lines.

## 3. Check it worked

```powershell
Test-Path C:\CXS\commands\rotate-key.ps1
Get-ScheduledTask -TaskName "CXS Agent Heartbeat*" | Select-Object TaskName, State
```

You want **`True`** (the new command is installed) and the heartbeat task
**Running**.

That's it. Tell the CXS team the store is updated - they do the key switch from
the dashboard, and you do **not** need to touch the box again for that.

> **Safe to re-run anytime.** The updater keeps the store's current key, so
> re-running it later (e.g. for a future update) will not undo a key the CXS team
> has issued. To deliberately set a brand-new key, the CXS team rotates it from
> the dashboard.
