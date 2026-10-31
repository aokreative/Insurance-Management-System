# Team & Access Control Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Owner / Manager / Agent roles enforced by Postgres RLS, client assignment, invite links, and a Team page, so Agents only ever see their own book.

**Architecture:** All rules live in Supabase (RLS policies + `SECURITY DEFINER` RPCs with explicit role checks). The React app keeps one set of pages; it reads role from `AuthContext` only to hide controls and relabel figures, never to protect data. DB behaviour is proven by a rolled-back SQL test script run against ERP Demo.

**Tech Stack:** Supabase Postgres 17 (RLS, plpgsql, pgcrypto), React 19 + Vite + wouter + React Query + supabase-js, shadcn/ui components already in `src/components/ui`.

**Spec:** `docs/superpowers/specs/2026-11-01-team-access-control-design.md`

**Deviation from spec:** the spec's single "migration 006" is split into three files (006 roles & RLS, 007 invites, 008 team management) so each task applies and tests independently. Combined content is identical.

## Global Constraints

- Roles are exactly `owner`, `manager`, `agent`; one Owner per agency; no ownership transfer.
- Every new function: `SECURITY DEFINER` (unless noted), `SET search_path = public`, `REVOKE EXECUTE ... FROM PUBLIC, anon`, then explicit `GRANT ... TO authenticated`. Only `get_invite_preview` is also granted to `anon`.
- Invite code: 32 random bytes, hex-encoded (64 chars); only `encode(digest(code,'sha256'),'hex')` is stored. Expiry 7 days. Single use.
- Emails compared as `lower(trim(email))`.
- Reassignment moves only `active` and `pending` policies; `expired`/`cancelled` keep their original `agent_id`.
- Deactivated users: `current_user_agency_id()` and `current_user_role()` return NULL.
- Supabase project: ERP Demo `frzjhknbocuaduuduxkk`. Apply migrations with the Supabase MCP `apply_migration`; run tests with `execute_sql`.
- Frontend checks: `npx -y pnpm@10.28.0 run typecheck` (repo root) and `VITE_SUPABASE_URL=https://x.supabase.co VITE_SUPABASE_ANON_KEY=x npx -y pnpm@10.28.0 run build` (in `artifacts/ams`). Builds can take ~2–3 min; run in background if needed.
- Commit as `aokreative <aokreative@gmail.com>`, messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Do not push until Task 9.
- Passwords for demo logins are given to the user in chat only — never written to the repo or memory.

## Review Focus

1. **Invite email typed with different case or spaces** (`" Jane@Agency.co.ke"` vs sign-up `jane@agency.co.ke`) — must still match. Test in Task 2.
2. **Garbage or truncated code in the `/join` URL** — preview returns the generic "invalid or expired" error, never a 500 or a leak of whether the code once existed. Test in Task 2.
3. **Owner removes themselves, or reassigns to the member being removed / a deactivated member / someone in another agency** — refused with a clear message. Test in Task 3.
4. **Agent with zero clients and zero policies** — dashboard shows zeros (no NaN conversion rate, no crash). Check in Task 6.
5. **Removed member still has an open browser session** — next data fetch returns nothing and the app shows "Your access to this agency has been removed". Test (DB side) in Task 1, UI in Task 4.

---

### Task 1: Roles, deactivation, client assignment and RLS (migration 006)

**Files:**
- Create: `supabase/tests/006_team_access_control.sql`
- Create: `supabase/migrations/006_team_access_control.sql`

**Interfaces:**
- Produces (SQL): `users.role IN ('owner','manager','agent')`; `users.deactivated_at TIMESTAMPTZ`; `clients.assigned_agent_id UUID NOT NULL DEFAULT auth.uid() REFERENCES users(id)`; `public.current_user_agency_id() → uuid`, `public.current_user_role() → text` (NULL when deactivated); `public.is_owner_or_manager() → boolean`.
- Produces (test harness, reused by Tasks 2–3): inside the test file, a local plpgsql helper pattern `PERFORM set_config('request.jwt.claims', json_build_object('sub', <uid>, 'role','authenticated')::text, true); SET LOCAL ROLE authenticated;` and `RESET ROLE;` between actors. Fixture agency with Owner `o`, Manager `m`, Agents `a1`, `a2`, each with clients/policies/commissions/reminders.

- [ ] **Step 1: Write the failing test** — file wraps everything in `BEGIN; … ROLLBACK;`, builds the fixture as superuser (auth.users rows with `@test.local` emails; agency; 4 `users` rows; clients: 2 assigned to `a1`, 1 to `a2`, 1 to `m`; one active policy + one pending commission + reminders per client), then `ASSERT`s. Final statement `SELECT 'ALL PASSED' AS result;`. Assertions:
  - as `a1`: `count(clients)=2`, `count(policies)=2`, `count(commission_transactions)=2`, `count(renewal_reminders)` = reminders on `a1`'s policies only, `count(reports)=0`, `count(users)=1`.
  - as `m` and as `o`: clients=4, policies=4, users=4.
  - as `a1`: `UPDATE clients SET name='x'` on `a2`'s client affects 0 rows; `INSERT clients(... assigned_agent_id=a2)` raises; `INSERT policies` with `agent_id=a2` raises; `INSERT policies` with `agent_id=a1` on `a2`'s client raises; `UPDATE policies SET client_id=<a2 client>` on own policy raises; `UPDATE commission_transactions SET status='received'` affects 0 rows; `DELETE FROM clients` affects 0 rows; `UPDATE insurers` affects 0 rows; `UPDATE agencies` affects 0 rows.
  - as `m`: `UPDATE agencies` affects 0 rows; `UPDATE commission_transactions SET status='received'` affects ≥1.
  - as `a1` inserting a client without `assigned_agent_id` → row has `assigned_agent_id = a1`.
  - after `UPDATE users SET deactivated_at=now() WHERE id=a1` (superuser): as `a1`, clients=0 and `current_user_role() IS NULL`.

- [ ] **Step 2: Run the test to verify it fails**
Run: `execute_sql` with the test file contents.
Expected: error `column "assigned_agent_id" ... does not exist` (or the role CHECK rejecting `manager`).

- [ ] **Step 3: Write `supabase/migrations/006_team_access_control.sql`** in this order:
  1. `UPDATE users SET role='manager' WHERE role='admin'`; replace the role CHECK with `owner|manager|agent`.
  2. `ALTER TABLE users ADD COLUMN deactivated_at TIMESTAMPTZ`; redefine `current_user_agency_id()` / `current_user_role()` with `AND deactivated_at IS NULL`; add `is_owner_or_manager()`.
  3. `clients.assigned_agent_id`: add nullable FK → backfill to each agency's owner → `SET NOT NULL` → `SET DEFAULT auth.uid()` → index `idx_clients_assigned_agent_id`.
  4. Drop every existing policy on `agencies, users, clients, policies, commission_transactions, renewal_reminders, reports, insurers, product_lines` and recreate per the spec's access matrix. Agent-side predicates: clients `assigned_agent_id = auth.uid()`; policies `agent_id = auth.uid() AND client_id IN (SELECT id FROM clients WHERE assigned_agent_id = auth.uid())` in both `USING` and `WITH CHECK`; commissions/reminders `policy_id IN (SELECT id FROM policies WHERE agent_id = auth.uid())` SELECT-only.
  5. `generate_monthly_report`: change `IN ('owner','admin')` to `IN ('owner','manager')`.

- [ ] **Step 4: Run the test to verify it still fails** (migration not applied yet), then apply
Run: `apply_migration` name `006_team_access_control` with the file body.
Expected: `{"success":true}`.

- [ ] **Step 5: Run the test to verify it passes**
Run: `execute_sql` with the test file.
Expected: `[{"result":"ALL PASSED"}]`. Then confirm the demo agency still reads correctly: as superuser, `SELECT count(*) FROM clients WHERE assigned_agent_id IS NULL` = 0.

- [ ] **Step 6: Commit**
```bash
git add supabase/migrations/006_team_access_control.sql supabase/tests/006_team_access_control.sql
git commit -m "feat(db): owner/manager/agent roles, client assignment and role-scoped RLS"
```

### Task 2: Invites (migration 007)

**Files:**
- Create: `supabase/migrations/007_agency_invites.sql`
- Create: `supabase/tests/007_agency_invites.sql`

**Interfaces:**
- Consumes: Task 1 helpers and fixture pattern.
- Produces (SQL):
  - table `agency_invites(id, agency_id, email, role, token_hash, invited_by, created_at, expires_at, accepted_at, accepted_by, revoked_at)`; RLS: SELECT for owner/manager of the agency only; no insert/update/delete policies.
  - `create_invite(p_email text, p_role text) → jsonb {invite_id uuid, code text, expires_at timestamptz}`
  - `get_invite_preview(p_code text) → jsonb {agency_name text, role text, email text}` (anon + authenticated)
  - `accept_invite(p_code text, p_full_name text) → jsonb {agency_id uuid, role text}`
  - `revoke_invite(p_invite_id uuid) → void`
  - Error messages (exact, the UI shows them): `'Invalid or expired invite'`, `'This invite is for a different email address'`, `'This account already belongs to an agency'`, `'That person is already a member of this agency'`, `'There is already a pending invite for this email'`, `'You are not allowed to invite that role'`.

- [ ] **Step 1: Write the failing test** (same harness). Assertions:
  - `o` invites `manager` and `agent` → both return 64-char `code`; `m` inviting `manager` raises `'You are not allowed to invite that role'`; `a1` inviting anyone raises it too.
  - stored `token_hash` ≠ `code` and = `encode(digest(code,'sha256'),'hex')`.
  - as `anon`: preview of a valid code returns agency name/role/email; preview of `'garbage'`, `''`, and a revoked code each raise `'Invalid or expired invite'`.
  - new auth user `new@test.local` (no `users` row) accepts an invite created for `' New@Test.local '` → succeeds, `users` row has the invite's role, invite `accepted_at` set; accepting the same code again raises `'Invalid or expired invite'`.
  - invite with `expires_at` forced to the past → accept raises `'Invalid or expired invite'`.
  - `other@test.local` accepting an invite for `new2@test.local` raises `'This invite is for a different email address'`.
  - `a2` (already a member) accepting a fresh invite for their email raises `'This account already belongs to an agency'`.
  - inviting an existing member's email raises `'That person is already a member of this agency'`; inviting the same email twice raises `'There is already a pending invite for this email'`.
  - `m` can revoke an agent invite they created; `m` revoking `o`'s manager invite raises.
  - as `a1`: `SELECT count(*) FROM agency_invites` = 0; direct `INSERT INTO agency_invites` raises.

- [ ] **Step 2: Run to verify it fails** — Expected: `relation "agency_invites" does not exist`.

- [ ] **Step 3: Write `007_agency_invites.sql`.** Code generation: `encode(extensions.gen_random_bytes(32),'hex')`; hash with `extensions.digest`. `get_invite_preview` validates the code is 64 hex chars before hashing (otherwise the generic error). `accept_invite` reads the caller's email from `auth.users` and uses `p_full_name` (trimmed, ≥2 chars) for the new `users` row.

- [ ] **Step 4: Apply** with `apply_migration` name `007_agency_invites`. Expected `{"success":true}`.

- [ ] **Step 5: Run tests 006 and 007** — Expected: both `ALL PASSED`.

- [ ] **Step 6: Commit**
```bash
git add supabase/migrations/007_agency_invites.sql supabase/tests/007_agency_invites.sql
git commit -m "feat(db): one-time invite links with hashed codes"
```

### Task 3: Team management RPCs (migration 008)

**Files:**
- Create: `supabase/migrations/008_team_management.sql`
- Create: `supabase/tests/008_team_management.sql`

**Interfaces:**
- Consumes: Task 1 fixture/helpers.
- Produces (SQL):
  - `reassign_client(p_client_id uuid, p_new_agent_id uuid) → jsonb {policies_moved int}` (owner/manager)
  - `change_member_role(p_user_id uuid, p_role text) → void` (owner; `p_role` ∈ manager/agent)
  - `remove_member(p_user_id uuid, p_reassign_to uuid) → jsonb {clients_moved int, policies_moved int}` (owner)
  - Error messages: `'Only the owner can do that'`, `'Only owners and managers can do that'`, `'The owner cannot be changed or removed'`, `'Pick an active member of this agency'`.

- [ ] **Step 1: Write the failing test.** Assertions:
  - fixture adds a new client `c_mix` assigned to `a1` with exactly four policies: one `active`, one `pending`, one `expired`, one `cancelled`. `m` reassigns `c_mix` to `a2` → `policies_moved = 2`; the expired and cancelled policies still have `agent_id = a1`; as `a2` the client is visible, as `a1` it is not.
  - `a1` calling `reassign_client` raises `'Only owners and managers can do that'`.
  - `reassign_client` to a user in another agency, to a deactivated user → `'Pick an active member of this agency'`.
  - `o` changes `a1` → `manager` and back; `m` calling `change_member_role` raises `'Only the owner can do that'`; `o` targeting `o` raises `'The owner cannot be changed or removed'`; `p_role='owner'` raises.
  - `o` removes `a2` reassigning to `a1` → `a2.deactivated_at` set, all `a2` clients now `a1`; `remove_member(o, a1)` raises owner error; `remove_member(a1, a1)` raises `'Pick an active member of this agency'`.

- [ ] **Step 2: Run to verify it fails** — Expected: `function reassign_client(uuid, uuid) does not exist`.

- [ ] **Step 3: Write `008_team_management.sql`.** `remove_member` calls `reassign_client` logic per client in one transaction (reuse an internal `_reassign_client_unchecked(client, agent)` with EXECUTE revoked from all API roles).

- [ ] **Step 4: Apply** `008_team_management`. Expected `{"success":true}`.

- [ ] **Step 5: Run tests 006, 007, 008** — Expected: all `ALL PASSED`.

- [ ] **Step 6: Commit**
```bash
git add supabase/migrations/008_team_management.sql supabase/tests/008_team_management.sql
git commit -m "feat(db): reassign clients, change roles and remove members"
```

### Task 4: Types, AuthContext and navigation

**Files:**
- Modify: `artifacts/ams/src/lib/types.ts` (`UserRole`, `AgencyUser`, `Client`; add `AgencyInvite`)
- Modify: `artifacts/ams/src/contexts/AuthContext.tsx`
- Modify: `artifacts/ams/src/layouts/AppLayout.tsx:55-74`
- Modify: every `role === 'admin'` site: `pages/client-detail.tsx:311`, `pages/policies.tsx:276`, `pages/settings.tsx:39`

**Interfaces:**
- Produces: `type UserRole = 'owner' | 'manager' | 'agent'`; `AgencyUser.deactivated_at: string | null`; `Client.assigned_agent_id: string`; `interface AgencyInvite { id; agency_id; email; role: 'manager'|'agent'; invited_by; created_at; expires_at; accepted_at: string|null; revoked_at: string|null }`.
- Produces from `useAuth()`: `isOwner: boolean`, `isOwnerOrManager: boolean`, `isDeactivated: boolean` (alongside existing `session, profile, agency, refreshProfile`).

- [ ] **Step 1: Run typecheck to capture the baseline** — Expected: passes.
- [ ] **Step 2: Change the types**, then run typecheck — Expected: FAIL at each `'admin'` comparison (proves every site is found).
- [ ] **Step 3: Implement** the `useAuth` flags; replace `'admin'` checks with `isOwnerOrManager`; in `AppLayout`, Owner/Manager see Reports, Insurers, Product Lines, Settings; Agents see Dashboard, Clients, Policies, Commissions, Renewals, Settings (Settings shows only their profile for Agents — Task 7). Agency-less redirect to `/register` skips `/join`. If `profile.deactivated_at` is set, render a full-screen "Your access to this agency has been removed" card with a Sign out button instead of the app.
- [ ] **Step 4: Run typecheck and build** — Expected: both pass.
- [ ] **Step 5: Commit** `feat(app): role flags, role-based navigation, deactivated screen`

### Task 5: Client assignment and agent-safe policy form

**Files:**
- Modify: `artifacts/ams/src/hooks/queries.ts` (`useClients`, `useCreateClient`, `useCreatePolicy`)
- Create: `artifacts/ams/src/hooks/team.ts` (team hooks; `useReassignClient` lives here)
- Modify: `artifacts/ams/src/pages/clients.tsx`, `artifacts/ams/src/pages/client-detail.tsx`, `artifacts/ams/src/pages/policies.tsx`

**Interfaces:**
- Consumes: Task 4 flags/types; Task 3 `reassign_client`.
- Produces in `hooks/team.ts`: `useAgencyMembers()` → active members `{id, full_name, role}[]` (moved from `useAgencyUsers`, filtering `deactivated_at IS NULL`); `useReassignClient()` mutation `({clientId, newAgentId}) → {policies_moved}` invalidating `['clients']`, `['policies']`, `['commissions']`.

- [ ] **Step 1: Implement** `useClients` selects `*, assigned_agent:users!clients_assigned_agent_id_fkey(id, full_name)`; Clients table gets an "Assigned to" column and an Owner/Manager-only filter (All / each member); create-client dialog shows an assignee select for Owner/Manager (default self) and omits it for Agents (DB default applies). Client detail shows the assignee and, for Owner/Manager, a **Reassign** dialog with member picker and a toast `"Reassigned — {n} policies moved"`. Policy forms: for Agents, hide the agent select and send `agent_id = session.id`; client select lists only visible clients (already RLS-scoped).
- [ ] **Step 2: Run typecheck and build** — Expected: pass.
- [ ] **Step 3: Verify against the DB** with `execute_sql` as the demo Owner: the exact select string used by `useClients` returns 16 rows each with `assigned_agent.full_name`.
- [ ] **Step 4: Commit** `feat(app): client assignment, reassign action, agent-scoped policy form`

### Task 6: Role-aware dashboard and commissions

**Files:**
- Modify: `artifacts/ams/src/pages/dashboard.tsx`, `artifacts/ams/src/pages/commissions.tsx`, `artifacts/ams/src/pages/renewals.tsx`

**Interfaces:**
- Consumes: `useAuth().isOwnerOrManager`.

- [ ] **Step 1: Implement** — for Agents: card titles prefixed "My" (e.g. "My active policies", "My premium in force", "My commission received", "My commission outstanding"), page subtitle "Your book of business", hide any agency-only card (team count, conversion vs agency). Commissions: hide "Mark received" and bulk-mark for Agents. Guard every ratio against a zero denominator (Review Focus 4) — show `0%`.
- [ ] **Step 2: Run typecheck and build** — Expected: pass.
- [ ] **Step 3: Verify zero-data case** with `execute_sql` as a fresh agent with no clients (inside a rolled-back transaction): every dashboard query returns 0 rows / null sums; confirm the component code paths coalesce nulls to 0.
- [ ] **Step 4: Commit** `feat(app): agent dashboard and commission views`

### Task 7: Team tab in Settings

**Files:**
- Modify: `artifacts/ams/src/hooks/team.ts`
- Create: `artifacts/ams/src/components/team/InviteMemberDialog.tsx`, `artifacts/ams/src/components/team/RemoveMemberDialog.tsx`
- Modify: `artifacts/ams/src/pages/settings.tsx`

**Interfaces:**
- Consumes: Task 2 `create_invite`, `revoke_invite`; Task 3 `change_member_role`, `remove_member`.
- Produces in `hooks/team.ts`: `usePendingInvites()`, `useCreateInvite()` → `{invite_id, code, expires_at}`, `useRevokeInvite()`, `useChangeMemberRole()`, `useRemoveMember()`; helper `inviteLink(code: string): string` = `${window.location.origin}/join?code=${code}`.

- [ ] **Step 1: Implement** — Settings tabs: **Profile** (all), **Agency** (edit for Owner, read-only otherwise), **Team** (Owner/Manager). Team: members table (name, email, role badge, assigned client count), pending invites (email, role, expires, Revoke). InviteMemberDialog: email + role (Manager option only for Owner) → after success shows the link once, **Copy link**, and **Share on WhatsApp** (`https://wa.me/?text=` + encoded `"You've been invited to join {agency} on AMS: {link}"`), with the note "This link is shown only once and expires in 7 days." Owner-only row actions: role select (Manager/Agent), Remove → RemoveMemberDialog with "Reassign their clients to" picker (excludes the member being removed). Surface RPC error messages verbatim in toasts. Remove the old "Invites coming soon" button.
- [ ] **Step 2: Run typecheck and build** — Expected: pass.
- [ ] **Step 3: Commit** `feat(app): team management in settings`

### Task 8: `/join` page

**Files:**
- Create: `artifacts/ams/src/pages/join.tsx`
- Modify: `artifacts/ams/src/App.tsx` (public route `/join`)

**Interfaces:**
- Consumes: Task 2 `get_invite_preview`, `accept_invite`; `useAuth().refreshProfile`.

- [ ] **Step 1: Implement** — read `code` from the query string; call preview; on error show "This invite link is invalid or has expired. Ask the person who invited you for a new one." On success: heading "Join {agency_name}", text "You've been invited as {Role}", email field pre-filled and disabled, full name, password (min 8). Submit: `signUp`; if already registered → `signInWithPassword` (same path as `register.tsx`); then `accept_invite(code, fullName)` → `refreshProfile()` → `/dashboard`. A "Already have an account? Sign in instead" toggle hides the name field and signs in before accepting. Show RPC errors verbatim.
- [ ] **Step 2: Run typecheck and build** — Expected: pass.
- [ ] **Step 3: Commit** `feat(app): join agency from invite link`

### Task 9: Demo logins, docs and deploy

**Files:**
- Modify: `README.md` (roles section, migrations 006–008, test scripts)
- Modify: `supabase/tests/` — none

- [ ] **Step 1: Re-run all DB tests** 006, 007, 008 — Expected: `ALL PASSED` ×3.
- [ ] **Step 2: Create demo staff through the real path** — as demo Owner via `execute_sql`, `create_invite('manager@ams.co.ke','manager')` and `create_invite('agent@ams.co.ke','agent')`; create the two `auth.users` (confirmed email, bcrypt password via `extensions.crypt`, matching `auth.identities` row) with newly generated passwords; as each, `accept_invite(code, 'Demo Manager' / 'Demo Agent')`.
- [ ] **Step 3: Give the Demo Agent a book** — as demo Owner, `reassign_client` for: Brian Mutua, Grace Njeri, Faith Achieng, Kevin Omondi, Halima Abdi. Verify as Demo Agent: clients=5, reports=0, users=1; as Demo Manager: clients=16.
- [ ] **Step 4: Update README** roles/access table summary and the test-run instructions; commit `docs: roles and team access`.
- [ ] **Step 5: Push and confirm deploy** — `git push origin main`; Vercel latest deployment for `prj_UyQCDF5Ic46niYnEVsQQMlbFohq4` reaches `READY`; `/join?code=garbage` on the live site shows the invalid-link message.
- [ ] **Step 6: Hand over** the Manager and Agent logins in chat and ask the user to sign in as each of the three demo accounts.
