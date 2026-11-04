-- ============================================================
-- Test 012: reconciliation follow-ups
--   - generate_monthly_report: received = money applied from receipts
--     dated in the month
--   - undo_commission_allocation unmatches a line left with no
--     allocations
--   - apply_receipt_allocations
--
-- Run the whole file in one go (Supabase SQL editor / execute_sql).
-- One transaction, ALWAYS rolled back: on success the final SELECT
-- returns 'ALL PASSED'; any failed ASSERT aborts the batch.
-- Same harness as supabase/tests/010_reconciliation_rpcs.sql: each
-- scenario ends with RAISE ... ERRCODE 'ZZ001' to roll itself back.
-- ============================================================

BEGIN;

DO $$
DECLARE
  ag    UUID := gen_random_uuid();
  ag2   UUID := gen_random_uuid();
  o     UUID := gen_random_uuid();
  a1    UUID := gen_random_uuid();
  o2    UUID := gen_random_uuid();
  ins1  UUID;
  ins2  UUID;
  pl    UUID;
  pl_x  UUID;
  cl    UUID := gen_random_uuid();
  cl_x  UUID := gen_random_uuid();
  p1    UUID := gen_random_uuid();   -- annual, ins1, 5000, started January
  p2    UUID := gen_random_uuid();   -- annual, ins1, 2000 + 2000 a year later
  p3    UUID := gen_random_uuid();   -- annual, ins2, started March
  c_p1  UUID;
  c_p2a UUID;
  c_p2b UUID;
  c_p3  UUID;
  r     JSONB;
  r_id  UUID;
  ln_id UUID;
  al_id UUID;
  n     INTEGER;
  v_num NUMERIC;
  v_exp NUMERIC;
  v_txt TEXT;
  v_uid UUID;
  v_msg TEXT;
  v_st  TEXT;
BEGIN
  -- ---------------------------------------------------------
  -- Fixture (as superuser, no JWT)
  -- ---------------------------------------------------------
  PERFORM set_config('request.jwt.claims', '{}', true);

  INSERT INTO auth.users (id, email, aud, role, instance_id) VALUES
    (o,  'o-012@test.local',  'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000'),
    (a1, 'a1-012@test.local', 'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000'),
    (o2, 'o2-012@test.local', 'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000');

  INSERT INTO agencies (id, name) VALUES (ag, 'Test Agency 012'), (ag2, 'Other Agency 012');
  INSERT INTO users (id, agency_id, role, full_name, email) VALUES
    (o,  ag,  'owner', 'Owner 012',  'o-012@test.local'),
    (a1, ag,  'agent', 'Agent1 012', 'a1-012@test.local'),
    (o2, ag2, 'owner', 'Owner2 012', 'o2-012@test.local');

  INSERT INTO insurers (agency_id, name) VALUES (ag, 'Insurer 012 A') RETURNING id INTO ins1;
  INSERT INTO insurers (agency_id, name) VALUES (ag, 'Insurer 012 B') RETURNING id INTO ins2;
  INSERT INTO product_lines (agency_id, name) VALUES (ag, 'Motor 012') RETURNING id INTO pl;
  INSERT INTO clients (id, agency_id, type, name, assigned_agent_id) VALUES
    (cl, ag, 'individual', 'Client 012', a1);

  INSERT INTO policies (id, agency_id, client_id, insurer_id, product_line_id, agent_id,
                        policy_number, premium_amount, commission_rate, commission_basis,
                        start_date, expiry_date, status)
  VALUES
    (p1, ag, cl, ins1, pl, a1, 'T012-P1', 50000, 10, 'annual', DATE '2026-01-15', DATE '2027-01-14', 'active'),
    (p2, ag, cl, ins1, pl, a1, 'T012-P2', 20000, 10, 'annual', DATE '2026-01-20', DATE '2027-01-19', 'active'),
    (p3, ag, cl, ins2, pl, a1, 'T012-P3', 30000, 10, 'annual', DATE '2026-03-10', DATE '2027-03-09', 'active');

  SELECT id INTO c_p1  FROM commission_transactions WHERE policy_id = p1;
  SELECT id INTO c_p2a FROM commission_transactions WHERE policy_id = p2;
  SELECT id INTO c_p3  FROM commission_transactions WHERE policy_id = p3;
  INSERT INTO commission_transactions (policy_id, agency_id, amount, expected_date, source, notes)
  VALUES (p2, ag, 2000, DATE '2027-02-19', 'expected', 'Expected commission')
  RETURNING id INTO c_p2b;

  SELECT amount INTO v_num FROM commission_transactions WHERE id = c_p1;
  ASSERT v_num = 5000, format('fixture: P1 expected 5000, got %s', v_num);
  SELECT amount INTO v_num FROM commission_transactions WHERE id = c_p2a;
  ASSERT v_num = 2000, format('fixture: P2 expected 2000, got %s', v_num);

  -- ---------------------------------------------------------
  -- 1. Report: received = money applied from receipts dated in
  --    the month (part payment + older commission count; a receipt
  --    dated last month does not)
  -- ---------------------------------------------------------
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', o, 'role','authenticated')::text, true);
    SET LOCAL ROLE authenticated;

    -- February receipt: 1000 on P1 (excluded from March)
    r := create_insurer_receipt(ins1, DATE '2026-02-20', 1000, NULL, NULL, '[]'::jsonb,
           jsonb_build_array(jsonb_build_object('commission_id', c_p1, 'amount', 1000)));
    -- March receipt: part payment 1500 on P1 + 2000 for P2's (January) commission
    r := create_insurer_receipt(ins1, DATE '2026-03-05', 3500, NULL, NULL, '[]'::jsonb,
           jsonb_build_array(jsonb_build_object('commission_id', c_p1,  'amount', 1500),
                             jsonb_build_object('commission_id', c_p2a, 'amount', 2000)));

    SELECT status INTO v_txt FROM commission_transactions WHERE id = c_p1;
    ASSERT v_txt = 'part_paid', format('report: P1 expected part_paid, got %s', v_txt);

    r := generate_monthly_report(3, 2026);
    v_num := (r->'metadata'->>'commission_received_kes')::numeric;
    ASSERT v_num = 3500, format('report: March received expected 3500, got %s', v_num);
    v_exp := (r->'metadata'->>'commission_expected_kes')::numeric;
    ASSERT v_exp > 0, format('report: March expected should be > 0 (P3), got %s', v_exp);
    ASSERT (r->'metadata'->>'collection_rate_pct')::numeric = ROUND(3500 / v_exp * 100, 1),
      format('report: collection rate %s inconsistent with received 3500 / expected %s',
             r->'metadata'->>'collection_rate_pct', v_exp);

    r := generate_monthly_report(2, 2026);
    v_num := (r->'metadata'->>'commission_received_kes')::numeric;
    ASSERT v_num = 1000, format('report: February received expected 1000, got %s', v_num);

    r := generate_monthly_report(4, 2026);
    v_num := (r->'metadata'->>'commission_received_kes')::numeric;
    ASSERT v_num = 0, format('report: April received expected 0, got %s', v_num);

    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
  END;

  -- ---------------------------------------------------------
  -- 2. Undo a line's only allocation: line unmatched, re-link works
  -- ---------------------------------------------------------
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', o, 'role','authenticated')::text, true);
    SET LOCAL ROLE authenticated;

    r := create_insurer_receipt(ins1, DATE '2026-03-01', 5000, NULL, NULL,
           jsonb_build_array(jsonb_build_object('policy_number','T012-P1','commission',5000,'policy_id',p1)),
           '[]'::jsonb);
    r_id := (r->>'receipt_id')::uuid;
    SELECT id INTO ln_id FROM statement_lines WHERE receipt_id = r_id;
    SELECT id INTO al_id FROM commission_allocations WHERE statement_line_id = ln_id;

    PERFORM undo_commission_allocation(al_id);

    SELECT policy_id INTO v_uid FROM statement_lines WHERE id = ln_id;
    ASSERT v_uid IS NULL, format('undo only: line policy_id expected NULL, got %s', v_uid);
    SELECT amount_received INTO v_num FROM commission_transactions WHERE id = c_p1;
    ASSERT v_num = 0, format('undo only: P1 received expected 0, got %s', v_num);

    r := link_statement_line(ln_id, p1);
    ASSERT (r->>'applied')::numeric = 5000, format('undo only: re-link applied expected 5000, got %s', r->>'applied');
    SELECT policy_id INTO v_uid FROM statement_lines WHERE id = ln_id;
    ASSERT v_uid = p1, 'undo only: re-linked line should be matched to P1';
    SELECT status INTO v_txt FROM commission_transactions WHERE id = c_p1;
    ASSERT v_txt = 'received', format('undo only: P1 expected received after re-link, got %s', v_txt);

    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
  END;

  -- ---------------------------------------------------------
  -- 3. Undo one of two allocations on a line: line stays matched
  -- ---------------------------------------------------------
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', o, 'role','authenticated')::text, true);
    SET LOCAL ROLE authenticated;

    -- P2 3000 -> 2000 on year 1, 1000 on year 2
    r := create_insurer_receipt(ins1, DATE '2026-03-01', 3000, NULL, NULL,
           jsonb_build_array(jsonb_build_object('policy_number','T012-P2','commission',3000,'policy_id',p2)),
           '[]'::jsonb);
    r_id := (r->>'receipt_id')::uuid;
    SELECT id INTO ln_id FROM statement_lines WHERE receipt_id = r_id;
    SELECT count(*) INTO n FROM commission_allocations WHERE statement_line_id = ln_id;
    ASSERT n = 2, format('undo one of two: expected 2 allocations, got %s', n);
    SELECT id INTO al_id FROM commission_allocations WHERE statement_line_id = ln_id AND commission_id = c_p2b;

    PERFORM undo_commission_allocation(al_id);

    SELECT policy_id INTO v_uid FROM statement_lines WHERE id = ln_id;
    ASSERT v_uid = p2, format('undo one of two: line should stay matched to P2, got %s', v_uid);

    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
  END;

  -- ---------------------------------------------------------
  -- 4. apply_receipt_allocations: success
  --    Receipt 7000, P1 line 5000 -> 2000 unapplied
  -- ---------------------------------------------------------
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', o, 'role','authenticated')::text, true);
    SET LOCAL ROLE authenticated;

    r := create_insurer_receipt(ins1, DATE '2026-03-01', 7000, NULL, NULL,
           jsonb_build_array(jsonb_build_object('policy_number','T012-P1','commission',5000,'policy_id',p1)),
           '[]'::jsonb);
    r_id := (r->>'receipt_id')::uuid;
    ASSERT (r->>'unapplied')::numeric = 2000, 'apply: fixture unapplied 2000';

    r := apply_receipt_allocations(r_id, jsonb_build_array(jsonb_build_object('commission_id', c_p2a, 'amount', 1500)));
    ASSERT r->>'applied' = '1500.00', format('apply: applied expected 1500.00, got %s', r->>'applied');
    ASSERT r->>'unapplied' = '500.00', format('apply: unapplied expected 500.00, got %s', r->>'unapplied');
    SELECT status, amount_received INTO v_txt, v_num FROM commission_transactions WHERE id = c_p2a;
    ASSERT v_txt = 'part_paid' AND v_num = 1500, format('apply: P2 year 1 got %s / %s', v_txt, v_num);

    r := apply_receipt_allocations(r_id, jsonb_build_array(jsonb_build_object('commission_id', c_p2a, 'amount', 500)));
    ASSERT (r->>'applied')::numeric = 500 AND (r->>'unapplied')::numeric = 0,
      format('apply: second call got %s', r);
    SELECT status INTO v_txt FROM commission_transactions WHERE id = c_p2a;
    ASSERT v_txt = 'received', format('apply: P2 year 1 expected received, got %s', v_txt);
    SELECT count(*) INTO n FROM commission_allocations WHERE receipt_id = r_id AND statement_line_id IS NULL;
    ASSERT n = 2, format('apply: expected 2 unlinked allocations, got %s', n);

    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
  END;

  -- ---------------------------------------------------------
  -- 5. apply_receipt_allocations: rejections
  -- ---------------------------------------------------------
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', o, 'role','authenticated')::text, true);
    SET LOCAL ROLE authenticated;

    r := create_insurer_receipt(ins1, DATE '2026-03-01', 7000, NULL, NULL,
           jsonb_build_array(jsonb_build_object('policy_number','T012-P1','commission',5000,'policy_id',p1)),
           '[]'::jsonb);
    r_id := (r->>'receipt_id')::uuid;

    -- over the unapplied money (1500 + 1000 > 2000)
    BEGIN
      PERFORM apply_receipt_allocations(r_id, jsonb_build_array(
        jsonb_build_object('commission_id', c_p2a, 'amount', 1500),
        jsonb_build_object('commission_id', c_p2b, 'amount', 1000)));
      ASSERT false, 'apply over: should have failed';
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT, v_st = RETURNED_SQLSTATE;
      IF v_st = 'P0004' THEN RAISE; END IF;
      ASSERT v_msg = 'Applied amount exceeds the receipt amount', format('apply over: got %s', v_msg);
    END;

    -- wrong insurer (P3 is with ins2)
    BEGIN
      PERFORM apply_receipt_allocations(r_id, jsonb_build_array(jsonb_build_object('commission_id', c_p3, 'amount', 100)));
      ASSERT false, 'apply wrong insurer: should have failed';
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT, v_st = RETURNED_SQLSTATE;
      IF v_st = 'P0004' THEN RAISE; END IF;
      ASSERT v_msg = 'That policy is not with this insurer', format('apply wrong insurer: got %s', v_msg);
    END;

    -- fully received (P1 paid by the line)
    BEGIN
      PERFORM apply_receipt_allocations(r_id, jsonb_build_array(jsonb_build_object('commission_id', c_p1, 'amount', 100)));
      ASSERT false, 'apply fully received: should have failed';
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT, v_st = RETURNED_SQLSTATE;
      IF v_st = 'P0004' THEN RAISE; END IF;
      ASSERT v_msg = 'That commission is already fully received', format('apply fully received: got %s', v_msg);
    END;

    -- non-positive amount
    BEGIN
      PERFORM apply_receipt_allocations(r_id, jsonb_build_array(jsonb_build_object('commission_id', c_p2a, 'amount', 0)));
      ASSERT false, 'apply zero: should have failed';
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT, v_st = RETURNED_SQLSTATE;
      IF v_st = 'P0004' THEN RAISE; END IF;
      ASSERT v_msg = 'Enter an amount to apply', format('apply zero: got %s', v_msg);
    END;

    SELECT count(*) INTO n FROM commission_allocations WHERE receipt_id = r_id;
    ASSERT n = 1, format('apply rejections: nothing extra applied, got %s allocations', n);

    -- agent
    PERFORM set_config('request.jwt.claims', json_build_object('sub', a1, 'role','authenticated')::text, true);
    BEGIN
      PERFORM apply_receipt_allocations(r_id, jsonb_build_array(jsonb_build_object('commission_id', c_p2a, 'amount', 100)));
      ASSERT false, 'apply agent: should have failed';
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT, v_st = RETURNED_SQLSTATE;
      IF v_st = 'P0004' THEN RAISE; END IF;
      ASSERT v_st = '42501' AND v_msg = 'Only owners and managers can do that',
        format('apply agent: got %s %s', v_st, v_msg);
    END;

    -- other agency's owner
    PERFORM set_config('request.jwt.claims', json_build_object('sub', o2, 'role','authenticated')::text, true);
    BEGIN
      PERFORM apply_receipt_allocations(r_id, jsonb_build_array(jsonb_build_object('commission_id', c_p2a, 'amount', 100)));
      ASSERT false, 'apply other agency: should have failed';
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT, v_st = RETURNED_SQLSTATE;
      IF v_st = 'P0004' THEN RAISE; END IF;
      ASSERT v_st = 'P0002' AND v_msg = 'Receipt not found',
        format('apply other agency: got %s %s', v_st, v_msg);
    END;

    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
  END;

  -- ---------------------------------------------------------
  -- 6. Grants
  -- ---------------------------------------------------------
  RESET ROLE;
  ASSERT NOT has_function_privilege('anon', 'public.apply_receipt_allocations(uuid, jsonb)', 'EXECUTE'),
    'anon can execute apply_receipt_allocations';
  ASSERT has_function_privilege('authenticated', 'public.apply_receipt_allocations(uuid, jsonb)', 'EXECUTE'),
    'authenticated cannot execute apply_receipt_allocations';
  ASSERT NOT has_function_privilege('anon', 'public.undo_commission_allocation(uuid)', 'EXECUTE'),
    'anon can execute undo_commission_allocation';
  ASSERT NOT has_function_privilege('anon', 'public.generate_monthly_report(integer, integer)', 'EXECUTE'),
    'anon can execute generate_monthly_report';
  ASSERT has_function_privilege('authenticated', 'public.generate_monthly_report(integer, integer)', 'EXECUTE'),
    'authenticated cannot execute generate_monthly_report';
END;
$$;

SELECT 'ALL PASSED' AS result;

ROLLBACK;
