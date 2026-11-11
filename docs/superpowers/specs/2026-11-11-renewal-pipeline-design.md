# Renewal Pipeline — Design

**Date:** 2026-11-11
**Phase:** 2c (phase 2 = reconciliation ✅ → agent payouts ✅ → renewal pipeline)
**Status:** Approved in conversation; awaiting written-spec review

## Goal

Track every expiring policy through **To contact → Contacted → Quoted →
Renewed / Lost**, so the agency knows who still needs a call, what was
quoted, which renewals were won (with the new-term policy created and
linked), which were lost and why, and its renewal rate.

### Success criteria

- Every active policy expiring within 90 days (or already expired) appears
  in the pipeline with a stage, without anyone creating it by hand.
- Contacts, quotes and outcomes are recorded with who and when; the history
  is visible per renewal.
- "Renew" creates the new-term policy in one step, linked to the old one,
  and its expected commission is created as for any new policy.
- Lost renewals carry a reason; the page shows a renewal rate and a
  lost-reason breakdown for a period.
- Agents can work their own renewals when the agency allows it; Owner and
  Manager can always work any renewal. Enforced in the database.

## Decisions

| Question | Decision |
|---|---|
| Who works renewals | Owner/Manager always (any policy); Agents on their own policies when the agency setting allows (on by default, Owner toggles). |
| On Renewed | Create the new-term policy from a pre-filled form, link it, mark the old one expired. |
| Stage details | Contact: channel, date, note. Quote: insurer, premium, note. Lost: reason from a fixed list + note. |
| Page | Stage tabs with counts + expiry-window and agent filters; mobile-friendly. |
| Model | A renewal record per policy term + an activity log; writes only via RPCs. |
| Placeholder reminders | Stop auto-creating 90/60/30 placeholders; delete unsent ones. Automatic sending is roadmap step 4. |
| Policy numbers | A renewed term may keep the old number; uniqueness applies only among active/pending policies. |

Rejected: stage columns on `policies` (agents can edit their policies, so
the setting could not be enforced; no history); stage derived from the
activity log alone (every list load recomputes every stage).

## 1. Data

### Agency setting

`agencies.agents_manage_renewals boolean NOT NULL DEFAULT true`. Changed
only via `set_agents_manage_renewals(p_enabled boolean)` (Owner).

### Policy numbers

Replace `UNIQUE (agency_id, policy_number)` on `policies` with a partial
unique index on `(agency_id, policy_number) WHERE status IN ('active',
'pending')`. Statement matching in the browser (`matchLines` in
`src/lib/reconcile.ts`): when several policies share a normalised number,
pick the one with outstanding commission (earliest `start_date` first), else
the one with the latest `start_date`.

### `policy_renewals` (one row per policy term)

| Column | Notes |
|---|---|
| `id`, `agency_id` | |
| `policy_id` | UNIQUE, FK policies ON DELETE CASCADE |
| `stage` | `'to_contact'` \| `'contacted'` \| `'quoted'` \| `'renewed'` \| `'lost'` |
| `previous_stage` | stage before the last close (renewed/lost); used by reopen and by the delete-reset |
| `quoted_insurer_id` | FK insurers ON DELETE SET NULL; latest quote |
| `quoted_premium numeric(12,2)` | latest quote |
| `lost_reason` | `'price'` \| `'competitor'` \| `'no_longer_needed'` \| `'no_response'` \| `'other'`; set only when lost |
| `renewed_policy_id` | FK policies ON DELETE SET NULL |
| `closed_at timestamptz`, `closed_by` | set when renewed/lost, cleared on reopen/reset |
| `expired_by_loss boolean DEFAULT false` | true when marking lost set the policy `expired`; reopen then restores `active` |
| `last_activity_at timestamptz` | |
| `created_at`, `updated_at` | |

A row is created by the first RPC that touches the policy; a policy without
a row is in `to_contact`.

### `renewal_activities` (history; append-only)

`id`, `agency_id`, `renewal_id` (FK ON DELETE CASCADE), `kind`
(`'contact'` \| `'quote'` \| `'renewed'` \| `'lost'` \| `'reopened'` \|
`'reset'`), `occurred_on date`, `channel` (`'phone'` \| `'whatsapp'` \|
`'sms'` \| `'email'` \| `'in_person'`, contacts only), `insurer_id`,
`premium` (quotes), `lost_reason`, `new_policy_id` (renewed), `note`,
`created_by`, `created_at`.

### Pipeline view `renewal_pipeline` (`security_invoker = true`)

Policies in the caller's visible set (RLS on `policies` applies, so Agents
see only their own) where either (a) `status = 'active'` and `expiry_date <=
today + 90 days`, or (b) a `policy_renewals` row exists with stage
`renewed`/`lost`. Columns: policy id, number, expiry, premium, status,
client (id, name, phone, email), insurer, product line, agent (id, name),
`days_to_expiry` (negative = overdue), and the renewal's stage (coalesced to
`to_contact`), quote, lost reason, renewed policy id, closed_at,
last_activity_at. "Today" is `(now() AT TIME ZONE 'Africa/Nairobi')::date`.

### Access (RLS)

- `policy_renewals`, `renewal_activities`: SELECT for owner/manager of the
  agency; an Agent can SELECT rows whose policy has `agent_id = auth.uid()`.
- No INSERT/UPDATE/DELETE for API roles; writes only via RPCs/triggers.

### Cleanup of the old reminders

- Copy each `renewal_reminders` row with `sent = true` (manually logged
  contacts) into `renewal_activities` as a `'contact'` (channel kept,
  `occurred_on = reminder_date`, note kept), creating its `policy_renewals`
  row in stage `contacted` when the policy is still active.
- Delete `renewal_reminders` rows with `sent = false`.
- Drop `trg_auto_renewal_reminders` and `auto_create_renewal_reminders()`.
- `renewal_reminders` stays (unused by the app) for roadmap step 4.

## 2. RPCs and rules

All SECURITY DEFINER, `SET search_path = public`, revoked from PUBLIC/anon,
granted to authenticated. Each locks the `policy_renewals` row (creating it
if missing) `FOR UPDATE`.

**Permission check (every write except reopen and the setting):** the
caller is Owner/Manager of the policy's agency; or the caller is the
policy's agent, active, and the agency has `agents_manage_renewals = true`.

| Function | Behaviour |
|---|---|
| `log_renewal_contact(p_policy_id uuid, p_channel text, p_occurred_on date, p_note text) → uuid` | Adds a contact. Stage `to_contact` → `contacted`; later open stages unchanged. |
| `record_renewal_quote(p_policy_id uuid, p_insurer_id uuid, p_premium numeric, p_note text) → uuid` | Adds a quote; sets `quoted_insurer_id/premium`; stage → `quoted`. |
| `mark_renewal_lost(p_policy_id uuid, p_reason text, p_note text) → void` | Stage → `lost`, `previous_stage` saved, `closed_at/by` set. If `expiry_date < today` the policy's status becomes `expired`. |
| `reopen_renewal(p_policy_id uuid) → void` | Owner/Manager. Only from `lost`: stage → `previous_stage`, clears reason/closed; adds `'reopened'`. Policy back to `active` when `expired_by_loss`, which is then cleared. |
| `renew_policy(p_policy_id uuid, p_new jsonb) → uuid` | Inserts the new policy (same agency, client and agent as the old one) from whitelisted keys: `policy_number, insurer_id, product_line_id, premium_amount, commission_rate, commission_basis, premium_frequency, instalment_premium, renewal_commission_rate, start_date, expiry_date, notes`. Sets the old policy `expired`, stage → `renewed`, `renewed_policy_id`, `previous_stage`, closed; adds `'renewed'`. Returns the new policy id. The existing policy-insert trigger creates its expected commission. |
| `set_agents_manage_renewals(p_enabled boolean) → void` | Owner. |

A policy can be acted on only if it is in the pipeline (active and
`expiry_date <= today + 90`, or already has a renewal row). Contact, quote,
lost and renew are refused on a closed renewal (`renewed`/`lost`).

**Reset trigger:** a BEFORE DELETE trigger on `policies`: when the deleted
policy is some renewal's `renewed_policy_id`, it sets that renewal's stage back to
`previous_stage`, clears closed fields, sets the old policy `active`, and
adds a `'reset'` activity.

Errors (exact):
'Only the owner can do that' (42501),
'Only owners and managers can do that' (42501),
'You can only update renewals for your own policies' (42501),
'Renewal updates by agents are turned off for this agency' (42501),
'Policy not found' (P0002),
'This policy is not due for renewal',
'This renewal is already closed',
'Only a lost renewal can be reopened',
'Pick a channel', 'Enter the date', 'Pick an insurer of this agency',
'Enter a premium', 'Pick a reason', 'Pick a product line of this agency',
'Enter the policy number', 'Expiry must be after the start date',
'That policy number is already used by an active policy'.

### Reports and overdue

- `generate_monthly_report` (latest from 012) adds `renewals_renewed`,
  `renewals_lost` (closed in the month) and `renewal_rate` (renewed ÷
  (renewed + lost), null when both 0). `renewals_due_30d` excludes policies
  whose renewal is closed.
- `useOverdueRenewals` and the dashboard due/overdue figures exclude closed
  renewals (renewed policies are already `expired`; lost ones may still be
  `active` until expiry).

## 3. Pages

### Renewals (`/renewals`, replaces the current page)

- Header cards: due in 30 days, overdue, renewal rate for the period,
  premium renewed for the period.
- Filters: window (Overdue / 30 / 60 / 90 days / All open; default 90 incl.
  overdue), agent (Owner/Manager), period for closed tabs (default this
  month).
- Stage tabs with counts: To contact · Contacted · Quoted · Renewed · Lost.
  Renewed/Lost filtered by `closed_at` in the period.
- Row: client + phone, policy no. + product + insurer, agent, expiry with
  "in N days"/"N days overdue" badge, last activity, quoted premium, and an
  **Update** menu: Log contact, Record quote, Renew…, Mark lost, Reopen
  (Owner/Manager). Agents see the menu only when the setting is on.
- Row click opens a drawer with the activity history and links to the old /
  new policy.
- Dialogs: Log contact (channel, date default today, note); Record quote
  (insurer default the current one, premium, note); Mark lost (reason,
  note); Renew (existing policy form fields, pre-filled: client and agent
  fixed; `start_date = old expiry + 1 day`; `expiry_date = start + 1 year −
  1 day`; insurer and premium from the latest quote else the old policy;
  commission fields copied; policy number pre-filled with the old one,
  editable).
- Lost tab: card with counts per reason for the period.
- Export CSV: adds stage, quoted premium, lost reason, closed date.

### Elsewhere

- Policy list/detail and client page: renewal stage badge for policies in
  the pipeline; "Renewed from" / "Renewed as" links.
- Settings → Agency (Owner edits, others read): switch "Agents can update
  their own renewals".
- Dashboard: due/overdue figures exclude closed renewals.

Pure helpers in `src/lib/renewals.ts` (Vitest): `defaultRenewalDates(oldExpiry)`
(handles 29 Feb), `renewalRate(renewed, lost)`, `stageLabel`,
`lostReasonLabel`, `channelLabel`.

## 4. Rollout, data, testing

### Migration 014 (`supabase/migrations/014_renewal_pipeline.sql`)

Setting column; policy-number index change; two tables + indexes
(`policy_renewals(agency_id, stage)`, `renewal_activities(renewal_id)`); RLS;
view; RPCs + grants; reset trigger; reminder copy/cleanup and trigger drop;
updated `generate_monthly_report`.

### Demo data (after 014)

In the demo agency, among policies in the pipeline: two Contacted
(WhatsApp, phone), one Quoted at a new premium, one Renewed (creates its
new-term policy), one Lost (price); the rest stay To contact. Report which
policies.

### Testing

`supabase/tests/014_renewal_pipeline.sql` (BEGIN…ROLLBACK, ALL PASSED):
contact moves to_contact → contacted and leaves quoted alone; newer quote
replaces the old; renew creates a linked policy with the same client/agent,
an expected commission, old policy expired, same policy number allowed;
duplicate number among active policies refused; deleting the new policy
resets stage and reactivates the old one; lost requires a reason and expires
only past-expiry policies; reopen only from lost, Owner/Manager only; closed
renewals refuse further actions; policy outside the 90-day window refused;
agent: own policies only, refused when the setting is off, sees only own
rows; setting Owner-only; other agency invisible; placeholder cleanup and
reminder copy; monthly report fields; view excludes closed renewals from
overdue. Vitest for the helpers and the `matchLines` duplicate-number rule.
Typecheck + build; Vercel preview; push the branch for the user to merge.

## Out of scope

Automatic WhatsApp/SMS/email sending (roadmap step 4), several competing
quotes per renewal, Kanban board, full renewal charts (reporting phase).
