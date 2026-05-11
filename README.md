# Accrual Engine: Helix Compute take-home

Single-engine accrual computation for **AR** (usage-event-based) and **AP**
(Goods-Receipt-not-Invoiced). Built for the 2026-03-31 close of fictional
Helix Compute Inc., with NetSuite-friendly journal CSV export and a
controller-facing UI.

- **Live URL**: https://accrual-engine.onrender.com
- **Repository**: https://github.com/vchern/accrual-engine
- **Architecture write-up**: [ARCHITECTURE.md](ARCHITECTURE.md)

## Bundled samples (pick one with a button on `/import`)

| Sample | Shape | Engine totals @ 2026-03-31 |
| --- | --- | --- |
| **Helix canonical anchor** (`Helix_Anchor_Canonical.xlsx`) | 3 customers, 1 vendor, 1 PO, 1 seeded anomaly. Synthetic regeneration of the brief's anchor. | AR $362.50 · AP $100,000 · **total $100,362.50** |
| **Helix expanded demo** (`Helix_Demo_Expanded.xlsx`) | Same company, 6 customers across USD/EUR/JPY/GBP/SGD, 5 SKUs, 2 POs, 2 seeded anomalies, exercises every engine skip path. | AR $1,042.50 · AP $30,000 · **total $31,042.50** |

Both files emit from `script/generate_*_dataset.rb` (caxlsx); data is in plain Ruby arrays, no binary opacity. You can also upload your own XLSX matching the schema; the upload form runs `Seeder.validate!` before any destructive op.

**Edge cases the engine handles correctly across both samples:**

- CUS-1001 Mar 30 lands `flagged` (25h vs ~10h median, z ≈ 6.1); accrues at actual qty, **stays off the JE until a controller approves**.
- CUS-1002 (EUR) books in USD via FX 1.08 (price book is USD; billing currency is display-only).
- CUS-1003 churned EOD Mar 29 → 1-day accrual, not 3.
- `period_end=2026-04-30` correctly produces AR=$0 (no April events) + AP=$100,000 (still uninvoiced); the calendar-month bound holds.
- Expanded demo: CUS-1006 has events only outside the unbilled window (AR skipped); GR-2026-0042 fully invoiced (AP skipped); GR-2026-0043 partially invoiced (accrues remainder only).

## Quick start (local)

```bash
git clone https://github.com/vchern/accrual-engine
cd accrual-engine

bin/setup                 # bundle install + db:migrate (no auto-seed in prod-like flow)
cp .env.example .env      # optional: populate GEMINI_API_KEY for AI notes
bundle exec rackup        # http://localhost:9292
bundle exec rspec         # 113 specs, ~22 sec
```

**Top-level nav**: `Closes` · `Data` · `Audit` · `Data Import`

**UI flow**:

1. Home → `/import` (auto-redirected on a clean DB)
2. Click **Load Canonical** or **Load Expanded Demo** (or upload your own XLSX) → seeder runs → redirected to `/closes`
3. **Run Engine** with `period_end=2026-03-31`. Re-running for an existing period shows a `confirm()` with the prior totals first. The server-side run is still idempotent (accruals upsert by key; approved/rejected decisions preserved).
4. The Overview tab leads with the **AI close summary** (one-paragraph LLM-written overview), followed by an **Awaiting review** banner (amber) with inline **Approve** / **Reject** buttons per flagged accrual, and a separate **Blocked: cannot post** banner (red) if any accruals couldn't be coded.
5. Per-close tabs for **Accruals**, **Journal Entries**, **Audit Log** → drill-through to the underlying `UsageEvent` / `GoodsReceipt` / `PoLine` source rows → **Download Journal CSV**.

**Operational affordances**:

- **`/data`**: tabbed browser of every loaded table (customers, vendors, SKUs, GL accounts, FX rates, usage events, Chargebee invoices, POs, PO lines, goods receipts, vendor invoices) with row counts in the nav badges. Up to 200 rows per tab.
- **`/audit`**: cross-close audit log. Includes `close_deleted` events whose `close_run_id` is detached before the cascade so the row survives its own subject's deletion; the period date and totals are snapshotted in the payload.
- **Delete Close**: per-close cascade delete (journal lines → JEs → accrual sources → audit events → accruals → close run, in one transaction). A `close_deleted` audit row is written first with `close_run_id=nil` so the deletion remains traceable on `/audit`.
- **Reset Engine State**: nuclear option. Wipes all closes and engine state, leaves reference data intact.

## Stack

- **Ruby 3.3 / Sinatra 4** (modular `Sinatra::Base`): readable end-to-end.
- **Sequel + SQLite**: Sinatra-idiomatic ORM; SQLite is production-viable on a single persistent volume at this scale.
- **BigDecimal everywhere**: `Float` is banned for money.
- **Tailwind (compiled)**: `tailwindcss-ruby` standalone binary; one ~15 KB minified `public/application.css` precompiled in Render's build step. No Node, no runtime CDN.
- **RSpec + Rack::Test**: service, engine, integration, and HTTP-level system specs.
- **Google Gemini 2.5 Flash-Lite**: grounded LLM for two applications, per-flagged-accrual review notes and per-close executive summary.

## Project layout

```
app.rb                       Sinatra app: routes, helpers
config/                      boot, database connection
db/migrations/               7 migrations, 17 tables
db/seeds.rb                  XLSX → DB + 30 days synthetic prior-period usage
lib/accruals/                engine, handler base, narrator, summarizer, calendar, CSV
lib/accruals/handlers/       pluggable handlers, one file per accrual type
lib/models/                  Sequel models, one per table
script/                      one-shot dataset generators (caxlsx-based)
spec/                        unit, integration, system specs
views/                       ERB + Tailwind UI
  views/closes/              Close index + per-close show (tabs: Overview / Accruals / Journal Entries / Audit Log)
  views/accruals/            Accrual drill-through page
  views/import/              XLSX upload + bundled-sample buttons
  views/data/                /data browser: 11-tab inspector for the loaded tables
  views/audit/               /audit: cross-close audit log including close_deleted events
Helix_Anchor_Canonical.xlsx  Bundled: synthetic regen of the brief's anchor
Helix_Demo_Expanded.xlsx     Bundled: richer, exercises every skip path
```

## AI applications (Gemini)

Two distinct LLM uses, both grounded by design. The prompt forbids
inventing or recomputing amounts; the model only paraphrases facts the
engine already produced.

1. **Per-flagged-accrual review notes** (`Accruals::ReviewNarrator`):
   2-3 sentences explaining the anomaly. Cached on `accruals.review_narration`.
2. **Per-close executive summary** (`Accruals::CloseSummarizer`):
   3-5 sentences covering totals, awaiting-review count, flagged items, and
   reversal date. Cached on `close_runs.summary`. Lands at the top of the
   close overview tab.

Get a free key at https://aistudio.google.com/apikey, paste into `.env` as
`GEMINI_API_KEY=...`. Both UIs read the audit log and show the **outcome**
(`added` / `failed` / `skipped` with reason) instead of silently
disappearing. A reviewer can tell at a glance whether the LLM ran,
errored, or was disabled.

**Rate-limit handling**: failed narration calls trigger a 10-minute
cooldown so repeated "Run engine" clicks don't slam an already-rate-
limited endpoint. Close summaries don't re-run if a summary already
exists, saving quota.

## Review workflow: flagged accruals stay off the journal entry

Engine produces `posted` for normal accruals and `flagged` for anomalies.
Flagged accruals are real (idempotency key, source rows, FX detail) but
they are **excluded from the consolidated journal entry** until a
Controller decides:

- **Approve** → status flips to `approved`; lines appear on the JE; audit
  event written.
- **Reject** → status flips to `rejected`; stays off the JE; audit event
  written.
- **Reset to flagged** → reverts an approved/rejected accrual back to
  awaiting review.

Approve / Reject buttons appear inline on the close overview banner
(clear the queue without drilling) and inside the flagged box on the
accrual drill-through page. Engine re-runs preserve the controller's
decision; re-running doesn't silently revert an approval.

## Testing

```bash
bundle exec rspec                        # all 113
bundle exec rspec spec/integration       # asserts AR=$362.50, AP=$100,000
bundle exec rspec spec/system            # HTTP-level UI flow
```

Coverage spans handlers (target cents per the brief), engine plumbing
(idempotency, consolidated JEs, audit, source replacement, narration
cooldown, summary cache, blocked-status persistence + audit + JE
exclusion), the **review workflow** (approve / reject / reset
transitions; engine re-run preserves human decisions), anomaly
detector edge cases, business calendar (weekend + holiday skip), CSV
export shape + balance + **natural-id source refs** (XLSX-traceable
`UsageEvent#evt_u0001` instead of internal PKs), narrator and
summarizer transport injection, seeder schema validation (missing
sheet / renamed column / swapped columns), append vs replace import
modes, the full HTTP close-run flow, **per-close delete cascade**
(audit-preserving), the **central `/audit` page** (close_deleted
survives its own subject), and the tabbed **`/data` browser**.

## Deploy (Render free tier)

The repo ships a `render.yaml` blueprint and a `bin/start` entrypoint.
Render's free tier requires no card and runs Ruby natively; no Docker
needed.

```
1. Push the repo to GitHub.
2. https://dashboard.render.com → New → Blueprint → connect this repo.
3. Render reads render.yaml and provisions the web service.
4. In the new service's Environment tab, set GEMINI_API_KEY = <your key>.
5. First request: visit the URL → /import → upload the XLSX or click "Load sample data" → /closes.
```

**Free-tier trade-off**: ephemeral disk plus a 15-min idle spin-down. Cold
boots wipe SQLite, so the reviewer either re-uploads an XLSX or clicks
**Load sample data** (which seeds from the bundled anchor) on the first
visit of each demo session. `bin/start` migrates on every boot but does
NOT auto-seed; imports are the only way data lands. For a demo this is
actually a feature: each session starts clean.

For persistent state, switch the Render service to the `starter` plan
($7/mo) and add a managed disk, or swap SQLite for a managed Postgres
(Render's own, Neon, Supabase) via a Sequel adapter change.

## Known limitations

See [ARCHITECTURE.md § Known limitations](ARCHITECTURE.md#known-limitations).
