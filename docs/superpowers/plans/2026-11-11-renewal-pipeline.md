# Renewal Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Track each expiring policy through To contact → Contacted → Quoted → Renewed / Lost, with a one-step Renew that creates the linked new-term policy, lost reasons and a renewal rate.

**Architecture:** Migration 014 adds `agencies.agents_manage_renewals`, `policy_renewals` (one row per term), `renewal_activities` (append-only history), a `security_invoker` view `renewal_pipeline`, SECURITY DEFINER RPCs as the only write path, a reset trigger, and retires the placeholder reminders. The React app adds a renewals data layer, rebuilds `/renewals` around stage tabs, and touches policies, client, dashboard and settings.

**Tech Stack:** Supabase Postgres 17 (RLS, plpgsql), React 19 + Vite + wouter + React Query + supabase-js + shadcn/ui, Vitest.

**Spec:** `docs/superpowers/specs/2026-11-11-renewal-pipeline-design.md`

## Global Constraints

- Supabase ERP Demo `frzjhknbocuaduuduxkk` (live; restore first if paused). Apply with MCP `apply_migration`; tests via `execute_sql` as `BEGIN; … ROLLBACK;` scripts ending `SELECT 'ALL PASSED' AS result;`, own fixtures (`@test.local` users; impersonate with `set_config('request.jwt.claims', …)` + `SET LOCAL ROLE authenticated`).
- Every new function: SECURITY DEFINER, `SET search_path = public`, `REVOKE EXECUTE … FROM PUBLIC, anon`, `GRANT … TO authenticated`; trigger/internal functions also revoked from authenticated. Role helpers: `current_user_agency_id()`, `current_user_role()`, `is_owner_or_manager()` (NULL/false for deactivated users).
- "Today" in SQL = `(now() AT TIME ZONE 'Africa/Nairobi')::date`. Pipeline window = `status = 'active' AND expiry_date <= today + 90`, or a renewal row exists.
- Exact enums: stage `'to_contact'|'contacted'|'quoted'|'renewed'|'lost'`; activity kind `'contact'|'quote'|'renewed'|'lost'|'reopened'|'reset'`; channel `'phone'|'whatsapp'|'sms'|'email'|'in_person'` (labels "Phone", "WhatsApp", "SMS", "Email", "In person"); lost reason `'price'|'competitor'|'no_longer_needed'|'no_response'|'other'` (labels "Price", "Went to another agent/insurer", "No longer needs cover", "No response", "Other"). Stage labels "To contact", "Contacted", "Quoted", "Renewed", "Lost".
- Exact errors (spec §2): 'Only the owner can do that' (42501), 'Only owners and managers can do that' (42501), 'You can only update renewals for your own policies' (42501), 'Renewal updates by agents are turned off for this agency' (42501), 'Policy not found' (P0002), 'This policy is not due for renewal', 'This renewal is already closed', 'Only a lost renewal can be reopened', 'Pick a channel', 'Enter the date', 'Pick an insurer of this agency', 'Enter a premium', 'Pick a reason', 'Pick a product line of this agency', 'Enter the policy number', 'Expiry must be after the start date', 'That policy number is already used by an active policy'.
- Browser money in integer cents via `toCents`/`fromCents` (`src/lib/reconcile.ts`); dates local (`format(d,'yyyy-MM-dd')`, never `toISOString().split`).
- Frontend checks: `npx -y pnpm@10.28.0 run typecheck` (repo root); `npx -y pnpm@10.28.0 --filter @workspace/ams run test`; `VITE_SUPABASE_URL=https://x.supabase.co VITE_SUPABASE_ANON_KEY=x npx -y pnpm@10.28.0 run build` in `artifacts/ams` (rerun once on OOM).
- Commits as `aokreative <aokreative@gmail.com>` ending `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Branch `feat/renewal-pipeline`. No push until the end.

## Review Focus

1. **Two people act on the same renewal at once** (e.g. one renews while another marks lost) — the second gets 'This renewal is already closed'; never two new policies. Test in Task 1 (sequential renew + lost; `FOR UPDATE` on the renewal row in code).
2. **Renewing with the old policy number when the insurer keeps it** — succeeds (old becomes expired first, then insert); a third active policy with that number is refused with the exact message, not a raw unique-violation. Test in Task 1.
3. **Policy reassigned to another agent mid-pipeline** — the new agent can act on it, the old agent cannot; history keeps who did what. Test in Task 1.
4. **Agent deactivated or setting switched off between page load and click** — RPC refuses with the exact message; the UI shows it as a toast. Test (setting off) in Task 1; toast mapping in Task 2.
5. **Renewal start date on 29 Feb / old expiry 28 Feb in a leap year** — `defaultRenewalDates` gives sensible dates (start = expiry + 1 day; expiry = start + 1 year − 1 day, clamped). Test in Task 2.

---

### Task 1: Migration 014 — schema, view, RPCs, cleanup

**Files:** Create `supabase/migrations/014_renewal_pipeline.sql`, `supabase/tests/014_renewal_pipeline.sql`

**Interfaces — Produces:** column `agencies.agents_manage_renewals boolean NOT NULL DEFAULT true`; tables `policy_renewals`, `renewal_activities` (columns exactly as spec §1, incl. `previous_stage`, `expired_by_loss`); view `renewal_pipeline` with columns `policy_id, agency_id, policy_number, expiry_date, start_date, premium_amount, policy_status, client_id, client_name, client_phone, client_email, insurer_id, insurer_name, product_line_id, product_line_name, agent_id, agent_name, days_to_expiry int, renewal_id, stage, quoted_insurer_id, quoted_insurer_name, quoted_premium, lost_reason, renewed_policy_id, closed_at, last_activity_at`; RPCs `log_renewal_contact(p_policy_id uuid, p_channel text, p_occurred_on date, p_note text) → uuid`, `record_renewal_quote(p_policy_id uuid, p_insurer_id uuid, p_premium numeric, p_note text) → uuid`, `mark_renewal_lost(p_policy_id uuid, p_reason text, p_note text) → void`, `reopen_renewal(p_policy_id uuid) → void`, `renew_policy(p_policy_id uuid, p_new jsonb) → uuid`, `set_agents_manage_renewals(p_enabled boolean) → void`; trigger `trg_policy_renewal_reset` (BEFORE DELETE on `policies`); `generate_monthly_report` adds `renewals_renewed`, `renewals_lost`, `renewal_rate`.

- [ ] **Step 1: Failing test** (fixture: agency, owner o, manager m, agents a1/a2, insurers I1/I2, product line Motor; a1 policies P1 (expires today+20), P2 (today+40), P3 (today−5, overdue), P4 (today+200, outside window); a2 policy Q1 (today+10); a second agency with its own policy X). Assertions:
  - view as o: P1, P2, P3, Q1 present with stage `to_contact`; P4 absent; P3 `days_to_expiry = -5`.
  - contact (a1 on P1, 'whatsapp') → stage `contacted`, one `contact` activity, `last_activity_at` set; after a quote, another contact leaves stage `quoted`.
  - quote I2 15000 then I1 14000 → `quoted_insurer_id = I1`, `quoted_premium = 14000`, two `quote` activities.
  - renew P1 as a1 with same `policy_number`, `start_date = expiry+1`, `expiry_date = start+1y−1d` → returns new id; new policy has P1's client and agent, I1, premium 14000; one expected `commission_transactions` row for it; P1 `status = 'expired'`; renewal `stage = 'renewed'`, `renewed_policy_id` = new id, `previous_stage = 'quoted'`; then mark lost on P1 → 'This renewal is already closed' (Review Focus 1).
  - duplicate number: insert another active policy with P1's number via renew of P2 → 'That policy number is already used by an active policy' (Review Focus 2).
  - renew validation: missing number → 'Enter the policy number'; expiry ≤ start → 'Expiry must be after the start date'; other agency's insurer → 'Pick an insurer of this agency'; other agency's product line → 'Pick a product line of this agency'.
  - delete the new policy (as o) → renewal back to `quoted`, closed fields NULL, P1 `active`, one `reset` activity.
  - lost: no reason → 'Pick a reason'; P3 lost 'price' → P3 `expired`, `expired_by_loss = true`; P2 lost → P2 still `active`; view still lists both in stage `lost`.
  - reopen: as a1 → 'Only owners and managers can do that'; as m on P3 → stage = previous, P3 `active`, `reopened` activity; reopen on a non-lost renewal → 'Only a lost renewal can be reopened'.
  - window: contact on P4 → 'This policy is not due for renewal'; unknown id → 'Policy not found'.
  - agents: a1 on Q1 → 'You can only update renewals for your own policies'; a1 sees 0 view/table rows for Q1; `reassign_client` Q1's client to a1 (Q1 moves to a1) → a1 can now log a contact, a2 cannot (Review Focus 3).
  - setting: m calls `set_agents_manage_renewals(false)` → 'Only the owner can do that'; o sets false → a1 contact → 'Renewal updates by agents are turned off for this agency'; m still can.
  - validation: bad channel → 'Pick a channel'; NULL date → 'Enter the date'; premium 0 → 'Enter a premium'.
  - access: direct INSERT/UPDATE on `policy_renewals`/`renewal_activities` as o → insufficient_privilege; other agency's X → 'Policy not found'.
  - cleanup: fixture inserts (as superuser) one `renewal_reminders` sent=true row and one sent=false row, then calls `_migrate_renewal_reminders()` → the sent row is a `contact` activity and the unsent row is gone; `trg_auto_renewal_reminders` no longer exists; inserting a new policy creates no reminder rows.
  - report: `generate_monthly_report` for the current month as o → `renewals_renewed`, `renewals_lost`, `renewal_rate` present with the expected counts; `renewals_due_30d` excludes closed renewals.
- [ ] **Step 2: Run → RED.**
- [ ] **Step 3: Write 014.** Put the reminder copy/cleanup in an internal `_migrate_renewal_reminders() → int` (revoked from API roles) that the migration calls once, so the test can exercise it. Policy-number change: `ALTER TABLE policies DROP CONSTRAINT policies_agency_id_policy_number_key` (check the real name first) + `CREATE UNIQUE INDEX policies_active_number_uniq ON policies(agency_id, policy_number) WHERE status IN ('active','pending')`; catch `unique_violation` in `renew_policy` and raise the exact message. `renew_policy` sets the old policy `expired` before inserting the new one. Base `generate_monthly_report` on the 012 version.
- [ ] **Step 4: Apply** `014_renewal_pipeline`; run tests 006–014 → ALL PASSED (separate runs per file).
- [ ] **Step 5: Commit** `feat(db): renewal pipeline`

### Task 2: Data layer, helpers, Renewals page

**Files:** Create `src/lib/renewals.ts` (+ `renewals.test.ts`), `src/hooks/renewals.ts`, `src/components/renewals/RenewalDialogs.tsx` (contact, quote, lost, renew), `src/components/renewals/RenewalDrawer.tsx`; Rewrite `src/pages/renewals.tsx`; Modify `src/lib/types.ts`, `src/lib/reconcile.ts` (+ its test), `src/hooks/queries.ts` (remove `useRenewalReminders`, `useCreateRenewalReminder`, `useRenewalReminderCounts`, `useOverdueRenewals` once unused), `src/contexts/AuthContext.tsx` if the agency type needs `agents_manage_renewals`.

**Interfaces — Consumes:** Task 1 view and RPCs. **Produces:** types `RenewalStage`, `RenewalChannel`, `LostReason`, `RenewalRow` (view row), `RenewalActivity`; hooks `useRenewalPipeline({ window: 'overdue'|'30'|'60'|'90'|'all', agentId? })` (open renewals), `useClosedRenewals({ from, to, agentId? })`, `useRenewalForPolicies(policyIds: string[])` → `Record<policyId, {stage, renewed_policy_id}>` plus reverse links (`renewedFrom`), `useRenewalActivities(renewalId)`, `useLogContact()`, `useRecordQuote()`, `useMarkLost()`, `useReopenRenewal()`, `useRenewPolicy()`, `useSetAgentsManageRenewals()`; all mutations invalidate `['renewals']`, `['renewal-activities']`, `['policies']`, `['commissions']`, `['dashboard']`, `['agency']`. Helpers in `lib/renewals.ts`: `defaultRenewalDates(oldExpiry: string): { start: string; expiry: string }`, `renewalRate(renewed: number, lost: number): number | null`, `stageLabel`, `channelLabel`, `lostReasonLabel`, `canUpdateRenewals(role, agentsManage: boolean, isOwnPolicy: boolean): boolean`.

- [ ] **Step 1:** Vitest → RED → implement → GREEN:
  - `defaultRenewalDates('2026-12-31')` → `{start:'2027-01-01', expiry:'2027-12-31'}`; `('2028-02-28')` → `{start:'2028-02-29', expiry:'2029-02-28'}`; `('2027-02-28')` → `{start:'2027-03-01', expiry:'2028-02-29'}` (Review Focus 5).
  - `renewalRate(3,1)` = 75; `(0,0)` = null; `(0,2)` = 0.
  - labels return the exact Global Constraints strings.
  - `canUpdateRenewals`: owner/manager always true; agent true only with setting on and own policy.
  - `matchLines` with two policies sharing a normalised number: the older one with outstanding > 0 wins; when neither has outstanding, the later `start_date` wins (add `start_date` to the policy input type; update callers).
- [ ] **Step 2:** Page per spec §3 "Renewals": header cards (due 30 days, overdue, renewal rate %, premium renewed in KES via cents), filters (window select, agent select for Owner/Manager, period month picker for closed tabs, default this month), stage tabs with counts, rows with "in N days"/"N days overdue" badge, Update menu gated by `canUpdateRenewals` (Reopen only Owner/Manager on Lost), row click → drawer with activity list, the old and new policy numbers, and a link to the client page `/clients/<client_id>` (there is no policy detail page), Lost tab reason-count card, CSV export with stage, quoted premium, lost reason, closed date. Renew dialog reuses the policy form fields/`PolicyCommissionFields` with `withCommissionColumns`, pre-filled per spec (dates from `defaultRenewalDates`, insurer/premium from quote else old, commission fields copied, number = old). RPC errors shown as destructive toasts with the server message (Review Focus 4). Works at 375px width (cards stack, table scrolls horizontally inside its card).
- [ ] **Step 3:** Typecheck, vitest, build GREEN. Confirm each PostgREST select string parses via anon curl against `renewal_pipeline` / `renewal_activities` (returns `[]`).
- [ ] **Step 4: Commit** `feat(app): renewal pipeline page`

### Task 3: Policies, client, dashboard, settings; demo data; README

**Files:** Modify `src/pages/policies.tsx`, `src/pages/client-detail.tsx`, `src/pages/dashboard.tsx`, `src/pages/settings.tsx`, `README.md`.

**Interfaces — Consumes:** Task 2 hooks `useRenewalForPolicies`, `useSetAgentsManageRenewals`, helper `stageLabel`; Task 1 view.

- [ ] **Step 1:** Policies list and client page: stage badge (`stageLabel`) for policies in the pipeline; "Renewed as <number>" / "Renewed from <number>" links. Dashboard: "Expiring (30 Days)" count and "Upcoming Renewals" list read `renewal_pipeline` where `stage NOT IN ('renewed','lost')` and `0 <= days_to_expiry <= 30`, showing the stage badge. Settings → Agency: switch "Agents can update their own renewals" (Owner edits via `useSetAgentsManageRenewals`; others see it disabled). Typecheck, vitest, build GREEN.
- [ ] **Step 2: Demo data** as demo Owner `e01ee698-7800-43cd-9615-ef9376d32136` (agency `00ca4ec4-7ca5-4f84-a9ef-ef8b6e3b006c`, committed transaction via impersonation): among pipeline policies (earliest expiry first) — two contacts ('whatsapp', 'phone'), one quote at +5% premium on the old insurer, one renewed with the same number and default dates, one lost 'price'; rest untouched. Report the policy numbers per stage and confirm demo `commission_received` total is unchanged (390307.00).
- [ ] **Step 3:** Verify as demo Agent (rolled back): sees only own pipeline rows; can log a contact on own policy; refused on another agent's.
- [ ] **Step 4:** README: Database row 014; "Renewal pipeline" section (stages, renew creates linked policy, lost reasons, renewal rate, who can do what + the agency switch, placeholder reminders removed, policy numbers may repeat across terms); Roles table row "Renewal pipeline: Owner/Manager any; Agent own when allowed"; test list 006–014; phase plan line "✅ Renewal pipeline".
- [ ] **Step 5: Commit** `feat(app): renewal badges, dashboard and settings; docs`. No push.
