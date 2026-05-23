# Architecture: Helix Compute Accrual Engine

## 1. Problem framing

At month-end, two distinct accruals need to land on Helix's books:

- **AR**: Chargebee invoices on a Sun-Sat weekly cycle. The Mar 29 invoice covered Mar 22-28, so at the Mar 31 (Tue) close, three days of usage are earned-but-unbilled.
- **AP**: Coupa goods receipts post into NetSuite when hardware arrives, but the vendor invoice often follows weeks later. At close, any GR without a matching invoice represents an asset/expense to accrue (GR/IR clearing).

Both reduce to the same shape: _given the data we have, what's the closest-to-actual accrual we can compute, and what's the journal entry?_ Two integrations and two audit trails would be wasteful; one engine with pluggable handlers solves both.

## 2. Stack & rationale

| Choice                      | Why                                                                                                                                                                                                                                                         |
| --------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Sinatra over Rails**      | I chose Sinatra because it is lightweight and quick to prototype. For creating small focused applications, Sinatra is a better choice over Rails.                                                                                                           |
| **SQLite**                  | Single file, zero ops. Render's free tier has ephemeral disk, so production data is uploaded fresh per session via `/import` (this is also a feature: the demo always starts clean). Postgres swap is a 30-min Sequel adapter change for true persistence. |
| **BigDecimal**              | Float is banned for money to avoid binary representation issues. Decimal columns + Sequel coercion give exact arithmetic.                                                                                                                                   |
| **RSpec**                   | Standard. Each example wraps in a Sequel transaction with rollback for clean isolation.                                                                                                                                                                     |
| **Google Gemini 2.5 Flash-Lite** | Free-tier LLM, current generation, grounded narration. Lite variant chosen for higher RPM/RPD on the free tier; quality drop for 2-3 sentence paraphrasing is negligible. Swappable to Anthropic/OpenAI without engine changes.                                                                                                                                                |

## 3. Data model

Two-layer separation. `Accrual` is the **business fact**; `JournalEntry` + `JournalLine` are the **GL representation**. Handlers compute Accruals; the engine emits JEs. This keeps handlers GL-agnostic and makes the export layer pure formatting.

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

17 tables across 7 migrations (3 create the schema; the others add LLM-cache columns to `accruals`, refine `journal_entries` for line-level traceability after JE consolidation, add `summary` columns to `close_runs`, and relax `accruals.gl_*_account_id` to nullable so blocked accruals can persist without GL coding).

### Data import as a first-class flow

The deployed app starts with an empty schema and lands on `/import` until reference data is loaded. Three ways in:

- **Upload an XLSX** in the same shape as the Helix anchor (sheets: `customers`, `sku_price_book`, `vendors`, `gl_accounts`, `usage_events`, `chargebee_invoices`, `purchase_orders`, `po_lines`, `goods_receipts`, `vendor_invoices`).
- **Load canonical**: bundled `Helix_Anchor_Canonical.xlsx` (synthetic regeneration of the brief's anchor; no proprietary instructions). Engine produces the brief's $362.50 / $100,000 / $100,362.50 targets exactly.
- **Load expanded demo**: bundled `Helix_Demo_Expanded.xlsx`. Same company, 6 customers across USD/EUR/JPY/GBP/SGD, 5 SKUs, 2 POs, 2 seeded anomalies, and three deliberate skip-paths (one customer with no unbilled events; one fully-invoiced GR; one partially-invoiced GR). Targets: AR $1,042.50 / AP $30,000 / total $31,042.50.

Both bundled files are emitted from `script/generate_*_dataset.rb` via the `caxlsx` gem, so the data is in plain Ruby arrays; no binary opacity. Imports support two modes: **replace** (wipe all tables, then seed) is the default; **append** (skip any row whose natural key already exists) supports adding a later month's events without losing history. Render's free tier has ephemeral disk, which makes the per-session reset a feature rather than a constraint: every cold-boot session starts clean and the panelist picks which dataset to demo against.

**Schema validation before any destructive op.** The seeder destructured rows positionally, which would silently shift data if a column were renamed or reordered. That is exactly the kind of bug that ruins an accrual without anyone noticing. `Seeder.validate!(path:)` checks every sheet name and every column header against `SHEET_SCHEMA` before any row is read or any table is touched. On failure it raises `Seeder::SchemaError` with a list of human-readable problems ("Missing sheet: X", "Sheet Y, column 3: expected currency, got CURRENCY"). The upload route returns 422 and re-renders `/import` with a red banner listing every issue; the existing data is untouched.

**Data inspection at `/data`.** Once loaded, every reference + transaction table is browsable through a single tabbed page (Customers, Vendors, SKUs, GL Accounts, FX Rates, Usage Events, Chargebee Invoices, Purchase Orders, PO Lines, Goods Receipts, Vendor Invoices). Tab badges show row counts; each tab shows up to 200 rows with sensible ordering (most-recent first for time-stamped tables). Useful for a reviewer who wants to verify exactly what the engine is running against before clicking Run Engine.

## 4. Engine flow

```ruby
mark_started                                 # outside txn; survives rollback

DB.transaction do
  HANDLERS.each { |klass| process_handler(klass) }
    # for each draft: upsert by idempotency_key; replace sources

  regenerate_journal_entries
    # delete stale JEs+lines; emit ONE consolidated accrual JE for the
    # close (a DR/CR pair per posted-or-approved accrual, line-level
    # accrual_id for trace) + ONE paired reversal JE dated next biz day

  mark_completed
end

audit :run_completed
dispatch_llm_tasks                           # post-commit, on a fire-and-forget
                                             # Thread.new in production (sync in tests).
                                             # Runs narrate_flagged_accruals + summarize_close
                                             # so engine.run! returns immediately.
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

- AR: `ar_usage|<period_end>|<customer_code>` (one accrual per customer per close)
- AP: `ap_gr_not_invoiced|<period_end>|<receipt_id>` (one accrual per receipt per close)

Re-running the engine for the same close: existing rows update in place; if amount changed, an `audit_event` records the delta. Period scoping in the AP key prevents two closes for different period_ends from fighting over a shared GR-not-invoiced row.

**UX guard on the idempotent server.** The `/closes` index runs a browser-side `confirm()` when the user submits Run Engine for a `period_end` that already has a close, showing the existing status / accrual count / flagged count / total USD. The server behavior doesn't change. Re-runs are still idempotent, decisions are still preserved, audit deltas are still written. The warning exists so a controller doesn't accidentally recompute a close they thought was settled. (Programmatic POSTs bypass the warning; the server-side contract is the safety net.)

## 5a. Review workflow: flagged accruals stay off the JE

The brief weighs "what gets auto-posted, what gets flagged for human review, what gets blocked" at 15%. The engine encodes this as an accrual `status` state machine:

| Status | Set by | Posts to JE? |
| --- | --- | --- |
| `posted` | engine (no anomaly detected) | ✓ |
| `flagged` | engine (anomaly detected) | ✗ awaiting controller decision |
| `approved` | controller (was flagged, accept) | ✓ |
| `rejected` | controller (was flagged, decline) | ✗ |
| `blocked` | engine (can't post) | ✗ |

`Engine#generate_consolidated_entries` filters by `status IN (posted, approved)`. A flagged accrual is real (idempotency key, source links, FX detail) but it stays off the close's GL output until a human decides, which is exactly what flagging should mean.

UI affordances:

- **Close overview banner** shows "Awaiting review (N)" with inline Approve/Reject buttons per accrual + a "View detail" link.
- **Accrual drill-through page** has Approve/Reject buttons inside the flagged box, alongside the AI review note. Approved/rejected accruals show a status banner with a "Reset to flagged" link to revert.
- `POST /closes/:id/accruals/:aid/review?decision=approved|rejected|reset` is the API. After the status flip, the route calls `Engine#regenerate_journal_entries` so the consolidated JE updates in place. Approving an accrual lands it on the JE immediately.

**Engine re-runs preserve human decisions.** If a controller approves an accrual then re-runs the engine, `Engine#upsert_accrual` keeps the `approved` status (instead of reverting to `flagged` from the recomputed draft). Amount changes still get an `accrual_amount_changed` audit event so the controller can decide whether to reset for re-review. Each transition writes `accrual_approved` / `accrual_rejected` / `accrual_reflagged` audit events with prev→current status payload.

**Blocked is also a real engine state, not just an enum value.** `Accruals::Handlers::ApGoodsReceiptNotInvoiced` emits a `blocked` draft (rather than raising) when a PO references a GL account that doesn't exist in `gl_accounts`, so one bad row doesn't crash the whole month-end close. The blocked accrual persists with `gl_*_account_id` nullable, the reason captured in `flagged_reason`, and an `accrual_blocked` audit event written on the transition into the state. The close-overview UI surfaces a separate red **Blocked: cannot post** banner (no Approve/Reject affordance because the action is "fix the data and re-run," not "decide"). Re-running after the GL is added picks up the corrected coding and the accrual transitions to `posted`.

## 5b. Close lifecycle and central audit

Three operations a controller can take on an existing close: **re-run**, **delete**, or **reset all**. Each is audit-defensible.

- **Re-run** routes through the same `POST /closes` flow. The route reuses the existing `CloseRun` row by `period_end`, the engine upserts accruals by idempotency key, and human decisions (approved/rejected) survive the recompute. Browser-side `confirm()` warns the controller; the server treats it as idempotent regardless.
- **Per-close delete** (`POST /closes/:id/delete`) cascades through journal lines, journal entries, accrual sources, audit events, accruals, and the close run itself, all in one transaction. FK order is deliberate: audit events go before accruals because `audit_events.accrual_id` references them. Other closes are untouched.
- **Wipe All Data** (`POST /closes/reset`) wipes every table in one transaction: engine state plus imported reference and transaction data. After confirm the user lands back on `/import` on a clean DB. Useful as a demo affordance; would not exist in production.

For audit defensibility after a delete, **a `close_deleted` audit event is written before the cascade**, with `close_run_id` deliberately set to `nil` so the row isn't itself removed by `AuditEvent.where(close_run_id: close_run.id).delete`. The payload snapshots `deleted_close_run_id`, `period_end`, `status`, `accrual_count`, `flagged_count`, `journal_entry_count`, and `total_amount_usd`. The row survives its own subject.

The central `/audit` page lists every event across every close, ordered most-recent first, with active-close rows linking back to that close's audit tab and deleted-close rows rendered in red with the snapshotted period date and a `(deleted)` tag. This is the only place where deleted-close history remains visible after the cascade.

## 6. Multi-currency

The price book is USD-only (`list_unit_price_usd`). `Customer.currency` is the _display_ currency. For non-USD-billed customers (CUS-1002 EUR):

- `amount_usd`: canonical, computed from `quantity × USD list price`
- `amount_billing_ccy = amount_usd / fx_rate` (display only)
- `fx_rate`: snapped at `period_end` via `FxRate.lookup!`
- All journal lines are USD

Real-world refinement: a per-customer or per-SKU price book in non-USD currencies would land here without engine changes; just an FX lookup at price-resolution time.

## 7. Consolidated journal entries + reversing entries

The engine produces **exactly two journal entries per close run**: one accrual JE dated `period_end` plus one paired reversal JE dated `BusinessCalendar.next_business_day(period_end)` with DR/CR signs swapped. Each accrual contributes 2 lines (DR + CR) to each JE, and `journal_lines.accrual_id` carries the line-level traceback so an auditor can drill from any line back to the originating accrual + sources.

Why consolidated rather than one-JE-per-accrual: it matches how a controller actually posts to NetSuite. Month-end is normally a single big JE per direction with many lines, not N tiny JEs. Calendar covers US-Fed holidays for 2026-27. For the anchor: Mar 31 (Tue) → reversal dated Apr 1 (Wed).

## 8. Calendar-month bound

The unbilled window is:

```
[ max(last_invoice_end + 1, first_day_of_period_month), period_end ]
```

Without the month bound, an Apr 30 close would sweep in March's already-handled events (no April invoices have been issued in the anchor). The bound makes per-period closes well-defined.

## 9. Source traceability

Each `Accrual` has many `AccrualSource` rows, polymorphic to `UsageEvent`, `GoodsReceipt`, or `PoLine`. The drill-through page resolves them inline; the CSV export includes a `source_refs` column so an auditor can trace any GL line back to the underlying records.

**Refs use natural XLSX ids, not internal database PKs.** `AccrualSource#natural_ref` maps each polymorphic source to its human-meaningful identifier: `event_id` for `UsageEvent`, `receipt_id` for `GoodsReceipt`, `"<po_number>/<po_line_ref>"` for `PoLine`, and so on. The CSV output reads `UsageEvent#evt_u0001;UsageEvent#evt_u0007` and `GoodsReceipt#GR-2026-0042;PoLine#PO-2026-0188/L1`, directly matchable against the rows in the source XLSX. Falls back to the internal PK if a source row was deleted upstream.

## 10. Anomaly detection (statistical): the stretch I picked

The brief lists three optional stretch tracks (AP subscription, AP milestone, AR anomaly detection) and asks me to pick one and explain why. **I picked AR anomaly detection** because it directly serves the 15%-weighted "Business judgment in surfacing" criterion. Without it, the AR handler would post every accrual silently, leaving the controller to spot a 6σ usage spike by eye. It also pairs naturally with the LLM application: the detector produces the *structured* signal (date, qty, median, z-score), the LLM produces the *plain-English* paraphrase, and the review workflow gives the controller the *decision* affordance. One feature, three rubric criteria covered.

**Algorithm**: median + MAD (Median Absolute Deviation), scaled by 1.4826 for normal-ish data, with a 3σ-equivalent threshold. Per-customer-per-SKU baseline from prior history. The seeder augments the anchor's 9 days of real telemetry with 30 days of synthetic prior-period events (disclosed; deterministic via `Random.new(42)`).

**Why MAD over a learned model**: at this scale (small N, no labeled training data, audit needs to be fully explainable), classical statistics is the right tool. The detector isn't skewed by outliers in its own baseline (mean+stddev would shift after a single spike), is deterministic, and is traceable. Returns `nil` z-score when the baseline is too small (<7) or has zero MAD; "no opinion" is honest.

For the anchor's seeded outlier (CUS-1001 Mar 30, 25h vs ~10h median): z ≈ 6.1, well above threshold. The accrual still books at actual quantity per spec; the flag is for human review, not auto-correction.

## 11. AI: LLM-narrated review notes (Gemini 2.5 Flash-Lite)

For each flagged accrual, the engine sends the **structured signal** to Gemini and persists a 2-3 sentence Controller-grade narrative.

**Grounded by design**:

- The prompt forbids inventing or recomputing amounts
- The LLM receives only fields the engine already computed (date, qty, median, z-score, customer label)
- Its job is plain-English paraphrasing, not arithmetic

**Example output** (live, against the seeded anchor):

> "The accrual for CUS-1001 includes 25.0 GPU-H100-HR units on 2026-03-30, which is 14.5 units above the median daily usage of 10.5 units. While this deviation is significant (z=6.1), it could represent valid, increased usage by the customer. The Controller should verify with the sales or account management team if this spike in usage was expected or communicated by Acme Robotics Inc. before approving the accrual."

**Implementation**:

- `Accruals::ReviewNarrator` is a thin service with an injectable `transport` callable (tests pass a lambda; production uses Net::HTTP)
- `thinkingConfig.thinkingBudget = 0` disables Gemini 2.5's internal reasoning tokens (we don't need CoT for paraphrasing)
- Runs **outside** the engine transaction, so an LLM error never rolls back the close
- Result cached on `accruals.review_narration` so the UI never blocks on a live API call
- Swappable to Anthropic / OpenAI by replacing one class; the engine is unaware

**Reliability around the API call**:

- **Audited outcomes**: every narration attempt writes one of `review_narration_added` (success, with model name), `review_narration_failed` (with the Gemini error string), or `review_narration_skipped` (typical reason: "GEMINI_API_KEY not set in environment")
- **UI surfacing via `narration_status` helper**: instead of silently hiding the section, the flagged-accrual UI reads the audit log and shows *why* a narration is missing. "AI review note · skipped · GEMINI_API_KEY not set" or "AI review note · failed · Gemini 429: quota exceeded". A reviewer can tell at a glance whether to add a key, retry later, or escalate.
- **Retry cooldown**: `Engine::NARRATION_RETRY_COOLDOWN_SECONDS` (10 min) gates re-attempts after a failure. Without it, repeated "Run engine" clicks would slam an already-rate-limited endpoint and pile up identical 429s. Cooldown is failure-scoped only; a config-level "skipped" event doesn't block immediate retry once the key is added.

## 12. Test strategy (113 specs)

| Layer                | What it covers                                                                                                                                                           |
| -------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Service              | Each handler against the brief's target cents (`AR=$362.50`, `AP=$100,000`); EUR fx math; mid-period churn; partial receipt; fully-invoiced skip                         |
| Engine               | Idempotent re-run, source replacement, consolidated-JE shape, audit events, amount-change detection, narration cooldown, summary cache + skip-when-already-summarized, blocked-status persistence + audit + JE exclusion |
| Review workflow      | Approve / reject / reset state transitions; flagged accrual stays off the JE; approve adds 4 lines (2 JEs × DR/CR); engine re-run preserves approved/rejected; 422 / 400 |
| Anomaly detector     | Outlier flag, baseline-too-small, zero-MAD edge case                                                                                                                     |
| Business calendar    | Weekend skip, federal-holiday skip, the close→reversal date specifically                                                                                                 |
| CSV exporter         | Header + per-line + balanced DR/CR; `source_refs` use natural XLSX ids, not internal PKs                                                                                 |
| Narrator + summarizer | Nil paths (no key), transport injection, error capture, prompt grounding on supplied numbers                                                                            |
| Seeder validation    | Happy path; missing file, missing sheet, renamed column, swapped columns                                                                                                 |
| Integration          | Full close against both bundled datasets → target match; calendar-month bound on a non-anchor period_end                                                                 |
| Close lifecycle      | Per-close delete cascades through journal lines, JEs, accrual sources, audit events, and accruals; sibling closes untouched; `close_deleted` audit row survives with `close_run_id=nil`                                  |
| Central `/audit`     | Empty-state hint; cross-close listing; `close_deleted` event surfaces with the snapshotted period date after deletion                                                    |
| `/data` browser      | Empty-state hint; default tab; all 11 tab labels in nav; switching by `?tab=` query; unknown-tab fallback                                                                |
| System (HTTP)        | Close flow (index → run → drill-through → CSV); engine-state reset; data-import upload + bundled-sample buttons; append vs replace mode; schema-validation 422; narration & summary UI states; review-action endpoints |

Each spec wraps in a Sequel transaction with rollback for isolation.

## 13. What I'd do differently with more time

| Refinement                                                                                           | Effort                                     |
| ---------------------------------------------------------------------------------------------------- | ------------------------------------------ |
| Per-customer unbilled window (denormalize `last_invoiced_through` on Customer) instead of global max | 30 min                                     |
| Move LLM narration + summary to Solid Queue / Que for retry + persistence (today's `Thread.new` loses work if the process restarts mid-call) | 1-2 hr                                     |
| Stretch handlers (AP subscription / straight-line and AP milestone; pattern is in place)             | 2 hr each                                  |
| Forecast model with prediction interval per customer / per close (the brief's third AI bullet)       | half day                                   |
| Real per-currency price book (anchor only had USD); FX path in handlers is ready for it              | 1 hr                                       |
| Postgres swap (Sequel adapter change + Render-managed Postgres or Neon free tier)                    | 30 min                                     |
| Multi-step review with approver/role separation (currently any controller can approve)               | 2-3 hr                                     |
| Auth + RBAC (out of scope per brief)                                                                 | 1 day with Devise/Sorcery or roll-your-own |

## Known limitations

- **SQLite + single-process**: fine for demo; replace with Postgres for prod.
- **No NetSuite API integration**: brief explicitly says CSV is sufficient.
- **LLM calls run on a fire-and-forget `Thread.new`** spawned after the DB transaction commits, so `engine.run!` returns immediately. The thread has no retry, no persistence across process death, and no concurrency control. A managed queue (Solid Queue / Que / Sidekiq) is the production-grade upgrade.
- **Anomaly detection is per-(customer, SKU)** with no cross-customer signal. Adequate for the seeded scenario. Richer detection (cross-customer, cross-SKU correlation, time-series decomposition) would land alongside the forecast model.
- **Audit events are append-only but unsigned**. For true compliance you'd hash-chain them or write to an immutable store.
