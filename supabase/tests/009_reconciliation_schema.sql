-- ============================================================
-- Test 009: reconciliation schema (policy commission basis,
-- derived commission status, receipts / statement lines /
-- allocations, triggers and RLS).
--
-- Run the whole file in one go (Supabase SQL editor / execute_sql).
-- One transaction, ALWAYS rolled back: on success the final SELECT
-- returns 'ALL PASSED'; any failed ASSERT aborts the batch.
-- Impersonation pattern: see supabase/tests/006_team_access_control.sql.
-- ============================================================

BEGIN;

DO $$
DECLARE
  ag    UUID := gen_random_uuid();
  o     UUID := gen_random_uuid();
  a1    UUID := gen_random_uuid();
  ins   UUID;
  ins2  UUID;
  pl    UUID;
  cl    UUID := gen_random_uuid();
  p_ann UUID := gen_random_uuid();
  p_pp  UUID := gen_random_uuid();
  ct    UUID;
  ct_x  UUID;
  p_ann2 UUID := gen_random_uuid();
  ct2   UUID;
  r1    UUID;
  r2    UUID;
  r3    UUID;
  al1   UUID;
  n     INTEGER;
  v_num NUMERIC;
  v_txt TEXT;
  v_date DATE;
  v_msg TEXT;
BEGIN
  -- ---------------------------------------------------------
  -- Fixture (as superuser, no JWT)
  -- ---------------------------------------------------------
  PERFORM set_config('request.jwt.claims', '{}', true);

  INSERT INTO auth.users (id, email, aud, role, instance_id) VALUES
    (o,  'o-009@test.local',  'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000'),
    (a1, 'a1-009@test.local', 'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000');

  INSERT INTO agencies (id, name) VALUES (ag, 'Test Agency 009');
  INSERT INTO users (id, agency_id, role, full_name, email) VALUES
    (o,  ag, 'owner', 'Owner 009',  'o-009@test.local'),
    (a1, ag, 'agent', 'Agent1 009', 'a1-009@test.local');

  INSERT INTO insurers (agency_id, name) VALUES (ag, 'Insurer 009')   RETURNING id INTO ins;
  INSERT INTO insurers (agency_id, name) VALUES (ag, 'Insurer 009 B') RETURNING id INTO ins2;
  INSERT INTO product_lines (agency_id, name) VALUES (ag, 'Life 009') RETURNING id INTO pl;
  INSERT INTO clients (id, agency_id, type, name, assigned_agent_id)
  VALUES (cl, ag, 'individual', 'Client 009', a1);

  -- Annual policy: 120000 x 10% = 12000 expected
  INSERT INTO policies (id, agency_id, client_id, insurer_id, product_line_id, agent_id,
                        policy_number, premium_amount, commission_rate, commission_basis,
                        start_date, expiry_date, status)
  VALUES (p_ann, ag, cl, ins, pl, a1, 'T009-ANN', 120000, 10, 'annual',
          DATE '2026-01-15', DATE '2027-01-14', 'active');

  -- Per-premium policy
  INSERT INTO policies (id, agency_id, client_id, insurer_id, product_line_id, agent_id,
                        policy_number, premium_amount, commission_rate, commission_basis,
                        premium_frequency, instalment_premium,
                        start_date, expiry_date, status)
  VALUES (p_pp, ag, cl, ins, pl, a1, 'T009-PP', 12000, 10, 'per_premium',
          'monthly', 1000, DATE '2026-01-15', DATE '2027-01-14', 'active');

  -- ---------------------------------------------------------
  -- Expected-commission trigger
  -- ---------------------------------------------------------
  SELECT count(*) INTO n FROM commission_transactions WHERE policy_id = p_ann;
  ASSERT n = 1, format('annual policy: expected 1 commission, got %s', n);
  SELECT id, amount, expected_date, status, source
    INTO ct, v_num, v_date, v_txt, v_msg
    FROM commission_transactions WHERE policy_id = p_ann;
  ASSERT v_num = 12000, format('annual commission amount: expected 12000, got %s', v_num);
  ASSERT v_date = DATE '2026-02-14', format('annual expected_date: expected 2026-02-14, got %s', v_date);
  ASSERT v_txt = 'pending', format('annual commission status: expected pending, got %s', v_txt);
  ASSERT v_msg = 'expected', format('annual commission source: expected expected, got %s', v_msg);

  SELECT count(*) INTO n FROM commission_transactions WHERE policy_id = p_pp;
  ASSERT n = 0, format('per-premium policy: expected 0 commissions, got %s', n);

  -- per_premium without premium_frequency -> check_violation
  BEGIN
    INSERT INTO policies (agency_id, client_id, insurer_id, product_line_id, agent_id,
                          policy_number, premium_amount, commission_rate, commission_basis,
                          instalment_premium, start_date, expiry_date)
    VALUES (ag, cl, ins, pl, a1, 'T009-BAD', 12000, 10, 'per_premium',
            1000, DATE '2026-01-15', DATE '2027-01-14');
    RAISE EXCEPTION 'FAIL: per_premium policy without premium_frequency was accepted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;

  -- ---------------------------------------------------------
  -- Owner (JWT): amount_received guarded, status derived
  -- ---------------------------------------------------------
  PERFORM set_config('request.jwt.claims', json_build_object('sub', o, 'role','authenticated')::text, true);
  SET LOCAL ROLE authenticated;

  BEGIN
    UPDATE commission_transactions SET amount_received = 1 WHERE id = ct;
    RAISE EXCEPTION 'FAIL: owner changed amount_received directly';
  EXCEPTION WHEN insufficient_privilege THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    ASSERT v_msg = 'Commission received is recorded through receipts',
      format('owner amount_received guard: unexpected message %s', v_msg);
  END;

  BEGIN
    INSERT INTO commission_transactions (policy_id, agency_id, amount, amount_received)
    VALUES (p_ann, ag, 100, 100);
    RAISE EXCEPTION 'FAIL: owner inserted a commission with amount_received';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;

  UPDATE commission_transactions SET status = 'received' WHERE id = ct;
  GET DIAGNOSTICS n = ROW_COUNT;
  ASSERT n = 1, format('owner status update: expected 1 row, got %s', n);
  SELECT status INTO v_txt FROM commission_transactions WHERE id = ct;
  ASSERT v_txt = 'pending', format('owner status update: expected derived pending, got %s', v_txt);

  -- Owner/Manager: direct writes to the new tables are denied (RPC-only)
  BEGIN
    INSERT INTO insurer_receipts (agency_id, insurer_id, received_on, amount)
    VALUES (ag, ins, CURRENT_DATE, 100);
    RAISE EXCEPTION 'FAIL: owner inserted into insurer_receipts';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    INSERT INTO statement_lines (agency_id, receipt_id, line_no, commission)
    VALUES (ag, gen_random_uuid(), 1, 100);
    RAISE EXCEPTION 'FAIL: owner inserted into statement_lines';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    INSERT INTO commission_allocations (agency_id, receipt_id, commission_id, amount)
    VALUES (ag, gen_random_uuid(), ct, 100);
    RAISE EXCEPTION 'FAIL: owner inserted into commission_allocations';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  RESET ROLE;

  -- ---------------------------------------------------------
  -- Allocations: run as superuser while carrying the owner's JWT,
  -- i.e. exactly how a SECURITY DEFINER RPC called by the owner runs.
  -- The recompute trigger's app.allocating flag lets it through the
  -- amount_received guard; 006a passes because o is the owner.
  -- ---------------------------------------------------------
  INSERT INTO insurer_receipts (agency_id, insurer_id, received_on, amount)
  VALUES (ag, ins, DATE '2026-03-01', 12000) RETURNING id INTO r1;
  INSERT INTO statement_lines (agency_id, receipt_id, line_no, policy_number, commission, policy_id)
  VALUES (ag, r1, 1, 'T009-ANN', 12000, p_ann);

  INSERT INTO commission_allocations (agency_id, receipt_id, commission_id, amount)
  VALUES (ag, r1, ct, 6000) RETURNING id INTO al1;
  SELECT status, amount_received INTO v_txt, v_num FROM commission_transactions WHERE id = ct;
  ASSERT v_txt = 'part_paid', format('half allocated: expected part_paid, got %s', v_txt);
  ASSERT v_num = 6000, format('half allocated: expected amount_received 6000, got %s', v_num);
  SELECT commission_received INTO v_num FROM policies WHERE id = p_ann;
  ASSERT v_num = 6000, format('half allocated: expected policy commission_received 6000, got %s', v_num);

  INSERT INTO commission_allocations (agency_id, receipt_id, commission_id, amount)
  VALUES (ag, r1, ct, 6000);
  SELECT status, amount_received INTO v_txt, v_num FROM commission_transactions WHERE id = ct;
  ASSERT v_txt = 'received', format('fully allocated: expected received, got %s', v_txt);
  ASSERT v_num = 12000, format('fully allocated: expected amount_received 12000, got %s', v_num);
  SELECT commission_received INTO v_num FROM policies WHERE id = p_ann;
  ASSERT v_num = 12000, format('fully allocated: expected policy commission_received 12000, got %s', v_num);

  -- Caps and insurer match (re-checked by the allocation trigger)
  BEGIN
    INSERT INTO commission_allocations (agency_id, receipt_id, commission_id, amount)
    VALUES (ag, r1, ct, 1);
    RAISE EXCEPTION 'FAIL: receipt over-allocated';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    ASSERT v_msg = 'Applied amount exceeds the receipt amount', format('receipt cap: unexpected message %s', v_msg);
  END;

  INSERT INTO insurer_receipts (agency_id, insurer_id, received_on, amount)
  VALUES (ag, ins, DATE '2026-03-02', 5000) RETURNING id INTO r2;
  BEGIN
    INSERT INTO commission_allocations (agency_id, receipt_id, commission_id, amount)
    VALUES (ag, r2, ct, 1);
    RAISE EXCEPTION 'FAIL: commission over-allocated';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    ASSERT v_msg = 'That commission is already fully received', format('commission cap: unexpected message %s', v_msg);
  END;

  INSERT INTO insurer_receipts (agency_id, insurer_id, received_on, amount)
  VALUES (ag, ins2, DATE '2026-03-03', 5000) RETURNING id INTO r3;
  BEGIN
    INSERT INTO commission_allocations (agency_id, receipt_id, commission_id, amount)
    VALUES (ag, r3, ct, 1);
    RAISE EXCEPTION 'FAIL: allocation across insurers accepted';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    ASSERT v_msg = 'That policy is not with this insurer', format('insurer match: unexpected message %s', v_msg);
  END;

  -- Delete one allocation -> back to part_paid, tallies drop
  DELETE FROM commission_allocations WHERE id = al1;
  SELECT status, amount_received INTO v_txt, v_num FROM commission_transactions WHERE id = ct;
  ASSERT v_txt = 'part_paid', format('after undo: expected part_paid, got %s', v_txt);
  ASSERT v_num = 6000, format('after undo: expected amount_received 6000, got %s', v_num);
  SELECT commission_received INTO v_num FROM policies WHERE id = p_ann;
  ASSERT v_num = 6000, format('after undo: expected policy commission_received 6000, got %s', v_num);

  -- ---------------------------------------------------------
  -- Agent a1: sees own commission (with amount_received), nothing else
  -- ---------------------------------------------------------
  PERFORM set_config('request.jwt.claims', json_build_object('sub', a1, 'role','authenticated')::text, true);
  SET LOCAL ROLE authenticated;

  SELECT amount_received, status INTO v_num, v_txt FROM commission_transactions WHERE id = ct;
  ASSERT v_num = 6000 AND v_txt = 'part_paid', format('a1 own commission: got %s / %s', v_num, v_txt);
  SELECT count(*) INTO n FROM insurer_receipts;       ASSERT n = 0, format('a1 receipts: expected 0, got %s', n);
  SELECT count(*) INTO n FROM statement_lines;        ASSERT n = 0, format('a1 lines: expected 0, got %s', n);
  SELECT count(*) INTO n FROM commission_allocations; ASSERT n = 0, format('a1 allocations: expected 0, got %s', n);

  BEGIN
    INSERT INTO insurer_receipts (agency_id, insurer_id, received_on, amount)
    VALUES (ag, ins, CURRENT_DATE, 100);
    RAISE EXCEPTION 'FAIL: a1 inserted into insurer_receipts';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    INSERT INTO statement_lines (agency_id, receipt_id, line_no, commission)
    VALUES (ag, r1, 2, 100);
    RAISE EXCEPTION 'FAIL: a1 inserted into statement_lines';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    INSERT INTO commission_allocations (agency_id, receipt_id, commission_id, amount)
    VALUES (ag, r1, ct, 100);
    RAISE EXCEPTION 'FAIL: a1 inserted into commission_allocations';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  RESET ROLE;

  -- Owner sees the agency's receipts / lines / allocations
  PERFORM set_config('request.jwt.claims', json_build_object('sub', o, 'role','authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  SELECT count(*) INTO n FROM insurer_receipts WHERE agency_id = ag;       ASSERT n = 3, format('o receipts: expected 3, got %s', n);
  SELECT count(*) INTO n FROM statement_lines WHERE agency_id = ag;        ASSERT n = 1, format('o lines: expected 1, got %s', n);
  SELECT count(*) INTO n FROM commission_allocations WHERE agency_id = ag; ASSERT n = 1, format('o allocations: expected 1, got %s', n);
  RESET ROLE;

  -- ---------------------------------------------------------
  -- Status conversion of existing data
  -- ---------------------------------------------------------
  PERFORM set_config('request.jwt.claims', '{}', true);

  SELECT count(*) INTO n FROM commission_transactions WHERE status = 'overdue';
  ASSERT n = 0, format('overdue rows remain: %s', n);
  SELECT count(*) INTO n FROM commission_transactions WHERE status = 'received' AND amount_received <> amount;
  ASSERT n = 0, format('received rows with amount_received <> amount: %s', n);

  -- Fixture: the conversion statement (amount_received = amount, no JWT)
  -- turns a row into a consistent 'received' row
  INSERT INTO commission_transactions (policy_id, agency_id, amount, expected_date)
  VALUES (p_pp, ag, 500, DATE '2026-02-01') RETURNING id INTO ct_x;
  UPDATE commission_transactions SET amount_received = amount WHERE id = ct_x;
  SELECT status, amount_received INTO v_txt, v_num FROM commission_transactions WHERE id = ct_x;
  ASSERT v_txt = 'received' AND v_num = 500, format('conversion fixture: got %s / %s', v_txt, v_num);

  -- ---------------------------------------------------------
  -- Policy tally follows commission moves and deletes
  -- (ct: 6000 received on p_ann via r1; r2 has 5000 unapplied)
  -- ---------------------------------------------------------
  INSERT INTO policies (id, agency_id, client_id, insurer_id, product_line_id, agent_id,
                        policy_number, premium_amount, commission_rate, commission_basis,
                        start_date, expiry_date, status)
  VALUES (p_ann2, ag, cl, ins, pl, a1, 'T009-ANN2', 50000, 10, 'annual',
          DATE '2026-01-20', DATE '2027-01-19', 'active');
  SELECT id INTO ct2 FROM commission_transactions WHERE policy_id = p_ann2;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', o, 'role','authenticated')::text, true);
  INSERT INTO commission_allocations (agency_id, receipt_id, commission_id, amount)
  VALUES (ag, r2, ct2, 1000);
  SELECT commission_received INTO v_num FROM policies WHERE id = p_ann2;
  ASSERT v_num = 1000, format('p_ann2 after 1000 allocated: expected 1000, got %s', v_num);

  -- p_ann gets a second commission (500 received via r2) so a delete
  -- has a remaining sum to drop to
  INSERT INTO commission_transactions (policy_id, agency_id, amount, expected_date)
  VALUES (p_ann, ag, 2000, DATE '2026-04-01') RETURNING id INTO ct_x;
  INSERT INTO commission_allocations (agency_id, receipt_id, commission_id, amount)
  VALUES (ag, r2, ct_x, 500);
  SELECT commission_received INTO v_num FROM policies WHERE id = p_ann;
  ASSERT v_num = 6500, format('p_ann before delete: expected 6500, got %s', v_num);

  -- Owner deletes the allocated commission ct: its allocation cascades,
  -- the policy drops to the remaining sum
  SET LOCAL ROLE authenticated;
  DELETE FROM commission_transactions WHERE id = ct;
  GET DIAGNOSTICS n = ROW_COUNT;
  ASSERT n = 1, format('owner deleting commission: expected 1 row, got %s', n);
  RESET ROLE;
  SELECT commission_received INTO v_num FROM policies WHERE id = p_ann;
  ASSERT v_num = 500, format('after delete: p_ann expected 500, got %s', v_num);
  SELECT count(*) INTO n FROM commission_allocations WHERE receipt_id = r1;
  ASSERT n = 0, format('after delete: r1 allocations expected 0, got %s', n);

  -- Owner moves the allocated commission ct2 (1000) from p_ann2 to p_ann
  SET LOCAL ROLE authenticated;
  UPDATE commission_transactions SET policy_id = p_ann WHERE id = ct2;
  GET DIAGNOSTICS n = ROW_COUNT;
  ASSERT n = 1, format('owner moving commission: expected 1 row, got %s', n);
  RESET ROLE;
  SELECT commission_received INTO v_num FROM policies WHERE id = p_ann;
  ASSERT v_num = 1500, format('after move: p_ann expected 1500, got %s', v_num);
  SELECT commission_received INTO v_num FROM policies WHERE id = p_ann2;
  ASSERT v_num = 0, format('after move: p_ann2 expected 0, got %s', v_num);

  -- Deleting a policy with allocated commissions still works and
  -- returns the money to the receipt (no allocations left on r2)
  DELETE FROM policies WHERE id = p_ann;
  SELECT count(*) INTO n FROM commission_allocations WHERE receipt_id = r2;
  ASSERT n = 0, format('after policy delete: r2 allocations expected 0, got %s', n);
END;
$$;

SELECT 'ALL PASSED' AS result;

ROLLBACK;
