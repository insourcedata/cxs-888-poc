# Fix a store agent (start here)

Use this when a store has no `C:\CXS\config\cxs-agent.json` or the scripts
won't run. Do the steps in order on the store server (PowerShell as Admin).

The scripts in `files-to-copy/` are now plain text and won't get scrambled
when copied. **Copy the whole folder** onto the server (drag the folder in
RDP) - do NOT paste file contents one at a time.

---

## Step 1 - Get the clean files onto the server

1. Download the repo from GitHub: green **Code** button -> **Download ZIP**.
   (Downloading keeps the files exact - this is the safe way.)
2. Unzip it. Inside is a folder called **`files-to-copy`**.
3. On the store server, copy that whole **`files-to-copy`** folder to
   **`C:\Temp\store-agent`** (so you have
   `C:\Temp\store-agent\install-cxs-collector.ps1`, etc.).

Do NOT open the scripts in Word/Notepad to copy them - just copy the folder.

## Step 2 - Install (fill in this store's details)

Below is DK003 as the example. Change the values for other stores.
The API key is this store's own key (from Arshath).

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force

C:\Temp\store-agent\install-cxs-collector.ps1 `
    -Brand      "wendys" `
    -ApiUrl     "https://888.insourcedata.org/api/collect" `
    -ApiKey     "<THIS STORE'S API KEY>" `
    -SqlServer  "WFTISERVER" `
    -Database   "WFTIDB" `
    -StoreCode  "DK003" `
    -OracleCode "4058"
```

For a Conti's store: use `-Brand "contis"` and drop `-OracleCode`.

It should end with `=== Installation Complete ===`.

## Step 3 - Check it worked

The installer names files per-store (`cxs-agent-<StoreCode>.json`,
`agent-<StoreCode>.log`). This block reads them automatically - nothing to edit,
works for one store or several on the box:

```powershell
Get-ChildItem C:\CXS\config\cxs-agent-*.json | ForEach-Object {
    $sc = ($_.Name -replace '^cxs-agent-(.+)\.json$','$1')
    Write-Host "`n=== $sc ===" -ForegroundColor Cyan
    Get-ScheduledTask -TaskName "CXS Daily Sync - $sc","CXS Agent Heartbeat - $sc" `
        -ErrorAction SilentlyContinue | Select-Object TaskName, State | Format-Table -Auto
    Start-ScheduledTask -TaskName "CXS Agent Heartbeat - $sc" -ErrorAction SilentlyContinue
    $log = "C:\CXS\logs\agent-$sc.log"
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline) {
        if ((Test-Path $log) -and (Select-String $log -Pattern 'Heartbeat (sent|failed)' -Quiet)) { break }
        Start-Sleep 5
    }
    if (Test-Path $log) { Get-Content $log -Tail 20 }
    else { Write-Host "No log yet at $log - heartbeat task may not be running" -ForegroundColor Yellow }
}
```

You want to see, for each store:
- Daily Sync task = **Ready**, Heartbeat task = **Running**
- A line in the log like `Heartbeat sent. SQL=True ...`
- The store shows up on the dashboard: **Admin -> Agent Fleet**

If the log says `SQL=False`, SQL Server isn't letting the agent in - see
Step 12 in `poc-store-agent-setup.md`.

---

## Store details (fill in as you go)

| Store | Brand | SqlServer | Database | StoreCode | OracleCode |
|-------|-------|-----------|----------|-----------|------------|
| FTI / DK003 | wendys | WFTISERVER | WFTIDB | DK003 | 4058 |
|       |       |           |          |           |            |

## Notes
- Always copy the files to `C:\Temp\store-agent`, NOT into `C:\CXS`.
  (Running from inside `C:\CXS` makes it copy files onto themselves.)
- After fixing a store whose key was shown on screen, rotate that key.
