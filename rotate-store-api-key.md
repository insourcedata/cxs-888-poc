# Update a Store's Collector Key (key rotation)

Use this when insourcedata sends you a **new collector key for a store**. We are
moving each store onto its **own** key instead of the old shared one (more
secure - a leaked key can no longer affect every store).

We do the hard parts (generating the keys and switching the server over). You do
one small thing per store: put the new key on the store server and restart the
agent.

**There is no downtime.** The old key keeps working until we flip the switch on
our side, so you can do these whenever convenient - just tell us when each store
is done.

Do every step on the store server, in **PowerShell as Administrator**.

---

## What you need from us (per store)

- The **StoreCode** (e.g. `DK003`, `NOCSST`).
- The **new key** for that store (a long random string).

If you don't have both, stop and ask us before doing anything.

---

## Step 1 - Open that store's config file

The config is one of these two files - use whichever one **exists** on the box:

- `C:\CXS\config\cxs-agent-<STORECODE>.json`   (newer, per-store)
- `C:\CXS\config\cxs-agent.json`                (older, single store)

Open it in Notepad (replace `<STORECODE>`):

```powershell
notepad C:\CXS\config\cxs-agent-<STORECODE>.json
```

## Step 2 - Replace the key

Find the line that looks like:

```
"ApiKey":  "old-key-goes-here",
```

Replace **only** the text inside the quotes with the new key we sent you. Keep
the quotes and the comma. Make sure there are **no extra spaces**. Save and close.

**Do NOT change anything else in the file.**

## Step 3 - Restart the agent

The agent only reads the key when it **starts up**, so it has to be restarted for
the new key to take effect. Run (replace `<STORECODE>`):

```powershell
Stop-ScheduledTask  -TaskName "CXS Agent Heartbeat - <STORECODE>"
Start-ScheduledTask -TaskName "CXS Agent Heartbeat - <STORECODE>"
```

You do **not** need to restart anything else. The nightly data sync picks up the
new key on its own.

## Step 4 - Confirm

Within a few minutes, check the dashboard: the store should still show as
**online / heartbeating**. Then tell us "**<StoreCode> done**".

---

## If a server runs more than one store

Repeat **all** steps for each store, using that store's own StoreCode and its own
key. Each store is independent - one config file and one heartbeat task per store.

---

## If something looks wrong

- The store shows **offline**, or you see **401 / Unauthorized**: the key was
  almost certainly mistyped or has a stray space. Re-open the config file,
  carefully re-paste the key exactly as we sent it, save, and run the Stop/Start
  commands in Step 3 again.
- Still stuck: send us a screenshot of the config file (you can black out the key)
  and the dashboard, and we will help. Do not keep retrying changes.

**Do NOT:**

- touch any **other** store's config,
- change any field **other than** `ApiKey`,
- delete or rename any files.
