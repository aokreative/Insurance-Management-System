# Agent Commission & Payouts — Design

**Date:** 2026-11-11
**Phase:** 2b (phase 2 = reconciliation ✅ → agent payouts → renewal pipeline)
**Status:** Approved in conversation; awaiting written-spec review

## Goal

Pay agents their share of the commission the agency actually receives, with
a traceable trail from insurer receipt → commission → agent earning → payout,
and give each agent a statement of what they were paid and why.

### Success criteria

- When money is applied to a commission (phase 2a receipts), the policy's
  agent automatically earns their rate × the applied amount; nothing is
  earned before the insurer pays.
- Rates can be changed without rewriting past earnings.
- An Owner/Manager can pay an agent everything owed up to a date in one
  step, recording method and reference, and no earning is ever paid twice.
- A reversal after payout is deducted from the agent's next payout.
- Each payout has a printable statement; each Agent can see their own
  earnings and payouts and nobody else's.

## Decisions

| Question | Decision |
|---|---|
| How agents are paid | Percentage of commission. |
| When earned | When the agency receives the commission (allocation applied). |
| Rate setup | Default rate per member + optional per-product-line overrides; rate snapshotted on each earning. |
| Payouts | Pay run per agent up to a date; each earning paid once; statement per payout. |
| Reversals | Negative earning, deducted from the next payout. |
| Model | Append-only earnings ledger driven by `commission_allocations`. |

Rejected: computing "owed" on the fly (rate changes rewrite history, no
statement lines); one mutable earning per commission (partial payouts get
messy).

## 1. Rates and earnings

### Rates

- `agent_rates`: `id`, `agency_id`, `user_id`, `product_line_id NULL`
  (NULL = default rate), `rate numeric(5,2)` (0–100), `updated_by`,
  `updated_at`. UNIQUE (`user_id`, `product_line_id`) with NULLs treated as
  equal for the default row (use a partial unique index for the NULL case).
- No rate for a member → that member earns nothing (e.g. an Owner who
  doesn't pay themselves).
- Lookup for an allocation: the policy's product-line override for the
  agent, else the agent's default, else none.

### Earnings

`agent_earnings` (append-only; no UPDATE except `payout_id` by the payout
RPCs):

| Column | Notes |
|---|---|
| `id`, `agency_id` | |
| `agent_id` | FK users |
| `kind` | `'commission'` \| `'reversal'` \| `'adjustment'` |
| `allocation_id` | NULL for adjustments; NOT a FK (the allocation may be deleted) |
| `reverses_earning_id` | for `'reversal'`: the earning it negates |
| `policy_id`, `commission_id` | FK … ON DELETE SET NULL |
| `policy_number`, `client_name` | snapshot text for statements |
| `base_amount numeric(12,2)` | allocation amount (negative for reversal); NULL for adjustments |
| `rate numeric(5,2)` | snapshot; NULL for adjustments |
| `amount numeric(12,2)` | earned = round(base × rate / 100, 2); negative for reversal; adjustment amount ≠ 0 |
| `earned_on date` | receipt `received_on`; reversal/adjustment = current_date |
| `note text` | required for adjustments |
| `payout_id` | NULL until paid |
| `created_by`, `created_at` | |

Rules:
- **On allocation INSERT** (AFTER trigger): agent = the policy's `agent_id`
  at that moment; skip if the receipt `is_opening_balance` or no rate
  applies; else insert a `'commission'` earning.
- **On allocation DELETE** (AFTER trigger, incl. cascades from commission or
  policy deletes): if a `'commission'` earning exists for that
  `allocation_id` and has not already been reversed, insert a `'reversal'`
  copying agent, rate, policy/client snapshot, with negated base and amount,
  `reverses_earning_id` set. Works when the policy row is already gone.
- Earnings are never deleted or edited (except `payout_id`).

### Access (RLS)

- `agent_rates`: SELECT for owner/manager of the agency; a member can SELECT
  their own rows.
- `agent_earnings`, `agent_payouts`: SELECT for owner/manager of the agency;
  an Agent (any member) can SELECT rows where `agent_id = auth.uid()`.
- No direct INSERT/UPDATE/DELETE for API roles on any of the three
  (REVOKE from anon, authenticated); writes only via RPCs/triggers.

## 2. Payouts, adjustments, statements

### Payouts

`agent_payouts`: `id`, `agency_id`, `agent_id`, `period_end date`,
`paid_on date`, `method` (`'mpesa'` \| `'bank'` \| `'cash'`), `reference`,
`amount numeric(12,2) > 0`, `voided_at`, `voided_by`, `created_by`,
`created_at`.

### RPCs (SECURITY DEFINER, `search_path` pinned, revoked from PUBLIC/anon, granted to authenticated)

| Function | Who | Behaviour |
|---|---|---|
| `set_agent_rates(p_user_id uuid, p_default_rate numeric, p_overrides jsonb) → void` | Owner | Replaces that member's rates; `p_default_rate` NULL removes the default; overrides `[{product_line_id, rate}]`; rates 0–100; member and product lines must be in the caller's agency. |
| `add_agent_adjustment(p_user_id uuid, p_amount numeric, p_note text) → uuid` | Owner | Inserts an `'adjustment'` earning; amount ≠ 0; note required. |
| `preview_agent_payout(p_user_id uuid, p_period_end date) → jsonb {lines, total}` | Owner/Manager | Unpaid earnings with `earned_on ≤ p_period_end` (adjustments/reversals by `earned_on` too), ordered by `earned_on, created_at`. |
| `create_agent_payout(p_user_id uuid, p_period_end date, p_paid_on date, p_method text, p_reference text) → jsonb {payout_id, amount, lines}` | Owner/Manager | Locks the agent's unpaid earnings up to the date (`FOR UPDATE`), sums them; total ≤ 0 → error; inserts the payout and sets `payout_id` on exactly those rows. Works for deactivated members. |
| `void_agent_payout(p_payout_id uuid) → void` | Owner | Sets `voided_at/by`, clears `payout_id` on its earnings; already voided → error. |
| `_backfill_agent_earnings(p_agency_id uuid) → int` | internal (revoked from API roles) | Creates `'commission'` earnings for existing non-opening-balance allocations that have none, using current rates. Idempotent. |

Errors (exact): 'Only the owner can do that' (42501), 'Only owners and
managers can do that' (42501), 'Pick an active member of this agency'
(rates), 'Pick a member of this agency' (payouts/adjustments; deactivated
allowed), 'Rate must be between 0 and 100', 'Nothing to pay for this agent up
to that date', 'Add a note for this adjustment', 'Enter an amount',
'Payout not found' (P0002), 'This payout is already voided'.

### Statements

- `/payouts/:id`: agent, period end, paid on, method, reference, total;
  lines (earned on, policy no., client, base, rate, earned; adjustments show
  the note; reversals labelled "Reversal"); print stylesheet so "Save as
  PDF" gives a clean statement. Voided payouts show a "Voided" banner.
- Agents can open statements of their own payouts.

### Pages

- **Payouts** (`/payouts`, Owner/Manager; nav after Receipts): "Owed to
  agents" per member (unpaid total, last paid), payouts list (filter by agent),
  **New payout** (agent, pay-up-to date → preview lines + total → paid on,
  method M-Pesa/Bank transfer/Cash, reference → Confirm; disabled with
  "Nothing to pay for this agent up to that date" when total ≤ 0), Owner:
  **Add adjustment**, **Void**.
- **My earnings** (`/my-earnings`, Agents; Owner/Manager can also open it for
  themselves if they have rates): unpaid now, earned this month, earned this
  year, my payouts with statement links.
- **Settings → Team**: rates editor per member (Owner edits; Manager views):
  default % plus per-product-line overrides.

Money is handled in integer cents in the browser (`toCents`/`fromCents`).

## 3. Rollout, data, testing

### Migration 013 (`supabase/migrations/013_agent_payouts.sql`)

Tables + indexes (`agent_earnings(agent_id, payout_id)`,
`agent_earnings(allocation_id)`), RLS, earnings triggers on
`commission_allocations`, RPCs + grants, `_backfill_agent_earnings`
(not called by the migration — no rates exist yet).

### Demo data (after 013)

- Rates: Demo Agent 40% default, Life 50%; Demo Manager 20%; Owner none.
- `_backfill_agent_earnings(demo agency)` → earnings for the Britam/Jubilee
  phase-2a allocations held by agents with rates.
- One completed payout for the Demo Agent (paid on today, M-Pesa,
  reference `QK7H2M9XLP`) covering their earnings up to the day before the
  newest one, if any remain; otherwise up to today. Report what is left
  unpaid.

### Testing

`supabase/tests/013_agent_payouts.sql` (BEGIN…ROLLBACK, ALL PASSED):
rate lookup (override > default > none); snapshot unchanged after rate edit;
part payment earns part share; undo before payout nets to zero in the next
payout; undo after payout deducts from the next; commission/policy delete
creates the reversal; opening-balance receipt creates no earning; payout up
to a date excludes later earnings; total ≤ 0 refused; void returns earnings
to unpaid; an earning can't be in two payouts; backfill idempotent;
Agent sees only own rows and is refused every RPC; Manager refused rates,
adjustments, void; other agency invisible. Vitest for statement-total
helpers. Typecheck + build; Vercel preview; push.

## Out of scope

M-Pesa/B2C disbursement, tax/withholding deductions, splitting one
commission between agents, renewal pipeline (next spec).
