# Team & Access Control — Design

**Date:** 2026-11-01
**Phase:** 1 of the remaining roadmap (see "Roadmap" below)
**Status:** Approved in conversation; awaiting written-spec review

## Goal

An agency can have more than one person. The Owner sees and runs the whole
agency; employees see only what their role allows. An Agent sees only their
own clients, policies, commissions and renewals — never colleagues' data or
company totals — unless the Owner promotes them to Manager.

### Success criteria

- An Agent signed in to the app, **or calling the Supabase API directly with
  their token**, cannot read or change another agent's clients, policies,
  commissions or renewals, nor any report or company total.
- An Owner or Manager can invite a person by link and that person lands in the
  agency with the right role, with no server or email provider involved.
- The Owner can change a member's role and remove a member without losing that
  member's history.
- The demo agency has three logins (Owner, Manager, Agent) that show the
  three different views.

## Roadmap context

The remaining phases are separate sub-projects, each with its own spec:

1. **Team & access control** — this document
2. Commission & renewal tracking (reconciliation, overdue flagging, per-agent statements/payouts)
3. Reporting dashboard (charts, CSV/Excel export, role-scoped)
4. Automated monthly reports (PDF + email/WhatsApp)
5. Polish (mobile, onboarding)

Phase 1 goes first because phases 2–3 depend on knowing what each person may see.

## Decisions

| Question | Decision |
|---|---|
| How is wider access granted? | Fixed roles only: **Owner**, **Manager**, **Agent**. Granting access = promoting to Manager. |
| Which clients does an Agent see? | Clients have an **assigned agent**; Agents see only their assigned clients. |
| What can a Manager do? | Run the business (see matrix). Only the Owner manages settings, roles and staff removal. |
| How does an employee join? | **Invite link**, shared by the inviter (copy / WhatsApp). |
| Where are rules enforced? | **In the database (RLS + checked RPCs)**. The UI only reflects them. |

Rejected: UI-only filtering (an Agent could read everything via the API);
separate Agent screens (duplicated code, still needs RLS).

## 1. Roles and data rules

### Roles

- `owner`, `manager`, `agent`. The existing `admin` value is renamed to
  `manager` (no rows use `admin` today).
- Exactly one Owner per agency. Ownership transfer is out of scope.

### Client assignment

- New column `clients.assigned_agent_id UUID NOT NULL REFERENCES users(id)`.
- Agent creates a client → assigned to themselves (enforced by RLS).
- Owner/Manager creates a client → they pick the assignee (defaults to themselves).
- Existing clients are backfilled to the agency's Owner.

### Access matrix

| Data | Owner | Manager | Agent |
|---|---|---|---|
| Clients | All, full edit | All, full edit | Read/insert/update only where `assigned_agent_id = me`; no delete |
| Policies | All, full edit | All, full edit | Read/update only where `agent_id = me`; insert or update only so that the row still has `agent_id = me` **and** a client assigned to me; no delete |
| Commissions | All; mark received | All; mark received | Read only, on own policies |
| Renewal reminders | All | All | Read only, on own policies |
| Reports & company totals | Read, generate | Read, generate | None |
| Insurers, product lines | Edit | Edit | Read |
| Team list (`users`) | All members | All members | Own row only |
| Agency settings/branding | Edit | Read | Read |
| Invite staff | Manager or Agent | Agent only | — |
| Change roles, remove staff | Yes | — | — |

### Reassigning a client

`reassign_client(client_id, new_agent_id)` (Owner/Manager only) sets the
client's `assigned_agent_id` **and** moves that client's `active` and `pending`
policies to the new agent. `expired` and `cancelled` policies stay with the
original agent, so commission history is not rewritten. The new agent must be
an active member of the same agency.

### Agent dashboard

Same layout and code as the Owner's. Because RLS returns only the Agent's
rows, the same queries produce the Agent's own figures. Labels switch to
"My …" for Agents. Reports, Settings → Team, Insurers/Product Lines editing are
hidden for Agents.

## 2. Invites and team management

### Data

New table `agency_invites`:

| Column | Notes |
|---|---|
| `id` | UUID PK |
| `agency_id` | FK agencies |
| `email` | lower-cased |
| `role` | `manager` or `agent` |
| `token_hash` | SHA-256 of the one-time code; the code itself is never stored |
| `invited_by` | FK users |
| `created_at`, `expires_at` | expiry = created + 7 days |
| `accepted_at`, `accepted_by` | set on use |
| `revoked_at` | set on revoke |

RLS: Owner/Manager can read their agency's invites (never `token_hash` via the
UI); no direct insert/update/delete — all writes go through RPCs.

New column `users.deactivated_at TIMESTAMPTZ`.

### RPCs (all `SECURITY DEFINER`, `search_path` pinned, EXECUTE revoked from `PUBLIC`/`anon` unless stated)

| Function | Caller | Behaviour |
|---|---|---|
| `create_invite(email, role)` | Owner (manager/agent), Manager (agent) | Rejects if email already a member of this agency or has a live invite. Returns the plain code once. |
| `get_invite_preview(code)` | **anon + authenticated** | Returns agency name, role, email only if the code is live; otherwise a generic "invalid or expired" error. |
| `accept_invite(code)` | authenticated | Requires: code live, `auth.users.email` = invite email, caller not in any agency. Inserts the `users` row with the invite's role, marks invite accepted. |
| `revoke_invite(invite_id)` | Owner/Manager (Managers only their own agent invites) | Sets `revoked_at`. |
| `change_member_role(user_id, role)` | Owner | `manager` ↔ `agent` only; cannot target the Owner. |
| `remove_member(user_id, reassign_to)` | Owner | Reassigns all the member's clients to `reassign_to` (same rules as `reassign_client`), then sets `deactivated_at`. Cannot target the Owner. |
| `reassign_client(client_id, new_agent_id)` | Owner/Manager | See section 1. |

### Deactivation

`current_user_agency_id()` and `current_user_role()` return NULL for a
deactivated user, so every RLS policy denies them. The app shows
"Your access to this agency has been removed" and offers sign-out.

### UI

- **Settings → Team** (Owner/Manager): members (name, email, role, assigned
  client count), pending invites with Revoke, **Invite member** dialog
  (email + role → shows link once with **Copy link** and **Share on WhatsApp**
  `wa.me/?text=` button). Owner-only: change role, remove member (with
  "reassign clients to" picker).
- **`/join?code=…`**: shows "You've been invited to {agency} as {role}",
  email pre-filled and locked, set password → `signUp` → `accept_invite` →
  `refreshProfile()` → dashboard. If the email already has an account, a
  "Sign in instead" path signs in then accepts. Signed-in users without an
  agency are still routed to `/register`, except on `/join`.

## 3. Rollout, demo data, testing

### Migration 006 (`supabase/migrations/006_team_access_control.sql`)

1. Roles: update CHECK to `owner|manager|agent`; `UPDATE users SET role='manager' WHERE role='admin'`.
2. `users.deactivated_at`; helper functions return NULL when deactivated; new helper `is_owner_or_manager()`.
3. `clients.assigned_agent_id` — add nullable, backfill to agency owner, set NOT NULL, default `auth.uid()`, index.
4. `agency_invites` table + RLS.
5. Drop and recreate RLS policies on every table per the matrix.
6. RPCs above; `generate_monthly_report` check changed to owner/manager.
7. Revoke/grant EXECUTE explicitly on every new function.

### App changes

- `lib/types.ts`: `Role = 'owner' | 'manager' | 'agent'`, `Client.assigned_agent_id`, `User.deactivated_at`, `AgencyInvite`.
- `contexts/AuthContext.tsx`: expose `isOwner`, `isOwnerOrManager`; handle deactivated profile; allow `/join` for agency-less users.
- `layouts/AppLayout.tsx`: nav by role (replace `isAgent` hiding with the matrix).
- `pages/dashboard.tsx`: role-aware labels; hide company-only cards for Agents.
- `pages/clients.tsx`, `pages/client-detail.tsx`: "Assigned to" column + filter, assignee picker on create (Owner/Manager), Reassign action.
- `pages/policies.tsx`, `pages/client-detail.tsx`: Agents' policy form fixes `agent_id` to self.
- `pages/commissions.tsx`: hide "mark received" for Agents.
- `pages/settings.tsx`: Team tab as above; agency form read-only for Managers/Agents.
- New `pages/join.tsx` + route.
- Replace every `role === 'admin'` check.

### Demo data

- `demo@ams.co.ke` remains Owner.
- Add **Demo Manager** and **Demo Agent** logins (created through `accept_invite` so they follow the real path), each with a generated password given to the user, not stored in the repo.
- Reassign ~5 clients (and their active policies) to the Demo Agent.

### Testing

- `supabase/tests/006_team_access_control.sql`: a single transaction that is
  always rolled back. Creates an agency with Owner, Manager, two Agents, and
  data, then asserts, impersonating each role:
  - visible counts per table match the matrix;
  - denied writes: Agent editing another agent's client/policy, Agent
    inserting a policy for someone else or on another agent's client, Agent
    marking a commission received, Agent reading reports/team, Manager
    inviting a Manager, Manager changing roles/removing staff, deactivated
    user reading anything;
  - invite paths: success, expired, reused, revoked, wrong email, already in
    an agency, anon preview of a bad code;
  - `reassign_client` and `remove_member` move active/pending policies only.
- `pnpm run typecheck` and the production build pass.
- Manual: the user signs in with each demo login on the live site.

## Out of scope

Ownership transfer; automatic invite emails; per-person permission toggles;
record-level sharing; agent commission payouts (phase 2).
