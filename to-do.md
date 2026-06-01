# Recovery B — re-provision a store whose config was wiped

Use this when `C:\CXS\config\cxs-agent.json` is missing AND the collector
scripts only have empty placeholders (no API key / StoreCode survived) —
i.e. the box was reset by copying fresh files over the old ones and deleting
the configured originals. The store has lost its identity + API key and must
be re-provisioned with the **installer** (the `-Migrate` updater can't help —
it only carries forward config from an already-configured install).

Run on the store server (PowerShell as Administrator).

## 1. Stage the bundle outside C:\CXS

Running the installer from inside `C:\CXS` makes it copy files onto themselves
("cannot overwrite with itself"). Stage it in a separate folder first.

```powershell
New-Item -ItemType Directory C:\Temp\store-agent -Force | Out-Null
Copy-Item C:\CXS\cxs-collector.ps1,C:\CXS\cxs-agent.ps1,C:\CXS\install-cxs-collector.ps1 C:\Temp\store-agent
Copy-Item C:\CXS\commands C:\Temp\store-agent -Recurse -Force
```

## 2. Re-install with this store's real values

The **API key is this store's per-store key** (from Arshath's records).
Fill in every `<...>` placeholder. Drop `-OracleCode` for Conti's stores.

```powershell
powershell -ExecutionPolicy Bypass -File "C:\Temp\store-agent\install-cxs-collector.ps1" `
    -Brand      "wendys" `
    -ApiUrl     "https://888.insourcedata.org/api/collect" `
    -ApiKey     "<THIS STORE'S API KEY>" `
    -SqlServer  "localhost" `
    -Database   "<DB e.g. WSMOD8 / NEWPOS / NOCSSTDB>" `
    -StoreCode  "<e.g. DK003>" `
    -OracleCode "<e.g. 4058>"
```

The installer writes `config\cxs-agent.json`, creates `cxs-collector-<Store>.ps1`
plus both scheduled tasks (`CXS Daily Sync - <Store>`, `CXS Agent Heartbeat - <Store>`),
removes any legacy bare task, and starts the heartbeat.

## 3. Verify

```powershell
$cfg = Get-Content C:\CXS\config\cxs-agent.json -Raw | ConvertFrom-Json
$sc  = $cfg.StoreCode
Get-ScheduledTask -TaskName "CXS Daily Sync - $sc","CXS Agent Heartbeat - $sc" |
  Select-Object TaskName, State, @{n='RunAs';e={$_.Principal.UserId}}
Start-Sleep 12
Get-Content C:\CXS\logs\agent.log -Tail 10
```

Good:
- `CXS Daily Sync - <Store>` = **Ready**, `CXS Agent Heartbeat - <Store>` = **Running**, both **RunAs SYSTEM**
- `agent.log` shows `CXS Agent starting…` then `Heartbeat sent. SQL=True …`
- Store appears in the dashboard: **Admin → Agent Fleet** (recent heartbeat) and **Admin → Store Syncs**

If `agent.log` shows `SQL=False`, SYSTEM can't reach SQL Server — grant it
`db_datareader` (see Step 12 in `poc-store-agent-setup.md`).

## 4. End-to-end sync test (optional but recommended)

```powershell
powershell -ExecutionPolicy Bypass -File "C:\CXS\cxs-collector-$sc.ps1" -StartDate "2026-05-31" -EndDate "2026-05-31"
```

Expect `POST ok: accepted` and `=== CXS Sync Complete ===`, then confirm the
day's data on **Admin → Store Syncs** in the dashboard.
