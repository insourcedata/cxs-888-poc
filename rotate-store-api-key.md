# Generate and Apply a Store's Collector Key

We are moving each store onto its **own** collector key (more secure - a leaked
key no longer affects every store). For each store you will: **generate a key on
the store server, send it to us, wait for us to activate it, then apply it and
restart the agent.**

**There is no downtime** - the old shared key keeps working until we switch over
on our side. But the order below matters: **do not apply a new key until we
confirm we have loaded it**, or that store gets rejected and shows offline.

Do every step on the store server, in **PowerShell as Administrator**.

> **Important:** Always generate the key with the command in Step 1. Do **not**
> invent your own key, reuse a key, or shorten it - the command makes a strong,
> unique key, and anything else is a security risk.

---

## The order (per store)

1. Generate a key on the box.
2. Send us the StoreCode + key.
3. **Wait** for us to reply "loaded".
4. Put the key in the config.
5. Restart the agent.
6. Confirm online, tell us "done".

Steps 4 and 5 must come **after** step 3.

---

## Step 1 - Generate the key

Run this exactly (it prints one long random key):

```powershell
[Convert]::ToHexString([System.Security.Cryptography.RandomNumberGenerator]::GetBytes(24))
```

Copy the **whole** output (48 characters). That is this store's new key.
Generate a **separate** key for **each** store - never reuse one.

## Step 2 - Send us the key

Send us, for this store, over the secure channel we agreed:

- the **StoreCode** (e.g. `DK003`, `NOCSST`)
- the **key** you just generated

Keep the key handy - you will paste it in Step 4. Do nothing else yet.

## Step 3 - Wait for our "loaded" reply

We add the key to the collector and reply when it is active. **Do not continue
until you get that reply.** If you apply the key before it is loaded, the store is
rejected (401) and goes offline.

## Step 4 - Put the key in the store's config

The config is one of these:

- `C:\CXS\config\cxs-agent-<STORECODE>.json`   (newer, per-store)
- `C:\CXS\config\cxs-agent.json`                (older, single store)

**If only one exists, use it. If BOTH exist** (e.g. after the multi-store
upgrade), **always edit the per-store `cxs-agent-<STORECODE>.json`** - the old
`cxs-agent.json` is left in place but is **no longer read**, so editing it
changes nothing and the store will stay offline after you restart.

Open it (replace `<STORECODE>`):

```powershell
notepad C:\CXS\config\cxs-agent-<STORECODE>.json
```

Find the line `"ApiKey":  "...",` and replace **only** the text inside the quotes
with your key. Keep the quotes and the comma, and make sure there are **no extra
spaces**. Save and close. **Do NOT change anything else.**

## Step 5 - Restart the agent

The agent only reads the key when it **starts up**, so it must be restarted
(replace `<STORECODE>`):

```powershell
Stop-ScheduledTask  -TaskName "CXS Agent Heartbeat - <STORECODE>"
Start-ScheduledTask -TaskName "CXS Agent Heartbeat - <STORECODE>"
```

Nothing else needs restarting - the nightly data sync picks up the new key on its
own.

## Step 6 - Confirm

Within a few minutes the store should still show **online / heartbeating** on the
dashboard. Then tell us "**<StoreCode> done**".

---

## If a server runs more than one store

Repeat **all** steps for each store, using that store's own StoreCode and its own
key. Each store is independent - one config file and one heartbeat task per store.

## If something looks wrong

- **Offline, or 401 / Unauthorized**, right after Step 5: either we have not
  loaded the key yet (go back to Step 3 and wait for our reply), **or** you
  edited the wrong file (if both configs exist, it must be the per-store
  `cxs-agent-<STORECODE>.json`), **or** the key was mistyped or has a stray
  space - re-open the correct config, carefully re-paste the key exactly, save,
  and run the Step 5 commands again.
- Still stuck: send us a screenshot of the config file (black out the key) and the
  dashboard. Do not keep retrying changes.

**Do NOT:**

- invent, shorten, or reuse a key,
- apply a key **before** we confirm it is loaded,
- touch any **other** store's config,
- change any field **other than** `ApiKey`,
- delete or rename any files.
