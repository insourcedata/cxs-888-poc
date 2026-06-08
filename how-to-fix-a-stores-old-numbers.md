# How to fix a store's old sales numbers

This is the plain-English guide. (Engineers: the technical version is
`historical-backfill-resync.md`.)

## What this does, in one sentence

If a store's **old** sales figures on the dashboard look wrong (too high), this lets you
tell that store's till system to **send its records again** so the dashboard recalculates
them correctly — without anyone touching a database or a spreadsheet.

## Why the old numbers were wrong

For a while, **refunds were being counted as extra sales** instead of being subtracted. So
a day with returns showed *more* money than the store actually made. That counting mistake
is now fixed for all **new** days. This guide is how you go back and fix the **old** days.

## Before you start — quick checklist

You're ready if all of these are true:

- ☐ The fix is live (an engineer has confirmed the corrected version is running).
- ☐ The store's computer/agent is **online** (you can see it checking in on the fleet page).
- ☐ The store has the **updated agent** installed (ask an engineer if unsure — an out-of-date
  store will look like it worked but nothing changes).
- ☐ You know **which store** and **which dates** look wrong.

> **The one thing this can't do:** it can only re-pull days the store's till system *still
> has*. If the till has already deleted very old records, those days can't be fixed this way.

## How to fix a store (step by step)

1. **Open the fleet page** in the admin app and find the store you want to fix.
2. Choose **"Re-sync"** for that store.
3. Enter the **start date** and **end date** of the period that looks wrong (use the format
   the form shows, e.g. `2026-06-01`).
   - **Keep the range small — about a month at a time.** Long ranges are more likely to time
     out. If you need a whole year, do it month by month.
4. **Submit it.** That's all you do. The store's computer picks up the request the next time
   it checks in (usually within a few minutes) and starts re-sending those days one by one.
5. **Wait and watch.** On the store's sync history you'll see each day update as it comes back
   in.

## How to know it worked

For each day you re-sent, the sync history shows a small summary. A good result looks like:

- the day's status is **"ok"**, and
- the **sales total now matches** what Finance/the store expects (the inflated number is gone).

The system **replaces** the old version of each day with the freshly re-sent one, so you can
safely run the same request again if you're ever unsure — it won't double-count.

## If a day says "failed"

Don't worry — **"failed" means it did NOT change your data.** It refused to touch that day
because something wasn't right, and left the existing numbers alone. The usual reasons:

- **"No sales came back"** → the store sent an empty or half-empty day (often a brief
  connection hiccup). Just **run it again** for that day.
- **"Couldn't confirm the request"** → the re-sync request was too old by the time the store
  got around to it (this happens on very long ranges). **Re-issue it** for the days that are
  still wrong, in a smaller chunk.
- **A day never appears at all** → the store was offline, or its till no longer has that day.
  Try again when the store is online; if the till truly doesn't have it, that day can't be
  recovered this way.

If a day is stuck or you're unsure, it's always safe to re-issue the re-sync — the worst case
is it redoes work, never that it corrupts anything.

## Good habits

- **One store, one month at a time.** Start with a single store and a single bad period,
  confirm the numbers look right, then move on.
- **Do a test run first.** Pick one store/day you *know* is wrong, fix it, and check the number
  matches expectations before doing the rest of the fleet.
- **Always start the re-sync from the admin app**, not from the store's computer directly.
- If many days come back **"failed"**, stop and ask an engineer rather than retrying endlessly —
  something upstream (the store's agent or connection) probably needs a look.
