# Statement Reconciliation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Record insurer payments as receipts (statement lines and/or lump sums), apply them to commissions, and derive every commission's received amount and status in the database.

**Architecture:** Three new tables (`insurer_receipts`, `statement_lines`, `commission_allocations`) written only through SECURITY DEFINER RPCs; triggers derive `commission_transactions.amount_received/status` and `policies.commission_received` from allocations. The React app gets a Receipts area and a three-step Record-receipt page; matching/paste logic lives in a pure, unit-tested module.

**Tech Stack:** Supabase Postgres 17 (RLS, plpgsql, Storage), React 19 + Vite + wouter + React Query + supabase-js, shadcn/ui, Vitest (new, unit tests only).

**Spec:** `docs/superpowers/specs/2026-11-03-statement-reconciliation-design.md`

**Deviation from spec:** the spec's single migration 009 is split into `009_reconciliation_schema.sql`, `010_reconciliation_rpcs.sql`, `011_receipts_storage_and_opening_balances.sql` so each DB task applies and tests independently. Combined content is the spec's.

## Global Constraints

- Supabase project ERP Demo `frzjhknbocuaduuduxkk` (live; restore it first if paused). Apply with MCP `apply_migration`; test with `execute_sql`. Tests are `BEGIN; … ROLLBACK;` scripts ending `SELECT 'ALL PASSED' AS result;`, fixtures build their own agency (`@test.local` users, impersonation via `set_config('request.jwt.claims', …)` + `SET LOCAL ROLE authenticated`).
- Every new function: SECURITY DEFINER, `SET search_path = public`, `REVOKE EXECUTE … FROM PUBLIC, anon`, `GRANT … TO authenticated`; internal/trigger functions revoked from authenticated too. Role check via existing `public.is_owner_or_manager()`; error `'Only owners and managers can do that'` (42501).
- Exact enums: `commission_basis` `'annual'|'per_premium'`; `premium_frequency` `'monthly'|'quarterly'|'half_yearly'|'yearly'`; commission `status` `'pending'|'part_paid'|'received'`; commission `source` `'expected'|'statement'`.
- Exact error messages: `'Applied amount exceeds the receipt amount'`, `'That commission is already fully received'`, `'That policy is not with this insurer'`, `'Undo the applied amounts before deleting this receipt'`, `'Receipt not found'` (P0002), `'Commission received is recorded through receipts'` (42501).
- Annual expected commission: `amount = premium_amount * commission_rate / 100`, `expected_date = start_date + 30`, notes `'Expected commission'`.
- Overdue (never stored): `status IN ('pending','part_paid') AND expected_date < current_date`.
- Policy-number normalisation: lower-case, remove spaces, `-`, `/`, `.`.
- Money in the browser is handled as integer cents in `lib/reconcile.ts`; 2-decimal numeric in Postgres.
- Storage bucket `receipts`, private, 10 MB, `application/pdf`, path `{agency_id}/{uuid}.pdf` (refines the spec's `{receipt_id}`: the file is uploaded before the receipt exists, because receipts have no direct UPDATE).
- Frontend checks: `npx -y pnpm@10.28.0 run typecheck` (repo root); `VITE_SUPABASE_URL=https://x.supabase.co VITE_SUPABASE_ANON_KEY=x npx -y pnpm@10.28.0 run build` (artifacts/ams, 2–3 min).
- Commits as `aokreative <aokreative@gmail.com>` ending `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Branch `feat/statement-reconciliation`. No push.

## Review Focus

1. **Negative statement lines** (reversals/clawbacks like `-1,250.00` or `(1,250.00)`) — saved on the receipt but never applied; shown as "Reversal — not applied". Tests in Tasks 2 and 4.
2. **Pasted numbers with thousands separators and currency text** (`KES 12,345.00`, `Ksh 1,000`) — parse to cents correctly; commas inside numbers must not split columns. Test in Task 4.
3. **Same policy twice on one statement** — the second line applies to what remains (then the next-oldest year); nothing double-counted. Test in Task 2.
4. **Lines total larger than the amount received** — Confirm is blocked in the UI with the difference shown; the RPC rejects with 'Applied amount exceeds the receipt amount'. Tests in Tasks 2 and 7.
5. **Per-premium line with no period** — commission period and expected date fall back to the receipt's `received_on`. Test in Task 2.

---

### Task 1: Schema, triggers and RLS (migration 009)

**Files:**
- Create: `supabase/migrations/009_reconciliation_schema.sql`
- Create: `supabase/tests/009_reconciliation_schema.sql`

**Interfaces:**
- Produces: the policy and commission columns, the three tables, CHECKs, indexes (`commission_allocations(commission_id)`, `commission_allocations(receipt_id)`, `statement_lines(receipt_id)`, `policies(agent_id)`), RLS per spec §1 Access; triggers: `trg_commission_status` (BEFORE INSERT/UPDATE on commission_transactions: derive status; reject JWT-caller change of `amount_received` with the exact 42501 message — exempt when `auth.uid() IS NULL` or when a transaction-local flag `app.allocating = 'on'` is set by the allocation trigger), `trg_allocation_recompute` (AFTER INSERT/DELETE on commission_allocations: set flag, recompute `amount_received` = Σ allocations, recompute `policies.commission_received` = Σ `amount_received` of its commissions), `trg_policy_expected_commission` (AFTER INSERT on policies, annual only).

- [ ] **Step 1: Write the failing test.** Fixture: agency, owner `o`, agent `a1`, insurer `ins`, client, one annual policy and one per-premium policy (`premium_frequency='monthly'`, `instalment_premium=1000`). Assertions:
  - annual policy insert created exactly one commission: amount = premium×rate/100, `expected_date = start_date + 30`, `status='pending'`, `source='expected'`; per-premium insert created none.
  - per-premium insert without `premium_frequency` raises check_violation.
  - as superuser insert an allocation of half → commission `part_paid`, `amount_received` = half, policy `commission_received` = half; second allocation for the rest → `received`; delete one allocation → back to `part_paid` and tallies drop.
  - as `o` (JWT): `UPDATE commission_transactions SET amount_received = 1` raises 42501 'Commission received is recorded through receipts'; `UPDATE … SET status='received'` leaves status derived (still `pending`).
  - as `a1`: `count(insurer_receipts)=0`, `count(statement_lines)=0`, `count(commission_allocations)=0`; direct INSERT into each raises insufficient_privilege.
  - as `o`: direct INSERT into each of the three tables raises insufficient_privilege (RPC-only writes).
  - existing rows with `status='overdue'` were converted: `SELECT count(*) FROM commission_transactions WHERE status='overdue'` = 0.
- [ ] **Step 2: Run → RED** (`column "commission_basis" does not exist`).
- [ ] **Step 3: Write `009_reconciliation_schema.sql`** in spec §3 order steps 1–3 (no RPCs, no backfill). Drop the old status CHECK, `UPDATE … SET status='pending' WHERE status='overdue'`, then add the new CHECK.
- [ ] **Step 4: Apply** `009_reconciliation_schema`; re-run tests 006, 007, 008 and 009 → all ALL PASSED (006 may assert old statuses — if so, update only those assertions and note it in the report).
- [ ] **Step 5: Commit** `feat(db): receipts schema and derived commission status`

### Task 2: Reconciliation RPCs (migration 010)

**Files:**
- Create: `supabase/migrations/010_reconciliation_rpcs.sql`
- Create: `supabase/tests/010_reconciliation_rpcs.sql`

**Interfaces:**
- Consumes: Task 1 tables/triggers.
- Produces: `create_insurer_receipt(p_insurer_id uuid, p_received_on date, p_amount numeric, p_bank_reference text, p_file_path text, p_lines jsonb, p_allocations jsonb) → jsonb {receipt_id uuid, applied numeric, unapplied numeric}`; `link_statement_line(p_line_id uuid, p_policy_id uuid) → jsonb {applied numeric}`; `undo_commission_allocation(p_allocation_id uuid) → void`; `delete_insurer_receipt(p_receipt_id uuid) → void`. `p_lines` items `{policy_number, client_name, premium, commission, period, policy_id}` (period ISO date or null, policy_id uuid or null); `p_allocations` items `{commission_id, amount}`. Drops `mark_overdue_commissions()`. Internal helper `_apply_line(p_line_id uuid, p_budget numeric) RETURNS numeric` (amount applied), revoked from API roles.

- [ ] **Step 1: Write the failing test.** Fixture: agency (o, m, a1), insurers `ins1`, `ins2`; annual policies P1 (expected 5,000), P2 (expected 2,000, two years: add a second expected commission dated a year later), P3 on `ins2`; per-premium policy L1 on `ins1`. Assertions:
  - full line (P1, 5,000) → P1 commission `received`; result `applied=5000, unapplied=receipt−5000`.
  - short line (P1 in a fresh fixture, 3,000) → `part_paid` 3,000.
  - over line (P1, 6,000; receipt 6,000) → applies 5,000, `unapplied=1000`.
  - same policy twice (P2 lines 1,500 and 1,500) → older year `received` (2,000), newer year `part_paid` 1,000.
  - per-premium line (L1, 800, period 2026-10-01) → new commission `source='statement'`, `amount=800`, `period='2026-10-01'`, `received`; with `period` null → `period` and `expected_date` = `received_on`.
  - negative line (P1, −1,250) → line stored, nothing applied, P1 unchanged.
  - unmatched line (policy_id null) → stored with `policy_id NULL`, nothing applied; `link_statement_line(line, P1)` then applies from unapplied money.
  - allocations-only receipt (`p_lines='[]'`) applying two commissions → both updated.
  - lines/allocations totalling more than `p_amount` → raises 'Applied amount exceeds the receipt amount' and nothing persists.
  - allocation to an already-received commission → 'That commission is already fully received'; line with policy P3 on an `ins1` receipt → 'That policy is not with this insurer'.
  - `undo_commission_allocation` on the L1 allocation → statement-sourced commission deleted; on a P1 allocation → P1 back to pending.
  - `delete_insurer_receipt` with allocations → 'Undo the applied amounts before deleting this receipt'; after undoing all → succeeds and lines are gone; unknown id → 'Receipt not found'.
  - as `a1`: every RPC raises 'Only owners and managers can do that'; as `m`: create succeeds.
  - receipt in another agency is invisible to `o` and `link_statement_line`/`undo`/`delete` on it raise 'Receipt not found'.
  - `mark_overdue_commissions` no longer exists.
- [ ] **Step 2: Run → RED** (`function create_insurer_receipt(...) does not exist`).
- [ ] **Step 3: Write `010_reconciliation_rpcs.sql`.** Annual lines apply oldest `expected_date` first across the policy's commissions with remaining > 0, capped by the line's commission and the receipt's remaining budget; lock the receipt row `FOR UPDATE` and the touched commission rows in id order.
- [ ] **Step 4: Apply** `010_reconciliation_rpcs`; run tests 006–010 → all ALL PASSED.
- [ ] **Step 5: Commit** `feat(db): receipt, link, undo and delete RPCs`

### Task 3: Storage bucket and opening balances (migration 011)

**Files:**
- Create: `supabase/migrations/011_receipts_storage_and_opening_balances.sql`
- Create: `supabase/tests/011_opening_balances.sql`

**Interfaces:**
- Produces: bucket `receipts` + storage.objects policies (owner/manager of the agency named by the first path segment: insert/select/delete); `_backfill_opening_balances(p_agency_id uuid DEFAULT NULL) RETURNS int` (receipts created; NULL = all agencies; idempotent — skips agency×insurer pairs that already have an opening-balance receipt), revoked from API roles; the migration calls it once.

- [ ] **Step 1: Write the failing test.** Fixture agency with 2 insurers, 3 received commissions (with `received_date`s) and 1 pending; record each policy's `commission_received` before; call `_backfill_opening_balances(<fixture agency>)` → returns 2; each insurer has one receipt with `is_opening_balance`, amount = sum of its received commissions, `received_on` = latest received_date, notes 'Opening balance (before receipts were tracked)'; every policy's `commission_received` equals its before value; the pending commission untouched; calling again returns 0. Storage: `SELECT public FROM storage.buckets WHERE id='receipts'` = false, `file_size_limit = 10485760`, `allowed_mime_types = '{application/pdf}'`.
- [ ] **Step 2: Run → RED.**
- [ ] **Step 3: Write `011_…sql`.** Opening-balance allocations are inserted with the recompute trigger active (amounts already equal, so tallies are unchanged). The pre-existing received rows have `amount_received = 0` until backfilled — the backfill is what sets them.
- [ ] **Step 4: Apply** `011_receipts_storage_and_opening_balances`; run tests 006–011 → ALL PASSED. Then verify live: for the demo agency, `SELECT count(*) FROM commission_transactions WHERE status='received' AND amount_received <> amount` = 0 and the Σ `commission_received` over its policies equals 379317.00 (value before migration).
- [ ] **Step 5: Commit** `feat(db): receipts storage and opening balances`

### Task 4: Reconcile logic module + Vitest

**Files:**
- Create: `artifacts/ams/src/lib/reconcile.ts`, `artifacts/ams/src/lib/reconcile.test.ts`, `artifacts/ams/vitest.config.ts`
- Modify: `artifacts/ams/package.json` (devDependency `vitest`, script `"test": "vitest run"`)

**Interfaces:**
- Produces:
  - `toCents(input: string | number): number | null` — strips `KES`, `Ksh`, spaces and thousands commas; `(x)` or leading `-` → negative; invalid → null.
  - `fromCents(c: number): number`
  - `normalisePolicyNumber(s: string): string`
  - `type DraftLine = { policyNumber: string; clientName: string; premiumCents: number | null; commissionCents: number | null; period: string | null }`
  - `parsePastedLines(text: string): DraftLine[]` — per line: split on tab if any tab, else on runs of 2+ spaces, else on `,` only when that yields exactly 5 fields; columns in order policy no., client, premium, commission, period; blank lines skipped; period accepts `YYYY-MM-DD`, `DD/MM/YYYY`, `MM/YYYY` (→ first of month) else null.
  - `type MatchStatus = 'matched' | 'short' | 'over' | 'unmatched' | 'new_commission' | 'reversal'`
  - `matchLines(lines: DraftLine[], policies: { id: string; policy_number: string; commission_basis: 'annual'|'per_premium'; outstandingCents: number }[]): { line: DraftLine; policyId: string | null; status: MatchStatus; applyCents: number }[]` — consumes each policy's outstanding sequentially (Review Focus 3); negative commission → `reversal`, applyCents 0.
  - `totalCents(lines: DraftLine[]): number`

- [ ] **Step 1: Write failing tests** in `reconcile.test.ts`: `toCents('KES 12,345.00')===1234500`, `toCents('(1,250.00)')===-125000`, `toCents('abc')===null`; `normalisePolicyNumber('BRI/MP-2025/01111')==='brimp202501111'`; paste with tabs → 5 fields even when amounts contain commas; paste with 2+ spaces works; comma-separated 5-field line splits; `'10/2026'` period → `'2026-10-01'`; matchLines: matched/short/over/unmatched/reversal/new_commission; same policy twice consumes outstanding (second line `short` with remaining).
- [ ] **Step 2: Run** `npx -y pnpm@10.28.0 --filter @workspace/ams run test` → RED.
- [ ] **Step 3: Implement**; install vitest with `npx -y pnpm@10.28.0 --filter @workspace/ams add -D vitest` (lockfile updated).
- [ ] **Step 4: Run tests → GREEN;** typecheck passes.
- [ ] **Step 5: Commit** `feat(app): reconcile parsing and matching`

### Task 5: Data layer and Commissions page

**Files:**
- Modify: `artifacts/ams/src/lib/types.ts`, `artifacts/ams/src/hooks/queries.ts`, `artifacts/ams/src/pages/commissions.tsx`
- Create: `artifacts/ams/src/hooks/receipts.ts`

**Interfaces:**
- Consumes: Task 2 RPCs.
- Produces: types `CommissionBasis`, `PremiumFrequency`, `InsurerReceipt`, `StatementLine`, `CommissionAllocation`; `Policy` gains the four columns; `CommissionTransaction` gains `amount_received`, `period`, `source`, status union `'pending'|'part_paid'|'received'`. Hooks in `hooks/receipts.ts`: `useReceipts(filters?: { insurerId?: string; month?: string })`, `useReceipt(id)` (receipt + lines + allocations with commission/policy), `useCreateReceipt()` (calls `create_insurer_receipt`, args camelCase → p_ names), `useLinkStatementLine()`, `useUndoAllocation()`, `useDeleteReceipt()` (also removes the storage file), `useUploadReceiptPdf()` (`(agencyId, receiptId, file) → path`), `useInsurerMoneySummary()` → `{ insurerId, outstanding, overdue, unapplied }[]`. All receipt mutations invalidate `['receipts']`, `['commissions']`, `['policies']`, `['dashboard-metrics']`, `['insurer-money']`.

- [ ] **Step 1:** Update types; remove client-side tally writes and the expected-row insert from `useCreatePolicy`, `useUpdateCommission`, `useCreateCommission`, `useBulkMarkCommissionsReceived` (delete the bulk hook); typecheck → RED at call sites (lists them).
- [ ] **Step 2:** Implement `hooks/receipts.ts`; Commissions page: status column renders `Part-paid` with `received / expected`, overdue badge from the computed rule, Owner/Manager see a link to the paying receipt(s) (via allocations), "Record payment" dialog (date, amount, bank reference) → `useCreateReceipt` with one allocation; selection action "Record payment for selected" (disabled with tooltip "Select commissions from one insurer" when insurers differ) → one receipt, allocations = each remaining amount, receipt amount = their sum. Agents unchanged (read-only).
- [ ] **Step 3:** Typecheck + build GREEN; verify against DB as demo Owner inside BEGIN…ROLLBACK that the hook's select for commissions returns `amount_received` and the new statuses.
- [ ] **Step 4: Commit** `feat(app): receipts data layer and record payment`

### Task 6: Receipts list and detail pages

**Files:**
- Create: `artifacts/ams/src/pages/receipts.tsx`, `artifacts/ams/src/pages/receipt-detail.tsx`
- Modify: `artifacts/ams/src/App.tsx` (routes `/receipts`, `/receipts/new` placeholder → Task 7, `/receipts/:id`), `artifacts/ams/src/layouts/AppLayout.tsx` (nav "Receipts" after Commissions, Owner/Manager only, icon `Receipt`)

**Interfaces:**
- Consumes: Task 5 hooks.

- [ ] **Step 1: Implement** list (unapplied-money cards per insurer; table date, insurer, amount, applied, unapplied, status `Fully applied`/`Partly applied`/`Not applied`; filters insurer + month; "Record receipt" → `/receipts/new`) and detail (header with PDF link via signed URL; lines table with status badges, "Link to policy" for unmatched opening a policy search limited to the receipt's insurer; allocations table with Undo; Delete button enabled only when no allocations, confirm dialog). Opening-balance receipts show a muted "Opening balance" badge and no Delete.
- [ ] **Step 2:** Typecheck + build GREEN.
- [ ] **Step 3: Commit** `feat(app): receipts list and detail`

### Task 7: Record receipt flow

**Files:**
- Create: `artifacts/ams/src/pages/receipt-new.tsx`, `artifacts/ams/src/components/receipts/LinesGrid.tsx`, `artifacts/ams/src/components/receipts/MatchTable.tsx`, `artifacts/ams/src/components/receipts/AllocateOutstanding.tsx`

**Interfaces:**
- Consumes: Task 4 `parsePastedLines`, `matchLines`, `toCents`, `totalCents`; Task 5 `useCreateReceipt`, `useUploadReceiptPdf`.

- [ ] **Step 1: Implement** steps per spec §2 "Record receipt": Details (insurer select, date default today, amount, bank ref, PDF ≤10 MB) → Lines grid (Enter new row, Tab next cell, onPaste → `parsePastedLines`, running "Lines total KES x vs received KES y") → Match & apply (MatchTable with badges `Matched`/`Short`/`Over`/`Unmatched`/`New commission`/`Reversal — not applied`, policy search for unmatched; or AllocateOutstanding when there are no lines). Confirm disabled with message "Applied amount is KES {d} more than the amount received" when Σ applyCents > amount (Review Focus 4). On confirm: if a PDF was chosen, upload it first to `{agency_id}/{crypto.randomUUID()}.pdf` (receipts have no direct UPDATE, so the path must be known before create) and pass that path as `p_file_path`; if create then fails, delete the uploaded file. Navigate to `/receipts/{id}` with toast "Receipt recorded — KES {applied} applied, KES {unapplied} unapplied".
- [ ] **Step 2:** Typecheck + build GREEN; vitest still GREEN.
- [ ] **Step 3: Commit** `feat(app): record receipt flow`

### Task 8: Policy form, insurers totals, dashboard projection

**Files:**
- Modify: `artifacts/ams/src/pages/policies.tsx`, `artifacts/ams/src/pages/client-detail.tsx`, `artifacts/ams/src/pages/insurers.tsx`, `artifacts/ams/src/pages/dashboard.tsx`

**Interfaces:**
- Consumes: Task 5 types and `useInsurerMoneySummary`.

- [ ] **Step 1: Implement** policy forms: "Commission type" (Annual / Per premium; default Per premium when the selected product line's name is "Life"), and for Per premium: frequency select, "Amount per payment", optional "Later-years rate (%)"; zod refine requiring both when per premium. Insurers: Outstanding / Overdue / Unapplied columns (Owner/Manager). Dashboard: "Projected monthly (life)" StatCard per spec §2 formula, only when ≥1 per-premium active policy; Agents see their own ("My projected monthly (life)").
- [ ] **Step 2:** Typecheck + build GREEN.
- [ ] **Step 3: Commit** `feat(app): commission type on policies, insurer totals, life projection`

### Task 9: Demo data, README

**Files:**
- Modify: `README.md`

- [ ] **Step 1:** Run tests 006–011 → ALL PASSED.
- [ ] **Step 2: Demo data** (committed SQL via `execute_sql` as the demo Owner `e01ee698-7800-43cd-9615-ef9376d32136`, agency `00ca4ec4-7ca5-4f84-a9ef-ef8b6e3b006c`): convert Brian Mutua's Old Mutual Life and Kevin Omondi's ICEA LION Life policies to per premium, monthly, `instalment_premium` = premium/12; `create_insurer_receipt` for Britam dated 2026-10-31 with three lines — one matching an outstanding Britam commission in full, one short-paying another, one unmatched policy number `BRI/MP/2026/09999`; `create_insurer_receipt` for Jubilee (lump sum, no lines) applying to one outstanding Jubilee commission with KES 5,000 left unapplied. Pick the outstanding commissions by query; if Britam has fewer than two outstanding, use what exists and report it.
- [ ] **Step 3: README:** Database table rows 009–011; a "Receipts & reconciliation" section (what a receipt is, statuses, who can do it); `pnpm --filter @workspace/ams run test` under Run & Operate.
- [ ] **Step 4: Commit** `docs: receipts and reconciliation`. No push.
