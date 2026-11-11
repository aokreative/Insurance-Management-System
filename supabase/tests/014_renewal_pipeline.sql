-- ============================================================
-- Test 014: renewal pipeline
--   - pipeline view window, days_to_expiry, default stage
--   - contact / quote stage moves and history
--   - renew: linked new policy, same number, commission, old expired
--   - closed renewals refuse further actions (sequential race)
--   - duplicate active policy number refused
--   - renew validation; deleting the new policy resets the renewal
--   - lost (reason, expiry only when past), reopen (Owner/Manager)
--   - window / not found; agent own policies; reassignment
--   - agents_manage_renewals setting; field validation
--   - direct writes refused; other agency; reminder migration
--   - monthly report fields; grants
--
-- Run the whole file in one go. One transaction, ALWAYS rolled back:
-- on success the final SELECT returns 'ALL PASSED'.
-- ============================================================

BEGIN;
SET LOCAL TIME ZONE 'Africa/Nairobi';

CREATE FUNCTION public._t014_expect(p_sql TEXT, p_msg TEXT, p_state TEXT DEFAULT NULL)
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
GRANT EXECUTE ON FUNCTION public._t014_expect(TEXT, TEXT, TEXT) TO authenticated;

CREATE FUNCTION public._t014_as(p_uid UUID)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
END;
$$;
GRANT EXECUTE ON FUNCTION public._t014_as(UUID) TO authenticated;

DO $$
DECLARE
  today DATE := (now() AT TIME ZONE 'Africa/Nairobi')::date;
  ag    UUID := gen_random_uuid();
  ag2   UUID := gen_random_uuid();
  o     UUID := gen_random_uuid();
  m     UUID := gen_random_uuid();
  a1    UUID := gen_random_uuid();
  a2    UUID := gen_random_uuid();
  o2    UUID := gen_random_uuid();
  i1    UUID;
  i2    UUID;
  ix    UUID;   -- other agency's insurer
  pl    UUID;
  plx   UUID;   -- other agency's product line
  cl1   UUID := gen_random_uuid();
  cl2   UUID := gen_random_uuid();
  clx   UUID := gen_random_uuid();
  p1    UUID := gen_random_uuid();   -- a1, expires today+20
  p2    UUID := gen_random_uuid();   -- a1, today+40
  p3    UUID := gen_random_uuid();   -- a1, today-5 (overdue)
  p4    UUID := gen_random_uuid();   -- a1, today+200 (outside window)
  q1    UUID := gen_random_uuid();   -- a2, today+10
  px    UUID := gen_random_uuid();   -- other agency
  newp  UUID;
  rid   UUID;
  n     INTEGER;
  v_txt TEXT;
  v_num NUMERIC;
  v_uid UUID;
  v_bool BOOLEAN;
  v_new JSONB;
  v_meta JSONB;
BEGIN
  PERFORM set_config('request.jwt.claims', '{}', true);

  INSERT INTO auth.users (id, email, aud, role, instance_id) VALUES
    (o,  'o-014@test.local',  'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000'),
    (m,  'm-014@test.local',  'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000'),
    (a1, 'a1-014@test.local', 'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000'),
    (a2, 'a2-014@test.local', 'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000'),
    (o2, 'o2-014@test.local', 'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000');
  INSERT INTO agencies (id, name) VALUES (ag, 'Test Agency 014'), (ag2, 'Other Agency 014');
  INSERT INTO users (id, agency_id, role, full_name, email) VALUES
    (o,  ag,  'owner',   'Owner 014',   'o-014@test.local'),
    (m,  ag,  'manager', 'Manager 014', 'm-014@test.local'),
    (a1, ag,  'agent',   'Agent1 014',  'a1-014@test.local'),
    (a2, ag,  'agent',   'Agent2 014',  'a2-014@test.local'),
    (o2, ag2, 'owner',   'Owner2 014',  'o2-014@test.local');
  INSERT INTO insurers (agency_id, name) VALUES (ag, 'Insurer One 014') RETURNING id INTO i1;
  INSERT INTO insurers (agency_id, name) VALUES (ag, 'Insurer Two 014') RETURNING id INTO i2;
  INSERT INTO insurers (agency_id, name) VALUES (ag2, 'Insurer X 014') RETURNING id INTO ix;
  INSERT INTO product_lines (agency_id, name) VALUES (ag, 'Motor 014') RETURNING id INTO pl;
  INSERT INTO product_lines (agency_id, name) VALUES (ag2, 'Other 014') RETURNING id INTO plx;
  INSERT INTO clients (id, agency_id, type, name, assigned_agent_id) VALUES
    (cl1, ag,  'individual', 'Client One 014', a1),
    (cl2, ag,  'individual', 'Client Two 014', a2),
    (clx, ag2, 'individual', 'Client X 014',   o2);
  INSERT INTO policies (id, agency_id, client_id, insurer_id, product_line_id, agent_id,
                        policy_number, premium_amount, commission_rate, commission_basis,
                        start_date, expiry_date, status)
  VALUES
    (p1, ag,  cl1, i2, pl,  a1, 'T014-P1', 12000, 10, 'annual', today + 20 - 364, today + 20,  'active'),
    (p2, ag,  cl1, i2, pl,  a1, 'T014-P2', 20000, 10, 'annual', today + 40 - 364, today + 40,  'active'),
    (p3, ag,  cl1, i2, pl,  a1, 'T014-P3', 30000, 10, 'annual', today - 5 - 364,  today - 5,   'active'),
    (p4, ag,  cl1, i2, pl,  a1, 'T014-P4', 40000, 10, 'annual', today + 200 - 364, today + 200, 'active'),
    (q1, ag,  cl2, i2, pl,  a2, 'T014-Q1', 50000, 10, 'annual', today + 10 - 364, today + 10,  'active'),
    (px, ag2, clx, ix, plx, o2, 'T014-X',  60000, 10, 'annual', today + 10 - 364, today + 10,  'active');

  -- placeholders are no longer created for new policies
  SELECT count(*) INTO n FROM renewal_reminders WHERE policy_id IN (p1, p2, p3, p4, q1, px);
  ASSERT n = 0, format('cleanup: new policies created %s placeholder reminders', n);
  ASSERT NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_auto_renewal_reminders'), 'cleanup: trigger dropped';

  -- ---------------------------------------------------------
  -- 1. View window and defaults
  -- ---------------------------------------------------------
  BEGIN
    PERFORM _t014_as(o);
    SET LOCAL ROLE authenticated;
    SELECT count(*) INTO n FROM renewal_pipeline WHERE policy_id IN (p1, p2, p3, q1) AND stage = 'to_contact';
    ASSERT n = 4, format('view: expected 4 to_contact rows, got %s', n);
    ASSERT NOT EXISTS (SELECT 1 FROM renewal_pipeline WHERE policy_id = p4), 'view: p4 outside window';
    ASSERT NOT EXISTS (SELECT 1 FROM renewal_pipeline WHERE policy_id = px), 'view: other agency hidden';
    ASSERT (SELECT days_to_expiry FROM renewal_pipeline WHERE policy_id = p3) = -5, 'view: p3 days_to_expiry -5';
    ASSERT (SELECT client_name FROM renewal_pipeline WHERE policy_id = p1) = 'Client One 014', 'view: client_name';
    ASSERT (SELECT agent_name FROM renewal_pipeline WHERE policy_id = p1) = 'Agent1 014', 'view: agent_name';
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
  END;

  -- ---------------------------------------------------------
  -- 2. Contact, quote, renew, closed, duplicate number, validation,
  --    reset on delete, report
  -- ---------------------------------------------------------
  BEGIN
    PERFORM _t014_as(a1);
    SET LOCAL ROLE authenticated;

    PERFORM log_renewal_contact(p1, 'whatsapp', today, 'Sent renewal notice');
    SELECT stage INTO v_txt FROM policy_renewals WHERE policy_id = p1;
    ASSERT v_txt = 'contacted', format('contact: stage %s', v_txt);
    SELECT id INTO rid FROM policy_renewals WHERE policy_id = p1;
    ASSERT (SELECT count(*) FROM renewal_activities WHERE renewal_id = rid AND kind = 'contact') = 1, 'contact: one activity';
    ASSERT (SELECT last_activity_at FROM policy_renewals WHERE id = rid) IS NOT NULL, 'contact: last_activity_at';

    PERFORM record_renewal_quote(p1, i2, 15000, 'First quote');
    PERFORM record_renewal_quote(p1, i1, 14000, 'Better quote');
    SELECT stage, quoted_insurer_id, quoted_premium INTO v_txt, v_uid, v_num FROM policy_renewals WHERE id = rid;
    ASSERT v_txt = 'quoted' AND v_uid = i1 AND v_num = 14000, format('quote: %s %s %s', v_txt, v_uid, v_num);
    ASSERT (SELECT count(*) FROM renewal_activities WHERE renewal_id = rid AND kind = 'quote') = 2, 'quote: two activities';

    PERFORM log_renewal_contact(p1, 'phone', today, 'Called to confirm');
    ASSERT (SELECT stage FROM policy_renewals WHERE id = rid) = 'quoted', 'contact after quote keeps quoted';

    -- renew validation
    v_new := jsonb_build_object('policy_number', 'T014-P1', 'insurer_id', i1, 'product_line_id', pl,
               'premium_amount', 14000, 'commission_rate', 10, 'commission_basis', 'annual',
               'start_date', today + 21, 'expiry_date', today + 21 + 364);
    PERFORM _t014_expect(format('SELECT renew_policy(%L, %L)', p1, v_new - 'policy_number'), 'Enter the policy number');
    PERFORM _t014_expect(format('SELECT renew_policy(%L, %L)', p1, v_new || jsonb_build_object('expiry_date', today + 21)), 'Expiry must be after the start date');
    PERFORM _t014_expect(format('SELECT renew_policy(%L, %L)', p1, v_new || jsonb_build_object('insurer_id', ix)), 'Pick an insurer of this agency');
    PERFORM _t014_expect(format('SELECT renew_policy(%L, %L)', p1, v_new || jsonb_build_object('product_line_id', plx)), 'Pick a product line of this agency');
    ASSERT (SELECT status FROM policies WHERE id = p1) = 'active', 'renew: failed renew leaves p1 active';

    newp := renew_policy(p1, v_new);
    ASSERT newp IS NOT NULL AND newp <> p1, 'renew: new id';
    RESET ROLE;
    ASSERT (SELECT client_id = cl1 AND agent_id = a1 AND insurer_id = i1 AND premium_amount = 14000
                   AND policy_number = 'T014-P1' AND status = 'active' AND agency_id = ag
              FROM policies WHERE id = newp), 'renew: new policy fields';
    ASSERT (SELECT count(*) FROM commission_transactions WHERE policy_id = newp) = 1, 'renew: expected commission created';
    ASSERT (SELECT status FROM policies WHERE id = p1) = 'expired', 'renew: old expired';
    ASSERT (SELECT stage = 'renewed' AND renewed_policy_id = newp AND previous_stage = 'quoted'
                   AND closed_at IS NOT NULL AND closed_by = a1
              FROM policy_renewals WHERE id = rid), 'renew: renewal closed';
    ASSERT (SELECT count(*) FROM renewal_activities WHERE renewal_id = rid AND kind = 'renewed' AND new_policy_id = newp) = 1, 'renew: activity';
    SET LOCAL ROLE authenticated;

    -- closed renewal refuses everything (Review Focus 1)
    PERFORM _t014_expect(format('SELECT mark_renewal_lost(%L, %L, NULL)', p1, 'price'), 'This renewal is already closed');
    PERFORM _t014_expect(format('SELECT renew_policy(%L, %L)', p1, v_new || jsonb_build_object('policy_number', 'T014-P1b')), 'This renewal is already closed');
    PERFORM _t014_expect(format('SELECT log_renewal_contact(%L, %L, %L, NULL)', p1, 'phone', today), 'This renewal is already closed');
    PERFORM _t014_expect(format('SELECT record_renewal_quote(%L, %L, 100, NULL)', p1, i1), 'This renewal is already closed');
    -- renewed stays visible in the view
    ASSERT (SELECT stage FROM renewal_pipeline WHERE policy_id = p1) = 'renewed', 'view: renewed visible';

    -- duplicate active number (Review Focus 2)
    PERFORM _t014_expect(format('SELECT renew_policy(%L, %L)', p2,
              v_new || jsonb_build_object('start_date', today + 41, 'expiry_date', today + 41 + 364)),
              'That policy number is already used by an active policy');
    ASSERT (SELECT status FROM policies WHERE id = p2) = 'active', 'dup: p2 still active';

    -- report fields while renewed
    RESET ROLE;
    PERFORM _t014_as(o);
    SET LOCAL ROLE authenticated;
    v_meta := (generate_monthly_report(EXTRACT(MONTH FROM today)::int, EXTRACT(YEAR FROM today)::int))->'metadata';
    ASSERT (v_meta->>'renewals_renewed')::int = 1, format('report: renewed %s', v_meta->>'renewals_renewed');
    ASSERT (v_meta->>'renewals_lost')::int = 0, 'report: lost 0';
    ASSERT (v_meta->>'renewal_rate')::numeric = 100, format('report: rate %s', v_meta->>'renewal_rate');

    -- delete the new policy → reset
    DELETE FROM policies WHERE id = newp;
    RESET ROLE;
    ASSERT (SELECT stage = 'quoted' AND renewed_policy_id IS NULL AND closed_at IS NULL AND closed_by IS NULL
              FROM policy_renewals WHERE id = rid), 'reset: back to quoted';
    ASSERT (SELECT status FROM policies WHERE id = p1) = 'active', 'reset: old active again';
    ASSERT (SELECT count(*) FROM renewal_activities WHERE renewal_id = rid AND kind = 'reset') = 1, 'reset: activity';
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
  END;

  -- ---------------------------------------------------------
  -- 3. Lost, reopen, window, not found
  -- ---------------------------------------------------------
  BEGIN
    PERFORM _t014_as(a1);
    SET LOCAL ROLE authenticated;
    PERFORM _t014_expect(format('SELECT mark_renewal_lost(%L, NULL, NULL)', p3), 'Pick a reason');
    PERFORM _t014_expect(format('SELECT mark_renewal_lost(%L, %L, NULL)', p3, 'cheaper'), 'Pick a reason');
    PERFORM mark_renewal_lost(p3, 'price', 'Too expensive');
    PERFORM mark_renewal_lost(p2, 'no_response', NULL);
    RESET ROLE;
    ASSERT (SELECT status FROM policies WHERE id = p3) = 'expired', 'lost: past-expiry policy expired';
    ASSERT (SELECT expired_by_loss FROM policy_renewals WHERE policy_id = p3), 'lost: expired_by_loss';
    ASSERT (SELECT status FROM policies WHERE id = p2) = 'active', 'lost: running policy stays active';
    ASSERT (SELECT stage = 'lost' AND lost_reason = 'price' AND previous_stage = 'to_contact' FROM policy_renewals WHERE policy_id = p3), 'lost: fields';
    SET LOCAL ROLE authenticated;
    ASSERT (SELECT count(*) FROM renewal_pipeline WHERE policy_id IN (p2, p3) AND stage = 'lost') = 2, 'view: lost visible';

    PERFORM _t014_expect(format('SELECT reopen_renewal(%L)', p3), 'Only owners and managers can do that', '42501');
    RESET ROLE;
    PERFORM _t014_as(m);
    SET LOCAL ROLE authenticated;
    PERFORM reopen_renewal(p3);
    RESET ROLE;
    ASSERT (SELECT stage = 'to_contact' AND lost_reason IS NULL AND closed_at IS NULL AND NOT expired_by_loss
              FROM policy_renewals WHERE policy_id = p3), 'reopen: fields';
    ASSERT (SELECT status FROM policies WHERE id = p3) = 'active', 'reopen: policy active again';
    ASSERT (SELECT count(*) FROM renewal_activities a JOIN policy_renewals r ON r.id = a.renewal_id
             WHERE r.policy_id = p3 AND a.kind = 'reopened') = 1, 'reopen: activity';
    SET LOCAL ROLE authenticated;
    PERFORM _t014_expect(format('SELECT reopen_renewal(%L)', p3), 'Only a lost renewal can be reopened');
    PERFORM _t014_expect(format('SELECT reopen_renewal(%L)', p1), 'Only a lost renewal can be reopened');

    PERFORM _t014_expect(format('SELECT log_renewal_contact(%L, %L, %L, NULL)', p4, 'phone', today), 'This policy is not due for renewal');
    PERFORM _t014_expect(format('SELECT log_renewal_contact(%L, %L, %L, NULL)', gen_random_uuid(), 'phone', today), 'Policy not found', 'P0002');
    PERFORM _t014_expect(format('SELECT log_renewal_contact(%L, %L, %L, NULL)', px, 'phone', today), 'Policy not found', 'P0002');
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
  END;

  -- ---------------------------------------------------------
  -- 4. Agents: own policies, reassignment, setting
  -- ---------------------------------------------------------
  BEGIN
    PERFORM _t014_as(a1);
    SET LOCAL ROLE authenticated;
    PERFORM _t014_expect(format('SELECT log_renewal_contact(%L, %L, %L, NULL)', q1, 'phone', today),
              'You can only update renewals for your own policies', '42501');
    ASSERT NOT EXISTS (SELECT 1 FROM renewal_pipeline WHERE policy_id = q1), 'agent: q1 hidden from a1';
    RESET ROLE;
    PERFORM _t014_as(a2);
    SET LOCAL ROLE authenticated;
    PERFORM log_renewal_contact(q1, 'sms', today, NULL);
    RESET ROLE;
    PERFORM _t014_as(a1);
    SET LOCAL ROLE authenticated;
    ASSERT (SELECT count(*) FROM policy_renewals WHERE policy_id = q1) = 0, 'agent: a1 cannot read q1 renewal';
    ASSERT (SELECT count(*) FROM renewal_activities a JOIN policy_renewals r ON r.id = a.renewal_id WHERE r.policy_id = q1) = 0, 'agent: a1 cannot read q1 activities';
    RESET ROLE;

    -- reassignment (Review Focus 3)
    PERFORM _t014_as(o);
    SET LOCAL ROLE authenticated;
    PERFORM reassign_client(cl2, a1);
    RESET ROLE;
    ASSERT (SELECT agent_id FROM policies WHERE id = q1) = a1, 'reassign: q1 moved to a1';
    PERFORM _t014_as(a1);
    SET LOCAL ROLE authenticated;
    PERFORM log_renewal_contact(q1, 'phone', today, 'New agent call');
    RESET ROLE;
    PERFORM _t014_as(a2);
    SET LOCAL ROLE authenticated;
    PERFORM _t014_expect(format('SELECT log_renewal_contact(%L, %L, %L, NULL)', q1, 'phone', today),
              'You can only update renewals for your own policies', '42501');
    RESET ROLE;
    ASSERT (SELECT count(DISTINCT a.created_by) FROM renewal_activities a JOIN policy_renewals r ON r.id = a.renewal_id
             WHERE r.policy_id = q1) = 2, 'reassign: history keeps both agents';

    -- setting
    PERFORM _t014_as(m);
    SET LOCAL ROLE authenticated;
    PERFORM _t014_expect('SELECT set_agents_manage_renewals(false)', 'Only the owner can do that', '42501');
    RESET ROLE;
    PERFORM _t014_as(o);
    SET LOCAL ROLE authenticated;
    PERFORM set_agents_manage_renewals(false);
    RESET ROLE;
    ASSERT NOT (SELECT agents_manage_renewals FROM agencies WHERE id = ag), 'setting: off';
    PERFORM _t014_as(a1);
    SET LOCAL ROLE authenticated;
    PERFORM _t014_expect(format('SELECT log_renewal_contact(%L, %L, %L, NULL)', p2, 'phone', today),
              'Renewal updates by agents are turned off for this agency', '42501');
    PERFORM _t014_expect(format('SELECT mark_renewal_lost(%L, %L, NULL)', p2, 'price'),
              'Renewal updates by agents are turned off for this agency', '42501');
    RESET ROLE;
    PERFORM _t014_as(m);
    SET LOCAL ROLE authenticated;
    PERFORM log_renewal_contact(p2, 'email', today, NULL);
    RESET ROLE;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
  END;

  -- ---------------------------------------------------------
  -- 5. Field validation, direct writes, deactivated agent
  -- ---------------------------------------------------------
  BEGIN
    PERFORM _t014_as(o);
    SET LOCAL ROLE authenticated;
    PERFORM _t014_expect(format('SELECT log_renewal_contact(%L, %L, %L, NULL)', p2, 'fax', today), 'Pick a channel');
    PERFORM _t014_expect(format('SELECT log_renewal_contact(%L, %L, NULL, NULL)', p2, 'phone'), 'Enter the date');
    PERFORM _t014_expect(format('SELECT record_renewal_quote(%L, %L, 0, NULL)', p2, i1), 'Enter a premium');
    PERFORM _t014_expect(format('SELECT record_renewal_quote(%L, %L, NULL, NULL)', p2, i1), 'Enter a premium');
    PERFORM _t014_expect(format('SELECT record_renewal_quote(%L, %L, 100, NULL)', p2, ix), 'Pick an insurer of this agency');
    PERFORM _t014_expect(format('INSERT INTO policy_renewals (agency_id, policy_id, stage) VALUES (%L, %L, %L)', ag, p2, 'quoted'), NULL, '42501');
    PERFORM log_renewal_contact(p2, 'phone', today, NULL);
    PERFORM _t014_expect(format('UPDATE policy_renewals SET stage = %L WHERE policy_id = %L', 'renewed', p2), NULL, '42501');
    PERFORM _t014_expect(format('DELETE FROM renewal_activities WHERE agency_id = %L', ag), NULL, '42501');
    RESET ROLE;
    -- deactivated agent
    UPDATE users SET deactivated_at = now() WHERE id = a1;
    PERFORM _t014_as(a1);
    SET LOCAL ROLE authenticated;
    PERFORM _t014_expect(format('SELECT log_renewal_contact(%L, %L, %L, NULL)', p2, 'phone', today), NULL);
    RESET ROLE;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
  END;

  -- ---------------------------------------------------------
  -- 6. Reminder migration helper
  -- ---------------------------------------------------------
  BEGIN
    RESET ROLE;
    INSERT INTO renewal_reminders (policy_id, agency_id, reminder_date, channel, sent, sent_at, notes)
    VALUES (p2, ag, today - 3, 'whatsapp', true, now(), 'Manual log'),
           (p2, ag, today + 10, 'email', false, NULL, NULL);
    n := _migrate_renewal_reminders();
    ASSERT n = 1, format('migrate: copied %s', n);
    ASSERT (SELECT count(*) FROM renewal_reminders WHERE policy_id = p2 AND NOT sent) = 0, 'migrate: unsent deleted';
    ASSERT (SELECT count(*) FROM renewal_activities a JOIN policy_renewals r ON r.id = a.renewal_id
             WHERE r.policy_id = p2 AND a.kind = 'contact' AND a.channel = 'whatsapp'
               AND a.occurred_on = today - 3 AND a.note = 'Manual log') = 1, 'migrate: contact copied';
    ASSERT (SELECT stage FROM policy_renewals WHERE policy_id = p2) = 'contacted', 'migrate: stage contacted';
    n := _migrate_renewal_reminders();
    ASSERT n = 0, format('migrate: second run copied %s', n);
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
  END;

  -- ---------------------------------------------------------
  -- 7. Grants
  -- ---------------------------------------------------------
  RESET ROLE;
  ASSERT NOT has_function_privilege('anon', 'public.log_renewal_contact(uuid, text, date, text)', 'EXECUTE'), 'anon: log_renewal_contact';
  ASSERT has_function_privilege('authenticated', 'public.log_renewal_contact(uuid, text, date, text)', 'EXECUTE'), 'auth: log_renewal_contact';
  ASSERT NOT has_function_privilege('anon', 'public.record_renewal_quote(uuid, uuid, numeric, text)', 'EXECUTE'), 'anon: record_renewal_quote';
  ASSERT NOT has_function_privilege('anon', 'public.mark_renewal_lost(uuid, text, text)', 'EXECUTE'), 'anon: mark_renewal_lost';
  ASSERT NOT has_function_privilege('anon', 'public.reopen_renewal(uuid)', 'EXECUTE'), 'anon: reopen_renewal';
  ASSERT NOT has_function_privilege('anon', 'public.renew_policy(uuid, jsonb)', 'EXECUTE'), 'anon: renew_policy';
  ASSERT has_function_privilege('authenticated', 'public.renew_policy(uuid, jsonb)', 'EXECUTE'), 'auth: renew_policy';
  ASSERT NOT has_function_privilege('anon', 'public.set_agents_manage_renewals(boolean)', 'EXECUTE'), 'anon: set_agents_manage_renewals';
  ASSERT NOT has_function_privilege('authenticated', 'public._migrate_renewal_reminders()', 'EXECUTE'), 'auth: _migrate_renewal_reminders';
  ASSERT NOT has_function_privilege('authenticated', 'public.policy_renewal_reset()', 'EXECUTE'), 'auth: policy_renewal_reset';
  ASSERT NOT has_table_privilege('anon', 'public.renewal_pipeline', 'SELECT'), 'anon: view';
END;
$$;

SELECT 'ALL PASSED' AS result;

ROLLBACK;
