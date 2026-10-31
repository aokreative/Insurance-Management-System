-- ============================================================
-- Migration 005: Lock down SECURITY DEFINER functions
--
-- create_agency_with_owner trusted a client-supplied user id and
-- email, and (like every function here) was executable by anon via
-- the default PUBLIC grant. It now takes the caller from auth.uid()
-- and the email from auth.users, and refuses a second agency.
--
-- seed_default_product_lines and mark_overdue_commissions bypass RLS
-- for arbitrary agencies, so they are no longer callable from the
-- browser at all. All SECURITY DEFINER functions get a fixed
-- search_path.
-- ============================================================

DROP FUNCTION IF EXISTS public.create_agency_with_owner(UUID, TEXT, TEXT, TEXT, TEXT);

CREATE OR REPLACE FUNCTION public.create_agency_with_owner(
  p_agency_name TEXT,
  p_owner_name  TEXT,
  p_owner_phone TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid       UUID := auth.uid();
  v_email     TEXT;
  v_agency_id UUID;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '42501';
  END IF;

  IF EXISTS (SELECT 1 FROM users WHERE id = v_uid) THEN
    RAISE EXCEPTION 'This account already belongs to an agency' USING ERRCODE = '23505';
  END IF;

  IF length(trim(coalesce(p_agency_name, ''))) < 2 OR length(trim(coalesce(p_owner_name, ''))) < 2 THEN
    RAISE EXCEPTION 'Agency name and owner name are required' USING ERRCODE = '22023';
  END IF;

  SELECT email INTO v_email FROM auth.users WHERE id = v_uid;

  INSERT INTO agencies (name, email)
  VALUES (trim(p_agency_name), v_email)
  RETURNING id INTO v_agency_id;

  INSERT INTO users (id, agency_id, role, full_name, phone, email)
  VALUES (v_uid, v_agency_id, 'owner', trim(p_owner_name), p_owner_phone, v_email);

  PERFORM public.seed_default_product_lines(v_agency_id);

  RETURN jsonb_build_object('agency_id', v_agency_id);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.create_agency_with_owner(TEXT, TEXT, TEXT) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.create_agency_with_owner(TEXT, TEXT, TEXT) TO authenticated;

-- Internal only: called by create_agency_with_owner (runs as owner) and by cron/service_role.
REVOKE EXECUTE ON FUNCTION public.seed_default_product_lines(UUID) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.mark_overdue_commissions()       FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.auto_create_renewal_reminders()  FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.mark_overdue_commissions()       TO service_role;

-- RLS helpers keep their grants: policies evaluate them for every role, and for
-- anon they return NULL (auth.uid() is NULL), so they expose nothing.
ALTER FUNCTION public.current_user_agency_id()          SET search_path = public;
ALTER FUNCTION public.current_user_role()               SET search_path = public;
ALTER FUNCTION public.seed_default_product_lines(UUID)  SET search_path = public;
ALTER FUNCTION public.mark_overdue_commissions()        SET search_path = public;
ALTER FUNCTION public.auto_create_renewal_reminders()   SET search_path = public;
