# Agency Management System (AMS)

A multi-tenant SaaS platform for Kenyan insurance agencies. Agencies manage clients, policies, commissions, and renewal tracking — all scoped per-agency with Supabase RLS.

## Run & Operate

- `pnpm --filter @workspace/ams run dev` — frontend dev server (auto-started by workflow)
- `pnpm --filter @workspace/api-server run dev` — Express API server (auto-started by workflow)
- `pnpm run typecheck` — full typecheck across all packages

## Stack

- **Frontend:** React + Vite + Tailwind (artifacts/ams)
- **Backend:** Supabase (Postgres + RLS + Auth) + Express API server for admin ops
- **Auth:** Supabase Auth (email/password)
- **State:** React Query wrapping Supabase client calls directly (no Orval/codegen)

## Where things live

- `artifacts/ams/src/` — React frontend
  - `contexts/AuthContext.tsx` — session, profile, agency state; `refreshProfile()` for post-signup reload
  - `lib/supabase.ts` — Supabase client (anon key)
  - `lib/types.ts` — TypeScript types for all DB tables
  - `hooks/queries.ts` — React Query hooks wrapping Supabase
  - `pages/` — all pages
  - `layouts/AppLayout.tsx` — persistent sidebar layout
- `artifacts/api-server/src/` — Express server
  - `routes/agency.ts` — POST /api/agency/setup (creates agency + owner + seeds product lines)
  - `lib/supabase-admin.ts` — service-role Supabase client (server-side only)
- `supabase/migrations/001_initial_schema.sql` — **Run this in Supabase SQL Editor first**

## Architecture decisions

- Supabase RLS enforces multi-tenancy at the DB layer; every table has `agency_id` with `current_user_agency_id()` helper
- Service-role key is server-side only (Express); frontend uses anon key only
- Signup flow: `supabase.auth.signUp` → `POST /api/agency/setup` (server-side RPC) → `refreshProfile()` — avoids auth state race
- No Orval/OpenAPI codegen for this app; Supabase client used directly with React Query
- Default Kenyan product lines seeded via `seed_default_product_lines()` SQL function on agency creation

## Required: Apply the SQL schema to Supabase

1. Open your [Supabase SQL Editor](https://supabase.com/dashboard/project/_/sql)
2. Run the contents of `supabase/migrations/001_initial_schema.sql`
3. This creates all tables, RLS policies, helper functions, and seed function

## Secrets (already configured)

- `SUPABASE_URL` — project URL
- `SUPABASE_ANON_KEY` — public anon key (used by frontend via vite.config.ts define)
- `SUPABASE_SERVICE_ROLE_KEY` — server-side admin key (Express only)

## Phase build plan

- ✅ Phase 1: Foundation — schema + RLS + auth + all core pages
- 🔲 Phase 2: Core CRUD (clients, policies, insurers, product lines — UI built, backend integration next)
- 🔲 Phase 3: Commission & renewal tracking
- 🔲 Phase 4: Reporting dashboard with Recharts
- 🔲 Phase 5: Automated monthly reports (Edge Function + PDF)
- 🔲 Phase 6: Polish (mobile-first, role-based views, onboarding flow)

## User preferences

_Populate as you build._

## Gotchas

- **Run SQL migration first** before testing auth — tables must exist for Supabase RLS to work
- Supabase signup with email confirmation disabled in project settings, or users won't get a session on signUp
- `refreshProfile()` must be called after `POST /api/agency/setup` completes to avoid the race where SIGNED_IN fires before the `users` row is created
- `vite.config.ts` maps `SUPABASE_URL`/`SUPABASE_ANON_KEY` secrets to `VITE_` vars via `define` — no VITE_ prefix secrets needed
- pnpm workspace: `pnpm --filter @workspace/<name>` to target specific packages
