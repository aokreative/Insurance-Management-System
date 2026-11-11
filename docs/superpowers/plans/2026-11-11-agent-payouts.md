# Agent Payouts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Agents earn their rate × commission actually received (driven by receipt allocations), Owners/Managers pay them in per-agent pay runs, and every payout has a printable statement.

**Architecture:** Migration 013 adds `agent_rates`, `agent_earnings` (append-only ledger) and `agent_payouts`, with AFTER INSERT/DELETE triggers on `commission_allocations` and SECURITY DEFINER RPCs as the only write path. The React app adds a payouts data layer, a rates editor in Settings → Team, a Payouts page, a statement page and My earnings.

**Tech Stack:** Supabase Postgres 17 (RLS, plpgsql), React 19 + Vite + wouter + React Query + supabase-js + shadcn/ui, Vitest.

**Spec:** `docs/superpowers/specs/2026-11-11-agent-payouts-design.md`

## Global Constraints

- Supabase ERP Demo `frzjhknbocuaduuduxkk` (live; restore first if paused). Apply with MCP `apply_migration`; tests via `execute_sql` as `BEGIN; … ROLLBACK;` scripts ending `SELECT 'ALL PASSED' AS result;`, own fixtures (`@test.local` users; impersonate with `set_config('request.jwt.claims', …)` + `SET LOCAL ROLE authenticated`).
- Every new function: SECURITY DEFINER, `SET search_path = public`, `REVOKE EXECUTE … FROM PUBLIC, anon`, `GRANT … TO authenticated`; internal/trigger functions also revoked from authenticated. Role helpers: `current_user_agency_id()`, `current_user_role()`, `is_owner_or_manager()`.
- Exact enums: earning `kind` `'commission'|'reversal'|'adjustment'`; payout `method` `'mpesa'|'bank'|'cash'` (labels "M-Pesa", "Bank transfer", "Cash").
- Exact errors: 'Only the owner can do that' (42501), 'Only owners and managers can do that' (42501), 'Pick an active member of this agency', 'Pick a member of this agency', 'Rate must be between 0 and 100', 'Nothing to pay for this agent up to that date', 'Add a note for this adjustment', 'Enter an amount', 'Payout not found' (P0002), 'This payout is already voided'.
- Earned amount = `round(base × rate / 100, 2)`; reversal = exact negation of the original earning's base and amount.
- Opening-balance receipts (`insurer_receipts.is_opening_balance`) never create earnings.
- Browser money in integer cents via `toCents`/`fromCents` (`src/lib/reconcile.ts`).
- Frontend checks: `npx -y pnpm@10.28.0 run typecheck` (repo root); `npx -y pnpm@10.28.0 --filter @workspace/ams run test`; `VITE_SUPABASE_URL=https://x.supabase.co VITE_SUPABASE_ANON_KEY=x npx -y pnpm@10.28.0 run build` in `artifacts/ams` (rerun once on OOM).
- Commits as `aokreative <aokreative@gmail.com>` ending `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Branch `feat/agent-payouts`. No push until the end.

## Review Focus

1. **Two people create a payout for the same agent at once** — second sees 'Nothing to pay for this agent up to that date' or only what's left; no earning in two payouts. Test in Task 1 (sequential double-create + FOR UPDATE in code).
2. **Undo of an allocation whose policy was later reassigned** — the reversal goes to the agent who earned the original, not the current agent. Test in Task 1.
3. **Voiding a payout whose earnings include a reversal** — all lines, incl. negatives, return to unpaid; totals unchanged. Test in Task 1.
4. **Rate of 0%** — no earning row (0 amount rows are noise). Test in Task 1.
5. **Agent views another agent's statement URL** — page shows "Payout not found" (RLS returns nothing). Check in Task 3.

---

### Task 1: Migration 013 — tables, triggers, RPCs

**Files:** Create `supabase/migrations/013_agent_payouts.sql`, `supabase/tests/013_agent_payouts.sql`

**Interfaces — Produces:** tables/columns exactly as spec §1–2; triggers `trg_allocation_agent_earning` (AFTER INSERT) and `trg_allocation_agent_reversal` (AFTER DELETE) on `commission_allocations`; RPCs `set_agent_rates(p_user_id uuid, p_default_rate numeric, p_overrides jsonb) → void`, `add_agent_adjustment(p_user_id uuid, p_amount numeric, p_note text) → uuid`, `preview_agent_payout(p_user_id uuid, p_period_end date) → jsonb {lines: [{id, kind, earned_on, policy_number, client_name, base_amount, rate, amount, note}], total}`, `create_agent_payout(p_user_id uuid, p_period_end date, p_paid_on date, p_method text, p_reference text) → jsonb {payout_id, amount, lines}`, `void_agent_payout(p_payout_id uuid) → void`; internal `_backfill_agent_earnings(p_agency_id uuid) → int`.

- [ ] **Step 1: Failing test** (fixture: agency, owner o, manager m, agents a1/a2, insurer, product lines Motor + Life, annual policies for a1 (Motor) and a1 (Life), a2 Motor; use `create_insurer_receipt`/`apply_receipt_allocations` as o to apply money). Assertions:
  - rates: a1 default 40, Life 50 → Motor allocation 1000 earns 400.00, Life allocation 1000 earns 500.00; a2 no rate → no earning; a1 rate 0 on a product → no earning (Review Focus 4).
  - snapshot: after `set_agent_rates(a1, 30, '[]')`, existing earnings keep rate 40/50; a new allocation earns 30%.
  - part payment 333.33 at 40% earns 133.33.
  - opening-balance receipt (insert one via `_backfill_opening_balances`-style superuser insert with `is_opening_balance=true` + allocation) → no earning.
  - undo before payout: `undo_commission_allocation` → reversal −400; preview total for a1 excludes both net (they sum to 0).
  - undo after payout: payout includes +400; undo → reversal −400 unpaid; next preview total −400 and `create_agent_payout` raises 'Nothing to pay for this agent up to that date' until more earnings exceed it.
  - reassign then undo (Review Focus 2): `reassign_client` moves the policy to a2, then undo → reversal belongs to a1.
  - deleting the commission (as o) → reversal created with the policy snapshot; deleting the policy → same.
  - payout up to a date excludes later `earned_on`; two sequential `create_agent_payout` calls → second raises 'Nothing to pay…' (Review Focus 1); no earning has two payouts.
  - void: payout containing a reversal → all its earnings back to unpaid, `voided_at` set; second void → 'This payout is already voided'.
  - adjustments: owner adds +2500 'Bonus' → in preview; empty note → 'Add a note for this adjustment'; 0 → 'Enter an amount'.
  - `_backfill_agent_earnings` creates missing earnings once; second call returns 0.
  - access: as a1 — sees own earnings/payouts only, 0 rows of a2's, every RPC raises its 42501 message; as m — preview/create allowed, `set_agent_rates`/`add_agent_adjustment`/`void_agent_payout` raise 'Only the owner can do that'; direct INSERT/UPDATE on the three tables raises insufficient_privilege; other agency's payout id → 'Payout not found'.
- [ ] **Step 2: Run → RED.**
- [ ] **Step 3: Write 013.** Reversal trigger reads the original earning (by `allocation_id`, `kind='commission'`, not yet reversed) — never the policy — so it works after cascades.
- [ ] **Step 4: Apply** `013_agent_payouts`; run tests 006–013 → ALL PASSED (split large files into separate BEGIN…ROLLBACK runs if needed).
- [ ] **Step 5: Commit** `feat(db): agent rates, earnings ledger and payouts`

### Task 2: Data layer, rates editor, Payouts + statement + My earnings pages

**Files:** Create `src/hooks/payouts.ts`, `src/lib/payouts.ts` (+ `payouts.test.ts`), `src/pages/payouts.tsx`, `src/pages/payout-detail.tsx`, `src/pages/my-earnings.tsx`, `src/components/team/AgentRatesDialog.tsx`; Modify `src/lib/types.ts`, `src/App.tsx`, `src/layouts/AppLayout.tsx`, `src/pages/settings.tsx`.

**Interfaces — Consumes:** Task 1 RPCs. **Produces:** types `AgentRate`, `AgentEarning`, `AgentPayout`, `PayoutMethod`; hooks `useAgentRates(userId?)`, `useSetAgentRates()`, `useAgentEarnings({ agentId?, unpaidOnly? })`, `useOwedToAgents()` → `{agentId, name, unpaid, lastPaidOn}[]`, `usePayouts({ agentId? })`, `usePayout(id)` (payout + its earnings), `usePreviewPayout(agentId, periodEnd)`, `useCreatePayout()`, `useVoidPayout()`, `useAddAdjustment()`; all mutations invalidate `['agent-earnings']`, `['payouts']`, `['payout']`, `['owed-to-agents']`, `['agent-rates']`. Pure helpers in `lib/payouts.ts`: `sumCents(lines: {amount: number|string}[]): number`, `earningLabel(e): string` ("Commission" / "Reversal" / note for adjustments), `methodLabel(m): string`.

- [ ] **Step 1:** Vitest for `sumCents` (mixed strings/numbers, negatives, `'0.10'+'0.20'` = 30 cents), `earningLabel`, `methodLabel` → RED → implement → GREEN.
- [ ] **Step 2:** Pages per spec §2 "Pages"/"Statements": Payouts (Owner/Manager; nav "Payouts" after Receipts, icon `Wallet`), New payout dialog (agent select incl. deactivated members with "(removed)" suffix, pay-up-to date default today → preview table + total → paid on, method, reference → Confirm; disabled + "Nothing to pay for this agent up to that date" when total ≤ 0); Owner: Add adjustment dialog, Void with confirm. `/payouts/:id` statement with `@media print` styles hiding nav/buttons, "Voided" banner, "Payout not found" when no row (Review Focus 5). `/my-earnings` (nav "My earnings" for Agents; also shown to Owner/Manager when they have a rate): unpaid now, earned this month, this year, my payouts with statement links. Settings → Team: "Rates" button per member opening AgentRatesDialog (default % + product-line overrides; Owner edits, Manager read-only).
- [ ] **Step 3:** Typecheck, vitest, build GREEN. Confirm each PostgREST select string parses via anon curl (returns `[]`).
- [ ] **Step 4: Commit** `feat(app): agent rates, payouts, statements and my earnings`

### Task 3: Demo data, README, verification

**Files:** Modify `README.md`

- [ ] **Step 1:** As demo Owner `e01ee698-7800-43cd-9615-ef9376d32136` (agency `00ca4ec4-7ca5-4f84-a9ef-ef8b6e3b006c`, committed transaction): `set_agent_rates` Demo Agent (agent@ams.co.ke) 40 + Life 50; Demo Manager (manager@ams.co.ke) 20; then superuser `SELECT _backfill_agent_earnings('<agency>')`. Create one Demo Agent payout (paid on today, 'mpesa', 'QK7H2M9XLP') with `p_period_end` = the day before their latest `earned_on` if that leaves ≥1 earning unpaid and the paid total > 0, else today. Report rows created, payout amount, what remains unpaid.
- [ ] **Step 2:** Verify as demo Agent (rolled back): sees own earnings/payout only; opening a manager's payout id returns nothing.
- [ ] **Step 3:** README: Database row 013; "Agent commission & payouts" section (earn on receipt, rates & overrides, payouts, reversals, adjustments, who can do what); test list 006–013; phase plan line "✅ Agent commission & payouts".
- [ ] **Step 4: Commit** `docs: agent payouts`. No push.
