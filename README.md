# Accrual Engine — Helix Compute take-home

Single-engine accrual computation for **AR** (usage-event-based) and **AP**
(Goods-Receipt-not-Invoiced). Built for the 2026-03-31 close of fictional
Helix Compute Inc., with NetSuite-friendly journal CSV export and a
controller-facing UI.

- **Repository**: https://github.com/vchern/accrual-engine
- **Architecture write-up**: [ARCHITECTURE.md](ARCHITECTURE.md)
- **Live URL**: _to follow once phase 7 deploy lands_

## Run-against targets

Engine against `Helix_Anchor_Dataset_CANDIDATE.xlsx` for **period_end = 2026-03-31**:

| Side | Source | Amount |
| --- | --- | ---: |
| AR | 3 customers · 7 events · Mar 29-31 | **$362.50** |
| AP | GR-2026-0042 (2 of 5 servers received) | **$100,000.00** |
| **Total** | | **$100,362.50** |

- CUS-1001 Mar 30 lands `flagged` (25h vs ~10h median, z ≈ 6.1) but still accrues at the actual quantity per spec.
- CUS-1002 (EUR) book in USD via FX 1.08 (price book is USD; EUR is display-only).
- CUS-1003 churned EOD Mar 29 → 1-day accrual, not 3.
- For `period_end=2026-04-30` the engine correctly produces AR=$0 (no April events) + AP=$100,000 (still uninvoiced) — calendar-month bound works.

## Quick start

```bash
git clone https://github.com/vchern/accrual-engine
cd accrual-engine

# Drop Helix_Anchor_Dataset_CANDIDATE.xlsx into the project root.
# It's gitignored by design (binary anchor data, not source).

bin/setup                 # bundle install + db:setup (drops, migrates, seeds)
cp .env.example .env      # optional — populate GEMINI_API_KEY for AI notes
bundle exec rackup        # http://localhost:9292
bundle exec rspec         # 53 specs, ~4 sec
```

UI flow: home → `/closes` → **Run engine** with `period_end=2026-03-31` →
overview shows totals + flagged banner → tabs for accruals / journal entries
/ audit log → drill-through to source UsageEvents and GoodsReceipts → CSV
export.

## Stack

- **Ruby 3.3 / Sinatra 4** (modular `Sinatra::Base`) — readable end-to-end; the handler-pluggability story is a Ruby concern, not a framework one.
- **Sequel + SQLite** — Sinatra-idiomatic ORM; SQLite is production-viable on a single Fly volume at this scale.
- **BigDecimal everywhere** — `Float` is banned for money.
- **Tailwind via CDN** — demo grade; production would compile.
- **RSpec + Rack::Test** — service, engine, integration, and HTTP-level system specs.
- **Google Gemini 2.5 Flash** — grounded review narration for flagged accruals.

## Project layout

```
app.rb                       Sinatra app: routes, helpers
config/                      boot, database connection
db/migrations/               4 migrations, 14 tables
db/seeds.rb                  XLSX → DB + 30 days synthetic prior-period usage
lib/accruals/                engine, handler base, narrator, calendar, CSV
lib/accruals/handlers/       pluggable handlers — one file per accrual type
lib/models/                  Sequel models, one per table
spec/                        unit, integration, system specs
views/                       ERB + Tailwind UI
Helix_Anchor_Dataset_CANDIDATE.xlsx   (gitignored — drop in to seed)
```

## AI review notes (Gemini)

When the engine flags an accrual, it sends the *structured* anomaly signal
(date, qty, median, z-score, customer label) to Gemini 2.5 Flash and asks
for a 2-3 sentence Controller-grade note. The prompt forbids inventing
amounts; the LLM only paraphrases the engine's facts. Result is cached on
the `accruals` row, so the UI never blocks on a live API call.

Get a free key at https://aistudio.google.com/apikey, paste into `.env` as
`GEMINI_API_KEY=...`. Without a key, the narration section is silently
hidden in the UI — everything else still works.

## Testing

```bash
bundle exec rspec                        # all 53
bundle exec rspec spec/integration       # asserts AR=$362.50, AP=$100,000
bundle exec rspec spec/system            # HTTP-level UI flow
```

Coverage spans handlers (against the brief's target cents), engine
plumbing (idempotency, reversals, audit, source replacement), anomaly
detector edge cases, business calendar (weekend + holiday skip), CSV
export shape + balance, narrator transport injection, and the full
HTTP close-run flow.

## Known limitations

See [ARCHITECTURE.md § Known limitations](ARCHITECTURE.md#known-limitations).
