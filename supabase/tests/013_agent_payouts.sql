-- ============================================================
-- Test 013: agent rates, earnings ledger and payouts
--   - rate lookup (override > default > none; rate 0 earns nothing)
--   - rate snapshot unchanged after a rate edit; part payment
--   - opening-balance receipts never earn
--   - undo before / after payout; reassign then undo
--   - commission / policy delete creates the reversal
--   - payout up to a date; no earning in two payouts
--   - void; adjustments; _backfill_agent_earnings
--   - access: Agent, Manager, direct writes, other agency, grants
--
-- Run the whole file in one go (Supabase SQL editor / execute_sql).
-- One transaction, ALWAYS rolled back: on success the final SELECT
-- returns 'ALL PASSED'; any failed ASSERT aborts the batch.
-- Each scenario ends with RAISE ... ERRCODE 'ZZ001' to roll itself
-- back. _t013_expect (created inside the transaction, so rolled
-- back too) runs one statement as the current role and asserts the
-- error it raises.
-- ============================================================

BEGIN;
-- current_date here means "today in Nairobi", like the RPCs (013a)
SET LOCAL TIME ZONE 'Africa/Nairobi';

CREATE FUNCTION public._t013_expect(p_sql TEXT, p_msg TEXT, p_state TEXT DEFAULT NULL)
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
GRANT EXECUTE ON FUNCTION public._t013_expect(TEXT, TEXT, TEXT) TO authenticated;

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
  pl_m  UUID;   -- Motor
  pl_l  UUID;   -- Life
  pl_x  UUID;   -- other agency's product line
  cl1   UUID := gen_random_uuid();   -- a1's client
  cl2   UUID := gen_random_uuid();   -- a2's client
  p1    UUID := gen_random_uuid();   -- a1 Motor, commission 10000
  p2    UUID := gen_random_uuid();   -- a1 Life,  commission 10000
  p3    UUID := gen_random_uuid();   -- a2 Motor, commission 10000
  c1    UUID;
  c2    UUID;
  c3    UUID;
  r     JSONB;
  r_id  UUID;
  al1   UUID;
  al2   UUID;
  al3   UUID;
  e1    UUID;
  e2    UUID;
  pay1  UUID;
  pay2  UUID;
  adj   UUID;
  n     INTEGER;
  v_num NUMERIC;
  v_rate NUMERIC;
  v_base NUMERIC;
  v_txt TEXT;
  v_txt2 TEXT;
  v_uid UUID;
  v_uid2 UUID;
  v_date DATE;
  v_ts  TIMESTAMPTZ;
BEGIN
  -- ---------------------------------------------------------
  -- Fixture (as superuser, no JWT)
  -- ---------------------------------------------------------
  PERFORM set_config('request.jwt.claims', '{}', true);

  INSERT INTO auth.users (id, email, aud, role, instance_id) VALUES
    (o,  'o-013@test.local',  'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000'),
    (m,  'm-013@test.local',  'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000'),
    (a1, 'a1-013@test.local', 'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000'),
    (a2, 'a2-013@test.local', 'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000'),
    (o2, 'o2-013@test.local', 'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000');

  INSERT INTO agencies (id, name) VALUES (ag, 'Test Agency 013'), (ag2, 'Other Agency 013');
  INSERT INTO users (id, agency_id, role, full_name, email) VALUES
    (o,  ag,  'owner',   'Owner 013',   'o-013@test.local'),
    (m,  ag,  'manager', 'Manager 013', 'm-013@test.local'),
    (a1, ag,  'agent',   'Agent1 013',  'a1-013@test.local'),
    (a2, ag,  'agent',   'Agent2 013',  'a2-013@test.local'),
    (o2, ag2, 'owner',   'Owner2 013',  'o2-013@test.local');

  INSERT INTO insurers (agency_id, name) VALUES (ag, 'Insurer 013') RETURNING id INTO ins;
  INSERT INTO product_lines (agency_id, name) VALUES (ag, 'Motor 013') RETURNING id INTO pl_m;
  INSERT INTO product_lines (agency_id, name) VALUES (ag, 'Life 013')  RETURNING id INTO pl_l;
  INSERT INTO product_lines (agency_id, name) VALUES (ag2, 'Other 013') RETURNING id INTO pl_x;
  INSERT INTO clients (id, agency_id, type, name, assigned_agent_id) VALUES
    (cl1, ag, 'individual', 'Client One 013', a1),
    (cl2, ag, 'individual', 'Client Two 013', a2);

  INSERT INTO policies (id, agency_id, client_id, insurer_id, product_line_id, agent_id,
                        policy_number, premium_amount, commission_rate, commission_basis,
                        start_date, expiry_date, status)
  VALUES
    (p1, ag, cl1, ins, pl_m, a1, 'T013-P1', 100000, 10, 'annual', DATE '2026-01-15', DATE '2027-01-14', 'active'),
    (p2, ag, cl1, ins, pl_l, a1, 'T013-P2', 100000, 10, 'annual', DATE '2026-01-20', DATE '2027-01-19', 'active'),
    (p3, ag, cl2, ins, pl_m, a2, 'T013-P3', 100000, 10, 'annual', DATE '2026-02-01', DATE '2027-01-31', 'active');

  SELECT id INTO c1 FROM commission_transactions WHERE policy_id = p1;
  SELECT id INTO c2 FROM commission_transactions WHERE policy_id = p2;
  SELECT id INTO c3 FROM commission_transactions WHERE policy_id = p3;
  ASSERT (SELECT amount FROM commission_transactions WHERE id = c1) = 10000, 'fixture: c1 10000';

  -- ---------------------------------------------------------
  -- 1. Rate lookup, snapshot, part payment
  -- ---------------------------------------------------------
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', o, 'role','authenticated')::text, true);
    SET LOCAL ROLE authenticated;

    PERFORM set_agent_rates(a1, 40, jsonb_build_array(jsonb_build_object('product_line_id', pl_l, 'rate', 50)));
    SELECT count(*) INTO n FROM agent_rates WHERE user_id = a1;
    ASSERT n = 2, format('rates: a1 expected 2 rate rows, got %s', n);

    r := create_insurer_receipt(ins, DATE '2026-03-01', 3000, NULL, NULL, '[]'::jsonb,
           jsonb_build_array(jsonb_build_object('commission_id', c1, 'amount', 1000),
                             jsonb_build_object('commission_id', c2, 'amount', 1000),
                             jsonb_build_object('commission_id', c3, 'amount', 1000)));
    r_id := (r->>'receipt_id')::uuid;
    SELECT id INTO al1 FROM commission_allocations WHERE receipt_id = r_id AND commission_id = c1;
    SELECT id INTO al2 FROM commission_allocations WHERE receipt_id = r_id AND commission_id = c2;

    SELECT amount, rate, base_amount, kind, agent_id, earned_on, policy_number
      INTO v_num, v_rate, v_base, v_txt, v_uid, v_date, v_txt2, v_uid2
      FROM agent_earnings WHERE allocation_id = al1;
    ASSERT v_num = 400.00 AND v_rate = 40 AND v_base = 1000 AND v_txt = 'commission' AND v_uid = a1,
      format('rates: Motor earning expected 400/40/1000/commission/a1, got %s/%s/%s/%s/%s', v_num, v_rate, v_base, v_txt, v_uid);
    ASSERT v_date = DATE '2026-03-01', format('rates: earned_on expected receipt date, got %s', v_date);
    ASSERT v_txt2 = 'T013-P1', format('rates: policy_number snapshot got %s', v_txt2);
    SELECT client_name, policy_id, commission_id, payout_id INTO v_txt, v_uid, v_uid2, pay1
      FROM agent_earnings WHERE allocation_id = al1;
    ASSERT v_txt = 'Client One 013' AND v_uid = p1 AND v_uid2 = c1 AND pay1 IS NULL,
      format('rates: snapshot got %s / %s / %s / %s', v_txt, v_uid, v_uid2, pay1);

    SELECT amount, rate INTO v_num, v_rate FROM agent_earnings WHERE allocation_id = al2;
    ASSERT v_num = 500.00 AND v_rate = 50, format('rates: Life earning expected 500/50, got %s/%s', v_num, v_rate);

    SELECT count(*) INTO n FROM agent_earnings WHERE agent_id = a2;
    ASSERT n = 0, format('rates: a2 has no rate, expected 0 earnings, got %s', n);

    -- Override of 0 beats the default: no earning
    PERFORM set_agent_rates(a1, 40, jsonb_build_array(jsonb_build_object('product_line_id', pl_l, 'rate', 0)));
    r := create_insurer_receipt(ins, DATE '2026-03-02', 100, NULL, NULL, '[]'::jsonb,
           jsonb_build_array(jsonb_build_object('commission_id', c2, 'amount', 100)));
    SELECT id INTO al3 FROM commission_allocations WHERE receipt_id = (r->>'receipt_id')::uuid;
    SELECT count(*) INTO n FROM agent_earnings WHERE allocation_id = al3;
    ASSERT n = 0, format('rates: rate 0 should earn nothing, got %s earnings', n);

    -- Snapshot: a rate edit leaves existing earnings alone
    PERFORM set_agent_rates(a1, 30, '[]'::jsonb);
    SELECT count(*) INTO n FROM agent_rates WHERE user_id = a1;
    ASSERT n = 1, format('rates: replace expected 1 row, got %s', n);
    SELECT amount, rate INTO v_num, v_rate FROM agent_earnings WHERE allocation_id = al1;
    ASSERT v_num = 400.00 AND v_rate = 40, format('snapshot: Motor earning changed to %s/%s', v_num, v_rate);
    SELECT amount, rate INTO v_num, v_rate FROM agent_earnings WHERE allocation_id = al2;
    ASSERT v_num = 500.00 AND v_rate = 50, format('snapshot: Life earning changed to %s/%s', v_num, v_rate);

    r := create_insurer_receipt(ins, DATE '2026-03-03', 1000, NULL, NULL, '[]'::jsonb,
           jsonb_build_array(jsonb_build_object('commission_id', c1, 'amount', 1000)));
    SELECT id INTO al3 FROM commission_allocations WHERE receipt_id = (r->>'receipt_id')::uuid;
    SELECT amount, rate INTO v_num, v_rate FROM agent_earnings WHERE allocation_id = al3;
    ASSERT v_num = 300.00 AND v_rate = 30, format('snapshot: new allocation expected 300/30, got %s/%s', v_num, v_rate);

    -- Part payment
    PERFORM set_agent_rates(a1, 40, '[]'::jsonb);
    r := create_insurer_receipt(ins, DATE '2026-03-04', 333.33, NULL, NULL, '[]'::jsonb,
           jsonb_build_array(jsonb_build_object('commission_id', c1, 'amount', 333.33)));
    SELECT id INTO al3 FROM commission_allocations WHERE receipt_id = (r->>'receipt_id')::uuid;
    SELECT amount, base_amount INTO v_num, v_base FROM agent_earnings WHERE allocation_id = al3;
    ASSERT v_num = 133.33 AND v_base = 333.33, format('part payment: expected 133.33 of 333.33, got %s of %s', v_num, v_base);

    -- Rate validation
    PERFORM _t013_expect(format('SELECT set_agent_rates(%L, 101, ''[]'')', a1), 'Rate must be between 0 and 100');
    PERFORM _t013_expect(format('SELECT set_agent_rates(%L, -1, ''[]'')', a1), 'Rate must be between 0 and 100');
    PERFORM _t013_expect(format('SELECT set_agent_rates(%L, 40, %L)', a1,
              jsonb_build_array(jsonb_build_object('product_line_id', pl_l, 'rate', 150))),
            'Rate must be between 0 and 100');
    PERFORM _t013_expect(format('SELECT set_agent_rates(%L, 40, %L)', a1,
              jsonb_build_array(jsonb_build_object('product_line_id', pl_l))),
            'Rate must be between 0 and 100');
    PERFORM _t013_expect(format('SELECT set_agent_rates(%L, 40, ''[]'')', o2), 'Pick a member of this agency');
    PERFORM _t013_expect(format('SELECT set_agent_rates(%L, 40, %L)', a1,
              jsonb_build_array(jsonb_build_object('product_line_id', pl_x, 'rate', 10))),
            'Pick a product line of this agency');
    -- rates unchanged by the failures
    SELECT rate INTO v_rate FROM agent_rates WHERE user_id = a1 AND product_line_id IS NULL;
    ASSERT v_rate = 40, format('rates: failed calls changed the default to %s', v_rate);

    -- NULL default removes it
    PERFORM set_agent_rates(a1, NULL, jsonb_build_array(jsonb_build_object('product_line_id', pl_l, 'rate', 50)));
    SELECT count(*) INTO n FROM agent_rates WHERE user_id = a1 AND product_line_id IS NULL;
    ASSERT n = 0, 'rates: NULL default should remove the default row';
    SELECT updated_by INTO v_uid FROM agent_rates WHERE user_id = a1;
    ASSERT v_uid = o, 'rates: updated_by should be the owner';

    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
  END;

  -- ---------------------------------------------------------
  -- 2. Opening-balance receipt never earns
  -- ---------------------------------------------------------
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', o, 'role','authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    PERFORM set_agent_rates(a1, 40, '[]'::jsonb);
    RESET ROLE;
    PERFORM set_config('request.jwt.claims', '{}', true);

    INSERT INTO insurer_receipts (agency_id, insurer_id, received_on, amount, notes, is_opening_balance, created_by)
    VALUES (ag, ins, DATE '2026-01-31', 1000, 'Opening balance', true, o)
    RETURNING id INTO r_id;
    INSERT INTO commission_allocations (agency_id, receipt_id, commission_id, amount, created_by)
    VALUES (ag, r_id, c1, 1000, o)
    RETURNING id INTO al1;

    SELECT count(*) INTO n FROM agent_earnings WHERE allocation_id = al1;
    ASSERT n = 0, format('opening balance: expected no earning, got %s', n);

    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
  END;

  -- ---------------------------------------------------------
  -- 3. Undo before payout: nets to zero
  -- ---------------------------------------------------------
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', o, 'role','authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    PERFORM set_agent_rates(a1, 40, '[]'::jsonb);

    r := create_insurer_receipt(ins, DATE '2026-03-01', 1000, NULL, NULL, '[]'::jsonb,
           jsonb_build_array(jsonb_build_object('commission_id', c1, 'amount', 1000)));
    SELECT id INTO al1 FROM commission_allocations WHERE receipt_id = (r->>'receipt_id')::uuid;
    SELECT id INTO e1 FROM agent_earnings WHERE allocation_id = al1 AND kind = 'commission';

    PERFORM undo_commission_allocation(al1);

    SELECT amount, base_amount, rate, agent_id, earned_on, reverses_earning_id, policy_id, commission_id, policy_number
      INTO v_num, v_base, v_rate, v_uid, v_date, v_uid2, pay1, pay2, v_txt
      FROM agent_earnings WHERE allocation_id = al1 AND kind = 'reversal';
    ASSERT v_num = -400.00 AND v_base = -1000 AND v_rate = 40 AND v_uid = a1,
      format('undo before: reversal expected -400/-1000/40/a1, got %s/%s/%s/%s', v_num, v_base, v_rate, v_uid);
    -- unpaid original: the reversal keeps its date (013a)
    ASSERT v_date = DATE '2026-03-01' AND v_uid2 = e1, format('undo before: earned_on %s, reverses %s', v_date, v_uid2);
    ASSERT pay1 = p1 AND pay2 = c1 AND v_txt = 'T013-P1', format('undo before: snapshot %s / %s / %s', pay1, pay2, v_txt);

    r := preview_agent_payout(a1, current_date);
    ASSERT (r->>'total')::numeric = 0, format('undo before: preview total expected 0, got %s', r->>'total');
    ASSERT jsonb_array_length(r->'lines') = 2, format('undo before: expected 2 lines, got %s', r->'lines');
    ASSERT (r->'lines'->0) ?& ARRAY['id','kind','earned_on','policy_number','client_name','base_amount','rate','amount','note'],
      format('preview: line keys missing in %s', r->'lines'->0);
    -- same earned_on and created_at (one transaction): order between them is by id
    ASSERT (SELECT array_agg(x->>'kind' ORDER BY x->>'kind') FROM jsonb_array_elements(r->'lines') x)
             = ARRAY['commission','reversal'],
      format('preview: expected a commission and its reversal, got %s', r->'lines');

    PERFORM _t013_expect(format('SELECT create_agent_payout(%L, current_date, current_date, ''mpesa'', NULL)', a1),
            'Nothing to pay for this agent up to that date');

    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
  END;

  -- ---------------------------------------------------------
  -- 4. Undo after payout: deducted from the next payout
  -- ---------------------------------------------------------
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', o, 'role','authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    PERFORM set_agent_rates(a1, 40, jsonb_build_array(jsonb_build_object('product_line_id', pl_l, 'rate', 50)));

    r := create_insurer_receipt(ins, DATE '2026-03-01', 1000, NULL, NULL, '[]'::jsonb,
           jsonb_build_array(jsonb_build_object('commission_id', c1, 'amount', 1000)));
    SELECT id INTO al1 FROM commission_allocations WHERE receipt_id = (r->>'receipt_id')::uuid;

    r := create_agent_payout(a1, current_date, current_date, 'mpesa', 'QK7H2M9XLP');
    pay1 := (r->>'payout_id')::uuid;
    ASSERT (r->>'amount')::numeric = 400, format('undo after: payout expected 400, got %s', r->>'amount');
    ASSERT jsonb_array_length(r->'lines') = 1, format('undo after: payout lines expected 1, got %s', r->'lines');
    SELECT payout_id INTO v_uid FROM agent_earnings WHERE allocation_id = al1;
    ASSERT v_uid = pay1, 'undo after: earning should be marked paid';
    SELECT agent_id, amount, method, reference, created_by
      INTO v_uid, v_num, v_txt, v_txt2, v_uid2
      FROM agent_payouts WHERE id = pay1;
    ASSERT v_uid = a1 AND v_num = 400 AND v_txt = 'mpesa' AND v_txt2 = 'QK7H2M9XLP' AND v_uid2 = o,
      format('undo after: payout row %s/%s/%s/%s/%s', v_uid, v_num, v_txt, v_txt2, v_uid2);

    PERFORM undo_commission_allocation(al1);
    SELECT amount, payout_id INTO v_num, v_uid FROM agent_earnings WHERE allocation_id = al1 AND kind = 'reversal';
    ASSERT v_num = -400 AND v_uid IS NULL, format('undo after: reversal expected -400 unpaid, got %s / %s', v_num, v_uid);

    r := preview_agent_payout(a1, current_date);
    ASSERT (r->>'total')::numeric = -400, format('undo after: preview expected -400, got %s', r->>'total');
    PERFORM _t013_expect(format('SELECT create_agent_payout(%L, current_date, current_date, ''mpesa'', NULL)', a1),
            'Nothing to pay for this agent up to that date');

    -- 300 more (Life at 50%: 600 -> 300) still does not cover it
    r := create_insurer_receipt(ins, DATE '2026-03-05', 600, NULL, NULL, '[]'::jsonb,
           jsonb_build_array(jsonb_build_object('commission_id', c2, 'amount', 600)));
    PERFORM _t013_expect(format('SELECT create_agent_payout(%L, current_date, current_date, ''mpesa'', NULL)', a1),
            'Nothing to pay for this agent up to that date');

    -- 500 more -> net 400
    r := create_insurer_receipt(ins, DATE '2026-03-06', 1000, NULL, NULL, '[]'::jsonb,
           jsonb_build_array(jsonb_build_object('commission_id', c2, 'amount', 1000)));
    r := create_agent_payout(a1, current_date, current_date, 'bank', 'TRF-1');
    pay2 := (r->>'payout_id')::uuid;
    ASSERT (r->>'amount')::numeric = 400, format('undo after: second payout expected 400, got %s', r->>'amount');
    ASSERT jsonb_array_length(r->'lines') = 3, format('undo after: second payout lines expected 3, got %s', r->'lines');
    SELECT payout_id INTO v_uid FROM agent_earnings WHERE allocation_id = al1 AND kind = 'reversal';
    ASSERT v_uid = pay2, 'undo after: reversal should be in the second payout';

    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
  END;

  -- ---------------------------------------------------------
  -- 5. Reassign then undo: reversal belongs to the original agent
  -- ---------------------------------------------------------
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', o, 'role','authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    PERFORM set_agent_rates(a1, 40, '[]'::jsonb);
    PERFORM set_agent_rates(a2, 20, '[]'::jsonb);

    r := create_insurer_receipt(ins, DATE '2026-03-01', 1000, NULL, NULL, '[]'::jsonb,
           jsonb_build_array(jsonb_build_object('commission_id', c1, 'amount', 1000)));
    SELECT id INTO al1 FROM commission_allocations WHERE receipt_id = (r->>'receipt_id')::uuid;

    r := reassign_client(cl1, a2);
    SELECT agent_id INTO v_uid FROM policies WHERE id = p1;
    ASSERT v_uid = a2, 'reassign: fixture policy should now be a2''s';

    PERFORM undo_commission_allocation(al1);
    SELECT agent_id, amount, rate INTO v_uid, v_num, v_rate
      FROM agent_earnings WHERE allocation_id = al1 AND kind = 'reversal';
    ASSERT v_uid = a1 AND v_num = -400 AND v_rate = 40,
      format('reassign: reversal expected a1/-400/40, got %s/%s/%s', v_uid, v_num, v_rate);
    SELECT count(*) INTO n FROM agent_earnings WHERE agent_id = a2;
    ASSERT n = 0, format('reassign: a2 should have no earnings, got %s', n);

    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
  END;

  -- ---------------------------------------------------------
  -- 6. Deleting the commission / the policy creates the reversal
  -- ---------------------------------------------------------
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', o, 'role','authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    PERFORM set_agent_rates(a1, 40, jsonb_build_array(jsonb_build_object('product_line_id', pl_l, 'rate', 50)));

    r := create_insurer_receipt(ins, DATE '2026-03-01', 2000, NULL, NULL, '[]'::jsonb,
           jsonb_build_array(jsonb_build_object('commission_id', c1, 'amount', 1000),
                             jsonb_build_object('commission_id', c2, 'amount', 1000)));
    r_id := (r->>'receipt_id')::uuid;
    SELECT id INTO al1 FROM commission_allocations WHERE receipt_id = r_id AND commission_id = c1;
    SELECT id INTO al2 FROM commission_allocations WHERE receipt_id = r_id AND commission_id = c2;
    SELECT id INTO e1 FROM agent_earnings WHERE allocation_id = al1;
    SELECT id INTO e2 FROM agent_earnings WHERE allocation_id = al2;

    -- commission delete
    DELETE FROM commission_transactions WHERE id = c1;
    SELECT count(*) INTO n FROM commission_allocations WHERE id = al1;
    ASSERT n = 0, 'delete commission: allocation should cascade';
    SELECT amount, reverses_earning_id, policy_id, commission_id, policy_number, client_name, agent_id
      INTO v_num, v_uid, v_uid2, pay1, v_txt, v_txt2, pay2
      FROM agent_earnings WHERE allocation_id = al1 AND kind = 'reversal';
    ASSERT v_num = -400 AND v_uid = e1 AND pay2 = a1, format('delete commission: reversal %s / %s / %s', v_num, v_uid, pay2);
    ASSERT v_uid2 = p1 AND pay1 IS NULL AND v_txt = 'T013-P1' AND v_txt2 = 'Client One 013',
      format('delete commission: snapshot %s / %s / %s / %s', v_uid2, pay1, v_txt, v_txt2);
    SELECT commission_id INTO v_uid FROM agent_earnings WHERE id = e1;
    ASSERT v_uid IS NULL, 'delete commission: original earning commission_id should be SET NULL';

    -- policy delete
    DELETE FROM policies WHERE id = p2;
    SELECT amount, reverses_earning_id, policy_id, commission_id, policy_number, client_name
      INTO v_num, v_uid, v_uid2, pay1, v_txt, v_txt2
      FROM agent_earnings WHERE allocation_id = al2 AND kind = 'reversal';
    ASSERT v_num = -500 AND v_uid = e2, format('delete policy: reversal %s / %s', v_num, v_uid);
    ASSERT v_uid2 IS NULL AND pay1 IS NULL AND v_txt = 'T013-P2' AND v_txt2 = 'Client One 013',
      format('delete policy: snapshot %s / %s / %s / %s', v_uid2, pay1, v_txt, v_txt2);
    SELECT policy_id, commission_id INTO v_uid, v_uid2 FROM agent_earnings WHERE id = e2;
    ASSERT v_uid IS NULL AND v_uid2 IS NULL, 'delete policy: original earning links should be SET NULL';

    SELECT count(*) INTO n FROM agent_earnings WHERE agent_id = a1;
    ASSERT n = 4, format('delete: expected 4 earnings (2 + 2 reversals), got %s', n);
    r := preview_agent_payout(a1, current_date);
    ASSERT (r->>'total')::numeric = 0, format('delete: preview expected 0, got %s', r->>'total');

    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
  END;

  -- ---------------------------------------------------------
  -- 7. Payout up to a date; sequential payouts; validation
  -- ---------------------------------------------------------
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', o, 'role','authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    PERFORM set_agent_rates(a1, 40, jsonb_build_array(jsonb_build_object('product_line_id', pl_l, 'rate', 50)));

    r := create_insurer_receipt(ins, DATE '2026-03-01', 1000, NULL, NULL, '[]'::jsonb,
           jsonb_build_array(jsonb_build_object('commission_id', c1, 'amount', 1000)));
    r := create_insurer_receipt(ins, DATE '2026-05-01', 1000, NULL, NULL, '[]'::jsonb,
           jsonb_build_array(jsonb_build_object('commission_id', c2, 'amount', 1000)));

    -- Manager runs the payouts
    PERFORM set_config('request.jwt.claims', json_build_object('sub', m, 'role','authenticated')::text, true);

    r := preview_agent_payout(a1, DATE '2026-04-30');
    ASSERT (r->>'total')::numeric = 400 AND jsonb_array_length(r->'lines') = 1,
      format('up to date: preview expected 400 / 1 line, got %s', r);
    ASSERT r->'lines'->0->>'policy_number' = 'T013-P1' AND r->'lines'->0->>'client_name' = 'Client One 013'
           AND (r->'lines'->0->>'base_amount')::numeric = 1000 AND (r->'lines'->0->>'rate')::numeric = 40,
      format('up to date: line %s', r->'lines'->0);

    PERFORM _t013_expect(format('SELECT create_agent_payout(%L, ''2026-04-30'', current_date, ''cheque'', NULL)', a1),
            'Pick a payment method');
    PERFORM _t013_expect(format('SELECT create_agent_payout(%L, ''2026-04-30'', NULL, ''bank'', NULL)', a1),
            'Enter the date paid');
    PERFORM _t013_expect(format('SELECT create_agent_payout(%L, NULL, current_date, ''bank'', NULL)', a1),
            'Pick a pay-up-to date');
    PERFORM _t013_expect(format('SELECT create_agent_payout(%L, ''2026-04-30'', current_date, ''bank'', NULL)', o2),
            'Pick a member of this agency');

    r := create_agent_payout(a1, DATE '2026-04-30', current_date, 'bank', 'B-1');
    pay1 := (r->>'payout_id')::uuid;
    ASSERT (r->>'amount')::numeric = 400, format('up to date: payout expected 400, got %s', r->>'amount');
    SELECT created_by, period_end INTO v_uid, v_date FROM agent_payouts WHERE id = pay1;
    ASSERT v_uid = m AND v_date = DATE '2026-04-30', format('up to date: payout created_by %s period_end %s', v_uid, v_date);

    PERFORM _t013_expect(format('SELECT create_agent_payout(%L, ''2026-04-30'', current_date, ''bank'', NULL)', a1),
            'Nothing to pay for this agent up to that date');

    r := create_agent_payout(a1, current_date, current_date, 'cash', NULL);
    pay2 := (r->>'payout_id')::uuid;
    ASSERT (r->>'amount')::numeric = 500, format('up to date: second payout expected 500, got %s', r->>'amount');
    PERFORM _t013_expect(format('SELECT create_agent_payout(%L, current_date, current_date, ''cash'', NULL)', a1),
            'Nothing to pay for this agent up to that date');

    SELECT count(*), count(DISTINCT payout_id) INTO n, v_num FROM agent_earnings WHERE agent_id = a1;
    ASSERT n = 2 AND v_num = 2, format('up to date: expected 2 earnings in 2 payouts, got %s / %s', n, v_num);
    SELECT sum(amount) INTO v_num FROM agent_payouts WHERE agent_id = a1;
    ASSERT v_num = (SELECT sum(amount) FROM agent_earnings WHERE agent_id = a1),
      'up to date: payouts should total the earnings';

    -- Payout for a deactivated member works
    RESET ROLE;
    UPDATE users SET deactivated_at = now() WHERE id = a1;
    SET LOCAL ROLE authenticated;
    PERFORM set_config('request.jwt.claims', json_build_object('sub', o, 'role','authenticated')::text, true);
    adj := add_agent_adjustment(a1, 100, 'Final settlement');
    r := create_agent_payout(a1, current_date, current_date, 'cash', NULL);
    ASSERT (r->>'amount')::numeric = 100, format('deactivated: payout expected 100, got %s', r->>'amount');
    -- rates can still be set for a removed member (013a)
    PERFORM set_agent_rates(a1, 40, '[]'::jsonb);

    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
  END;

  -- ---------------------------------------------------------
  -- 8. Void
  -- ---------------------------------------------------------
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', o, 'role','authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    PERFORM set_agent_rates(a1, 40, jsonb_build_array(jsonb_build_object('product_line_id', pl_l, 'rate', 50)));

    r := create_insurer_receipt(ins, DATE '2026-03-01', 1000, NULL, NULL, '[]'::jsonb,
           jsonb_build_array(jsonb_build_object('commission_id', c1, 'amount', 1000)));
    SELECT id INTO al1 FROM commission_allocations WHERE receipt_id = (r->>'receipt_id')::uuid;
    r := create_agent_payout(a1, current_date, current_date, 'mpesa', 'P-1');
    pay1 := (r->>'payout_id')::uuid;
    PERFORM undo_commission_allocation(al1);
    r := create_insurer_receipt(ins, DATE '2026-03-02', 1000, NULL, NULL, '[]'::jsonb,
           jsonb_build_array(jsonb_build_object('commission_id', c2, 'amount', 1000)));
    r := create_agent_payout(a1, current_date, current_date, 'mpesa', 'P-2');
    pay2 := (r->>'payout_id')::uuid;
    ASSERT (r->>'amount')::numeric = 100, format('void: payout with reversal expected 100, got %s', r->>'amount');

    PERFORM void_agent_payout(pay2);
    SELECT count(*) INTO n FROM agent_earnings WHERE payout_id = pay2;
    ASSERT n = 0, format('void: %s earnings still on the voided payout', n);
    SELECT voided_at, voided_by INTO v_ts, v_uid FROM agent_payouts WHERE id = pay2;
    ASSERT v_ts IS NOT NULL AND v_uid = o, 'void: voided_at/by not set';
    SELECT count(*) INTO n FROM agent_earnings WHERE agent_id = a1 AND payout_id IS NULL;
    ASSERT n = 2, format('void: expected reversal + Life earning unpaid, got %s', n);
    SELECT count(*) INTO n FROM agent_earnings WHERE payout_id = pay1;
    ASSERT n = 1, 'void: the other payout is untouched';

    PERFORM _t013_expect(format('SELECT void_agent_payout(%L)', pay2), 'This payout is already voided');
    PERFORM _t013_expect(format('SELECT void_agent_payout(%L)', gen_random_uuid()), 'Payout not found', 'P0002');

    r := preview_agent_payout(a1, current_date);
    ASSERT (r->>'total')::numeric = 100, format('void: preview expected 100 again, got %s', r->>'total');
    r := create_agent_payout(a1, current_date, current_date, 'mpesa', 'P-3');
    ASSERT (r->>'amount')::numeric = 100, format('void: re-pay expected 100, got %s', r->>'amount');

    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
  END;

  -- ---------------------------------------------------------
  -- 9. Adjustments
  -- ---------------------------------------------------------
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', o, 'role','authenticated')::text, true);
    SET LOCAL ROLE authenticated;

    adj := add_agent_adjustment(a1, 2500, 'Bonus');
    SELECT kind, amount, base_amount, rate, note, earned_on, allocation_id, created_by
      INTO v_txt, v_num, v_base, v_rate, v_txt2, v_date, v_uid, v_uid2
      FROM agent_earnings WHERE id = adj;
    ASSERT v_txt = 'adjustment' AND v_num = 2500 AND v_base IS NULL AND v_rate IS NULL AND v_txt2 = 'Bonus'
           AND v_date = current_date AND v_uid IS NULL AND v_uid2 = o,
      format('adjustment: row %s/%s/%s/%s/%s/%s/%s/%s', v_txt, v_num, v_base, v_rate, v_txt2, v_date, v_uid, v_uid2);

    r := preview_agent_payout(a1, current_date);
    ASSERT (r->>'total')::numeric = 2500 AND r->'lines'->0->>'note' = 'Bonus' AND r->'lines'->0->>'kind' = 'adjustment',
      format('adjustment: preview %s', r);

    adj := add_agent_adjustment(a1, -300, 'Advance recovered');
    r := preview_agent_payout(a1, current_date);
    ASSERT (r->>'total')::numeric = 2200, format('adjustment: negative adjustment total %s', r->>'total');

    PERFORM _t013_expect(format('SELECT add_agent_adjustment(%L, 100, '''')', a1), 'Add a note for this adjustment');
    PERFORM _t013_expect(format('SELECT add_agent_adjustment(%L, 100, ''   '')', a1), 'Add a note for this adjustment');
    PERFORM _t013_expect(format('SELECT add_agent_adjustment(%L, 100, NULL)', a1), 'Add a note for this adjustment');
    PERFORM _t013_expect(format('SELECT add_agent_adjustment(%L, 0, ''x'')', a1), 'Enter an amount');
    PERFORM _t013_expect(format('SELECT add_agent_adjustment(%L, NULL, ''x'')', a1), 'Enter an amount');
    PERFORM _t013_expect(format('SELECT add_agent_adjustment(%L, 100, ''x'')', o2), 'Pick a member of this agency');

    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
  END;

  -- ---------------------------------------------------------
  -- 10. _backfill_agent_earnings
  -- ---------------------------------------------------------
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', o, 'role','authenticated')::text, true);
    SET LOCAL ROLE authenticated;

    -- money applied before anyone has a rate
    r := create_insurer_receipt(ins, DATE '2026-03-01', 1000, NULL, NULL, '[]'::jsonb,
           jsonb_build_array(jsonb_build_object('commission_id', c1, 'amount', 1000)));
    SELECT id INTO al1 FROM commission_allocations WHERE receipt_id = (r->>'receipt_id')::uuid;
    r := create_insurer_receipt(ins, DATE '2026-04-01', 1000, NULL, NULL, '[]'::jsonb,
           jsonb_build_array(jsonb_build_object('commission_id', c3, 'amount', 1000)));
    SELECT id INTO al3 FROM commission_allocations WHERE receipt_id = (r->>'receipt_id')::uuid;
    SELECT count(*) INTO n FROM agent_earnings;
    ASSERT n = 0, format('backfill: no rates yet, expected 0 earnings, got %s', n);

    PERFORM set_agent_rates(a1, 40, '[]'::jsonb);
    PERFORM set_agent_rates(a2, 20, '[]'::jsonb);

    RESET ROLE;
    PERFORM set_config('request.jwt.claims', '{}', true);
    -- opening balance on Life: never earns
    INSERT INTO insurer_receipts (agency_id, insurer_id, received_on, amount, notes, is_opening_balance, created_by)
    VALUES (ag, ins, DATE '2026-01-31', 1000, 'Opening balance', true, o)
    RETURNING id INTO r_id;
    INSERT INTO commission_allocations (agency_id, receipt_id, commission_id, amount, created_by)
    VALUES (ag, r_id, c2, 1000, o)
    RETURNING id INTO al2;

    n := _backfill_agent_earnings(ag);
    ASSERT n = 2, format('backfill: expected 2 earnings created, got %s', n);
    SELECT amount, earned_on, agent_id, kind, rate INTO v_num, v_date, v_uid, v_txt, v_rate
      FROM agent_earnings WHERE allocation_id = al1;
    ASSERT v_num = 400 AND v_date = DATE '2026-03-01' AND v_uid = a1 AND v_txt = 'commission' AND v_rate = 40,
      format('backfill: a1 earning %s/%s/%s/%s/%s', v_num, v_date, v_uid, v_txt, v_rate);
    SELECT amount, earned_on, agent_id INTO v_num, v_date, v_uid FROM agent_earnings WHERE allocation_id = al3;
    ASSERT v_num = 200 AND v_date = DATE '2026-04-01' AND v_uid = a2,
      format('backfill: a2 earning %s/%s/%s', v_num, v_date, v_uid);
    SELECT count(*) INTO n FROM agent_earnings WHERE allocation_id = al2;
    ASSERT n = 0, 'backfill: opening balance must not earn';

    n := _backfill_agent_earnings(ag);
    ASSERT n = 0, format('backfill: second call expected 0, got %s', n);
    n := _backfill_agent_earnings(ag2);
    ASSERT n = 0, format('backfill: other agency expected 0, got %s', n);

    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
  END;

  -- ---------------------------------------------------------
  -- 11. Access
  -- ---------------------------------------------------------
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', o, 'role','authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    PERFORM set_agent_rates(a1, 40, '[]'::jsonb);
    PERFORM set_agent_rates(a2, 20, '[]'::jsonb);
    r := create_insurer_receipt(ins, DATE '2026-03-01', 2000, NULL, NULL, '[]'::jsonb,
           jsonb_build_array(jsonb_build_object('commission_id', c1, 'amount', 1000),
                             jsonb_build_object('commission_id', c3, 'amount', 1000)));
    r := create_agent_payout(a1, current_date, current_date, 'mpesa', 'A-1');
    pay1 := (r->>'payout_id')::uuid;
    r := create_agent_payout(a2, current_date, current_date, 'mpesa', 'A-2');
    pay2 := (r->>'payout_id')::uuid;

    -- Owner: direct writes refused
    PERFORM _t013_expect(format(
      'INSERT INTO agent_earnings (agency_id, agent_id, kind, amount, earned_on, note) VALUES (%L, %L, ''adjustment'', 1, current_date, ''x'')', ag, a1),
      NULL, '42501');
    PERFORM _t013_expect('UPDATE agent_earnings SET payout_id = NULL', NULL, '42501');
    PERFORM _t013_expect('DELETE FROM agent_earnings', NULL, '42501');
    PERFORM _t013_expect(format(
      'INSERT INTO agent_payouts (agency_id, agent_id, period_end, paid_on, method, amount) VALUES (%L, %L, current_date, current_date, ''cash'', 1)', ag, a1),
      NULL, '42501');
    PERFORM _t013_expect('UPDATE agent_payouts SET voided_at = now()', NULL, '42501');
    PERFORM _t013_expect(format(
      'INSERT INTO agent_rates (agency_id, user_id, rate) VALUES (%L, %L, 99)', ag, m),
      NULL, '42501');
    PERFORM _t013_expect('UPDATE agent_rates SET rate = 99', NULL, '42501');
    PERFORM _t013_expect('DELETE FROM agent_rates', NULL, '42501');

    -- Agent a1
    PERFORM set_config('request.jwt.claims', json_build_object('sub', a1, 'role','authenticated')::text, true);
    SELECT count(*) INTO n FROM agent_earnings;
    ASSERT n = 1, format('a1: expected to see 1 earning, got %s', n);
    SELECT count(*) INTO n FROM agent_earnings WHERE agent_id = a2;
    ASSERT n = 0, format('a1: sees %s of a2''s earnings', n);
    SELECT count(*) INTO n FROM agent_payouts;
    ASSERT n = 1, format('a1: expected to see 1 payout, got %s', n);
    SELECT count(*) INTO n FROM agent_payouts WHERE agent_id = a2;
    ASSERT n = 0, format('a1: sees %s of a2''s payouts', n);
    SELECT count(*) INTO n FROM agent_rates;
    ASSERT n = 1, format('a1: expected to see own rate only, got %s', n);

    PERFORM _t013_expect(format('SELECT set_agent_rates(%L, 90, ''[]'')', a1), 'Only the owner can do that', '42501');
    PERFORM _t013_expect(format('SELECT add_agent_adjustment(%L, 100, ''x'')', a1), 'Only the owner can do that', '42501');
    PERFORM _t013_expect(format('SELECT void_agent_payout(%L)', pay1), 'Only the owner can do that', '42501');
    PERFORM _t013_expect(format('SELECT preview_agent_payout(%L, current_date)', a1), 'Only owners and managers can do that', '42501');
    PERFORM _t013_expect(format('SELECT create_agent_payout(%L, current_date, current_date, ''cash'', NULL)', a1),
            'Only owners and managers can do that', '42501');
    PERFORM _t013_expect(format(
      'INSERT INTO agent_earnings (agency_id, agent_id, kind, amount, earned_on, note) VALUES (%L, %L, ''adjustment'', 1, current_date, ''x'')', ag, a1),
      NULL, '42501');
    PERFORM _t013_expect(format('UPDATE agent_earnings SET payout_id = NULL WHERE agent_id = %L', a1), NULL, '42501');

    -- Manager
    PERFORM set_config('request.jwt.claims', json_build_object('sub', m, 'role','authenticated')::text, true);
    SELECT count(*) INTO n FROM agent_earnings;
    ASSERT n = 2, format('m: expected to see 2 earnings, got %s', n);
    SELECT count(*) INTO n FROM agent_payouts;
    ASSERT n = 2, format('m: expected to see 2 payouts, got %s', n);
    SELECT count(*) INTO n FROM agent_rates;
    ASSERT n = 2, format('m: expected to see 2 rates, got %s', n);
    r := preview_agent_payout(a1, current_date);
    ASSERT (r->>'total')::numeric = 0, format('m: preview expected 0, got %s', r->>'total');
    PERFORM _t013_expect(format('SELECT set_agent_rates(%L, 90, ''[]'')', a1), 'Only the owner can do that', '42501');
    PERFORM _t013_expect(format('SELECT add_agent_adjustment(%L, 100, ''x'')', a1), 'Only the owner can do that', '42501');
    PERFORM _t013_expect(format('SELECT void_agent_payout(%L)', pay1), 'Only the owner can do that', '42501');

    -- Other agency's owner
    PERFORM set_config('request.jwt.claims', json_build_object('sub', o2, 'role','authenticated')::text, true);
    SELECT count(*) INTO n FROM agent_earnings;
    ASSERT n = 0, format('o2: sees %s earnings', n);
    SELECT count(*) INTO n FROM agent_payouts;
    ASSERT n = 0, format('o2: sees %s payouts', n);
    SELECT count(*) INTO n FROM agent_rates;
    ASSERT n = 0, format('o2: sees %s rates', n);
    PERFORM _t013_expect(format('SELECT void_agent_payout(%L)', pay1), 'Payout not found', 'P0002');
    PERFORM _t013_expect(format('SELECT preview_agent_payout(%L, current_date)', a1), 'Pick a member of this agency');
    PERFORM _t013_expect(format('SELECT add_agent_adjustment(%L, 100, ''x'')', a1), 'Pick a member of this agency');

    -- Deactivated owner is refused
    RESET ROLE;
    UPDATE users SET deactivated_at = now() WHERE id = o;
    SET LOCAL ROLE authenticated;
    PERFORM set_config('request.jwt.claims', json_build_object('sub', o, 'role','authenticated')::text, true);
    PERFORM _t013_expect(format('SELECT set_agent_rates(%L, 90, ''[]'')', a1), 'Only the owner can do that', '42501');
    SELECT count(*) INTO n FROM agent_earnings;
    ASSERT n = 0, format('deactivated owner: sees %s earnings', n);

    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
  END;

  -- ---------------------------------------------------------
  -- 12. Grants
  -- ---------------------------------------------------------
  RESET ROLE;
  ASSERT NOT has_function_privilege('anon', 'public.set_agent_rates(uuid, numeric, jsonb)', 'EXECUTE'), 'anon: set_agent_rates';
  ASSERT has_function_privilege('authenticated', 'public.set_agent_rates(uuid, numeric, jsonb)', 'EXECUTE'), 'authenticated: set_agent_rates';
  ASSERT NOT has_function_privilege('anon', 'public.add_agent_adjustment(uuid, numeric, text)', 'EXECUTE'), 'anon: add_agent_adjustment';
  ASSERT has_function_privilege('authenticated', 'public.add_agent_adjustment(uuid, numeric, text)', 'EXECUTE'), 'authenticated: add_agent_adjustment';
  ASSERT NOT has_function_privilege('anon', 'public.preview_agent_payout(uuid, date)', 'EXECUTE'), 'anon: preview_agent_payout';
  ASSERT has_function_privilege('authenticated', 'public.preview_agent_payout(uuid, date)', 'EXECUTE'), 'authenticated: preview_agent_payout';
  ASSERT NOT has_function_privilege('anon', 'public.create_agent_payout(uuid, date, date, text, text, numeric)', 'EXECUTE'), 'anon: create_agent_payout';
  ASSERT has_function_privilege('authenticated', 'public.create_agent_payout(uuid, date, date, text, text, numeric)', 'EXECUTE'), 'authenticated: create_agent_payout';
  ASSERT NOT has_function_privilege('anon', 'public.void_agent_payout(uuid)', 'EXECUTE'), 'anon: void_agent_payout';
  ASSERT has_function_privilege('authenticated', 'public.void_agent_payout(uuid)', 'EXECUTE'), 'authenticated: void_agent_payout';
  ASSERT NOT has_function_privilege('authenticated', 'public._backfill_agent_earnings(uuid)', 'EXECUTE'), 'authenticated: _backfill_agent_earnings';
  ASSERT NOT has_function_privilege('anon', 'public._backfill_agent_earnings(uuid)', 'EXECUTE'), 'anon: _backfill_agent_earnings';
  ASSERT NOT has_function_privilege('authenticated', 'public.allocation_agent_earning()', 'EXECUTE'), 'authenticated: allocation_agent_earning';
  ASSERT NOT has_function_privilege('authenticated', 'public.allocation_agent_reversal()', 'EXECUTE'), 'authenticated: allocation_agent_reversal';
  ASSERT NOT has_function_privilege('authenticated', 'public._agent_rate_for(uuid, uuid, uuid)', 'EXECUTE'), 'authenticated: _agent_rate_for';
END;
$$;

SELECT 'ALL PASSED' AS result;

ROLLBACK;
