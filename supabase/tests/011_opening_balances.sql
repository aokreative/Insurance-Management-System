-- ============================================================
-- Test 011: receipts storage bucket + policies, opening balances
-- (_backfill_opening_balances).
--
-- Run the whole file in one go (Supabase SQL editor / execute_sql).
-- One transaction, ALWAYS rolled back: on success the final SELECT
-- returns 'ALL PASSED'; any failed ASSERT aborts the batch.
-- Impersonation pattern: see supabase/tests/006_team_access_control.sql.
-- Scenarios end with RAISE ... ERRCODE 'ZZ001' so each starts from
-- the fresh fixture (see supabase/tests/010_reconciliation_rpcs.sql).
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
  ins3  UUID;
  pl    UUID;
  cl    UUID := gen_random_uuid();
  p1    UUID := gen_random_uuid();   -- ins1, received 2026-03-10
  p2    UUID := gen_random_uuid();   -- ins1, received 2026-04-20
  p3    UUID := gen_random_uuid();   -- ins2, received 2026-02-05
  p4    UUID := gen_random_uuid();   -- ins1, pending
  p5    UUID := gen_random_uuid();   -- ins2, paid by a real receipt (scenario 2)
  p6    UUID := gen_random_uuid();   -- ins3, received, no received_date (scenario 2)
  c1    UUID;
  c2    UUID;
  c3    UUID;
  c4    UUID;
  c5    UUID;
  c6    UUID;
  r_id  UUID;
  v_cr1 NUMERIC;
  v_cr2 NUMERIC;
  v_cr3 NUMERIC;
  v_cr4 NUMERIC;
  n     INTEGER;
  v_num NUMERIC;
  v_dt  DATE;
  v_txt TEXT;
  v_by  UUID;
  v_st  TEXT;
  v_b   BOOLEAN;
  v_lim BIGINT;
  v_mt  TEXT[];
BEGIN
  -- ---------------------------------------------------------
  -- Fixture (as superuser, no JWT)
  -- ---------------------------------------------------------
  PERFORM set_config('request.jwt.claims', '{}', true);

  INSERT INTO auth.users (id, email, aud, role, instance_id) VALUES
    (o,  'o-011@test.local',  'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000'),
    (m,  'm-011@test.local',  'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000'),
    (a1, 'a1-011@test.local', 'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000'),
    (o2, 'o2-011@test.local', 'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000');

  INSERT INTO agencies (id, name) VALUES (ag, 'Test Agency 011'), (ag2, 'Other Agency 011');
  INSERT INTO users (id, agency_id, role, full_name, email) VALUES
    (o,  ag,  'owner',   'Owner 011',   'o-011@test.local'),
    (m,  ag,  'manager', 'Manager 011', 'm-011@test.local'),
    (a1, ag,  'agent',   'Agent1 011',  'a1-011@test.local'),
    (o2, ag2, 'owner',   'Owner2 011',  'o2-011@test.local');

  INSERT INTO insurers (agency_id, name) VALUES (ag, 'Insurer 011 A') RETURNING id INTO ins1;
  INSERT INTO insurers (agency_id, name) VALUES (ag, 'Insurer 011 B') RETURNING id INTO ins2;
  INSERT INTO insurers (agency_id, name) VALUES (ag, 'Insurer 011 C') RETURNING id INTO ins3;
  INSERT INTO product_lines (agency_id, name) VALUES (ag, 'Motor 011') RETURNING id INTO pl;
  INSERT INTO clients (id, agency_id, type, name, assigned_agent_id) VALUES
    (cl, ag, 'individual', 'Client 011', a1);

  INSERT INTO policies (id, agency_id, client_id, insurer_id, product_line_id, agent_id,
                        policy_number, premium_amount, commission_rate, commission_basis,
                        start_date, expiry_date, status)
  VALUES
    (p1, ag, cl, ins1, pl, a1, 'T011-P1', 50000, 10, 'annual', DATE '2026-01-15', DATE '2027-01-14', 'active'),
    (p2, ag, cl, ins1, pl, a1, 'T011-P2', 20000, 10, 'annual', DATE '2026-01-20', DATE '2027-01-19', 'active'),
    (p3, ag, cl, ins2, pl, a1, 'T011-P3', 30000, 10, 'annual', DATE '2026-01-25', DATE '2027-01-24', 'active'),
    (p4, ag, cl, ins1, pl, a1, 'T011-P4', 10000, 10, 'annual', DATE '2026-02-01', DATE '2027-01-31', 'active');

  SELECT id INTO c1 FROM commission_transactions WHERE policy_id = p1;
  SELECT id INTO c2 FROM commission_transactions WHERE policy_id = p2;
  SELECT id INTO c3 FROM commission_transactions WHERE policy_id = p3;
  SELECT id INTO c4 FROM commission_transactions WHERE policy_id = p4;

  -- Pre-receipts "received" rows (as the app recorded them before receipts existed)
  UPDATE commission_transactions SET amount_received = amount, received_date = DATE '2026-03-10' WHERE id = c1;
  UPDATE commission_transactions SET amount_received = amount, received_date = DATE '2026-04-20' WHERE id = c2;
  UPDATE commission_transactions SET amount_received = amount, received_date = DATE '2026-02-05' WHERE id = c3;

  SELECT status INTO v_txt FROM commission_transactions WHERE id = c1;
  ASSERT v_txt = 'received', format('fixture: c1 expected received, got %s', v_txt);
  SELECT commission_received INTO v_cr1 FROM policies WHERE id = p1;
  SELECT commission_received INTO v_cr2 FROM policies WHERE id = p2;
  SELECT commission_received INTO v_cr3 FROM policies WHERE id = p3;
  SELECT commission_received INTO v_cr4 FROM policies WHERE id = p4;
  ASSERT v_cr1 = 5000 AND v_cr2 = 2000 AND v_cr3 = 3000 AND v_cr4 = 0,
    format('fixture: tallies %s / %s / %s / %s', v_cr1, v_cr2, v_cr3, v_cr4);

  -- ---------------------------------------------------------
  -- 1. Backfill: one opening receipt per insurer, tallies unchanged
  -- ---------------------------------------------------------
  BEGIN
    n := public._backfill_opening_balances(ag);
    ASSERT n = 2, format('backfill: 2 receipts expected, got %s', n);

    SELECT count(*) INTO n FROM insurer_receipts WHERE agency_id = ag;
    ASSERT n = 2, format('backfill: 2 receipts stored, got %s', n);

    SELECT amount, received_on, notes, created_by INTO v_num, v_dt, v_txt, v_by
      FROM insurer_receipts WHERE agency_id = ag AND insurer_id = ins1 AND is_opening_balance;
    ASSERT v_num = 7000, format('ins1: amount expected 7000, got %s', v_num);
    ASSERT v_dt = DATE '2026-04-20', format('ins1: received_on expected 2026-04-20, got %s', v_dt);
    ASSERT v_txt = 'Opening balance (before receipts were tracked)', format('ins1: notes %s', v_txt);
    ASSERT v_by = o, format('ins1: created_by expected owner, got %s', v_by);

    SELECT amount, received_on, notes INTO v_num, v_dt, v_txt
      FROM insurer_receipts WHERE agency_id = ag AND insurer_id = ins2 AND is_opening_balance;
    ASSERT v_num = 3000, format('ins2: amount expected 3000, got %s', v_num);
    ASSERT v_dt = DATE '2026-02-05', format('ins2: received_on expected 2026-02-05, got %s', v_dt);
    ASSERT v_txt = 'Opening balance (before receipts were tracked)', format('ins2: notes %s', v_txt);

    SELECT count(*) INTO n FROM insurer_receipts
     WHERE agency_id = ag AND (bank_reference IS NOT NULL OR file_path IS NOT NULL);
    ASSERT n = 0, 'backfill: bank_reference / file_path should be NULL';

    -- one full allocation per received commission
    SELECT count(*), sum(amount) INTO n, v_num FROM commission_allocations WHERE agency_id = ag;
    ASSERT n = 3 AND v_num = 10000, format('allocations: got %s / %s', n, v_num);
    SELECT count(*) INTO n FROM commission_allocations a
      JOIN commission_transactions ct ON ct.id = a.commission_id
     WHERE a.agency_id = ag AND a.amount <> ct.amount;
    ASSERT n = 0, 'allocations: each covers its commission in full';
    SELECT count(*) INTO n FROM commission_allocations a
      JOIN insurer_receipts r ON r.id = a.receipt_id
      JOIN commission_transactions ct ON ct.id = a.commission_id
      JOIN policies p ON p.id = ct.policy_id
     WHERE a.agency_id = ag AND r.insurer_id <> p.insurer_id;
    ASSERT n = 0, 'allocations: each on its insurer''s receipt';

    -- tallies unchanged; pending untouched
    SELECT commission_received INTO v_num FROM policies WHERE id = p1;
    ASSERT v_num = v_cr1, format('p1 tally changed: %s -> %s', v_cr1, v_num);
    SELECT commission_received INTO v_num FROM policies WHERE id = p2;
    ASSERT v_num = v_cr2, format('p2 tally changed: %s -> %s', v_cr2, v_num);
    SELECT commission_received INTO v_num FROM policies WHERE id = p3;
    ASSERT v_num = v_cr3, format('p3 tally changed: %s -> %s', v_cr3, v_num);
    SELECT commission_received INTO v_num FROM policies WHERE id = p4;
    ASSERT v_num = v_cr4, format('p4 tally changed: %s -> %s', v_cr4, v_num);
    SELECT status, amount_received INTO v_txt, v_num FROM commission_transactions WHERE id = c4;
    ASSERT v_txt = 'pending' AND v_num = 0, format('pending commission touched: %s / %s', v_txt, v_num);
    SELECT count(*) INTO n FROM commission_allocations WHERE commission_id = c4;
    ASSERT n = 0, 'pending commission got an allocation';
    SELECT count(*) INTO n FROM commission_transactions WHERE agency_id = ag AND status = 'received' AND amount_received <> amount;
    ASSERT n = 0, 'received commissions: amount_received = amount';

    -- idempotent
    n := public._backfill_opening_balances(ag);
    ASSERT n = 0, format('second run: 0 expected, got %s', n);
    SELECT count(*) INTO n FROM commission_allocations WHERE agency_id = ag;
    ASSERT n = 3, format('second run: allocations unchanged, got %s', n);

    -- an agency x insurer pair that already has an opening receipt is skipped,
    -- even if a received commission without allocations appears later
    UPDATE commission_transactions SET amount_received = amount, received_date = DATE '2026-05-01' WHERE id = c4;
    n := public._backfill_opening_balances(ag);
    ASSERT n = 0, format('pair skip: 0 expected, got %s', n);
    SELECT count(*) INTO n FROM commission_allocations WHERE commission_id = c4;
    ASSERT n = 0, 'pair skip: no allocation for the later commission';

    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
  END;

  -- ---------------------------------------------------------
  -- 2. Commissions already paid by a real receipt are excluded;
  --    all-NULL received_date -> current_date; NULL = all agencies
  -- ---------------------------------------------------------
  BEGIN
    INSERT INTO policies (id, agency_id, client_id, insurer_id, product_line_id, agent_id,
                          policy_number, premium_amount, commission_rate, commission_basis,
                          start_date, expiry_date, status)
    VALUES
      (p5, ag, cl, ins2, pl, a1, 'T011-P5', 40000, 10, 'annual', DATE '2026-02-10', DATE '2027-02-09', 'active'),
      (p6, ag, cl, ins3, pl, a1, 'T011-P6', 15000, 10, 'annual', DATE '2026-02-15', DATE '2027-02-14', 'active');
    SELECT id INTO c5 FROM commission_transactions WHERE policy_id = p5;
    SELECT id INTO c6 FROM commission_transactions WHERE policy_id = p6;

    -- p5 paid in full by a real receipt
    INSERT INTO insurer_receipts (agency_id, insurer_id, received_on, amount)
    VALUES (ag, ins2, DATE '2026-09-01', 4000) RETURNING id INTO r_id;
    INSERT INTO commission_allocations (agency_id, receipt_id, commission_id, amount)
    VALUES (ag, r_id, c5, 4000);
    SELECT status INTO v_txt FROM commission_transactions WHERE id = c5;
    ASSERT v_txt = 'received', format('scenario 2: c5 expected received, got %s', v_txt);

    -- p6 received before receipts, date unknown
    UPDATE commission_transactions SET amount_received = amount, received_date = NULL WHERE id = c6;

    n := public._backfill_opening_balances(ag);
    ASSERT n = 3, format('scenario 2: 3 receipts expected, got %s', n);

    SELECT amount, received_on INTO v_num, v_dt
      FROM insurer_receipts WHERE agency_id = ag AND insurer_id = ins2 AND is_opening_balance;
    ASSERT v_num = 3000 AND v_dt = DATE '2026-02-05',
      format('scenario 2: ins2 opening excludes p5, got %s / %s', v_num, v_dt);
    SELECT count(*) INTO n FROM commission_allocations WHERE commission_id = c5;
    ASSERT n = 1, format('scenario 2: c5 keeps its single allocation, got %s', n);
    SELECT commission_received INTO v_num FROM policies WHERE id = p5;
    ASSERT v_num = 4000, format('scenario 2: p5 tally expected 4000, got %s', v_num);

    SELECT amount, received_on INTO v_num, v_dt
      FROM insurer_receipts WHERE agency_id = ag AND insurer_id = ins3 AND is_opening_balance;
    ASSERT v_num = 1500 AND v_dt = current_date,
      format('scenario 2: ins3 opening got %s / %s', v_num, v_dt);
    SELECT commission_received INTO v_num FROM policies WHERE id = p6;
    ASSERT v_num = 1500, format('scenario 2: p6 tally expected 1500, got %s', v_num);

    -- NULL = all agencies; nothing left to do for this agency
    PERFORM public._backfill_opening_balances();
    SELECT count(*) INTO n FROM insurer_receipts WHERE agency_id = ag AND is_opening_balance;
    ASSERT n = 3, format('scenario 2: all-agencies run adds nothing here, got %s', n);
    SELECT count(*) INTO n FROM commission_transactions ct
     WHERE ct.status = 'received'
       AND NOT EXISTS (SELECT 1 FROM commission_allocations a WHERE a.commission_id = ct.id);
    ASSERT n = 0, format('scenario 2: received commissions without allocations remain: %s', n);

    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
  END;

  -- ---------------------------------------------------------
  -- 3. Storage bucket
  -- ---------------------------------------------------------
  SELECT public, file_size_limit, allowed_mime_types INTO v_b, v_lim, v_mt
    FROM storage.buckets WHERE id = 'receipts';
  ASSERT v_b = false, format('bucket: public expected false, got %s', v_b);
  ASSERT v_lim = 10485760, format('bucket: file_size_limit expected 10485760, got %s', v_lim);
  ASSERT v_mt = '{application/pdf}', format('bucket: allowed_mime_types got %s', v_mt);

  -- ---------------------------------------------------------
  -- 4. Storage policies (direct inserts into storage.objects)
  -- ---------------------------------------------------------
  BEGIN
    -- owner: own agency folder allowed, readable
    PERFORM set_config('request.jwt.claims', json_build_object('sub', o, 'role','authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    INSERT INTO storage.objects (bucket_id, name) VALUES ('receipts', ag::text || '/x.pdf');
    SELECT count(*) INTO n FROM storage.objects WHERE bucket_id = 'receipts' AND name = ag::text || '/x.pdf';
    ASSERT n = 1, format('owner: own object visible, got %s', n);

    -- owner: another agency's folder denied
    BEGIN
      INSERT INTO storage.objects (bucket_id, name) VALUES ('receipts', ag2::text || '/y.pdf');
      RAISE EXCEPTION 'FAIL: owner uploaded into another agency''s folder';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    -- owner: no folder (root) denied
    BEGIN
      INSERT INTO storage.objects (bucket_id, name) VALUES ('receipts', 'z.pdf');
      RAISE EXCEPTION 'FAIL: owner uploaded at the bucket root';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    RESET ROLE;

    -- manager allowed
    PERFORM set_config('request.jwt.claims', json_build_object('sub', m, 'role','authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    INSERT INTO storage.objects (bucket_id, name) VALUES ('receipts', ag::text || '/m.pdf');
    SELECT count(*) INTO n FROM storage.objects WHERE bucket_id = 'receipts' AND name LIKE ag::text || '/%';
    ASSERT n = 2, format('manager: sees agency objects, got %s', n);
    RESET ROLE;

    -- agent denied, sees nothing
    PERFORM set_config('request.jwt.claims', json_build_object('sub', a1, 'role','authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    BEGIN
      INSERT INTO storage.objects (bucket_id, name) VALUES ('receipts', ag::text || '/a.pdf');
      RAISE EXCEPTION 'FAIL: agent uploaded a receipt file';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    SELECT count(*) INTO n FROM storage.objects WHERE bucket_id = 'receipts' AND name LIKE ag::text || '/%';
    ASSERT n = 0, format('agent: sees receipt files, got %s', n);
    RESET ROLE;

    -- owner of another agency sees nothing
    PERFORM set_config('request.jwt.claims', json_build_object('sub', o2, 'role','authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    SELECT count(*) INTO n FROM storage.objects WHERE bucket_id = 'receipts' AND name LIKE ag::text || '/%';
    ASSERT n = 0, format('o2: sees another agency''s files, got %s', n);
    RESET ROLE;

    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
  END;
  PERFORM set_config('request.jwt.claims', '{}', true);

  -- DELETE is guarded by storage.protect_objects_delete for direct SQL,
  -- so its policy is asserted by definition; no UPDATE policy exists.
  SELECT count(*) INTO n FROM pg_policies
   WHERE schemaname = 'storage' AND tablename = 'objects'
     AND policyname IN ('receipts_owner_manager_insert', 'receipts_owner_manager_select', 'receipts_owner_manager_delete')
     AND roles = '{authenticated}';
  ASSERT n = 3, format('storage: 3 receipts policies for authenticated expected, got %s', n);
  SELECT qual INTO v_txt FROM pg_policies
   WHERE schemaname = 'storage' AND tablename = 'objects'
     AND policyname = 'receipts_owner_manager_delete' AND cmd = 'DELETE';
  ASSERT v_txt LIKE '%receipts%' AND v_txt LIKE '%foldername%'
     AND v_txt LIKE '%current_user_agency_id()%' AND v_txt LIKE '%is_owner_or_manager()%',
    format('storage: delete policy qual %s', v_txt);
  SELECT count(*) INTO n FROM pg_policies
   WHERE schemaname = 'storage' AND tablename = 'objects'
     AND policyname LIKE 'receipts%' AND cmd IN ('UPDATE', 'ALL');
  ASSERT n = 0, format('storage: no UPDATE policy expected, got %s', n);

  -- ---------------------------------------------------------
  -- 5. Grants
  -- ---------------------------------------------------------
  ASSERT NOT has_function_privilege('anon', 'public._backfill_opening_balances(uuid)', 'EXECUTE'),
    'anon can execute _backfill_opening_balances';
  ASSERT NOT has_function_privilege('authenticated', 'public._backfill_opening_balances(uuid)', 'EXECUTE'),
    'authenticated can execute _backfill_opening_balances';
END;
$$;

SELECT 'ALL PASSED' AS result;

ROLLBACK;
