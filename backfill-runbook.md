# Historical Backfill Runbook

How to re-pull a store's full POS history (1 Jan 2025 → present) into the
dashboard, and how the orchestration works under the hood.

The daily agent only sends *yesterday*. A manual **Re-sync** is capped at **90
days** per command. Backfilling ~18 months therefore needs orchestration: the
span is split into monthly windows that are issued **one at a time**. This is
built into the dashboard — an operator clicks one button.

---

## 1. What it does

- **Where:** dashboard → `/admin/sync/<storeCode>` (e.g. `/admin/sync/ACCGA2`).
- **Button:** **"Backfill all history"** (next to the two quick Re-sync buttons).
- **Effect:** re-pulls POS data from **2025-01-01 → yesterday**, one calendar
  month at a time, and **overwrites** each day it covers (`replace=true`).
- **Idempotent:** safe to re-run; a day is replaced, never duplicated.

No agent change is required — it issues the same `re-sync` command the manual
button already uses, just chunked and sequenced.

---

## 2. How it works

```
operator clicks "Backfill all history"
        │
        ▼
  startBackfill (oRPC)  ── inserts a backfill_jobs row:
        │                   status=running, windows=[18 monthly windows], currentIndex=0
        ▼
  collector 60s sweep  ── advanceBackfillJobs():
        │                   • issues window[currentIndex] as a re-sync command
        │                   • waits for it to "settle"
        │                   • advances to the next window
        ▼
  agent heartbeat picks up the re-sync command → spawns the collector for that month
        │
        ▼
  collector POSTs each day → store_syncs rows land → calendar fills in
```

- **Driver / clock:** the collector service already runs a **60-second sweep**
  (`scripts/poc-extraction/collector/server.ts`). The same tick now also calls
  `advanceBackfillJobs(db)` (`src/lib/backfill/orchestrator.ts`). No new cron.
- **One window at a time:** the next window is issued only after the current one
  settles — two collector runs never overlap at a single store's SQL box.

### Completion detection (no agent change)

A window is considered **settled** when the store goes **quiet** — i.e.
`max(store_syncs.received_at)` for the store stops advancing for `QUIET_MS`
after the window's command was *delivered*. The collector writes a `store_syncs`
row per non-empty day as it works, so "rows still landing" = "still running",
and "quiet" = "done".

- A window with only empty days produces no rows; it settles after
  `ISSUE_GRACE_MS` once the command was delivered.
- A `sync_error` checkin during the window marks it **failed**; its message
  (`Failed on YYYY-MM-DD after N/M days`) gives the resume day.
- If the re-sync command **expires** (agent offline past the 24h TTL), the
  window is re-issued (counts as an attempt).

### Retry / give-up

- Each window retries up to **3 attempts**. On a parsed `sync_error`, the retry
  resumes from the **failed day** (narrows `start` → failed day).
- After 3 attempts the window is marked `failed` and the **job stops**
  (`status=failed`) for a human to look — the progress card shows which window
  and the error.

---

## 3. Running a backfill (operator)

1. Open `/admin/sync/<storeCode>`.
2. Confirm the store's agent is **online** (it must heartbeat to receive the
   monthly commands) and **SQL is ✓** (it must be able to read the POS DB).
3. Click **"Backfill all history"** → confirm the dialog.
4. A **progress card** appears: `done / total months`, a bar, the current
   window, and a **Cancel** button. It polls every 15 s while running.
5. Watch the **heat-grid** below fill in left-to-right as months land. You can
   leave the page — it runs server-side.

**Timing:** each month is ~30 day-POSTs (a few minutes of work) plus up to
`QUIET_MS` (10 min) to confirm it settled, so a full 18-month run typically
takes a **few hours**. It is intentionally unhurried.

**Cancel:** stops issuing further windows. A window already in flight finishes
its current month; nothing new is queued.

**Re-run:** if a job ends `failed` or `cancelled`, the button is enabled again —
starting a new job re-pulls from 2025-01-01 (idempotent, so already-good days
are simply overwritten with identical data).

---

## 4. Deployment

This feature spans the dashboard, the collector, and one DB migration. All live
in the `demo-dashboard` repo.

1. **DB migration** `0026_*_backfill_jobs` — creates `backfill_jobs`
   (additive only, no destructive change). Applied by the **migrator** service
   on deploy.
2. **Collector** redeploy — its 60s sweep now advances jobs
   (`Dockerfile.collector` also copies `src/lib/backfill/`).
3. **Dashboard** redeploy — the oRPC procedures + the sync page UI.

After deploy, pilot on **ACCGA2** (currently 1 day of data), then roll out
per-store.

---

## 5. Tuning knobs

In `src/lib/backfill/orchestrator.ts`:

| Constant | Default | Meaning |
|---|---|---|
| `QUIET_MS` | 10 min | store idle this long ⇒ the window run finished |
| `ISSUE_GRACE_MS` | 20 min | min age before a zero-landed window may settle |
| `MAX_ATTEMPTS` | 3 | per-window retries before giving up |
| `COMMAND_TTL_MS` | 24 h | window command lifetime (survives brief agent downtime) |

The 90-day re-sync cap is **unchanged** (`RESYNC_MAX_RANGE_DAYS = 90` on both
sides) — monthly windows stay well under it, so the existing guardrail is intact.

---

## 6. Manual fallback (no dashboard)

If you must do it by hand, issue monthly Re-syncs from the fleet command panel
(or the agent box), one at a time, **waiting for each to finish** before the
next so you don't overlap runs:

```
re-sync  2025-01-01 → 2025-01-31
re-sync  2025-02-01 → 2025-02-28
...
re-sync  2026-06-01 → 2026-06-12
```

On the store box directly:

```powershell
.\cxs-collector-<StoreCode>.ps1 -StartDate "2025-01-01" -EndDate "2025-01-31"
```

---

## 7. Known limitations & future hardening

- **Quiet-period heuristic.** Completion is inferred from store activity, not a
  precise signal. A nightly daily-sync landing mid-backfill just *delays* a
  settle (resets the quiet clock) — it never corrupts data. Good enough for the
  pilot; the deterministic upgrade is below.
- **(Hardening) Date-context on the completion checkin.** Add `mode`,
  `syncStartDate`, `syncEndDate` to the `sync_complete` / `sync_error` checkin
  (agent `Send-Checkin` + the collector's checkin ingest + a `store_checkins`
  migration). Then a window's completion is matched exactly to its range instead
  of inferred — removes the quiet-period wait and the daily-sync ambiguity.
- **(Hardening, "B3") Per-day retry-with-backoff in the collector.** Today a
  transient SQL/POST blip on one day aborts that window's run (the orchestrator
  then retries the window). Wrapping each day in 2–3 retries makes long runs
  self-heal and reduces orchestrator retries. Empty days are already handled
  (they count as success and don't block the loop).
- **Per-store, on-demand.** Backfill is triggered per store. A fleet-wide
  campaign would loop `startBackfill` across stores — do it in small batches to
  avoid hammering many POS servers at once.
