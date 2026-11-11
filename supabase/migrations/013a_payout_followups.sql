-- ============================================================
-- Migration 013a: Agent payout follow-ups (applied live as
-- 013a_payout_followups)
--
--   1. create_agent_payout gains p_expected_total (last parameter,
--      DEFAULT NULL): when given and the locked sum differs, the
--      payout is refused ('The amount owed changed — review the
--      payout again') so a stale preview never pays a different
--      amount. The old 5-argument function is dropped.
--   2. Reversal dating: undoing an UNPAID commission earning dates
--      the reversal on the original's earned_on (any payout window
--      that includes the original also includes its reversal, so
--      they cancel). Undoing a PAID earning dates it today
--      (Africa/Nairobi), so it comes off the next payout.
--   3. Adjustments are dated today in Africa/Nairobi (not the
--      server's current_date).
--   4. Removed members: set_agent_rates accepts deactivated members
--      of the agency; remove_member deletes the member's agent_rates.
-- ============================================================

-- ------------------------------------------------------------
-- 1. create_agent_payout with the expected-total guard
-- ------------------------------------------------------------
DROP FUNCTION IF EXISTS public.create_agent_payout(UUID, DATE, DATE, TEXT, TEXT);

CREATE OR REPLACE FUNCTION public.create_agent_payout(
  p_user_id        UUID,
  p_period_end     DATE,
  p_paid_on        DATE,
  p_method         TEXT,
  p_reference      TEXT,
  p_expected_total NUMERIC DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_agency UUID := public.current_user_agency_id();
  v_ids    UUID[];
  v_total  NUMERIC;
  v_payout UUID;
  v_lines  JSONB;
BEGIN
  IF v_agency IS NULL OR NOT public.is_owner_or_manager() THEN
    RAISE EXCEPTION 'Only owners and managers can do that' USING ERRCODE = '42501';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM users WHERE id = p_user_id AND agency_id = v_agency) THEN
    RAISE EXCEPTION 'Pick a member of this agency' USING ERRCODE = '22023';
  END IF;
  IF p_period_end IS NULL THEN
    RAISE EXCEPTION 'Pick a pay-up-to date' USING ERRCODE = '22023';
  END IF;
  IF p_paid_on IS NULL THEN
    RAISE EXCEPTION 'Enter the date paid' USING ERRCODE = '22023';
  END IF;
  IF p_method IS NULL OR p_method NOT IN ('mpesa', 'bank', 'cash') THEN
    RAISE EXCEPTION 'Pick a payment method' USING ERRCODE = '22023';
  END IF;

  -- Lock in id order; a concurrent payout's rows drop out on re-check
  -- (payout_id no longer NULL), so nothing is paid twice.
  SELECT array_agg(id), COALESCE(SUM(amount), 0) INTO v_ids, v_total
    FROM (SELECT e.id, e.amount
            FROM agent_earnings e
           WHERE e.agency_id = v_agency
             AND e.agent_id = p_user_id
             AND e.payout_id IS NULL
             AND e.earned_on <= p_period_end
           ORDER BY e.id
             FOR UPDATE) s;

  -- The caller confirmed a preview: pay that amount or nothing.
  IF p_expected_total IS NOT NULL AND round(v_total, 2) <> round(p_expected_total, 2) THEN
    RAISE EXCEPTION 'The amount owed changed — review the payout again' USING ERRCODE = '22023';
  END IF;

  IF v_total <= 0 THEN
    RAISE EXCEPTION 'Nothing to pay for this agent up to that date' USING ERRCODE = '22023';
  END IF;

  INSERT INTO agent_payouts (agency_id, agent_id, period_end, paid_on, method, reference, amount, created_by)
  VALUES (v_agency, p_user_id, p_period_end, p_paid_on, p_method,
          NULLIF(btrim(p_reference), ''), round(v_total, 2), auth.uid())
  RETURNING id INTO v_payout;

  UPDATE agent_earnings SET payout_id = v_payout WHERE id = ANY (v_ids);

  SELECT jsonb_agg(jsonb_build_object(
           'id', e.id, 'kind', e.kind, 'earned_on', e.earned_on,
           'policy_number', e.policy_number, 'client_name', e.client_name,
           'base_amount', e.base_amount, 'rate', e.rate, 'amount', e.amount,
           'note', e.note)
           ORDER BY e.earned_on, e.created_at, e.id)
    INTO v_lines
    FROM agent_earnings e WHERE e.payout_id = v_payout;

  RETURN jsonb_build_object('payout_id', v_payout, 'amount', round(v_total, 2), 'lines', v_lines);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.create_agent_payout(UUID, DATE, DATE, TEXT, TEXT, NUMERIC) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.create_agent_payout(UUID, DATE, DATE, TEXT, TEXT, NUMERIC) TO authenticated;

-- ------------------------------------------------------------
-- 2. Reversal dating
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.allocation_agent_reversal()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_e agent_earnings;
BEGIN
  SELECT e.* INTO v_e
    FROM agent_earnings e
   WHERE e.allocation_id = OLD.id
     AND e.kind = 'commission'
     AND NOT EXISTS (SELECT 1 FROM agent_earnings r WHERE r.reverses_earning_id = e.id)
   ORDER BY e.created_at
   LIMIT 1
     FOR UPDATE;
  IF v_e.id IS NULL THEN
    RETURN NULL;
  END IF;

  INSERT INTO agent_earnings
    (agency_id, agent_id, kind, allocation_id, reverses_earning_id, policy_id, commission_id,
     policy_number, client_name, base_amount, rate, amount, earned_on, created_by)
  VALUES
    (v_e.agency_id, v_e.agent_id, 'reversal', v_e.allocation_id, v_e.id,
     (SELECT id FROM policies WHERE id = v_e.policy_id),
     (SELECT id FROM commission_transactions WHERE id = v_e.commission_id),
     v_e.policy_number, v_e.client_name, -v_e.base_amount, v_e.rate, -v_e.amount,
     -- unpaid: same date as the original, so they cancel in any payout;
     -- paid: today, so it comes off the next payout
     CASE WHEN v_e.payout_id IS NULL THEN v_e.earned_on
          ELSE (now() AT TIME ZONE 'Africa/Nairobi')::date END,
     auth.uid());

  RETURN NULL;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.allocation_agent_reversal() FROM PUBLIC, anon, authenticated;

-- ------------------------------------------------------------
-- 3. add_agent_adjustment: dated today in Africa/Nairobi
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.add_agent_adjustment(p_user_id UUID, p_amount NUMERIC, p_note TEXT)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_agency UUID := public.current_user_agency_id();
  v_id     UUID;
BEGIN
  IF v_agency IS NULL OR public.current_user_role() IS DISTINCT FROM 'owner' THEN
    RAISE EXCEPTION 'Only the owner can do that' USING ERRCODE = '42501';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM users WHERE id = p_user_id AND agency_id = v_agency) THEN
    RAISE EXCEPTION 'Pick a member of this agency' USING ERRCODE = '22023';
  END IF;
  IF p_amount IS NULL OR round(p_amount, 2) = 0 THEN
    RAISE EXCEPTION 'Enter an amount' USING ERRCODE = '22023';
  END IF;
  IF p_note IS NULL OR btrim(p_note) = '' THEN
    RAISE EXCEPTION 'Add a note for this adjustment' USING ERRCODE = '22023';
  END IF;

  INSERT INTO agent_earnings (agency_id, agent_id, kind, amount, earned_on, note, created_by)
  VALUES (v_agency, p_user_id, 'adjustment', round(p_amount, 2),
          (now() AT TIME ZONE 'Africa/Nairobi')::date, btrim(p_note), auth.uid())
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.add_agent_adjustment(UUID, NUMERIC, TEXT) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.add_agent_adjustment(UUID, NUMERIC, TEXT) TO authenticated;

-- ------------------------------------------------------------
-- 4a. set_agent_rates: any member of the agency, removed or not
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_agent_rates(p_user_id UUID, p_default_rate NUMERIC, p_overrides JSONB)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_agency UUID := public.current_user_agency_id();
  v_ov     JSONB;
  v_pl     UUID;
  v_rate   NUMERIC;
BEGIN
  IF v_agency IS NULL OR public.current_user_role() IS DISTINCT FROM 'owner' THEN
    RAISE EXCEPTION 'Only the owner can do that' USING ERRCODE = '42501';
  END IF;

  PERFORM 1 FROM users
   WHERE id = p_user_id AND agency_id = v_agency
   FOR SHARE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Pick a member of this agency' USING ERRCODE = '22023';
  END IF;

  p_overrides := COALESCE(p_overrides, '[]'::jsonb);
  IF jsonb_typeof(p_overrides) <> 'array' THEN
    RAISE EXCEPTION 'Pick a product line of this agency' USING ERRCODE = '22023';
  END IF;

  IF p_default_rate IS NOT NULL AND (p_default_rate < 0 OR p_default_rate > 100) THEN
    RAISE EXCEPTION 'Rate must be between 0 and 100' USING ERRCODE = '22023';
  END IF;

  FOR v_ov IN SELECT value FROM jsonb_array_elements(p_overrides)
  LOOP
    v_rate := NULLIF(v_ov->>'rate', '')::numeric;
    IF v_rate IS NULL OR v_rate < 0 OR v_rate > 100 THEN
      RAISE EXCEPTION 'Rate must be between 0 and 100' USING ERRCODE = '22023';
    END IF;
    v_pl := NULLIF(v_ov->>'product_line_id', '')::uuid;
    IF v_pl IS NULL OR NOT EXISTS (SELECT 1 FROM product_lines WHERE id = v_pl AND agency_id = v_agency) THEN
      RAISE EXCEPTION 'Pick a product line of this agency' USING ERRCODE = '22023';
    END IF;
  END LOOP;

  IF (SELECT count(*) <> count(DISTINCT value->>'product_line_id')
        FROM jsonb_array_elements(p_overrides)) THEN
    RAISE EXCEPTION 'Pick each product line once' USING ERRCODE = '22023';
  END IF;

  DELETE FROM agent_rates WHERE user_id = p_user_id;

  IF p_default_rate IS NOT NULL THEN
    INSERT INTO agent_rates (agency_id, user_id, product_line_id, rate, updated_by)
    VALUES (v_agency, p_user_id, NULL, p_default_rate, auth.uid());
  END IF;

  INSERT INTO agent_rates (agency_id, user_id, product_line_id, rate, updated_by)
  SELECT v_agency, p_user_id, (value->>'product_line_id')::uuid, (value->>'rate')::numeric, auth.uid()
    FROM jsonb_array_elements(p_overrides);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.set_agent_rates(UUID, NUMERIC, JSONB) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.set_agent_rates(UUID, NUMERIC, JSONB) TO authenticated;

-- ------------------------------------------------------------
-- 4b. remove_member: as in 008 (+ 008a policy sweep), and the
--     removed member's agent_rates are deleted
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
  v_swept    INTEGER;
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

  -- Sweep the member's remaining live policies on clients assigned to
  -- someone else (owners/managers may set any agent_id). Expired and
  -- cancelled policies stay with the removed member.
  -- (Applied live as 008a_remove_member_sweeps_policies.)
  UPDATE policies
     SET agent_id = p_reassign_to,
         updated_at = now()
   WHERE agency_id = v_agency
     AND agent_id = v_target.id
     AND status IN ('active', 'pending');
  GET DIAGNOSTICS v_swept = ROW_COUNT;
  v_policies := v_policies + v_swept;

  UPDATE agency_invites
     SET revoked_at = now()
   WHERE agency_id = v_agency
     AND invited_by = v_target.id
     AND accepted_at IS NULL AND revoked_at IS NULL AND expires_at > now();
  GET DIAGNOSTICS v_invites = ROW_COUNT;

  -- A removed member earns nothing more (013a). Their earnings and
  -- payouts stay; the Owner can still set rates again if needed.
  DELETE FROM agent_rates WHERE agency_id = v_agency AND user_id = v_target.id;

  UPDATE users SET deactivated_at = now() WHERE id = v_target.id;

  RETURN jsonb_build_object(
    'clients_moved',   v_clients,
    'policies_moved',  v_policies,
    'invites_revoked', v_invites);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.remove_member(UUID, UUID) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.remove_member(UUID, UUID) TO authenticated;
