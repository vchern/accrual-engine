# Accrual Engine — Helix Compute take-home

Single-engine accrual computation for AR (usage-based) and AP (Goods-Receipt-not-Invoiced),
period close 2026-03-31.

## Status

Engine, handlers, UI, and AI review notes are wired. Architecture write-up
and deploy land in later phases.

## Stack

- Ruby 3.3 / Sinatra 4 (modular, `Sinatra::Base`)
- Sequel + SQLite
- BigDecimal for money — Float is banned
- RSpec + Rack::Test for tests
- Tailwind via CDN (would compile in production)

## Setup

```bash
bin/setup                       # bundle install + db:setup
cp .env.example .env            # optional — see "AI review notes" below
bundle exec rackup              # http://localhost:9292
bundle exec rspec               # run the test suite
```

## AI review notes (Gemini)

When an accrual is flagged by the anomaly detector, the engine sends the
*structured* signal (date, qty, median, z-score) to Google Gemini and asks
for a 2-3 sentence Controller-grade review note. The LLM's job is plain-
English paraphrasing — the prompt forbids inventing amounts.

To enable: get a free key at https://aistudio.google.com/apikey, drop it
into `.env` as `GEMINI_API_KEY=...`, and run a close. Without a key, the
narration section is silently hidden in the UI — everything else still
works.

## Architecture

To follow — see the conversation plan for now.

## Anchor data

`Helix_Anchor_Dataset_CANDIDATE.xlsx` holds the seeded scenarios. Run-against
targets for the **2026-03-31** close:

| Side | Source | Expected accrual |
| --- | --- | ---: |
| AR | 3 customers × 7 events, Mar 29-31 | $362.50 |
| AP | GR-2026-0042 (2 of 5 servers received) | $100,000.00 |
| **Total** | | **$100,362.50** |

The AR window is calendar-month-bounded — running for `period_end=2026-04-30`
correctly produces AR=$0 (no April events in the anchor) while still
re-accruing the still-uninvoiced Dell receipt at $100,000.

CUS-1001 Mar 30 lands `flagged` (25h vs ~10h median, z ≈ 6) but accrues at
the actual quantity per spec.
