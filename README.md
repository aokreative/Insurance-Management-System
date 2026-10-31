# Agency Management System (AMS)

A multi-tenant SaaS platform for Kenyan insurance agencies. Agencies manage clients, policies, commissions, and renewal tracking — all scoped per-agency with Supabase RLS.

## Run & Operate

- `pnpm install` — install dependencies (pnpm only; npm/yarn are blocked)
- `pnpm --filter @workspace/ams run dev` — frontend dev server on http://localhost:5173
- `pnpm --filter @workspace/ams run build` — production build to `artifacts/ams/dist/public`
- `pnpm run typecheck` — typecheck all packages

Create `artifacts/ams/.env.local` with:

```
VITE_SUPABASE_URL=https://<project-ref>.supabase.co
VITE_SUPABASE_ANON_KEY=<anon key>
```

## Stack

- **Frontend:** React + Vite + Tailwind (`artifacts/ams`), routing with wouter
- **Backend:** Supabase only (Postgres + RLS + Auth + RPC functions) — there is no API server
- **State:** React Query wrapping Supabase client calls directly
- **Hosting:** Vercel (static build), project root `artifacts/ams`

## Where things live

- `artifacts/ams/src/` — React frontend
  - `contexts/AuthContext.tsx` — session, profile, agency state; `refreshProfile()` for post-signup reload
  - `lib/supabase.ts` — Supabase client (anon key)
  - `lib/types.ts` — TypeScript types for all DB tables
  - `hooks/queries.ts` — React Query hooks wrapping Supabase
  - `pages/` — all pages
  - `layouts/AppLayout.tsx` — persistent sidebar layout
- `artifacts/ams/vercel.json` — Vercel output directory + SPA rewrite
- `supabase/migrations/` — SQL migrations, run in order

## Architecture decisions

- Supabase RLS enforces multi-tenancy at the DB layer; every table has `agency_id` with the `current_user_agency_id()` helper
- Privileged operations are Postgres functions called with `supabase.rpc(...)`, not a server:
  - `create_agency_with_owner` — signup: creates agency + owner row + seeds default Kenyan product lines
  - `generate_monthly_report` — owner/admin only; computes the month's metrics and stores a `reports` row (runs under the caller's RLS)
- Signup flow: `supabase.auth.signUp` → `rpc('create_agency_with_owner')` → `refreshProfile()` — avoids the race where `SIGNED_IN` fires before the `users` row exists
- Commission visibility is role-scoped (migration 003): owners/admins see the whole agency, agents see only commissions on their own policies

## Database

Supabase project: **ERP Demo** (`frzjhknbocuaduuduxkk`). Migrations 001–004 are applied.
New migrations go in `supabase/migrations/` and should be applied in order.

## Deploying (Vercel)

Project `insurance-management-system-ams`, root directory `artifacts/ams`. Pushing to `main` deploys.
Required env vars: `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY`.

## Phase build plan

- ✅ Phase 1: Foundation — schema + RLS + auth + all core pages
- 🔲 Phase 2: Core CRUD (clients, policies, insurers, product lines — UI built, backend integration next)
- 🔲 Phase 3: Commission & renewal tracking
- 🔲 Phase 4: Reporting dashboard with Recharts
- 🔲 Phase 5: Automated monthly reports (PDF + email/WhatsApp)
- 🔲 Phase 6: Polish (mobile-first, role-based views, onboarding flow)

## Gotchas

- Disable email confirmation in Supabase Auth settings, or users won't get a session on `signUp`
- `refreshProfile()` must be called after agency setup completes, before navigating to a protected route
- The free-tier Supabase project pauses after ~1 week idle; restore it from the dashboard
