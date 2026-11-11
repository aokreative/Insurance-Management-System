-- ============================================================
-- Test 013a: agent payout follow-ups
--   - create_agent_payout expected-total guard (mismatch pays
--     nothing; match pays)
--   - reversal dating: undo of an unpaid earning keeps its date
--     (and nets in a payout up to that date); undo of a paid
--     earning is dated today (Africa/Nairobi)
--   - set_agent_rates on a deactivated member
--   - remove_member deletes the member's rates
--   - grants: one create_agent_payout signature
--
-- Run the whole file in one go. One transaction, ALWAYS rolled
-- back: on success the final SELECT returns 'ALL PASSED'.
-- ============================================================

BEGIN;
-- current_date in this file means "today in Nairobi", like the RPCs
SET LOCAL TIME ZONE 'Africa/Nairobi';

CREATE FUNCTION public._t013a_expect(p_sql TEXT, p_msg TEXT, p_state TEXT DEFAULT NULL)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
  v_msg TEXT;
  v_st  TEXT;
  v_ran BOOLEAN := false;
BEGIN
  BEGIN
    EXECUTE p_sql;
    v_ran := true;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT, v_st = RETURNED_SQLSTATE;
  END;
  ASSERT NOT v_ran, format('expected error %s %s, but it succeeded: %s', p_state, p_msg, p_sql);
  ASSERT (p_msg IS NULL OR v_msg = p_msg) AND (p_state IS NULL OR v_st = p_state),
    format('expected [%s] %s, got [%s] %s for: %s', p_state, p_msg, v_st, v_msg, p_sql);
END;
$$;
GRANT EXECUTE ON FUNCTION public._t013a_expect(TEXT, TEXT, TEXT) TO authenticated;

DO $$
DECLARE
  ag    UUID := gen_random_uuid();
  ag2   UUID := gen_random_uuid();
  o     UUID := gen_random_uuid();
  m     UUID := gen_random_uuid();
  a1    UUID := gen_random_uuid();
  a2    UUID := gen_random_uuid();
  o2    UUID := gen_random_uuid();
  ins   UUID;
  pl_m  UUID;
  cl1   UUID := gen_random_uuid();
  cl2   UUID := gen_random_uuid();
  p1    UUID := gen_random_uuid();
  p2    UUID := gen_random_uuid();
  p3    UUID := gen_random_uuid();
  c1    UUID;
  c2    UUID;
  c3    UUID;
  r     JSONB;
  al1   UUID;
  e1    UUID;
  pay1  UUID;
  n     INTEGER;
  v_num NUMERIC;
  v_uid UUID;
  v_date DATE;
  v_today DATE := (now() AT TIME ZONE 'Africa/Nairobi')::date;
BEGIN
  PERFORM set_config('request.jwt.claims', '{}', true);

  INSERT INTO auth.users (id, email, aud, role, instance_id) VALUES
    (o,  'o-013a@test.local',  'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000'),
    (m,  'm-013a@test.local',  'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000'),
    (a1, 'a1-013a@test.local', 'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000'),
    (a2, 'a2-013a@test.local', 'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000'),
    (o2, 'o2-013a@test.local', 'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000');

  INSERT INTO agencies (id, name) VALUES (ag, 'Test Agency 013a'), (ag2, 'Other Agency 013a');
  INSERT INTO users (id, agency_id, role, full_name, email) VALUES
    (o,  ag,  'owner',   'Owner 013a',   'o-013a@test.local'),
    (m,  ag,  'manager', 'Manager 013a', 'm-013a@test.local'),
    (a1, ag,  'agent',   'Agent1 013a',  'a1-013a@test.local'),
    (a2, ag,  'agent',   'Agent2 013a',  'a2-013a@test.local'),
    (o2, ag2, 'owner',   'Owner2 013a',  'o2-013a@test.local');

  INSERT INTO insurers (agency_id, name) VALUES (ag, 'Insurer 013a') RETURNING id INTO ins;
  INSERT INTO product_lines (agency_id, name) VALUES (ag, 'Motor 013a') RETURNING id INTO pl_m;
  INSERT INTO clients (id, agency_id, type, name, assigned_agent_id) VALUES
    (cl1, ag, 'individual', 'Client One 013a', a1),
    (cl2, ag, 'individual', 'Client Two 013a', a2);

  INSERT INTO policies (id, agency_id, client_id, insurer_id, product_line_id, agent_id,
                        policy_number, premium_amount, commission_rate, commission_basis,
                        start_date, expiry_date, status)
  VALUES
    (p1, ag, cl1, ins, pl_m, a1, 'T013A-P1', 100000, 10, 'annual', DATE '2026-01-15', DATE '2027-01-14', 'active'),
    (p2, ag, cl1, ins, pl_m, a1, 'T013A-P2', 100000, 10, 'annual', DATE '2026-01-20', DATE '2027-01-19', 'active'),
    (p3, ag, cl2, ins, pl_m, a2, 'T013A-P3', 100000, 10, 'annual', DATE '2026-02-01', DATE '2027-01-31', 'active');

  SELECT id INTO c1 FROM commission_transactions WHERE policy_id = p1;
  SELECT id INTO c2 FROM commission_transactions WHERE policy_id = p2;
  SELECT id INTO c3 FROM commission_transactions WHERE policy_id = p3;

  -- ---------------------------------------------------------
  -- 1. Expected-total guard
  -- ---------------------------------------------------------
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', o, 'role','authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    PERFORM set_agent_rates(a1, 40, '[]'::jsonb);
    r := create_insurer_receipt(ins, DATE '2026-03-01', 1000, NULL, NULL, '[]'::jsonb,
           jsonb_build_array(jsonb_build_object('commission_id', c1, 'amount', 1000)));

    PERFORM set_config('request.jwt.claims', json_build_object('sub', m, 'role','authenticated')::text, true);
    PERFORM _t013a_expect(format(
      'SELECT create_agent_payout(%L, current_date, current_date, ''mpesa'', NULL, 399.99)', a1),
      'The amount owed changed — review the payout again', '22023');
    SELECT count(*) INTO n FROM agent_payouts WHERE agent_id = a1;
    ASSERT n = 0, format('guard: mismatch created %s payouts', n);
    SELECT count(*) INTO n FROM agent_earnings WHERE agent_id = a1 AND payout_id IS NOT NULL;
    ASSERT n = 0, format('guard: mismatch marked %s earnings paid', n);

    -- a stale preview of 0 (nothing owed) when 400 is now owed
    PERFORM _t013a_expect(format(
      'SELECT create_agent_payout(%L, current_date, current_date, ''mpesa'', NULL, 0)', a1),
      'The amount owed changed — review the payout again', '22023');

    r := create_agent_payout(a1, current_date, current_date, 'mpesa', 'G-1', 400);
    ASSERT (r->>'amount')::numeric = 400, format('guard: match expected 400, got %s', r->>'amount');
    SELECT count(*) INTO n FROM agent_earnings WHERE agent_id = a1 AND payout_id = (r->>'payout_id')::uuid;
    ASSERT n = 1, format('guard: match expected 1 earning paid, got %s', n);

    -- NULL expected total keeps the old behaviour
    PERFORM _t013a_expect(format(
      'SELECT create_agent_payout(%L, current_date, current_date, ''mpesa'', NULL, NULL)', a1),
      'Nothing to pay for this agent up to that date');

    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
  END;

  -- ---------------------------------------------------------
  -- 2. Undo of an unpaid earning keeps its date; nets in a payout
  -- ---------------------------------------------------------
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', o, 'role','authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    PERFORM set_agent_rates(a1, 40, '[]'::jsonb);

    r := create_insurer_receipt(ins, DATE '2026-10-31', 2000, NULL, NULL, '[]'::jsonb,
           jsonb_build_array(jsonb_build_object('commission_id', c1, 'amount', 1000),
                             jsonb_build_object('commission_id', c2, 'amount', 1000)));
    SELECT id INTO al1 FROM commission_allocations
     WHERE receipt_id = (r->>'receipt_id')::uuid AND commission_id = c1;
    SELECT id INTO e1 FROM agent_earnings WHERE allocation_id = al1 AND kind = 'commission';

    PERFORM undo_commission_allocation(al1);
    SELECT earned_on, amount INTO v_date, v_num
      FROM agent_earnings WHERE reverses_earning_id = e1;
    ASSERT v_date = DATE '2026-10-31' AND v_num = -400,
      format('unpaid undo: reversal expected 2026-10-31 / -400, got %s / %s', v_date, v_num);

    r := preview_agent_payout(a1, DATE '2026-10-31');
    ASSERT (r->>'total')::numeric = 400 AND jsonb_array_length(r->'lines') = 3,
      format('unpaid undo: preview up to 2026-10-31 expected 400 / 3 lines, got %s', r);

    r := create_agent_payout(a1, DATE '2026-10-31', current_date, 'bank', 'N-1', 400);
    pay1 := (r->>'payout_id')::uuid;
    ASSERT (r->>'amount')::numeric = 400, format('unpaid undo: payout expected 400, got %s', r->>'amount');
    SELECT count(*) INTO n FROM agent_earnings WHERE payout_id = pay1;
    ASSERT n = 3, format('unpaid undo: payout expected commission + reversal + other, got %s', n);
    SELECT count(*) INTO n FROM agent_earnings WHERE agent_id = a1 AND payout_id IS NULL;
    ASSERT n = 0, format('unpaid undo: %s earnings left unpaid', n);

    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
  END;

  -- ---------------------------------------------------------
  -- 3. Undo of a paid earning is dated today (Nairobi)
  -- ---------------------------------------------------------
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', o, 'role','authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    PERFORM set_agent_rates(a1, 40, '[]'::jsonb);

    r := create_insurer_receipt(ins, DATE '2026-03-01', 1000, NULL, NULL, '[]'::jsonb,
           jsonb_build_array(jsonb_build_object('commission_id', c1, 'amount', 1000)));
    SELECT id INTO al1 FROM commission_allocations WHERE receipt_id = (r->>'receipt_id')::uuid;
    SELECT id INTO e1 FROM agent_earnings WHERE allocation_id = al1 AND kind = 'commission';
    r := create_agent_payout(a1, DATE '2026-03-31', current_date, 'mpesa', 'P-1', 400);

    PERFORM undo_commission_allocation(al1);
    SELECT earned_on, amount, payout_id INTO v_date, v_num, v_uid
      FROM agent_earnings WHERE reverses_earning_id = e1;
    ASSERT v_date = v_today AND v_num = -400 AND v_uid IS NULL,
      format('paid undo: reversal expected %s / -400 / unpaid, got %s / %s / %s', v_today, v_date, v_num, v_uid);
    r := preview_agent_payout(a1, DATE '2026-03-31');
    ASSERT (r->>'total')::numeric = 0, format('paid undo: reversal must not fall in the old window, got %s', r);

    -- adjustments are dated today in Nairobi too
    v_uid := add_agent_adjustment(a1, 50, 'Bonus');
    SELECT earned_on INTO v_date FROM agent_earnings WHERE id = v_uid;
    ASSERT v_date = v_today, format('adjustment: expected %s, got %s', v_today, v_date);

    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
  END;

  -- ---------------------------------------------------------
  -- 4. set_agent_rates on a deactivated member
  -- ---------------------------------------------------------
  BEGIN
    UPDATE users SET deactivated_at = now() WHERE id = a1;
    PERFORM set_config('request.jwt.claims', json_build_object('sub', o, 'role','authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    PERFORM set_agent_rates(a1, 25, '[]'::jsonb);
    SELECT rate INTO v_num FROM agent_rates WHERE user_id = a1 AND product_line_id IS NULL;
    ASSERT v_num = 25, format('deactivated: rate expected 25, got %s', v_num);
    PERFORM set_agent_rates(a1, NULL, '[]'::jsonb);
    SELECT count(*) INTO n FROM agent_rates WHERE user_id = a1;
    ASSERT n = 0, format('deactivated: clearing rates left %s rows', n);
    PERFORM _t013a_expect(format('SELECT set_agent_rates(%L, 40, ''[]'')', o2), 'Pick a member of this agency', '22023');
    PERFORM _t013a_expect(format('SELECT set_agent_rates(%L, 40, ''[]'')', gen_random_uuid()), 'Pick a member of this agency', '22023');

    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
  END;

  -- ---------------------------------------------------------
  -- 5. remove_member deletes the member's rates
  -- ---------------------------------------------------------
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', o, 'role','authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    PERFORM set_agent_rates(a1, 40, '[]'::jsonb);
    PERFORM set_agent_rates(a2, 20, jsonb_build_array(jsonb_build_object('product_line_id', pl_m, 'rate', 30)));

    r := remove_member(a2, m);
    ASSERT (r->>'clients_moved')::int = 1 AND (r->>'policies_moved')::int = 1,
      format('remove: result %s', r);
    RESET ROLE;
    SELECT count(*) INTO n FROM agent_rates WHERE user_id = a2;
    ASSERT n = 0, format('remove: a2 still has %s rates', n);
    SELECT count(*) INTO n FROM agent_rates WHERE user_id = a1;
    ASSERT n = 1, format('remove: a1 rates touched, %s left', n);
    SELECT agent_id INTO v_uid FROM policies WHERE id = p3;
    ASSERT v_uid = m, 'remove: policy should move to m';
    ASSERT (SELECT deactivated_at IS NOT NULL FROM users WHERE id = a2), 'remove: a2 should be deactivated';

    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
  END;

  -- ---------------------------------------------------------
  -- 6. Grants: one create_agent_payout signature
  -- ---------------------------------------------------------
  RESET ROLE;
  ASSERT to_regprocedure('public.create_agent_payout(uuid, date, date, text, text)') IS NULL,
    'grants: old 5-argument create_agent_payout should be dropped';
  ASSERT (SELECT count(*) FROM pg_proc WHERE proname = 'create_agent_payout'
            AND pronamespace = 'public'::regnamespace) = 1, 'grants: one create_agent_payout';
  ASSERT NOT has_function_privilege('anon', 'public.create_agent_payout(uuid, date, date, text, text, numeric)', 'EXECUTE'), 'anon: create_agent_payout';
  ASSERT has_function_privilege('authenticated', 'public.create_agent_payout(uuid, date, date, text, text, numeric)', 'EXECUTE'), 'authenticated: create_agent_payout';
  ASSERT NOT has_function_privilege('anon', 'public.remove_member(uuid, uuid)', 'EXECUTE'), 'anon: remove_member';
  ASSERT has_function_privilege('authenticated', 'public.remove_member(uuid, uuid)', 'EXECUTE'), 'authenticated: remove_member';
  ASSERT NOT has_function_privilege('authenticated', 'public.allocation_agent_reversal()', 'EXECUTE'), 'authenticated: allocation_agent_reversal';
END;
$$;

SELECT 'ALL PASSED' AS result;

ROLLBACK;
