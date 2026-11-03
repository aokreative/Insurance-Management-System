-- ============================================================
-- Test 010: reconciliation RPCs (create_insurer_receipt,
-- link_statement_line, undo_commission_allocation,
-- delete_insurer_receipt).
--
-- Run the whole file in one go (Supabase SQL editor / execute_sql).
-- One transaction, ALWAYS rolled back: on success the final SELECT
-- returns 'ALL PASSED'; any failed ASSERT aborts the batch.
-- Impersonation pattern: see supabase/tests/006_team_access_control.sql.
--
-- Each scenario runs in its own sub-block that ends with
-- RAISE ... ERRCODE 'ZZ001', which rolls the scenario back so the
-- next one starts from the fresh fixture. Failed ASSERTs raise
-- assert_failure (P0004), which is not caught and aborts the batch.
-- Expected errors are caught with WHEN OTHERS and both SQLSTATE and
-- message text are asserted (the UI shows the message).
-- ============================================================

BEGIN;

DO $$
DECLARE
  ag    UUID := gen_random_uuid();
  ag2   UUID := gen_random_uuid();
  o     UUID := gen_random_uuid();
  m     UUID := gen_random_uuid();
  a1    UUID := gen_random_uuid();
  o2    UUID := gen_random_uuid();
  ins1  UUID;
  ins2  UUID;
  ins_x UUID;   -- insurer of ag2
  pl    UUID;
  pl_x  UUID;
  cl    UUID := gen_random_uuid();
  cl_x  UUID := gen_random_uuid();
  p1    UUID := gen_random_uuid();   -- annual, ins1, expected 5000
  p2    UUID := gen_random_uuid();   -- annual, ins1, 2000 + 2000 a year later
  p3    UUID := gen_random_uuid();   -- annual, ins2
  l1    UUID := gen_random_uuid();   -- per-premium, ins1
  p_x   UUID := gen_random_uuid();   -- annual, ag2
  c_p1  UUID;
  c_p2a UUID;
  c_p2b UUID;
  c_p3  UUID;
  c_x   UUID;
  c_l   UUID;
  r     JSONB;
  r_id  UUID;
  r_x   UUID;
  ln_id UUID;
  ln_x  UUID;
  al_id UUID;
  al_l  UUID;
  al_x  UUID;
  n     INTEGER;
  v_num NUMERIC;
  v_txt TEXT;
  v_src TEXT;
  v_per DATE;
  v_exp DATE;
  v_msg TEXT;
  v_st  TEXT;
BEGIN
  -- ---------------------------------------------------------
  -- Fixture (as superuser, no JWT)
  -- ---------------------------------------------------------
  PERFORM set_config('request.jwt.claims', '{}', true);

  INSERT INTO auth.users (id, email, aud, role, instance_id) VALUES
    (o,  'o-010@test.local',  'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000'),
    (m,  'm-010@test.local',  'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000'),
    (a1, 'a1-010@test.local', 'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000'),
    (o2, 'o2-010@test.local', 'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000');

  INSERT INTO agencies (id, name) VALUES (ag, 'Test Agency 010'), (ag2, 'Other Agency 010');
  INSERT INTO users (id, agency_id, role, full_name, email) VALUES
    (o,  ag,  'owner',   'Owner 010',   'o-010@test.local'),
    (m,  ag,  'manager', 'Manager 010', 'm-010@test.local'),
    (a1, ag,  'agent',   'Agent1 010',  'a1-010@test.local'),
    (o2, ag2, 'owner',   'Owner2 010',  'o2-010@test.local');

  INSERT INTO insurers (agency_id, name) VALUES (ag,  'Insurer 010 A') RETURNING id INTO ins1;
  INSERT INTO insurers (agency_id, name) VALUES (ag,  'Insurer 010 B') RETURNING id INTO ins2;
  INSERT INTO insurers (agency_id, name) VALUES (ag2, 'Insurer 010 X') RETURNING id INTO ins_x;
  INSERT INTO product_lines (agency_id, name) VALUES (ag,  'Motor 010')   RETURNING id INTO pl;
  INSERT INTO product_lines (agency_id, name) VALUES (ag2, 'Motor 010 X') RETURNING id INTO pl_x;
  INSERT INTO clients (id, agency_id, type, name, assigned_agent_id) VALUES
    (cl,   ag,  'individual', 'Client 010',   a1),
    (cl_x, ag2, 'individual', 'Client 010 X', o2);

  INSERT INTO policies (id, agency_id, client_id, insurer_id, product_line_id, agent_id,
                        policy_number, premium_amount, commission_rate, commission_basis,
                        start_date, expiry_date, status)
  VALUES
    (p1, ag, cl, ins1, pl, a1, 'T010-P1', 50000, 10, 'annual', DATE '2026-01-15', DATE '2027-01-14', 'active'),
    (p2, ag, cl, ins1, pl, a1, 'T010-P2', 20000, 10, 'annual', DATE '2026-01-20', DATE '2027-01-19', 'active'),
    (p3, ag, cl, ins2, pl, a1, 'T010-P3', 30000, 10, 'annual', DATE '2026-01-25', DATE '2027-01-24', 'active');

  INSERT INTO policies (id, agency_id, client_id, insurer_id, product_line_id, agent_id,
                        policy_number, premium_amount, commission_rate, commission_basis,
                        premium_frequency, instalment_premium,
                        start_date, expiry_date, status)
  VALUES (l1, ag, cl, ins1, pl, a1, 'T010-L1', 96000, 10, 'per_premium',
          'monthly', 8000, DATE '2026-01-01', DATE '2036-12-31', 'active');

  INSERT INTO policies (id, agency_id, client_id, insurer_id, product_line_id, agent_id,
                        policy_number, premium_amount, commission_rate, commission_basis,
                        start_date, expiry_date, status)
  VALUES (p_x, ag2, cl_x, ins_x, pl_x, o2, 'T010-X', 10000, 10, 'annual',
          DATE '2026-01-15', DATE '2027-01-14', 'active');

  SELECT id INTO c_p1  FROM commission_transactions WHERE policy_id = p1;
  SELECT id INTO c_p2a FROM commission_transactions WHERE policy_id = p2;
  SELECT id INTO c_p3  FROM commission_transactions WHERE policy_id = p3;
  SELECT id INTO c_x   FROM commission_transactions WHERE policy_id = p_x;
  -- P2's second year
  INSERT INTO commission_transactions (policy_id, agency_id, amount, expected_date, source, notes)
  VALUES (p2, ag, 2000, DATE '2027-02-19', 'expected', 'Expected commission')
  RETURNING id INTO c_p2b;

  SELECT amount INTO v_num FROM commission_transactions WHERE id = c_p1;
  ASSERT v_num = 5000, format('fixture: P1 expected 5000, got %s', v_num);

  -- ---------------------------------------------------------
  -- 1. Full line: P1 5000 on a 7000 receipt
  -- ---------------------------------------------------------
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', o, 'role','authenticated')::text, true);
    SET LOCAL ROLE authenticated;

    r := create_insurer_receipt(ins1, DATE '2026-03-01', 7000, 'BANK-1', NULL,
           jsonb_build_array(jsonb_build_object('policy_number','T010-P1','client_name','Client 010',
             'premium',50000,'commission',5000,'period',NULL,'policy_id',p1)),
           '[]'::jsonb);
    ASSERT (r->>'applied')::numeric = 5000, format('full line: applied expected 5000, got %s', r->>'applied');
    ASSERT (r->>'unapplied')::numeric = 2000, format('full line: unapplied expected 2000, got %s', r->>'unapplied');
    ASSERT r->>'applied' = '5000.00', format('full line: applied should have 2 decimals, got %s', r->>'applied');
    r_id := (r->>'receipt_id')::uuid;

    SELECT status, amount_received INTO v_txt, v_num FROM commission_transactions WHERE id = c_p1;
    ASSERT v_txt = 'received' AND v_num = 5000, format('full line: P1 got %s / %s', v_txt, v_num);
    SELECT commission_received INTO v_num FROM policies WHERE id = p1;
    ASSERT v_num = 5000, format('full line: P1 policy tally expected 5000, got %s', v_num);
    SELECT count(*) INTO n FROM statement_lines WHERE receipt_id = r_id AND line_no = 1 AND policy_id = p1;
    ASSERT n = 1, format('full line: line 1 stored, got %s', n);
    SELECT count(*) INTO n FROM commission_allocations a JOIN statement_lines l ON l.id = a.statement_line_id
     WHERE a.receipt_id = r_id;
    ASSERT n = 1, format('full line: allocation linked to its line, got %s', n);
    SELECT bank_reference, created_by INTO v_txt, ln_id FROM insurer_receipts WHERE id = r_id;
    ASSERT v_txt = 'BANK-1' AND ln_id = o, format('full line: receipt fields %s / %s', v_txt, ln_id);

    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
  END;

  -- ---------------------------------------------------------
  -- 2. Short line: P1 3000
  -- ---------------------------------------------------------
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', o, 'role','authenticated')::text, true);
    SET LOCAL ROLE authenticated;

    r := create_insurer_receipt(ins1, DATE '2026-03-01', 3000, NULL, NULL,
           jsonb_build_array(jsonb_build_object('policy_number','T010-P1','commission',3000,'policy_id',p1)),
           '[]'::jsonb);
    SELECT status, amount_received INTO v_txt, v_num FROM commission_transactions WHERE id = c_p1;
    ASSERT v_txt = 'part_paid' AND v_num = 3000, format('short line: P1 got %s / %s', v_txt, v_num);
    ASSERT (r->>'unapplied')::numeric = 0, format('short line: unapplied expected 0, got %s', r->>'unapplied');

    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
  END;

  -- ---------------------------------------------------------
  -- 3. Over line: P1 6000 on a 6000 receipt -> 5000 applied
  -- ---------------------------------------------------------
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', o, 'role','authenticated')::text, true);
    SET LOCAL ROLE authenticated;

    r := create_insurer_receipt(ins1, DATE '2026-03-01', 6000, NULL, NULL,
           jsonb_build_array(jsonb_build_object('policy_number','T010-P1','commission',6000,'policy_id',p1)),
           '[]'::jsonb);
    ASSERT (r->>'applied')::numeric = 5000, format('over line: applied expected 5000, got %s', r->>'applied');
    ASSERT (r->>'unapplied')::numeric = 1000, format('over line: unapplied expected 1000, got %s', r->>'unapplied');
    SELECT status INTO v_txt FROM commission_transactions WHERE id = c_p1;
    ASSERT v_txt = 'received', format('over line: P1 expected received, got %s', v_txt);

    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
  END;

  -- ---------------------------------------------------------
  -- 4. Same policy twice: P2 1500 + 1500 -> older year first
  -- ---------------------------------------------------------
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', o, 'role','authenticated')::text, true);
    SET LOCAL ROLE authenticated;

    r := create_insurer_receipt(ins1, DATE '2026-03-01', 3000, NULL, NULL,
           jsonb_build_array(
             jsonb_build_object('policy_number','T010-P2','commission',1500,'policy_id',p2),
             jsonb_build_object('policy_number','T010-P2','commission',1500,'policy_id',p2)),
           '[]'::jsonb);
    SELECT status, amount_received INTO v_txt, v_num FROM commission_transactions WHERE id = c_p2a;
    ASSERT v_txt = 'received' AND v_num = 2000, format('P2 twice: older year got %s / %s', v_txt, v_num);
    SELECT status, amount_received INTO v_txt, v_num FROM commission_transactions WHERE id = c_p2b;
    ASSERT v_txt = 'part_paid' AND v_num = 1000, format('P2 twice: newer year got %s / %s', v_txt, v_num);
    SELECT commission_received INTO v_num FROM policies WHERE id = p2;
    ASSERT v_num = 3000, format('P2 twice: policy tally expected 3000, got %s', v_num);
    SELECT count(*) INTO n FROM statement_lines WHERE receipt_id = (r->>'receipt_id')::uuid;
    ASSERT n = 2, format('P2 twice: 2 lines expected, got %s', n);
    SELECT count(*) INTO n FROM commission_allocations WHERE receipt_id = (r->>'receipt_id')::uuid;
    ASSERT n = 3, format('P2 twice: 3 allocations expected, got %s', n);

    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
  END;

  -- ---------------------------------------------------------
  -- 5. Per-premium line: new statement commission
  -- ---------------------------------------------------------
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', o, 'role','authenticated')::text, true);
    SET LOCAL ROLE authenticated;

    r := create_insurer_receipt(ins1, DATE '2026-10-20', 800, NULL, NULL,
           jsonb_build_array(jsonb_build_object('policy_number','T010-L1','premium',8000,
             'commission',800,'period','2026-10-01','policy_id',l1)),
           '[]'::jsonb);
    SELECT count(*) INTO n FROM commission_transactions WHERE policy_id = l1;
    ASSERT n = 1, format('per-premium: 1 commission expected, got %s', n);
    SELECT source, amount, period, expected_date, status
      INTO v_src, v_num, v_per, v_exp, v_txt
      FROM commission_transactions WHERE policy_id = l1;
    ASSERT v_src = 'statement' AND v_num = 800 AND v_per = DATE '2026-10-01'
           AND v_exp = DATE '2026-10-01' AND v_txt = 'received',
      format('per-premium: got %s / %s / %s / %s / %s', v_src, v_num, v_per, v_exp, v_txt);
    SELECT commission_received INTO v_num FROM policies WHERE id = l1;
    ASSERT v_num = 800, format('per-premium: policy tally expected 800, got %s', v_num);

    -- period null -> period and expected_date = received_on
    r := create_insurer_receipt(ins1, DATE '2026-11-02', 500, NULL, NULL,
           jsonb_build_array(jsonb_build_object('policy_number','T010-L1','commission',500,
             'period',NULL,'policy_id',l1)),
           '[]'::jsonb);
    SELECT period, expected_date, status INTO v_per, v_exp, v_txt
      FROM commission_transactions WHERE policy_id = l1 AND amount = 500;
    ASSERT v_per = DATE '2026-11-02' AND v_exp = DATE '2026-11-02' AND v_txt = 'received',
      format('per-premium null period: got %s / %s / %s', v_per, v_exp, v_txt);

    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
  END;

  -- ---------------------------------------------------------
  -- 6. Negative line: stored, nothing applied
  -- ---------------------------------------------------------
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', o, 'role','authenticated')::text, true);
    SET LOCAL ROLE authenticated;

    r := create_insurer_receipt(ins1, DATE '2026-03-01', 1000, NULL, NULL,
           jsonb_build_array(jsonb_build_object('policy_number','T010-P1','commission',-1250,'policy_id',p1)),
           '[]'::jsonb);
    ASSERT (r->>'applied')::numeric = 0 AND (r->>'unapplied')::numeric = 1000,
      format('negative line: got applied %s unapplied %s', r->>'applied', r->>'unapplied');
    SELECT commission, policy_id INTO v_num, ln_id FROM statement_lines WHERE receipt_id = (r->>'receipt_id')::uuid;
    ASSERT v_num = -1250 AND ln_id = p1, format('negative line: stored %s / %s', v_num, ln_id);
    SELECT status, amount_received INTO v_txt, v_num FROM commission_transactions WHERE id = c_p1;
    ASSERT v_txt = 'pending' AND v_num = 0, format('negative line: P1 got %s / %s', v_txt, v_num);

    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
  END;

  -- ---------------------------------------------------------
  -- 7. Unmatched line, then link_statement_line
  -- ---------------------------------------------------------
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', o, 'role','authenticated')::text, true);
    SET LOCAL ROLE authenticated;

    r := create_insurer_receipt(ins1, DATE '2026-03-01', 5000, NULL, NULL,
           jsonb_build_array(jsonb_build_object('policy_number','T010 P1 ??','commission',5000,'policy_id',NULL)),
           '[]'::jsonb);
    ASSERT (r->>'applied')::numeric = 0, format('unmatched: applied expected 0, got %s', r->>'applied');
    SELECT id, policy_id INTO ln_id, ln_x FROM statement_lines WHERE receipt_id = (r->>'receipt_id')::uuid;
    ASSERT ln_x IS NULL, 'unmatched: policy_id should be NULL';

    r := link_statement_line(ln_id, p1);
    ASSERT (r->>'applied')::numeric = 5000, format('link: applied expected 5000, got %s', r->>'applied');
    SELECT policy_id INTO ln_x FROM statement_lines WHERE id = ln_id;
    ASSERT ln_x = p1, 'link: line now matched to P1';
    SELECT status INTO v_txt FROM commission_transactions WHERE id = c_p1;
    ASSERT v_txt = 'received', format('link: P1 expected received, got %s', v_txt);

    BEGIN
      PERFORM link_statement_line(ln_id, p2);
      RAISE EXCEPTION 'FAIL: linked an already matched line';
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
      ASSERT v_msg = 'That line is already matched', format('relink: unexpected message %s', v_msg);
    END;

    -- link is capped by the receipt's unapplied money
    r := create_insurer_receipt(ins1, DATE '2026-03-02', 1500, NULL, NULL,
           jsonb_build_array(jsonb_build_object('commission',2000,'policy_id',NULL)),
           '[]'::jsonb);
    SELECT id INTO ln_id FROM statement_lines WHERE receipt_id = (r->>'receipt_id')::uuid;
    r := link_statement_line(ln_id, p2);
    ASSERT (r->>'applied')::numeric = 1500, format('link capped: applied expected 1500, got %s', r->>'applied');
    SELECT status, amount_received INTO v_txt, v_num FROM commission_transactions WHERE id = c_p2a;
    ASSERT v_txt = 'part_paid' AND v_num = 1500, format('link capped: P2 got %s / %s', v_txt, v_num);

    -- link to a policy of another insurer
    r := create_insurer_receipt(ins1, DATE '2026-03-03', 100, NULL, NULL,
           jsonb_build_array(jsonb_build_object('commission',100,'policy_id',NULL)), '[]'::jsonb);
    SELECT id INTO ln_id FROM statement_lines WHERE receipt_id = (r->>'receipt_id')::uuid;
    BEGIN
      PERFORM link_statement_line(ln_id, p3);
      RAISE EXCEPTION 'FAIL: linked a line to a policy of another insurer';
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
      ASSERT v_msg = 'That policy is not with this insurer', format('link P3: unexpected message %s', v_msg);
    END;

    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
  END;

  -- ---------------------------------------------------------
  -- 8. Allocations-only receipt
  -- ---------------------------------------------------------
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', o, 'role','authenticated')::text, true);
    SET LOCAL ROLE authenticated;

    r := create_insurer_receipt(ins1, DATE '2026-03-01', 3500, NULL, NULL, '[]'::jsonb,
           jsonb_build_array(
             jsonb_build_object('commission_id', c_p1,  'amount', 1000),
             jsonb_build_object('commission_id', c_p2a, 'amount', 2000)));
    ASSERT (r->>'applied')::numeric = 3000 AND (r->>'unapplied')::numeric = 500,
      format('allocations-only: got applied %s unapplied %s', r->>'applied', r->>'unapplied');
    SELECT status, amount_received INTO v_txt, v_num FROM commission_transactions WHERE id = c_p1;
    ASSERT v_txt = 'part_paid' AND v_num = 1000, format('allocations-only: P1 got %s / %s', v_txt, v_num);
    SELECT status, amount_received INTO v_txt, v_num FROM commission_transactions WHERE id = c_p2a;
    ASSERT v_txt = 'received' AND v_num = 2000, format('allocations-only: P2 got %s / %s', v_txt, v_num);
    SELECT count(*) INTO n FROM statement_lines WHERE receipt_id = (r->>'receipt_id')::uuid;
    ASSERT n = 0, format('allocations-only: no lines expected, got %s', n);

    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
  END;

  -- ---------------------------------------------------------
  -- 9. Over the receipt amount -> error, nothing persists
  -- ---------------------------------------------------------
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', o, 'role','authenticated')::text, true);
    SET LOCAL ROLE authenticated;

    BEGIN
      PERFORM create_insurer_receipt(ins1, DATE '2026-03-01', 1000, NULL, NULL,
        jsonb_build_array(jsonb_build_object('commission',600,'policy_id',p1)),
        jsonb_build_array(jsonb_build_object('commission_id', c_p2a, 'amount', 500)));
      RAISE EXCEPTION 'FAIL: line + allocation over the receipt amount accepted';
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
      ASSERT v_msg = 'Applied amount exceeds the receipt amount', format('over receipt (mixed): unexpected message %s', v_msg);
    END;

    BEGIN
      PERFORM create_insurer_receipt(ins1, DATE '2026-03-01', 1000, NULL, NULL,
        jsonb_build_array(
          jsonb_build_object('commission',600,'policy_id',p1),
          jsonb_build_object('commission',600,'policy_id',p2)),
        '[]'::jsonb);
      RAISE EXCEPTION 'FAIL: lines over the receipt amount accepted';
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
      ASSERT v_msg = 'Applied amount exceeds the receipt amount', format('over receipt (lines): unexpected message %s', v_msg);
    END;

    BEGIN
      PERFORM create_insurer_receipt(ins1, DATE '2026-03-01', 1000, NULL, NULL, '[]'::jsonb,
        jsonb_build_array(
          jsonb_build_object('commission_id', c_p1,  'amount', 800),
          jsonb_build_object('commission_id', c_p2a, 'amount', 500)));
      RAISE EXCEPTION 'FAIL: allocations over the receipt amount accepted';
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
      ASSERT v_msg = 'Applied amount exceeds the receipt amount', format('over receipt (allocations): unexpected message %s', v_msg);
    END;

    SELECT count(*) INTO n FROM insurer_receipts WHERE agency_id = ag;
    ASSERT n = 0, format('over receipt: no receipt should persist, got %s', n);
    SELECT count(*) INTO n FROM statement_lines WHERE agency_id = ag;
    ASSERT n = 0, format('over receipt: no lines should persist, got %s', n);
    SELECT COALESCE(SUM(amount_received), 0) INTO v_num FROM commission_transactions WHERE agency_id = ag;
    ASSERT v_num = 0, format('over receipt: nothing received, got %s', v_num);

    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
  END;

  -- ---------------------------------------------------------
  -- 10. Already received / wrong insurer / bad input
  -- ---------------------------------------------------------
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', o, 'role','authenticated')::text, true);
    SET LOCAL ROLE authenticated;

    PERFORM create_insurer_receipt(ins1, DATE '2026-03-01', 5000, NULL, NULL, '[]'::jsonb,
      jsonb_build_array(jsonb_build_object('commission_id', c_p1, 'amount', 5000)));

    BEGIN
      PERFORM create_insurer_receipt(ins1, DATE '2026-03-02', 100, NULL, NULL, '[]'::jsonb,
        jsonb_build_array(jsonb_build_object('commission_id', c_p1, 'amount', 100)));
      RAISE EXCEPTION 'FAIL: allocation to a received commission accepted';
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
      ASSERT v_msg = 'That commission is already fully received', format('received: unexpected message %s', v_msg);
    END;

    BEGIN
      PERFORM create_insurer_receipt(ins1, DATE '2026-03-02', 100, NULL, NULL,
        jsonb_build_array(jsonb_build_object('commission',100,'policy_id',p3)), '[]'::jsonb);
      RAISE EXCEPTION 'FAIL: line with a policy of another insurer accepted';
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
      ASSERT v_msg = 'That policy is not with this insurer', format('P3 line: unexpected message %s', v_msg);
    END;

    BEGIN
      PERFORM create_insurer_receipt(ins1, DATE '2026-03-02', 100, NULL, NULL, '[]'::jsonb,
        jsonb_build_array(jsonb_build_object('commission_id', c_p3, 'amount', 100)));
      RAISE EXCEPTION 'FAIL: allocation to a commission of another insurer accepted';
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
      ASSERT v_msg = 'That policy is not with this insurer', format('P3 allocation: unexpected message %s', v_msg);
    END;

    -- another agency's commission / policy behave like a foreign insurer's
    BEGIN
      PERFORM create_insurer_receipt(ins1, DATE '2026-03-02', 100, NULL, NULL, '[]'::jsonb,
        jsonb_build_array(jsonb_build_object('commission_id', c_x, 'amount', 100)));
      RAISE EXCEPTION 'FAIL: allocation to another agency''s commission accepted';
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
      ASSERT v_msg = 'That policy is not with this insurer', format('foreign allocation: unexpected message %s', v_msg);
    END;
    BEGIN
      PERFORM create_insurer_receipt(ins1, DATE '2026-03-02', 100, NULL, NULL,
        jsonb_build_array(jsonb_build_object('commission',100,'policy_id',p_x)), '[]'::jsonb);
      RAISE EXCEPTION 'FAIL: line with another agency''s policy accepted';
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
      ASSERT v_msg = 'That policy is not with this insurer', format('foreign line: unexpected message %s', v_msg);
    END;

    BEGIN
      PERFORM create_insurer_receipt(ins1, DATE '2026-03-02', 0, NULL, NULL, '[]'::jsonb, '[]'::jsonb);
      RAISE EXCEPTION 'FAIL: zero receipt accepted';
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
      ASSERT v_msg = 'Enter the amount received', format('zero amount: unexpected message %s', v_msg);
    END;

    BEGIN
      PERFORM create_insurer_receipt(ins_x, DATE '2026-03-02', 100, NULL, NULL, '[]'::jsonb, '[]'::jsonb);
      RAISE EXCEPTION 'FAIL: receipt for another agency''s insurer accepted';
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT, v_st = RETURNED_SQLSTATE;
      ASSERT v_msg = 'Insurer not found' AND v_st = 'P0002',
        format('foreign insurer: unexpected %s / %s', v_st, v_msg);
    END;

    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
  END;

  -- ---------------------------------------------------------
  -- 11. Undo and delete
  -- ---------------------------------------------------------
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', o, 'role','authenticated')::text, true);
    SET LOCAL ROLE authenticated;

    r := create_insurer_receipt(ins1, DATE '2026-10-20', 5800, NULL, NULL,
           jsonb_build_array(
             jsonb_build_object('commission',5000,'policy_id',p1),
             jsonb_build_object('commission',800,'period','2026-10-01','policy_id',l1)),
           '[]'::jsonb);
    r_id := (r->>'receipt_id')::uuid;
    SELECT id INTO c_l FROM commission_transactions WHERE policy_id = l1;
    SELECT id INTO al_id FROM commission_allocations WHERE receipt_id = r_id AND commission_id = c_p1;
    SELECT id INTO al_l  FROM commission_allocations WHERE receipt_id = r_id AND commission_id = c_l;

    BEGIN
      PERFORM delete_insurer_receipt(r_id);
      RAISE EXCEPTION 'FAIL: deleted a receipt with allocations';
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
      ASSERT v_msg = 'Undo the applied amounts before deleting this receipt', format('delete applied: unexpected message %s', v_msg);
    END;

    PERFORM undo_commission_allocation(al_l);
    SELECT count(*) INTO n FROM commission_transactions WHERE id = c_l;
    ASSERT n = 0, 'undo L1: statement commission should be deleted';
    SELECT commission_received INTO v_num FROM policies WHERE id = l1;
    ASSERT v_num = 0, format('undo L1: policy tally expected 0, got %s', v_num);

    PERFORM undo_commission_allocation(al_id);
    SELECT status, amount_received INTO v_txt, v_num FROM commission_transactions WHERE id = c_p1;
    ASSERT v_txt = 'pending' AND v_num = 0, format('undo P1: got %s / %s', v_txt, v_num);
    SELECT count(*) INTO n FROM commission_transactions WHERE id = c_p1;
    ASSERT n = 1, 'undo P1: expected commission is kept';
    SELECT commission_received INTO v_num FROM policies WHERE id = p1;
    ASSERT v_num = 0, format('undo P1: policy tally expected 0, got %s', v_num);

    PERFORM delete_insurer_receipt(r_id);
    SELECT count(*) INTO n FROM insurer_receipts WHERE id = r_id;
    ASSERT n = 0, 'delete: receipt should be gone';
    SELECT count(*) INTO n FROM statement_lines WHERE receipt_id = r_id;
    ASSERT n = 0, format('delete: lines should be gone, got %s', n);

    BEGIN
      PERFORM delete_insurer_receipt(gen_random_uuid());
      RAISE EXCEPTION 'FAIL: deleted an unknown receipt';
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT, v_st = RETURNED_SQLSTATE;
      ASSERT v_msg = 'Receipt not found' AND v_st = 'P0002', format('delete unknown: %s / %s', v_st, v_msg);
    END;
    BEGIN
      PERFORM undo_commission_allocation(gen_random_uuid());
      RAISE EXCEPTION 'FAIL: undid an unknown allocation';
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT, v_st = RETURNED_SQLSTATE;
      ASSERT v_msg = 'Receipt not found' AND v_st = 'P0002', format('undo unknown: %s / %s', v_st, v_msg);
    END;
    BEGIN
      PERFORM link_statement_line(gen_random_uuid(), p1);
      RAISE EXCEPTION 'FAIL: linked an unknown line';
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT, v_st = RETURNED_SQLSTATE;
      ASSERT v_msg = 'Receipt not found' AND v_st = 'P0002', format('link unknown: %s / %s', v_st, v_msg);
    END;

    -- A statement commission keeps existing while another allocation remains
    r := create_insurer_receipt(ins1, DATE '2026-10-21', 300, NULL, NULL,
           jsonb_build_array(jsonb_build_object('commission',800,'period','2026-09-01','policy_id',NULL)),
           '[]'::jsonb);
    SELECT id INTO ln_id FROM statement_lines WHERE receipt_id = (r->>'receipt_id')::uuid;
    PERFORM link_statement_line(ln_id, l1);   -- 300 of 800 applied (capped)
    SELECT id, status, amount_received INTO c_l, v_txt, v_num
      FROM commission_transactions WHERE policy_id = l1 AND period = DATE '2026-09-01';
    ASSERT v_txt = 'part_paid' AND v_num = 300, format('link per-premium capped: got %s / %s', v_txt, v_num);
    PERFORM create_insurer_receipt(ins1, DATE '2026-10-22', 500, NULL, NULL, '[]'::jsonb,
      jsonb_build_array(jsonb_build_object('commission_id', c_l, 'amount', 500)));
    SELECT id INTO al_l FROM commission_allocations WHERE receipt_id = (r->>'receipt_id')::uuid;
    PERFORM undo_commission_allocation(al_l);
    SELECT status, amount_received INTO v_txt, v_num FROM commission_transactions WHERE id = c_l;
    ASSERT v_txt = 'part_paid' AND v_num = 500, format('undo with other allocation: got %s / %s', v_txt, v_num);

    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
  END;

  -- ---------------------------------------------------------
  -- 12. Opening-balance receipts: cannot be deleted, can be undone
  -- ---------------------------------------------------------
  BEGIN
    PERFORM set_config('request.jwt.claims', '{}', true);
    INSERT INTO insurer_receipts (agency_id, insurer_id, received_on, amount, is_opening_balance)
    VALUES (ag, ins1, DATE '2026-01-01', 5000, true) RETURNING id INTO r_id;
    INSERT INTO commission_allocations (agency_id, receipt_id, commission_id, amount)
    VALUES (ag, r_id, c_p1, 5000) RETURNING id INTO al_id;

    PERFORM set_config('request.jwt.claims', json_build_object('sub', o, 'role','authenticated')::text, true);
    SET LOCAL ROLE authenticated;

    BEGIN
      PERFORM delete_insurer_receipt(r_id);
      RAISE EXCEPTION 'FAIL: deleted an opening balance receipt';
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
      ASSERT v_msg = 'Opening balance receipts cannot be deleted', format('opening delete: unexpected message %s', v_msg);
    END;

    PERFORM undo_commission_allocation(al_id);
    SELECT status INTO v_txt FROM commission_transactions WHERE id = c_p1;
    ASSERT v_txt = 'pending', format('opening undo: P1 expected pending, got %s', v_txt);

    BEGIN
      PERFORM delete_insurer_receipt(r_id);
      RAISE EXCEPTION 'FAIL: deleted an opening balance receipt after undo';
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
      ASSERT v_msg = 'Opening balance receipts cannot be deleted', format('opening delete 2: unexpected message %s', v_msg);
    END;

    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
  END;

  -- ---------------------------------------------------------
  -- 13. Roles: agent refused everywhere, manager allowed
  -- ---------------------------------------------------------
  BEGIN
    -- a receipt with a line and an allocation for a1 to target
    PERFORM set_config('request.jwt.claims', json_build_object('sub', o, 'role','authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    r := create_insurer_receipt(ins1, DATE '2026-03-01', 6000, NULL, NULL,
           jsonb_build_array(
             jsonb_build_object('commission',1000,'policy_id',p1),
             jsonb_build_object('commission',100,'policy_id',NULL)),
           '[]'::jsonb);
    r_id := (r->>'receipt_id')::uuid;
    SELECT id INTO al_id FROM commission_allocations WHERE receipt_id = r_id;
    SELECT id INTO ln_id FROM statement_lines WHERE receipt_id = r_id AND policy_id IS NULL;
    RESET ROLE;

    PERFORM set_config('request.jwt.claims', json_build_object('sub', a1, 'role','authenticated')::text, true);
    SET LOCAL ROLE authenticated;

    BEGIN
      PERFORM create_insurer_receipt(ins1, DATE '2026-03-01', 100, NULL, NULL, '[]'::jsonb, '[]'::jsonb);
      RAISE EXCEPTION 'FAIL: agent created a receipt';
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT, v_st = RETURNED_SQLSTATE;
      ASSERT v_msg = 'Only owners and managers can do that' AND v_st = '42501', format('a1 create: %s / %s', v_st, v_msg);
    END;
    BEGIN
      PERFORM link_statement_line(ln_id, p2);
      RAISE EXCEPTION 'FAIL: agent linked a line';
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT, v_st = RETURNED_SQLSTATE;
      ASSERT v_msg = 'Only owners and managers can do that' AND v_st = '42501', format('a1 link: %s / %s', v_st, v_msg);
    END;
    BEGIN
      PERFORM undo_commission_allocation(al_id);
      RAISE EXCEPTION 'FAIL: agent undid an allocation';
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT, v_st = RETURNED_SQLSTATE;
      ASSERT v_msg = 'Only owners and managers can do that' AND v_st = '42501', format('a1 undo: %s / %s', v_st, v_msg);
    END;
    BEGIN
      PERFORM delete_insurer_receipt(r_id);
      RAISE EXCEPTION 'FAIL: agent deleted a receipt';
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT, v_st = RETURNED_SQLSTATE;
      ASSERT v_msg = 'Only owners and managers can do that' AND v_st = '42501', format('a1 delete: %s / %s', v_st, v_msg);
    END;
    BEGIN
      PERFORM _apply_line(ln_id, 100);
      RAISE EXCEPTION 'FAIL: agent called _apply_line';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    RESET ROLE;

    PERFORM set_config('request.jwt.claims', json_build_object('sub', m, 'role','authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    r := create_insurer_receipt(ins1, DATE '2026-03-05', 2000, NULL, NULL,
           jsonb_build_array(jsonb_build_object('commission',2000,'policy_id',p2)), '[]'::jsonb);
    ASSERT (r->>'applied')::numeric = 2000, format('manager create: applied expected 2000, got %s', r->>'applied');
    BEGIN
      PERFORM _apply_line(ln_id, 100);
      RAISE EXCEPTION 'FAIL: manager called _apply_line';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    RESET ROLE;

    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
  END;

  -- ---------------------------------------------------------
  -- 14. Another agency's receipt is invisible and untouchable
  -- ---------------------------------------------------------
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', o2, 'role','authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    r := create_insurer_receipt(ins_x, DATE '2026-03-01', 1500, NULL, NULL,
           jsonb_build_array(
             jsonb_build_object('commission',1000,'policy_id',p_x),
             jsonb_build_object('commission',100,'policy_id',NULL)),
           '[]'::jsonb);
    r_x := (r->>'receipt_id')::uuid;
    SELECT id INTO al_x FROM commission_allocations WHERE receipt_id = r_x;
    SELECT id INTO ln_x FROM statement_lines WHERE receipt_id = r_x AND policy_id IS NULL;
    ASSERT al_x IS NOT NULL AND ln_x IS NOT NULL, 'o2 fixture: allocation and unmatched line exist';
    RESET ROLE;

    PERFORM set_config('request.jwt.claims', json_build_object('sub', o, 'role','authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    SELECT count(*) INTO n FROM insurer_receipts WHERE id = r_x;
    ASSERT n = 0, 'o sees another agency''s receipt';
    SELECT count(*) INTO n FROM statement_lines WHERE receipt_id = r_x;
    ASSERT n = 0, 'o sees another agency''s lines';

    BEGIN
      PERFORM link_statement_line(ln_x, p1);
      RAISE EXCEPTION 'FAIL: o linked another agency''s line';
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT, v_st = RETURNED_SQLSTATE;
      ASSERT v_msg = 'Receipt not found' AND v_st = 'P0002', format('foreign link: %s / %s', v_st, v_msg);
    END;
    BEGIN
      PERFORM undo_commission_allocation(al_x);
      RAISE EXCEPTION 'FAIL: o undid another agency''s allocation';
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT, v_st = RETURNED_SQLSTATE;
      ASSERT v_msg = 'Receipt not found' AND v_st = 'P0002', format('foreign undo: %s / %s', v_st, v_msg);
    END;
    BEGIN
      PERFORM delete_insurer_receipt(r_x);
      RAISE EXCEPTION 'FAIL: o deleted another agency''s receipt';
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT, v_st = RETURNED_SQLSTATE;
      ASSERT v_msg = 'Receipt not found' AND v_st = 'P0002', format('foreign delete: %s / %s', v_st, v_msg);
    END;
    RESET ROLE;

    SELECT count(*) INTO n FROM commission_allocations WHERE id = al_x;
    ASSERT n = 1, 'foreign allocation still exists';
    SELECT count(*) INTO n FROM insurer_receipts WHERE id = r_x;
    ASSERT n = 1, 'foreign receipt still exists';

    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
  END;

  -- ---------------------------------------------------------
  -- 15. Grants and the dropped function
  -- ---------------------------------------------------------
  ASSERT to_regprocedure('public.mark_overdue_commissions()') IS NULL,
    'mark_overdue_commissions() should be dropped';

  ASSERT NOT has_function_privilege('anon',
    'public.create_insurer_receipt(uuid, date, numeric, text, text, jsonb, jsonb)', 'EXECUTE'),
    'anon can execute create_insurer_receipt';
  ASSERT NOT has_function_privilege('anon', 'public.link_statement_line(uuid, uuid)', 'EXECUTE'),
    'anon can execute link_statement_line';
  ASSERT NOT has_function_privilege('anon', 'public.undo_commission_allocation(uuid)', 'EXECUTE'),
    'anon can execute undo_commission_allocation';
  ASSERT NOT has_function_privilege('anon', 'public.delete_insurer_receipt(uuid)', 'EXECUTE'),
    'anon can execute delete_insurer_receipt';
  ASSERT has_function_privilege('authenticated',
    'public.create_insurer_receipt(uuid, date, numeric, text, text, jsonb, jsonb)', 'EXECUTE'),
    'authenticated cannot execute create_insurer_receipt';
  ASSERT NOT has_function_privilege('authenticated', 'public._apply_line(uuid, numeric)', 'EXECUTE'),
    'authenticated can execute _apply_line';
  ASSERT NOT has_function_privilege('anon', 'public._apply_line(uuid, numeric)', 'EXECUTE'),
    'anon can execute _apply_line';
END;
$$;

SELECT 'ALL PASSED' AS result;

ROLLBACK;
