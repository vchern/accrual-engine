# Accrual Engine — Helix Compute take-home

Single-engine accrual computation for **AR** (usage-event-based) and **AP**
(Goods-Receipt-not-Invoiced). Built for the 2026-03-31 close of fictional
Helix Compute Inc., with NetSuite-friendly journal CSV export and a
controller-facing UI.

- **Live URL**: https://accrual-engine.onrender.com
- **Repository**: https://github.com/vchern/accrual-engine
- **Architecture write-up**: [ARCHITECTURE.md](ARCHITECTURE.md)

## Run-against targets

Engine against `Helix_Anchor_Dataset_CANDIDATE.xlsx` for **period_end = 2026-03-31**:

| Side      | Source                                 |          Amount |
| --------- | -------------------------------------- | --------------: |
| AR        | 3 customers · 7 events · Mar 29-31     |     **$362.50** |
| AP        | GR-2026-0042 (2 of 5 servers received) | **$100,000.00** |
| **Total** |                                        | **$100,362.50** |

- CUS-1001 Mar 30 lands `flagged` (25h vs ~10h median, z ≈ 6.1) but still accrues at the actual quantity per spec.
- CUS-1002 (EUR) book in USD via FX 1.08 (price book is USD; EUR is display-only).
- CUS-1003 churned EOD Mar 29 → 1-day accrual, not 3.
- For `period_end=2026-04-30` the engine correctly produces AR=$0 (no April events) + AP=$100,000 (still uninvoiced) — calendar-month bound works.

## Quick start (local)

```bash
git clone https://github.com/vchern/accrual-engine
cd accrual-engine

bin/setup                 # bundle install + db:migrate (no auto-seed in prod-like flow)
cp .env.example .env      # optional — populate GEMINI_API_KEY for AI notes
bundle exec rackup        # http://localhost:9292
bundle exec rspec         # 62 specs, ~14 sec
```

You also need `Helix_Anchor_Dataset_CANDIDATE.xlsx` _somewhere_ on your
disk. The app uploads it via the UI rather than reading from disk —
gitignored binary data stays out of source control, and the same flow
that works locally works in production.

**UI flow**:

1. Home → `/import` (auto-redirected on a clean DB)
2. Either upload an XLSX or click **Load sample data** → seeder runs → redirected to `/closes`
3. **Run engine** with `period_end=2026-03-31`
4. Overview shows totals + flagged banner → tabs for accruals / journal
   entries / audit log → drill-through to source UsageEvents and
   GoodsReceipts → CSV export.

## Stack

- **Ruby 3.3 / Sinatra 4** (modular `Sinatra::Base`) — readable end-to-end.
- **Sequel + SQLite** — Sinatra-idiomatic ORM; SQLite is production-viable on a single persistent volume at this scale.
- **BigDecimal everywhere** — `Float` is banned for money.
- **Tailwind (compiled)** — `tailwindcss-ruby` standalone binary; one ~15 KB minified `public/application.css` precompiled in Render's build step. No Node, no runtime CDN.
- **RSpec + Rack::Test** — service, engine, integration, and HTTP-level system specs.
- **Google Gemini 2.5 Flash** — grounded review narration for flagged accruals.

## Project layout

```
app.rb                       Sinatra app: routes, helpers
config/                      boot, database connection
db/migrations/               4 migrations, 17 tables
db/seeds.rb                  XLSX → DB + 30 days synthetic prior-period usage
lib/accruals/                engine, handler base, narrator, calendar, CSV
lib/accruals/handlers/       pluggable handlers — one file per accrual type
lib/models/                  Sequel models, one per table
spec/                        unit, integration, system specs
views/                       ERB + Tailwind UI
Helix_Anchor_Dataset_CANDIDATE.xlsx   (gitignored — drop in to seed)
```

## AI review notes (Gemini)

When the engine flags an accrual, it sends the _structured_ anomaly signal
(date, qty, median, z-score, customer label) to Gemini 2.5 Flash and asks
for a 2-3 sentence Controller-grade note. The prompt forbids inventing
amounts; the LLM only paraphrases the engine's facts. Result is cached on
the `accruals` row, so the UI never blocks on a live API call.

Get a free key at https://aistudio.google.com/apikey, paste into `.env` as
`GEMINI_API_KEY=...`. Without a key, the narration section is silently
hidden in the UI — everything else still works.

## Testing

```bash
bundle exec rspec                        # all 62
bundle exec rspec spec/integration       # asserts AR=$362.50, AP=$100,000
bundle exec rspec spec/system            # HTTP-level UI flow
```

Coverage spans handlers (against the brief's target cents), engine
plumbing (idempotency, reversals, audit, source replacement), anomaly
detector edge cases, business calendar (weekend + holiday skip), CSV
export shape + balance, narrator transport injection, and the full
HTTP close-run flow.

## Deploy (Render free tier)

The repo ships a `render.yaml` blueprint and a `bin/start` entrypoint.
Render's free tier requires no card and runs Ruby natively — no Docker
needed.

```
1. Push the repo to GitHub.
2. https://dashboard.render.com → New → Blueprint → connect this repo.
3. Render reads render.yaml and provisions the web service.
4. In the new service's Environment tab, set GEMINI_API_KEY = <your key>.
5. First request: visit the URL → /import → upload the XLSX or click "Load sample data" → /closes.
```

**Free-tier trade-off**: ephemeral disk + 15-min idle spin-down. Cold
boots wipe SQLite, so the reviewer re-uploads the anchor XLSX on the
first visit of each demo session. `bin/start` migrates on every boot
but does NOT auto-seed — uploads are the only way data lands. For a
demo this is actually a feature: each session starts clean.

For persistent state, switch the Render service to the `starter` plan
($7/mo) and add a managed disk, or swap SQLite for a managed Postgres
(Render's own, Neon, Supabase) via a Sequel adapter change.

## Known limitations

See [ARCHITECTURE.md § Known limitations](ARCHITECTURE.md#known-limitations).
