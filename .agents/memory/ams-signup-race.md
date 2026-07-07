---
name: AMS Signup Race Fix
description: The post-signup auth context race condition and how it was fixed
---

**Problem:** Supabase fires `SIGNED_IN` auth event immediately after `signUp()`, before `POST /api/agency/setup` inserts the `users` and `agencies` rows. AuthContext's `onAuthStateChange` handler tries to fetch profile on SIGNED_IN — returns null since rows don't exist yet. Most queries are `enabled: !!agency?.id`, so the app appears empty/broken after first signup.

**Fix:**
1. `AuthContext.tsx` exposes `refreshProfile()` — explicitly re-fetches profile + agency from Supabase.
2. `register.tsx` calls `await refreshProfile()` after the setup API call succeeds and before `setLocation('/dashboard')`.

**How to apply:** Any time a new server-side operation creates the `users` or `agencies` rows after auth signup, call `refreshProfile()` explicitly before navigating to a protected route.
