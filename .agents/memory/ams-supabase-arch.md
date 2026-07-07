---
name: AMS Supabase Architecture
description: Key architectural decisions for the AMS app — Supabase client usage, secret exposure, and env var mapping
---

This app uses Supabase client directly with React Query — NOT Orval/codegen hooks.

**Frontend data layer:** `supabase.from('table').select(...)` wrapped in `useQuery`/`useMutation` via `artifacts/ams/src/hooks/queries.ts`.

**Secret exposure:** SUPABASE_URL and SUPABASE_ANON_KEY are stored as Replit secrets (no VITE_ prefix). `vite.config.ts` maps them via `define`:
```ts
define: {
  'import.meta.env.VITE_SUPABASE_URL': JSON.stringify(process.env.SUPABASE_URL ?? ''),
  'import.meta.env.VITE_SUPABASE_ANON_KEY': JSON.stringify(process.env.SUPABASE_ANON_KEY ?? ''),
}
```
SUPABASE_SERVICE_ROLE_KEY is only used server-side in `artifacts/api-server/src/lib/supabase-admin.ts`.

**Why:** User had secrets already saved without VITE_ prefix; the define approach avoids requiring them to re-enter values.
