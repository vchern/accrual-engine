# Accrual Engine — Helix Compute take-home

Single-engine accrual computation for AR (usage-based) and AP (Goods-Receipt-not-Invoiced),
period close 2026-03-31.

## Status

Phase 1 (scaffold) — engine and handlers land in subsequent phases.

## Stack

- Ruby 3.3 / Sinatra 4 (modular, `Sinatra::Base`)
- Sequel + SQLite
- BigDecimal for money — Float is banned
- RSpec + Rack::Test for tests
- Tailwind via CDN (would compile in production)

## Setup

```bash
bin/setup            # bundle install + db:setup
bundle exec rackup   # http://localhost:9292
bundle exec rspec    # run the test suite
```

## Architecture

To follow in phase 6 — see the plan in conversation notes for now.

## Anchor data

`Helix_Anchor_Dataset_CANDIDATE.xlsx` holds the seeded scenarios. Run-against targets:

| Side | Source | Expected accrual |
| --- | --- | ---: |
| AR | 3 customers × 7 events, Mar 29-31 | $362.50 |
| AP | GR-2026-0042 (2 of 5 servers received) | $100,000.00 |
| **Total** | | **$100,362.50** |
