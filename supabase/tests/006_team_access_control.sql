-- ============================================================
-- Test 006: team access control (roles, deactivation, client
-- assignment, role-scoped RLS).
--
-- Run the whole file in one go (Supabase SQL editor / execute_sql).
-- Everything happens inside one transaction that is ALWAYS rolled
-- back: on success the final SELECT returns 'ALL PASSED' and the
-- ROLLBACK discards the fixture; on any failed ASSERT the batch
-- aborts and nothing is committed.
--
-- Impersonation pattern (reused by later tests):
--   PERFORM set_config('request.jwt.claims',
--     json_build_object('sub', <uid>, 'role','authenticated')::text, true);
--   SET LOCAL ROLE authenticated;
--   ... queries run under RLS as <uid> ...
--   RESET ROLE;   -- back to superuser before switching actor
-- ============================================================

BEGIN;

DO $$
DECLARE
  ag   UUID := gen_random_uuid();
  o    UUID := gen_random_uuid();
  m    UUID := gen_random_uuid();
  a1   UUID := gen_random_uuid();
  a2   UUID := gen_random_uuid();
  ins  UUID;
  pl   UUID;
  c_a1_1 UUID := gen_random_uuid();
  c_a1_2 UUID := gen_random_uuid();
  c_a2   UUID := gen_random_uuid();
  c_m    UUID := gen_random_uuid();
  p_a1_1 UUID := gen_random_uuid();
  new_client UUID;
  n    INTEGER;
  expected_a1_reminders INTEGER;
  v_text TEXT;
  v_num  NUMERIC;
BEGIN
  -- ---------------------------------------------------------
  -- Fixture (as superuser)
  -- ---------------------------------------------------------
  INSERT INTO auth.users (id, email, aud, role, instance_id) VALUES
    (o,  'o-006@test.local',  'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000'),
    (m,  'm-006@test.local',  'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000'),
    (a1, 'a1-006@test.local', 'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000'),
    (a2, 'a2-006@test.local', 'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000');

  INSERT INTO agencies (id, name) VALUES (ag, 'Test Agency 006');

  INSERT INTO users (id, agency_id, role, full_name, email) VALUES
    (o,  ag, 'owner',   'Owner 006',   'o-006@test.local'),
    (m,  ag, 'manager', 'Manager 006', 'm-006@test.local'),
    (a1, ag, 'agent',   'Agent1 006',  'a1-006@test.local'),
    (a2, ag, 'agent',   'Agent2 006',  'a2-006@test.local');

  INSERT INTO insurers (agency_id, name) VALUES (ag, 'Insurer 006') RETURNING id INTO ins;
  INSERT INTO product_lines (agency_id, name) VALUES (ag, 'Motor 006') RETURNING id INTO pl;

  INSERT INTO clients (id, agency_id, type, name, assigned_agent_id) VALUES
    (c_a1_1, ag, 'individual', 'A1 Client 1', a1),
    (c_a1_2, ag, 'individual', 'A1 Client 2', a1),
    (c_a2,   ag, 'individual', 'A2 Client',   a2),
    (c_m,    ag, 'corporate',  'M Client',    m);

  -- One active policy per client, owned by the client's agent.
  -- Expiry 200 days out so the trigger creates 90/60/30-day reminders.
  INSERT INTO policies (id, agency_id, client_id, insurer_id, product_line_id, agent_id,
                        policy_number, premium_amount, commission_rate, start_date, expiry_date, status)
  VALUES
    (p_a1_1,            ag, c_a1_1, ins, pl, a1, 'T006-1', 10000, 10, CURRENT_DATE, CURRENT_DATE + 200, 'active'),
    (gen_random_uuid(), ag, c_a1_2, ins, pl, a1, 'T006-2', 20000, 10, CURRENT_DATE, CURRENT_DATE + 200, 'active'),
    (gen_random_uuid(), ag, c_a2,   ins, pl, a2, 'T006-3', 30000, 10, CURRENT_DATE, CURRENT_DATE + 200, 'active'),
    (gen_random_uuid(), ag, c_m,    ins, pl, m,  'T006-4', 40000, 10, CURRENT_DATE, CURRENT_DATE + 200, 'active');

  -- One pending commission per policy
  INSERT INTO commission_transactions (policy_id, agency_id, amount, expected_date, status)
  SELECT id, agency_id, premium_amount * commission_rate / 100, CURRENT_DATE + 30, 'pending'
    FROM policies WHERE agency_id = ag;

  -- One stored report (agents must not see it)
  INSERT INTO reports (agency_id, month, year, metadata) VALUES (ag, 1, 2026, '{}'::jsonb);

  SELECT count(*) INTO expected_a1_reminders
    FROM renewal_reminders r JOIN policies p ON p.id = r.policy_id
   WHERE p.agency_id = ag AND p.agent_id = a1;
  ASSERT expected_a1_reminders > 0, 'fixture: a1 should have reminders';
  SELECT count(*) INTO n FROM renewal_reminders WHERE agency_id = ag;
  ASSERT n > expected_a1_reminders, 'fixture: other agents should have reminders too';

  -- ---------------------------------------------------------
  -- Agent a1: visibility
  -- ---------------------------------------------------------
  PERFORM set_config('request.jwt.claims', json_build_object('sub', a1, 'role','authenticated')::text, true);
  SET LOCAL ROLE authenticated;

  SELECT count(*) INTO n FROM clients;                 ASSERT n = 2, format('a1 clients: expected 2, got %s', n);
  SELECT count(*) INTO n FROM policies;                ASSERT n = 2, format('a1 policies: expected 2, got %s', n);
  SELECT count(*) INTO n FROM commission_transactions; ASSERT n = 2, format('a1 commissions: expected 2, got %s', n);
  SELECT count(*) INTO n FROM renewal_reminders;
  ASSERT n = expected_a1_reminders, format('a1 reminders: expected %s, got %s', expected_a1_reminders, n);
  SELECT count(*) INTO n FROM reports;                 ASSERT n = 0, format('a1 reports: expected 0, got %s', n);
  SELECT count(*) INTO n FROM users;                   ASSERT n = 1, format('a1 users: expected 1, got %s', n);
  SELECT count(*) INTO n FROM insurers;                ASSERT n = 1, format('a1 insurers (read): expected 1, got %s', n);
  SELECT count(*) INTO n FROM agencies;                ASSERT n = 1, format('a1 agencies (read): expected 1, got %s', n);

  -- ---------------------------------------------------------
  -- Agent a1: denied writes
  -- ---------------------------------------------------------
  UPDATE clients SET name = 'x' WHERE id = c_a2;
  GET DIAGNOSTICS n = ROW_COUNT;
  ASSERT n = 0, format('a1 updating a2 client: expected 0 rows, got %s', n);

  BEGIN
    INSERT INTO clients (agency_id, type, name, assigned_agent_id) VALUES (ag, 'individual', 'Sneaky', a2);
    RAISE EXCEPTION 'FAIL: a1 inserted a client assigned to a2';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;

  BEGIN
    INSERT INTO policies (agency_id, client_id, insurer_id, product_line_id, agent_id,
                          policy_number, premium_amount, commission_rate, start_date, expiry_date)
    VALUES (ag, c_a1_1, ins, pl, a2, 'T006-X1', 1000, 10, CURRENT_DATE, CURRENT_DATE + 365);
    RAISE EXCEPTION 'FAIL: a1 inserted a policy with agent_id = a2';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;

  BEGIN
    INSERT INTO policies (agency_id, client_id, insurer_id, product_line_id, agent_id,
                          policy_number, premium_amount, commission_rate, start_date, expiry_date)
    VALUES (ag, c_a2, ins, pl, a1, 'T006-X2', 1000, 10, CURRENT_DATE, CURRENT_DATE + 365);
    RAISE EXCEPTION 'FAIL: a1 inserted a policy on a2''s client';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;

  BEGIN
    UPDATE policies SET client_id = c_a2 WHERE id = p_a1_1;
    RAISE EXCEPTION 'FAIL: a1 moved own policy onto a2''s client';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;

  UPDATE commission_transactions SET status = 'received';
  GET DIAGNOSTICS n = ROW_COUNT;
  ASSERT n = 0, format('a1 marking commissions received: expected 0 rows, got %s', n);

  DELETE FROM clients;
  GET DIAGNOSTICS n = ROW_COUNT;
  ASSERT n = 0, format('a1 deleting clients: expected 0 rows, got %s', n);

  UPDATE insurers SET name = 'x';
  GET DIAGNOSTICS n = ROW_COUNT;
  ASSERT n = 0, format('a1 updating insurers: expected 0 rows, got %s', n);

  UPDATE agencies SET name = 'x';
  GET DIAGNOSTICS n = ROW_COUNT;
  ASSERT n = 0, format('a1 updating agencies: expected 0 rows, got %s', n);

  -- Agent cannot record commission received on own policy
  BEGIN
    UPDATE policies SET commission_received = 999 WHERE id = p_a1_1;
    RAISE EXCEPTION 'FAIL: a1 set commission_received on own policy';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;

  -- Agent may insert a policy on own client, but commission_received is forced to 0
  INSERT INTO policies (agency_id, client_id, insurer_id, product_line_id, agent_id,
                        policy_number, premium_amount, commission_rate, commission_received,
                        start_date, expiry_date)
  VALUES (ag, c_a1_1, ins, pl, a1, 'T006-5', 5000, 10, 500, CURRENT_DATE, CURRENT_DATE + 365)
  RETURNING commission_received INTO v_num;
  ASSERT v_num = 0, format('a1 inserted policy commission_received: expected 0, got %s', v_num);

  -- Agent may edit own client and own policy
  UPDATE clients SET name = 'A1 Client 1 edited' WHERE id = c_a1_1;
  GET DIAGNOSTICS n = ROW_COUNT;
  ASSERT n = 1, format('a1 updating own client: expected 1 row, got %s', n);

  -- Agent-created client defaults to self
  INSERT INTO clients (agency_id, type, name) VALUES (ag, 'individual', 'A1 New')
  RETURNING id INTO new_client;
  SELECT assigned_agent_id::text INTO v_text FROM clients WHERE id = new_client;
  ASSERT v_text = a1::text, format('a1 new client: expected assigned to a1, got %s', v_text);

  RESET ROLE;

  -- ---------------------------------------------------------
  -- Manager m and Owner o: visibility
  -- ---------------------------------------------------------
  PERFORM set_config('request.jwt.claims', json_build_object('sub', m, 'role','authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  -- 5 clients now: 4 fixture + a1's new client
  -- 5 policies now: 4 fixture + a1's T006-5
  SELECT count(*) INTO n FROM clients;  ASSERT n = 5, format('m clients: expected 5, got %s', n);
  SELECT count(*) INTO n FROM policies; ASSERT n = 5, format('m policies: expected 5, got %s', n);
  SELECT count(*) INTO n FROM users;    ASSERT n = 4, format('m users: expected 4, got %s', n);
  SELECT count(*) INTO n FROM reports;  ASSERT n = 1, format('m reports: expected 1, got %s', n);

  UPDATE agencies SET name = 'x';
  GET DIAGNOSTICS n = ROW_COUNT;
  ASSERT n = 0, format('m updating agencies: expected 0 rows, got %s', n);

  UPDATE commission_transactions SET status = 'received' WHERE agency_id = ag;
  GET DIAGNOSTICS n = ROW_COUNT;
  ASSERT n >= 1, format('m marking commissions received: expected >=1 rows, got %s', n);

  UPDATE policies SET commission_received = 1000 WHERE id = p_a1_1;
  GET DIAGNOSTICS n = ROW_COUNT;
  ASSERT n = 1, format('m recording commission_received: expected 1 row, got %s', n);
  SELECT commission_received INTO v_num FROM policies WHERE id = p_a1_1;
  ASSERT v_num = 1000, format('m recording commission_received: expected 1000, got %s', v_num);
  RESET ROLE;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', o, 'role','authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  SELECT count(*) INTO n FROM clients;  ASSERT n = 5, format('o clients: expected 5, got %s', n);
  SELECT count(*) INTO n FROM policies; ASSERT n = 5, format('o policies: expected 5, got %s', n);
  SELECT count(*) INTO n FROM users;    ASSERT n = 4, format('o users: expected 4, got %s', n);

  UPDATE agencies SET name = 'Test Agency 006 renamed' WHERE id = ag;
  GET DIAGNOSTICS n = ROW_COUNT;
  ASSERT n = 1, format('o updating agency: expected 1 row, got %s', n);
  RESET ROLE;

  -- ---------------------------------------------------------
  -- Deactivation
  -- ---------------------------------------------------------
  UPDATE users SET deactivated_at = now() WHERE id = a1;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', a1, 'role','authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  SELECT count(*) INTO n FROM clients;  ASSERT n = 0, format('deactivated a1 clients: expected 0, got %s', n);
  SELECT count(*) INTO n FROM policies; ASSERT n = 0, format('deactivated a1 policies: expected 0, got %s', n);
  SELECT count(*) INTO n FROM users;    ASSERT n = 1, format('deactivated a1 users (own row): expected 1, got %s', n);
  ASSERT public.current_user_role() IS NULL, 'deactivated a1: current_user_role() should be NULL';
  ASSERT public.current_user_agency_id() IS NULL, 'deactivated a1: current_user_agency_id() should be NULL';
  RESET ROLE;
END;
$$;

SELECT 'ALL PASSED' AS result;

ROLLBACK;
