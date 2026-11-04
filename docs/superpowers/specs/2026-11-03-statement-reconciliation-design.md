# Statement Reconciliation — Design

**Date:** 2026-11-03
**Phase:** 2a of the roadmap (phase 2 = reconciliation → agent commission & payouts → renewal pipeline, one spec each)
**Status:** Approved in conversation; awaiting written-spec review

## Goal

Make "commission received" trustworthy. Every shilling an insurer pays is
recorded once (as a **receipt**) and applied to specific commissions, so the
agency can see what each insurer has paid, what is still owed, and money it
cannot yet explain.

### Success criteria

- An Owner/Manager can record an insurer's PDF statement by typing/pasting its
  lines, and the app matches lines to policies and applies the money in one step.
- An Owner/Manager can record a lump-sum bank deposit and apply it by ticking
  outstanding commissions.
- A commission's received amount and status, and a policy's
  `commission_received`, are always the sum of what has been applied to it —
  computed in the database, never typed.
- Life/savings policies earn commission per premium actually paid; nothing
  shows as overdue for them.
- Agents see the received amount and status of their own commissions and
  nothing about receipts.
- Existing received commissions keep their totals after migration.

## Decisions

| Question | Decision |
|---|---|
| Phase 2 scope | Statement reconciliation, then agent payouts, then renewal pipeline — separate specs. Overdue chasing deferred. |
| Statement sources | Insurer-portal PDFs and lump-sum bank deposits. |
| How commission is earned | Both: **annual** (general insurance) and **per premium** (life/savings). |
| PDF import | Manual entry grid with paste; PDF attached for reference. No AI, no parsers. |
| Lump-sum deposits | User ticks the commissions it covers and types amounts. No auto-suggestion. |
| Money model | Receipts + allocations; status derived in the DB. |

Rejected: mutating commission rows directly (no audit, no partials); statement
lines as the only commission record (loses overdue tracking for annual policies).

## 1. Data model

### Policies (new columns)

| Column | Type | Notes |
|---|---|---|
| `commission_basis` | text NOT NULL DEFAULT `'annual'` | `'annual'` \| `'per_premium'` |
| `premium_frequency` | text NULL | `'monthly'` \| `'quarterly'` \| `'half_yearly'` \| `'yearly'`; required when per_premium |
| `instalment_premium` | numeric(12,2) NULL | amount per payment; required when per_premium |
| `renewal_commission_rate` | numeric(5,2) NULL | rate after the first 12 months; NULL = same as `commission_rate` |

CHECK: per_premium ⇒ `premium_frequency` and `instalment_premium` NOT NULL.

### Commission transactions (changes)

- Add `amount_received numeric(12,2) NOT NULL DEFAULT 0`.
- Add `period date NULL` (the premium period a per-premium commission is for).
- Add `source text NOT NULL DEFAULT 'expected'` — `'expected'` (created for an annual policy or by hand) \| `'statement'` (created from a statement line on a per-premium policy).
- `status` values become `'pending'` \| `'part_paid'` \| `'received'`. Existing `'overdue'` rows become `'pending'`.
- **Overdue** is not stored: `status IN ('pending','part_paid') AND expected_date < current_date`.
- A BEFORE INSERT OR UPDATE trigger sets `status` from `amount_received` vs `amount` (0 → pending; 0 < x < amount → part_paid; ≥ amount → received). JWT callers cannot change `amount_received` directly (42501 'Commission received is recorded through receipts'); only the allocation trigger does.
- `mark_overdue_commissions()` is dropped.

### Expected commission creation

An AFTER INSERT trigger on `policies`: when `commission_basis = 'annual'`,
insert one commission transaction — `amount = premium_amount * commission_rate / 100`,
`expected_date = start_date + 30`, `source = 'expected'`, notes
'Expected commission'. Per-premium policies get none. The frontend's
`useCreatePolicy` stops creating this row itself.

### New tables

**`insurer_receipts`**: `id`, `agency_id`, `insurer_id` (same agency),
`received_on date`, `amount numeric(12,2) > 0`, `bank_reference text`,
`file_path text` (storage object path), `notes text`,
`is_opening_balance boolean DEFAULT false`, `created_by`, `created_at`.

**`statement_lines`**: `id`, `agency_id`, `receipt_id`, `line_no int`,
`policy_number text` (as printed), `client_name text`, `premium numeric(12,2)`,
`commission numeric(12,2) NOT NULL`, `period date`, `policy_id uuid NULL`
(matched policy), `created_at`.

**`commission_allocations`**: `id`, `agency_id`, `receipt_id`,
`commission_id`, `statement_line_id NULL`, `amount numeric(12,2) > 0`,
`created_by`, `created_at`.

Constraints (enforced in the RPCs and re-checked by trigger):
- allocation's commission and receipt have the same `agency_id` and the
  commission's policy has the receipt's `insurer_id`;
- sum of allocations on a receipt ≤ receipt `amount`;
- sum of allocations on a commission ≤ commission `amount`.

An AFTER INSERT/DELETE trigger on `commission_allocations` recomputes the
commission's `amount_received` and the policy's `commission_received`
(sum over all its commissions).

### Access (RLS)

- `insurer_receipts`, `statement_lines`, `commission_allocations`: SELECT for
  owner/manager of the agency; **no** direct INSERT/UPDATE/DELETE for anyone —
  writes only via the RPCs below. Agents: no access.
- Agents keep SELECT on their own commission transactions (now including
  `amount_received` and `part_paid`).
- Storage bucket `receipts` (private): object path `{agency_id}/{receipt_id}.pdf`;
  owner/manager of that agency may upload/read/delete; 10 MB limit;
  `application/pdf` only.

### RPCs (SECURITY DEFINER, `search_path` pinned, revoked from PUBLIC/anon, granted to authenticated, owner/manager only)

| Function | Behaviour |
|---|---|
| `create_insurer_receipt(p_insurer_id uuid, p_received_on date, p_amount numeric, p_bank_reference text, p_file_path text, p_lines jsonb, p_allocations jsonb) → jsonb {receipt_id, applied, unapplied}` | One transaction. Inserts the receipt, then each line (`{policy_number, client_name, premium, commission, period, policy_id}`); a line with a `policy_id` is re-validated (same agency and insurer) and applied: **annual** → to that policy's outstanding commissions oldest `expected_date` first, up to the line's commission; **per_premium** → creates a `source='statement'` commission (`amount` = line commission, `period`, `expected_date` = `period` or `received_on`) and allocates it in full. Then applies `p_allocations` (`[{commission_id, amount}]`). Raises 'Applied amount exceeds the receipt amount' if allocations exceed `p_amount`. |
| `link_statement_line(p_line_id uuid, p_policy_id uuid) → jsonb {applied}` | Matches a previously unmatched line and applies it as above from the receipt's unapplied money. |
| `undo_commission_allocation(p_allocation_id uuid) → void` | Deletes the allocation; if its commission has `source='statement'` and no other allocations, deletes that commission too. |
| `delete_insurer_receipt(p_receipt_id uuid) → void` | Allowed only when the receipt has no allocations; deletes its lines. (The app deletes the storage file.) |

Errors (exact): 'Only owners and managers can do that' (42501),
'Applied amount exceeds the receipt amount', 'That commission is already fully received',
'That policy is not with this insurer', 'Undo the applied amounts before deleting this receipt',
'Receipt not found' (P0002).

## 2. Screens

### Receipts page (Owner/Manager; nav item "Receipts" after Commissions)

- Per-insurer **Unapplied money** summary at the top.
- Receipts table: date, insurer, amount, applied, unapplied, status
  (fully / partly / not applied); filters: insurer, month. Row → receipt detail
  (lines, allocations with Undo, PDF link, Link-to-policy for unmatched lines,
  Delete when nothing is applied).

### Record receipt (one page, three steps)

1. **Details** — insurer, date received, amount received, bank reference,
   optional PDF.
2. **Statement lines** (optional) — grid: policy no., client, premium,
   commission, period. Enter adds a row, Tab moves cells. Paste of
   tab- or comma-separated rows fills the grid. Running "lines total vs amount
   received" shown.
3. **Match & apply** — each line auto-matched to a policy of the chosen
   insurer by normalised policy number (lower-case; remove spaces, `-`, `/`,
   `.`). Badges: **Matched** (commission = outstanding), **Short**
   (less), **Over** (more; excess stays unapplied), **Unmatched** (search box
   to pick a policy, or leave). Per-premium policies always show **New
   commission**. Without lines: list of the insurer's outstanding commissions
   with checkbox + amount (pre-filled with the remaining amount).
   **Confirm** calls `create_insurer_receipt` once.

### Commissions page

- Status column shows **Part-paid** with "received / expected"; overdue badge
  uses the computed rule. Link to the paying receipt(s).
- "Mark received" → **Record payment** (dialog: date, amount, bank ref) which
  calls `create_insurer_receipt` with one allocation.
- Bulk "Mark received" → **Record payment for selected**: one receipt
  allocated across the selection; disabled unless all selected commissions
  share one insurer.

### Policy form

- **Commission type** select (Annual / Per premium). Default Per premium when
  the product line is "Life", else Annual. Per premium shows frequency,
  amount per payment, and optional later-years rate.

### Insurers page

- Per insurer: **Outstanding**, **Overdue**, **Unapplied** totals.

### Dashboard

- Unchanged figures keep working (they read `commission_received` /
  commission transactions). For agencies with per-premium policies, add a
  "Projected monthly (life)" figure = Σ over active per-premium policies of
  `instalment_premium` × rate / 100 × payments-per-month, where
  payments-per-month is 1 (monthly), 1/3 (quarterly), 1/6 (half-yearly),
  1/12 (yearly), and rate is `renewal_commission_rate` (if set) once the
  policy is more than 12 months past `start_date`, else `commission_rate`.
  Shown only when the agency has at least one per-premium policy.

## 3. Rollout, data, testing

### Migration 009 (`supabase/migrations/009_statement_reconciliation.sql`)

1. Policy columns + CHECK; commission columns; status values; `'overdue'` → `'pending'`.
2. Tables, indexes (`commission_allocations(commission_id)`, `(receipt_id)`, `statement_lines(receipt_id)`, `policies(agent_id)`), RLS.
3. Triggers: status, amount_received guard, allocation recompute, expected-commission-on-insert.
4. RPCs + grants; drop `mark_overdue_commissions`.
5. Storage bucket `receipts` + storage policies.
6. **Opening balances:** for each agency × insurer with commissions where
   `status = 'received'`, one receipt `is_opening_balance = true`,
   `received_on` = latest `received_date` (or today if none), `amount` = sum
   of those commissions' `amount`, notes 'Opening balance (before receipts
   were tracked)', and one allocation per commission for its full `amount`.
   Afterwards every policy's `commission_received` equals its value before the
   migration (asserted in the test).

### Demo agency data (applied after 009, not in the migration)

- Brian Mutua's Old Mutual Life and Kevin Omondi's ICEA LION Life policies →
  per premium, monthly, instalment = annual premium / 12.
- A **Britam statement** receipt with lines: one matched, one short-paid,
  one unmatched.
- A **Jubilee lump-sum deposit** partly applied, leaving unapplied money.

### App changes

- New: `pages/receipts.tsx`, `pages/receipt-new.tsx`, `pages/receipt-detail.tsx`,
  `hooks/receipts.ts`, `lib/reconcile.ts` (pure: `normalisePolicyNumber`,
  `parsePastedLines`, `matchLines`).
- Changed: `pages/commissions.tsx`, `pages/policies.tsx` + `client-detail.tsx`
  policy forms, `pages/insurers.tsx`, `pages/dashboard.tsx`,
  `layouts/AppLayout.tsx`, `App.tsx` routes, `lib/types.ts`, `hooks/queries.ts`
  (remove client-side commission tally and expected-row creation).

### Testing

- `supabase/tests/009_statement_reconciliation.sql` (BEGIN…ROLLBACK, prints
  ALL PASSED): full / short / over line; multiple receipts on one commission;
  per-premium line creates a received commission; undo (incl. statement-sourced
  delete); receipt total cap; commission total cap; insurer mismatch;
  cross-agency; status + `commission_received` recompute; delete-receipt rule;
  expected-commission trigger (annual yes, per-premium no); agent sees own
  `amount_received`, no receipts/lines/allocations; direct `amount_received`
  write denied; opening-balance totals preserved (re-run the backfill logic on
  a fixture).
- Vitest unit tests for `lib/reconcile.ts`.
- Typecheck + build; Vercel preview for the user before merge.

## Out of scope

Automatic PDF reading; bank-feed import; overdue chasing workflow;
agent commission splits and payouts (next spec); renewal pipeline (spec after).
