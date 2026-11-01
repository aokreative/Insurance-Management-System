-- ============================================================
-- Migration 007: Agency invites
--
-- An Owner (manager/agent) or Manager (agent only) creates a
-- one-time invite for an email address. The plain 64-hex code is
-- returned once and shared as a link; only its SHA-256 is stored.
-- The invitee previews the invite (anon allowed), signs up with
-- the invited email, then accepts it, which writes their `users`
-- row. All writes go through SECURITY DEFINER RPCs; the table has
-- a read-only RLS policy for the agency's Owner/Manager, and
-- token_hash is not readable by API roles at all.
--
-- A "live" invite: accepted_at IS NULL AND revoked_at IS NULL AND
-- expires_at > now().
-- ============================================================

-- ------------------------------------------------------------
-- 1. Table
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS agency_invites (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id   UUID NOT NULL REFERENCES agencies(id) ON DELETE CASCADE,
  email       TEXT NOT NULL CHECK (email = lower(btrim(email)) AND position('@' IN email) > 0),
  role        TEXT NOT NULL CHECK (role IN ('manager', 'agent')),
  token_hash  TEXT NOT NULL UNIQUE,
  invited_by  UUID NOT NULL REFERENCES users(id),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at  TIMESTAMPTZ NOT NULL DEFAULT now() + interval '7 days',
  accepted_at TIMESTAMPTZ,
  accepted_by UUID REFERENCES users(id),
  revoked_at  TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_agency_invites_agency_email ON agency_invites(agency_id, email);

ALTER TABLE agency_invites ENABLE ROW LEVEL SECURITY;

-- Owner/Manager read their agency's invites. No write policies.
CREATE POLICY agency_invites_select ON agency_invites FOR SELECT TO authenticated
  USING (agency_id = public.current_user_agency_id() AND public.is_owner_or_manager());

-- Table privileges: anon nothing; authenticated may SELECT every
-- column except token_hash; no direct writes for either.
REVOKE ALL ON agency_invites FROM PUBLIC, anon, authenticated;
GRANT SELECT (id, agency_id, email, role, invited_by, created_at, expires_at,
              accepted_at, accepted_by, revoked_at)
  ON agency_invites TO authenticated;

-- ------------------------------------------------------------
-- 2. create_invite(email, role) -> {invite_id, code, expires_at}
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_invite(p_email TEXT, p_role TEXT)
RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role   TEXT := public.current_user_role();      -- NULL if deactivated / not a member
  v_agency UUID := public.current_user_agency_id();
  v_email  TEXT := lower(btrim(p_email));
  v_code   TEXT;
  v_id     UUID;
  v_exp    TIMESTAMPTZ;
BEGIN
  IF v_agency IS NULL
     OR NOT (   (v_role = 'owner'   AND p_role IN ('manager', 'agent'))
             OR (v_role = 'manager' AND p_role = 'agent')) THEN
    RAISE EXCEPTION 'You are not allowed to invite that role' USING ERRCODE = '42501';
  END IF;

  IF v_email IS NULL OR position('@' IN v_email) = 0 THEN
    RAISE EXCEPTION 'Enter a valid email address';
  END IF;

  -- Serialise concurrent invites for the same agency + email so the
  -- duplicate check below cannot be raced.
  PERFORM pg_advisory_xact_lock(hashtextextended(v_agency::text || ':' || v_email, 0));

  -- Already a member (active or deactivated), by profile or auth email
  IF EXISTS (
    SELECT 1
      FROM users u
      LEFT JOIN auth.users au ON au.id = u.id
     WHERE u.agency_id = v_agency
       AND (lower(btrim(u.email)) = v_email OR lower(btrim(au.email)) = v_email)
  ) THEN
    RAISE EXCEPTION 'That person is already a member of this agency';
  END IF;

  IF EXISTS (
    SELECT 1 FROM agency_invites
     WHERE agency_id = v_agency AND email = v_email
       AND accepted_at IS NULL AND revoked_at IS NULL AND expires_at > now()
  ) THEN
    RAISE EXCEPTION 'There is already a pending invite for this email';
  END IF;

  v_code := encode(extensions.gen_random_bytes(32), 'hex');

  INSERT INTO agency_invites (agency_id, email, role, token_hash, invited_by)
  VALUES (v_agency, v_email, p_role,
          encode(extensions.digest(v_code, 'sha256'), 'hex'), auth.uid())
  RETURNING id, expires_at INTO v_id, v_exp;

  RETURN jsonb_build_object('invite_id', v_id, 'code', v_code, 'expires_at', v_exp);
END;
$$;

-- ------------------------------------------------------------
-- 3. get_invite_preview(code) -> {agency_name, role, email}
--    Same generic error for malformed, unknown, expired, revoked
--    or accepted codes.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_invite_preview(p_code TEXT)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_code   TEXT := lower(p_code);
  v_result JSONB;
BEGIN
  IF v_code IS NULL OR v_code !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'Invalid or expired invite';
  END IF;

  SELECT jsonb_build_object('agency_name', a.name, 'role', i.role, 'email', i.email)
    INTO v_result
    FROM agency_invites i
    JOIN agencies a ON a.id = i.agency_id
   WHERE i.token_hash = encode(extensions.digest(v_code, 'sha256'), 'hex')
     AND i.accepted_at IS NULL AND i.revoked_at IS NULL AND i.expires_at > now();

  IF v_result IS NULL THEN
    RAISE EXCEPTION 'Invalid or expired invite';
  END IF;

  RETURN v_result;
END;
$$;

-- ------------------------------------------------------------
-- 4. accept_invite(code, full_name) -> {agency_id, role}
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.accept_invite(p_code TEXT, p_full_name TEXT)
RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid    UUID := auth.uid();
  v_code   TEXT := lower(p_code);
  v_name   TEXT := btrim(p_full_name);
  v_email  TEXT;
  v_invite agency_invites%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '42501';
  END IF;

  IF v_name IS NULL OR length(v_name) < 2 THEN
    RAISE EXCEPTION 'Enter your full name';
  END IF;

  IF v_code IS NULL OR v_code !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'Invalid or expired invite';
  END IF;

  -- Lock the invite so a code cannot be accepted twice concurrently
  SELECT * INTO v_invite
    FROM agency_invites
   WHERE token_hash = encode(extensions.digest(v_code, 'sha256'), 'hex')
   FOR UPDATE;

  IF NOT FOUND
     OR v_invite.accepted_at IS NOT NULL
     OR v_invite.revoked_at IS NOT NULL
     OR v_invite.expires_at <= now() THEN
    RAISE EXCEPTION 'Invalid or expired invite';
  END IF;

  SELECT lower(btrim(email)) INTO v_email FROM auth.users WHERE id = v_uid;
  IF v_email IS DISTINCT FROM v_invite.email THEN
    RAISE EXCEPTION 'This invite is for a different email address';
  END IF;

  IF EXISTS (SELECT 1 FROM users WHERE id = v_uid) THEN
    RAISE EXCEPTION 'This account already belongs to an agency';
  END IF;

  INSERT INTO users (id, agency_id, role, full_name, email)
  VALUES (v_uid, v_invite.agency_id, v_invite.role, v_name, v_invite.email);

  UPDATE agency_invites
     SET accepted_at = now(), accepted_by = v_uid
   WHERE id = v_invite.id;

  RETURN jsonb_build_object('agency_id', v_invite.agency_id, 'role', v_invite.role);
END;
$$;

-- ------------------------------------------------------------
-- 5. revoke_invite(invite_id)
--    Owner: any invite in the agency. Manager: only agent invites
--    they created themselves (invited_by = auth.uid()).
--    (Applied live as 007a_revoke_invite_own_only.)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.revoke_invite(p_invite_id UUID)
RETURNS VOID
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role   TEXT := public.current_user_role();
  v_agency UUID := public.current_user_agency_id();
  v_invite agency_invites%ROWTYPE;
BEGIN
  IF v_agency IS NULL OR v_role NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'You are not allowed to revoke that invite' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_invite
    FROM agency_invites
   WHERE id = p_invite_id AND agency_id = v_agency
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Invalid or expired invite';
  END IF;

  IF v_role = 'manager'
     AND (v_invite.role <> 'agent' OR v_invite.invited_by IS DISTINCT FROM auth.uid()) THEN
    RAISE EXCEPTION 'You are not allowed to revoke that invite' USING ERRCODE = '42501';
  END IF;

  IF v_invite.accepted_at IS NOT NULL OR v_invite.revoked_at IS NOT NULL THEN
    RAISE EXCEPTION 'Invalid or expired invite';
  END IF;

  UPDATE agency_invites SET revoked_at = now() WHERE id = v_invite.id;
END;
$$;

-- ------------------------------------------------------------
-- 6. Grants
-- ------------------------------------------------------------
REVOKE EXECUTE ON FUNCTION public.create_invite(TEXT, TEXT)      FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.get_invite_preview(TEXT)       FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.accept_invite(TEXT, TEXT)      FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.revoke_invite(UUID)            FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.create_invite(TEXT, TEXT)       TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_invite_preview(TEXT)        TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.accept_invite(TEXT, TEXT)       TO authenticated;
GRANT EXECUTE ON FUNCTION public.revoke_invite(UUID)             TO authenticated;
