# Architecture — Helix Compute Accrual Engine

## 1. Problem framing

At month-end, two distinct accruals need to land on Helix's books:

- **AR**: Chargebee invoices on a Sun-Sat weekly cycle. The Mar 29 invoice covered Mar 22-28, so at the Mar 31 (Tue) close, three days of usage are earned-but-unbilled.
- **AP**: Coupa goods receipts post into NetSuite when hardware arrives, but the vendor invoice often follows weeks later. At close, any GR without a matching invoice represents an asset/expense to accrue (GR/IR clearing).

Both reduce to the same shape: _given the data we have, what's the closest-to-actual accrual we can compute, and what's the journal entry?_ Two integrations and two audit trails would be wasteful — one engine with pluggable handlers solves both.

## 2. Stack & rationale

| Choice                      | Why                                                                                                                                                                                                                                                         |
| --------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Sinatra over Rails**      | I chose Sinatra because it is lightweight and quick to prototype. For creating small focused applications, Sinatra is a better choice over Rails.                                                                                                           |
| **SQLite**                  | Single file, zero ops. Render's free tier has ephemeral disk, so production data is uploaded fresh per session via `/import` (this is also a feature — the demo always starts clean). Postgres swap is a 30-min Sequel adapter change for true persistence. |
| **BigDecimal**              | Float is banned for money to avoid binary representation issues. Decimal columns + Sequel coercion give exact arithmetic.                                                                                                                                   |
| **RSpec**                   | Standard. Each example wraps in a Sequel transaction with rollback for clean isolation.                                                                                                                                                                     |
| **Google Gemini 2.5 Flash-Lite** | Free-tier LLM, current generation, grounded narration. Lite variant chosen for higher RPM/RPD on the free tier — quality drop for 2-3 sentence paraphrasing is negligible. Swappable to Anthropic/OpenAI without engine changes.                                                                                                                                                |

## 3. Data model

Two-layer separation: `Accrual` is the **business fact**, `JournalEntry` + `JournalLine` are the **GL representation**. Handlers compute Accruals; the engine emits JEs. This keeps handlers GL-agnostic and makes the export layer pure formatting.

```
Reference                Telemetry              Engine
---------                ---------              ------
customers                usage_events           close_runs
skus                     chargebee_invoices     accruals
                                                   ↳ idempotency_key UNIQUE
vendors                  purchase_orders           ↳ amount_usd, fx_rate, status
gl_accounts              po_lines                  ↳ review_narration (LLM cache)
fx_rates                 goods_receipts        accrual_sources
                         vendor_invoices          ↳ polymorphic source_type/source_id
                                                journal_entries
                                                   ↳ entry_type accrual|reversal
                                                   ↳ reverses_id (self-FK)
                                                journal_lines
                                                   ↳ DR / CR amounts per GL account
                                                audit_events  (append-only)
```

17 tables across 3 schema migrations (a 4th adds the LLM cache columns to `accruals`).

### Data import as a first-class flow

The deployed app starts with an empty schema and lands on `/import` until reference data is loaded. Two ways in:

- **Upload an XLSX** in the same shape as the Helix anchor (sheets: `customers`, `sku_price_book`, `vendors`, `gl_accounts`, `usage_events`, `chargebee_invoices`, `purchase_orders`, `po_lines`, `goods_receipts`, `vendor_invoices`).
- **Click "Load sample data"** — uses the bundled Helix anchor that ships with the repo, so a reviewer with no XLSX in hand can demo in one click.

Each import wipes all tables in dependency order before re-seeding, so the engine never accrues against a stale partial state. Render's free tier has ephemeral disk, which makes this a feature: every cold-boot session starts clean and the panelist can decide which dataset to demo against. Controller-grade framing ("Data import" rather than "anchor data") keeps the affordance unambiguous to a non-engineer.

**Schema validation before any destructive op.** The seeder destructured rows positionally, which would silently shift data if a column were renamed or reordered — exactly the kind of bug that ruins an accrual without anyone noticing. `Seeder.validate!(path:)` checks every sheet name and every column header against `SHEET_SCHEMA` before any row is read or any table is touched. On failure it raises `Seeder::SchemaError` with a list of human-readable problems ("Missing sheet: X", "Sheet Y, column 3: expected currency, got CURRENCY"). The upload route returns 422 and re-renders `/import` with a red banner listing every issue; the existing data is untouched.

## 4. Engine flow

```ruby
mark_started                                 # outside txn — survives rollback

DB.transaction do
  HANDLERS.each { |klass| process_handler(klass) }
    # for each draft: upsert by idempotency_key; replace sources

  regenerate_journal_entries
    # delete stale JEs+lines; emit accrual JE per accrual + paired reversal

  mark_completed
end

audit :run_completed
narrate_flagged_accruals                     # post-commit; LLM error never rolls back
```

**Handler interface**:

```ruby
class Accruals::Handlers::Foo < Accruals::Handler
  def self.handler_name; "foo"; end
  def call; [Accruals::DraftAccrual.new(...), ...]; end
end
Accruals::Engine.register(Foo)
```

To add a third handler: drop one file under `lib/accruals/handlers/`, add one line to register it. The engine has no knowledge of any specific handler.

## 5. Idempotency

Each `Accrual` has a UNIQUE `idempotency_key`. Handler keys:

- AR: `ar_usage|<period_end>|<customer_code>` — one accrual per customer per close
- AP: `ap_gr_not_invoiced|<period_end>|<receipt_id>` — one accrual per receipt per close

Re-running the engine for the same close: existing rows update in place; if amount changed, an `audit_event` records the delta. Period scoping in the AP key prevents two closes for different period_ends from fighting over a shared GR-not-invoiced row.

## 6. Multi-currency

The price book is USD-only (`list_unit_price_usd`). `Customer.currency` is the _display_ currency. For non-USD-billed customers (CUS-1002 EUR):

- `amount_usd` — canonical, computed from `quantity × USD list price`
- `amount_billing_ccy = amount_usd / fx_rate` — display only
- `fx_rate` — snapped at `period_end` via `FxRate.lookup!`
- All journal lines are USD

Real-world refinement: a per-customer or per-SKU price book in non-USD currencies would land here without engine changes — just an FX lookup at price-resolution time.

## 7. Reversing entries

For each accrual JE dated `period_end`, the engine generates a paired reversal JE dated `BusinessCalendar.next_business_day(period_end)` with DR/CR signs swapped. The calendar covers US-Fed holidays for 2026-27. For the anchor: Mar 31 (Tue) → reversal dated Apr 1 (Wed).

## 8. Calendar-month bound

The unbilled window is:

```
[ max(last_invoice_end + 1, first_day_of_period_month), period_end ]
```

Without the month bound, an Apr 30 close would sweep in March's already-handled events (no April invoices have been issued in the anchor). The bound makes per-period closes well-defined.

## 9. Source traceability

Each `Accrual` has many `AccrualSource` rows (polymorphic to `UsageEvent`, `GoodsReceipt`, `PoLine`). The drill-through page resolves them inline; the CSV export includes a `source_refs` column with `Type#id;Type#id;...` so an auditor can trace any GL line back to the underlying records.

## 10. Anomaly detection (statistical)

Median + MAD (Median Absolute Deviation), scaled by 1.4826 for normal-ish data, with a 3σ-equivalent threshold. Per-customer-per-SKU baseline from prior history (the seeder augments the anchor's 9 days of real telemetry with 30 days of synthetic prior-period events — disclosed; deterministic via `Random.new(42)`).

**Why MAD over a learned model**: at this scale (small N, no labeled training data, audit needs to be fully explainable), classical statistics is the right tool. The detector is robust to outliers in its own baseline (mean+stddev would be skewed by a single spike), deterministic, and traceable. Returns `nil` z-score when the baseline is too small (<7) or has zero MAD — "no opinion" is honest.

For the anchor's seeded outlier (CUS-1001 Mar 30, 25h vs ~10h median): z ≈ 6.1, well above threshold. The accrual still books at actual quantity per spec — the flag is for human review, not auto-correction.

## 11. AI: LLM-narrated review notes (Gemini 2.5 Flash-Lite)

For each flagged accrual, the engine sends the **structured signal** to Gemini and persists a 2-3 sentence Controller-grade narrative.

**Grounded by design**:

- The prompt forbids inventing or recomputing amounts
- The LLM receives only fields the engine already computed (date, qty, median, z-score, customer label)
- Its job is plain-English paraphrasing, not arithmetic

**Example output** (live, against the seeded anchor):

> "The accrual for CUS-1001 includes 25.0 GPU-H100-HR units on 2026-03-30, which is 14.5 units above the median daily usage of 10.5 units. While this deviation is significant (z=6.1), it could represent valid, increased usage by the customer. The Controller should verify with the sales or account management team if this spike in usage was expected or communicated by Acme Robotics Inc. before approving the accrual."

**Implementation**:

- `Accruals::ReviewNarrator` is a thin service with an injectable `transport` callable — tests pass a lambda; production uses Net::HTTP
- `thinkingConfig.thinkingBudget = 0` disables Gemini 2.5's internal reasoning tokens (we don't need CoT for paraphrasing)
- Runs **outside** the engine transaction — an LLM error never rolls back the close
- Result cached on `accruals.review_narration` so the UI never blocks on a live API call
- Swappable to Anthropic / OpenAI by replacing one class — engine is unaware

**Reliability around the API call**:

- **Audited outcomes**: every narration attempt writes one of `review_narration_added` (success, with model name), `review_narration_failed` (with the Gemini error string), or `review_narration_skipped` (with reason — typically "GEMINI_API_KEY not set in environment")
- **UI surfacing via `narration_status` helper**: instead of silently hiding the section, the flagged-accrual UI reads the audit log and shows *why* a narration is missing — "AI review note · skipped — GEMINI_API_KEY not set" or "AI review note · failed — Gemini 429: quota exceeded". A reviewer can tell at a glance whether to add a key, retry later, or escalate.
- **Retry cooldown**: `Engine::NARRATION_RETRY_COOLDOWN_SECONDS` (10 min) gates re-attempts after a failure. Without it, repeated "Run engine" clicks would slam an already-rate-limited endpoint and pile up identical 429s. Cooldown is failure-scoped only — a config-level "skipped" event doesn't block immediate retry once the key is added.

## 12. Test strategy (73 specs)

| Layer             | What it covers                                                                                                                                                      |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Service           | Each handler against the brief's target cents (`AR=$362.50`, `AP=$100,000`); EUR fx math; mid-period churn; partial receipt; fully-invoiced skip                    |
| Engine            | Idempotent re-run, source replacement, reversal pairing, audit events, amount-change detection, narration cooldown                                                  |
| Anomaly detector  | Outlier flag, baseline-too-small, zero-MAD edge case                                                                                                                |
| Business calendar | Weekend skip, federal-holiday skip, the close→reversal date specifically                                                                                            |
| CSV exporter      | Header + per-line + balanced DR/CR                                                                                                                                  |
| Narrator          | Nil paths, transport injection, error capture                                                                                                                       |
| Seeder validation | Happy path; missing file, missing sheet, renamed column, swapped columns                                                                                            |
| Integration       | Full close against the seeded anchor → exact target match; calendar-month bound on a non-anchor period_end                                                          |
| System (HTTP)     | Close flow (index → run → drill-through → CSV); engine-state reset endpoint; data-import upload + bundled-sample button; schema-validation 422; narration UI states |

Each spec wraps in a Sequel transaction with rollback for isolation.

## 13. What I'd do differently with more time

| Refinement                                                                                           | Effort                                     |
| ---------------------------------------------------------------------------------------------------- | ------------------------------------------ |
| Per-customer unbilled window (denormalize `last_invoiced_through` on Customer) instead of global max | 30 min                                     |
| Move LLM narration to Solid Queue / Que so a slow Gemini response doesn't block the run              | 1-2 hr                                     |
| Stretch handlers — AP subscription / straight-line and AP milestone (pattern is in place)            | 2 hr each                                  |
| Forecast model with prediction interval on a dashboard page                                          | half day                                   |
| Real per-currency price book (anchor only had USD); FX path in handlers is ready                     | 1 hr                                       |
| Postgres swap (Sequel adapter change + Render-managed Postgres or Neon free tier)                    | 30 min                                     |
| Auth + RBAC (out of scope per brief)                                                                 | 1 day with Devise/Sorcery or roll-your-own |

## Known limitations

- **SQLite + single-process**: fine for demo; replace with Postgres for prod.
- **No NetSuite API integration**: brief explicitly says CSV is sufficient.
- **LLM call is synchronous** in `engine.run!`; ~1-3s adder on free Gemini tier. Should be async-queued in production.
- **Anomaly detection is per-(customer, SKU)** with no cross-customer signal. Adequate for the seeded scenario; richer detection (cross-customer, cross-SKU correlation, time-series decomposition) would land alongside the forecast model.
- **Audit events are append-only but unsigned**. For true compliance you'd hash-chain them or write to an immutable store.
