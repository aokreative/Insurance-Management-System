-- ============================================================
-- Migration 008: Team management RPCs
--
--   reassign_client(client_id, new_agent_id) -> {policies_moved}
--     Owner/Manager. Sets clients.assigned_agent_id and moves the
--     client's active + pending policies to the new agent; expired
--     and cancelled policies keep their original agent so
--     commission history is not rewritten.
--   change_member_role(user_id, role)        -> void
--     Owner. manager <-> agent only; never the Owner.
--   remove_member(user_id, reassign_to)      -> {clients_moved,
--                                                policies_moved,
--                                                invites_revoked}
--     Owner. Reassigns all the member's clients (same rules as
--     reassign_client), revokes their live invites, then sets
--     deactivated_at. Never the Owner.
--
-- `users` has no write policies, so these are SECURITY DEFINER.
-- Callers are identified via current_user_role() /
-- current_user_agency_id(), which return NULL for deactivated
-- users, so a deactivated caller is always refused.
--
-- Error codes: 42501 permission, 22023 bad target/role,
-- P0002 client not found (also for other agencies' clients).
-- ============================================================

-- ------------------------------------------------------------
-- 1. Internal helper: no permission checks. Not callable by any
--    API role; only from the RPCs below.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._reassign_client_unchecked(p_client_id UUID, p_new_agent_id UUID)
RETURNS INTEGER
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_moved INTEGER;
BEGIN
  UPDATE clients
     SET assigned_agent_id = p_new_agent_id
   WHERE id = p_client_id;

  -- Only commission_received is guarded by trigger 006a; it is not touched here.
  UPDATE policies
     SET agent_id = p_new_agent_id,
         updated_at = now()
   WHERE client_id = p_client_id
     AND status IN ('active', 'pending')
     AND agent_id IS DISTINCT FROM p_new_agent_id;
  GET DIAGNOSTICS v_moved = ROW_COUNT;

  RETURN v_moved;
END;
$$;

REVOKE EXECUTE ON FUNCTION public._reassign_client_unchecked(UUID, UUID) FROM PUBLIC, anon, authenticated;

-- ------------------------------------------------------------
-- 2. reassign_client
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.reassign_client(p_client_id UUID, p_new_agent_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role   TEXT := public.current_user_role();
  v_agency UUID := public.current_user_agency_id();
BEGIN
  IF v_agency IS NULL OR v_role IS NULL OR v_role NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'Only owners and managers can do that' USING ERRCODE = '42501';
  END IF;

  -- Lock the client; same error whether it is missing or in another agency
  PERFORM 1 FROM clients
   WHERE id = p_client_id AND agency_id = v_agency
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Client not found' USING ERRCODE = 'P0002';
  END IF;

  -- Lock the target member row so it cannot be deactivated concurrently
  PERFORM 1 FROM users
   WHERE id = p_new_agent_id AND agency_id = v_agency AND deactivated_at IS NULL
   FOR SHARE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Pick an active member of this agency' USING ERRCODE = '22023';
  END IF;

  RETURN jsonb_build_object(
    'policies_moved', public._reassign_client_unchecked(p_client_id, p_new_agent_id));
END;
$$;

-- ------------------------------------------------------------
-- 3. change_member_role
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.change_member_role(p_user_id UUID, p_role TEXT)
RETURNS VOID
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role   TEXT := public.current_user_role();
  v_agency UUID := public.current_user_agency_id();
  v_target users%ROWTYPE;
BEGIN
  IF v_agency IS NULL OR v_role IS DISTINCT FROM 'owner' THEN
    RAISE EXCEPTION 'Only the owner can do that' USING ERRCODE = '42501';
  END IF;

  IF p_role IS NULL OR p_role NOT IN ('manager', 'agent') THEN
    RAISE EXCEPTION 'Role must be manager or agent' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_target
    FROM users
   WHERE id = p_user_id AND agency_id = v_agency
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Pick an active member of this agency' USING ERRCODE = '22023';
  END IF;
  IF v_target.role = 'owner' THEN
    RAISE EXCEPTION 'The owner cannot be changed or removed' USING ERRCODE = '42501';
  END IF;
  IF v_target.deactivated_at IS NOT NULL THEN
    RAISE EXCEPTION 'Pick an active member of this agency' USING ERRCODE = '22023';
  END IF;

  IF v_target.role IS DISTINCT FROM p_role THEN
    UPDATE users SET role = p_role WHERE id = v_target.id;
  END IF;
END;
$$;

-- ------------------------------------------------------------
-- 4. remove_member
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.remove_member(p_user_id UUID, p_reassign_to UUID)
RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role     TEXT := public.current_user_role();
  v_agency   UUID := public.current_user_agency_id();
  v_target   users%ROWTYPE;
  v_client   UUID;
  v_clients  INTEGER := 0;
  v_policies INTEGER := 0;
  v_invites  INTEGER;
BEGIN
  IF v_agency IS NULL OR v_role IS DISTINCT FROM 'owner' THEN
    RAISE EXCEPTION 'Only the owner can do that' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_target
    FROM users
   WHERE id = p_user_id AND agency_id = v_agency
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Pick an active member of this agency' USING ERRCODE = '22023';
  END IF;
  IF v_target.role = 'owner' THEN
    RAISE EXCEPTION 'The owner cannot be changed or removed' USING ERRCODE = '42501';
  END IF;
  IF v_target.deactivated_at IS NOT NULL THEN
    RAISE EXCEPTION 'Pick an active member of this agency' USING ERRCODE = '22023';
  END IF;

  -- The new assignee: an active member of the agency, not the one being removed
  PERFORM 1 FROM users
   WHERE id = p_reassign_to AND id <> v_target.id
     AND agency_id = v_agency AND deactivated_at IS NULL
   FOR SHARE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Pick an active member of this agency' USING ERRCODE = '22023';
  END IF;

  FOR v_client IN
    SELECT id FROM clients
     WHERE agency_id = v_agency AND assigned_agent_id = v_target.id
     ORDER BY id
     FOR UPDATE
  LOOP
    v_policies := v_policies + public._reassign_client_unchecked(v_client, p_reassign_to);
    v_clients  := v_clients + 1;
  END LOOP;

  UPDATE agency_invites
     SET revoked_at = now()
   WHERE agency_id = v_agency
     AND invited_by = v_target.id
     AND accepted_at IS NULL AND revoked_at IS NULL AND expires_at > now();
  GET DIAGNOSTICS v_invites = ROW_COUNT;

  UPDATE users SET deactivated_at = now() WHERE id = v_target.id;

  RETURN jsonb_build_object(
    'clients_moved',   v_clients,
    'policies_moved',  v_policies,
    'invites_revoked', v_invites);
END;
$$;

-- ------------------------------------------------------------
-- 5. Grants
-- ------------------------------------------------------------
REVOKE EXECUTE ON FUNCTION public.reassign_client(UUID, UUID)    FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.change_member_role(UUID, TEXT) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.remove_member(UUID, UUID)      FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.reassign_client(UUID, UUID)     TO authenticated;
GRANT EXECUTE ON FUNCTION public.change_member_role(UUID, TEXT)  TO authenticated;
GRANT EXECUTE ON FUNCTION public.remove_member(UUID, UUID)       TO authenticated;
