-- ============================================================
-- Test 008: team management RPCs (reassign_client,
-- change_member_role, remove_member).
--
-- Run the whole file in one go (Supabase SQL editor / execute_sql).
-- Everything happens inside one transaction that is ALWAYS rolled
-- back: on success the final SELECT returns 'ALL PASSED'; on any
-- failed ASSERT the batch aborts and nothing is committed.
--
-- Same impersonation pattern as test 006. Expected errors are
-- caught by SQLSTATE (insufficient_privilege = 42501,
-- invalid_parameter_value = 22023, no_data_found = P0002) and the
-- message text is asserted, because the UI shows it.
-- ============================================================

BEGIN;

DO $$
DECLARE
  ag   UUID := gen_random_uuid();
  ag2  UUID := gen_random_uuid();
  o    UUID := gen_random_uuid();
  m    UUID := gen_random_uuid();
  a1   UUID := gen_random_uuid();
  a2   UUID := gen_random_uuid();
  d    UUID := gen_random_uuid();   -- deactivated agent
  o2   UUID := gen_random_uuid();   -- owner of a second agency
  ins  UUID;
  pl   UUID;
  ins2 UUID;
  pl2  UUID;
  c_mix   UUID := gen_random_uuid();   -- a1, four policies of every status
  c_a2_1  UUID := gen_random_uuid();   -- a2, one active + one expired policy
  c_a2_2  UUID := gen_random_uuid();   -- a2, one pending policy
  c_other UUID := gen_random_uuid();   -- client of ag2
  c_m_x   UUID := gen_random_uuid();   -- m's client carrying a2 policies
  p_mx_active  UUID := gen_random_uuid();   -- agent a2, active, on m's client
  p_mx_expired UUID := gen_random_uuid();   -- agent a2, expired, on m's client
  p_active    UUID := gen_random_uuid();
  p_pending   UUID := gen_random_uuid();
  p_expired   UUID := gen_random_uuid();
  p_cancelled UUID := gen_random_uuid();
  p_a2_exp    UUID := gen_random_uuid();
  inv_live    UUID := gen_random_uuid();   -- by a2, live
  inv_expired UUID := gen_random_uuid();   -- by a2, expired
  inv_revoked UUID := gen_random_uuid();   -- by a2, already revoked
  inv_o       UUID := gen_random_uuid();   -- by o, live
  old_revoked TIMESTAMPTZ := now() - interval '3 days';
  r      JSONB;
  n      INTEGER;
  v_text TEXT;
BEGIN
  -- ---------------------------------------------------------
  -- Fixture (as superuser)
  -- ---------------------------------------------------------
  INSERT INTO auth.users (id, email, aud, role, instance_id) VALUES
    (o,  'o-008@test.local',  'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000'),
    (m,  'm-008@test.local',  'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000'),
    (a1, 'a1-008@test.local', 'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000'),
    (a2, 'a2-008@test.local', 'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000'),
    (d,  'd-008@test.local',  'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000'),
    (o2, 'o2-008@test.local', 'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000');

  INSERT INTO agencies (id, name) VALUES (ag, 'Test Agency 008'), (ag2, 'Other Agency 008');

  INSERT INTO users (id, agency_id, role, full_name, email, deactivated_at) VALUES
    (o,  ag,  'owner',   'Owner 008',   'o-008@test.local',  NULL),
    (m,  ag,  'manager', 'Manager 008', 'm-008@test.local',  NULL),
    (a1, ag,  'agent',   'Agent1 008',  'a1-008@test.local', NULL),
    (a2, ag,  'agent',   'Agent2 008',  'a2-008@test.local', NULL),
    (d,  ag,  'agent',   'Gone 008',    'd-008@test.local',  now()),
    (o2, ag2, 'owner',   'Owner2 008',  'o2-008@test.local', NULL);

  INSERT INTO insurers (agency_id, name) VALUES (ag, 'Insurer 008') RETURNING id INTO ins;
  INSERT INTO product_lines (agency_id, name) VALUES (ag, 'Motor 008') RETURNING id INTO pl;
  INSERT INTO insurers (agency_id, name) VALUES (ag2, 'Insurer2 008') RETURNING id INTO ins2;
  INSERT INTO product_lines (agency_id, name) VALUES (ag2, 'Motor2 008') RETURNING id INTO pl2;

  INSERT INTO clients (id, agency_id, type, name, assigned_agent_id) VALUES
    (c_mix,   ag,  'individual', 'Mix Client',   a1),
    (c_a2_1,  ag,  'individual', 'A2 Client 1',  a2),
    (c_a2_2,  ag,  'corporate',  'A2 Client 2',  a2),
    (c_other, ag2, 'individual', 'Other Client', o2),
    (c_m_x,   ag,  'corporate',  'M Client X',   m);

  INSERT INTO policies (id, agency_id, client_id, insurer_id, product_line_id, agent_id,
                        policy_number, premium_amount, commission_rate, commission_received,
                        start_date, expiry_date, status, updated_at)
  VALUES
    (p_active,    ag, c_mix,  ins, pl, a1, 'T008-1', 10000, 10, 0,   CURRENT_DATE,       CURRENT_DATE + 200, 'active',    now() - interval '1 day'),
    (p_pending,   ag, c_mix,  ins, pl, a1, 'T008-2', 20000, 10, 0,   CURRENT_DATE,       CURRENT_DATE + 200, 'pending',   now() - interval '1 day'),
    (p_expired,   ag, c_mix,  ins, pl, a1, 'T008-3', 30000, 10, 3000, CURRENT_DATE - 400, CURRENT_DATE - 35, 'expired',   now() - interval '1 day'),
    (p_cancelled, ag, c_mix,  ins, pl, a1, 'T008-4', 40000, 10, 0,   CURRENT_DATE - 100, CURRENT_DATE + 265, 'cancelled', now() - interval '1 day'),
    (gen_random_uuid(), ag, c_a2_1, ins, pl, a2, 'T008-5', 50000, 10, 0, CURRENT_DATE, CURRENT_DATE + 200, 'active',  now() - interval '1 day'),
    (p_a2_exp,    ag, c_a2_1, ins, pl, a2, 'T008-6', 60000, 10, 0,   CURRENT_DATE - 400, CURRENT_DATE - 35, 'expired',   now() - interval '1 day'),
    (gen_random_uuid(), ag, c_a2_2, ins, pl, a2, 'T008-7', 70000, 10, 0, CURRENT_DATE, CURRENT_DATE + 200, 'pending', now() - interval '1 day'),
    (gen_random_uuid(), ag2, c_other, ins2, pl2, o2, 'T008-8', 80000, 10, 0, CURRENT_DATE, CURRENT_DATE + 200, 'active', now() - interval '1 day'),
    -- a2's policies on a client assigned to m (an owner/manager may set any agent_id)
    (p_mx_active,  ag, c_m_x, ins, pl, a2, 'T008-9',  90000, 10, 0, CURRENT_DATE,       CURRENT_DATE + 200, 'active',  now() - interval '1 day'),
    (p_mx_expired, ag, c_m_x, ins, pl, a2, 'T008-10', 95000, 10, 0, CURRENT_DATE - 400, CURRENT_DATE - 35,  'expired', now() - interval '1 day');

  INSERT INTO agency_invites (id, agency_id, email, role, token_hash, invited_by, expires_at, revoked_at) VALUES
    (inv_live,    ag, 'live-008@test.local',    'agent', repeat('1', 64), a2, now() + interval '7 days', NULL),
    (inv_expired, ag, 'expired-008@test.local', 'agent', repeat('2', 64), a2, now() - interval '1 day',  NULL),
    (inv_revoked, ag, 'revoked-008@test.local', 'agent', repeat('3', 64), a2, now() + interval '7 days', old_revoked),
    (inv_o,       ag, 'o-inv-008@test.local',   'agent', repeat('4', 64), o,  now() + interval '7 days', NULL);

  -- ---------------------------------------------------------
  -- Grants
  -- ---------------------------------------------------------
  ASSERT NOT has_function_privilege('anon', 'public.reassign_client(uuid, uuid)', 'EXECUTE'), 'anon must not execute reassign_client';
  ASSERT NOT has_function_privilege('anon', 'public.change_member_role(uuid, text)', 'EXECUTE'), 'anon must not execute change_member_role';
  ASSERT NOT has_function_privilege('anon', 'public.remove_member(uuid, uuid)', 'EXECUTE'), 'anon must not execute remove_member';
  ASSERT has_function_privilege('authenticated', 'public.reassign_client(uuid, uuid)', 'EXECUTE'), 'authenticated must execute reassign_client';
  ASSERT has_function_privilege('authenticated', 'public.change_member_role(uuid, text)', 'EXECUTE'), 'authenticated must execute change_member_role';
  ASSERT has_function_privilege('authenticated', 'public.remove_member(uuid, uuid)', 'EXECUTE'), 'authenticated must execute remove_member';
  ASSERT NOT has_function_privilege('anon', 'public._reassign_client_unchecked(uuid, uuid)', 'EXECUTE'), 'anon must not execute the helper';
  ASSERT NOT has_function_privilege('authenticated', 'public._reassign_client_unchecked(uuid, uuid)', 'EXECUTE'), 'authenticated must not execute the helper';

  -- ---------------------------------------------------------
  -- reassign_client
  -- ---------------------------------------------------------
  -- Agent a1: not allowed (and helper not callable directly)
  PERFORM set_config('request.jwt.claims', json_build_object('sub', a1, 'role','authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  BEGIN
    PERFORM public.reassign_client(c_mix, a2);
    RAISE EXCEPTION 'FAIL: a1 reassigned a client';
  EXCEPTION WHEN insufficient_privilege THEN
    GET STACKED DIAGNOSTICS v_text = MESSAGE_TEXT;
    ASSERT v_text = 'Only owners and managers can do that', format('a1 reassign: got %s', v_text);
  END;
  BEGIN
    PERFORM public._reassign_client_unchecked(c_mix, a1);
    RAISE EXCEPTION 'FAIL: a1 called the unchecked helper';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  RESET ROLE;

  -- Deactivated member: not allowed
  PERFORM set_config('request.jwt.claims', json_build_object('sub', d, 'role','authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  BEGIN
    PERFORM public.reassign_client(c_mix, a2);
    RAISE EXCEPTION 'FAIL: deactivated member reassigned a client';
  EXCEPTION WHEN insufficient_privilege THEN
    GET STACKED DIAGNOSTICS v_text = MESSAGE_TEXT;
    ASSERT v_text = 'Only owners and managers can do that', format('d reassign: got %s', v_text);
  END;
  RESET ROLE;

  SELECT count(*) INTO n FROM clients WHERE id = c_mix AND assigned_agent_id = a1;
  ASSERT n = 1, 'denied reassigns must not change the client';

  -- Manager m
  PERFORM set_config('request.jwt.claims', json_build_object('sub', m, 'role','authenticated')::text, true);
  SET LOCAL ROLE authenticated;

  -- bad targets
  BEGIN
    PERFORM public.reassign_client(c_mix, o2);
    RAISE EXCEPTION 'FAIL: reassigned to another agency''s user';
  EXCEPTION WHEN invalid_parameter_value THEN
    GET STACKED DIAGNOSTICS v_text = MESSAGE_TEXT;
    ASSERT v_text = 'Pick an active member of this agency', format('reassign to o2: got %s', v_text);
  END;
  BEGIN
    PERFORM public.reassign_client(c_mix, d);
    RAISE EXCEPTION 'FAIL: reassigned to a deactivated user';
  EXCEPTION WHEN invalid_parameter_value THEN
    GET STACKED DIAGNOSTICS v_text = MESSAGE_TEXT;
    ASSERT v_text = 'Pick an active member of this agency', format('reassign to d: got %s', v_text);
  END;
  BEGIN
    PERFORM public.reassign_client(c_mix, NULL);
    RAISE EXCEPTION 'FAIL: reassigned to NULL';
  EXCEPTION WHEN invalid_parameter_value THEN
    GET STACKED DIAGNOSTICS v_text = MESSAGE_TEXT;
    ASSERT v_text = 'Pick an active member of this agency', format('reassign to NULL: got %s', v_text);
  END;
  BEGIN
    PERFORM public.reassign_client(gen_random_uuid(), a2);
    RAISE EXCEPTION 'FAIL: reassigned a missing client';
  EXCEPTION WHEN no_data_found THEN
    GET STACKED DIAGNOSTICS v_text = MESSAGE_TEXT;
    ASSERT v_text = 'Client not found', format('reassign missing client: got %s', v_text);
  END;
  BEGIN
    PERFORM public.reassign_client(c_other, a2);
    RAISE EXCEPTION 'FAIL: reassigned another agency''s client';
  EXCEPTION WHEN no_data_found THEN
    GET STACKED DIAGNOSTICS v_text = MESSAGE_TEXT;
    ASSERT v_text = 'Client not found', format('reassign other agency client: got %s', v_text);
  END;

  -- success: only active + pending move
  r := public.reassign_client(c_mix, a2);
  ASSERT (r->>'policies_moved')::int = 2, format('reassign c_mix: policies_moved expected 2, got %s', r->>'policies_moved');

  -- reassign to the current assignee: allowed, nothing to move
  r := public.reassign_client(c_mix, a2);
  ASSERT (r->>'policies_moved')::int = 0, format('reassign c_mix again: policies_moved expected 0, got %s', r->>'policies_moved');
  RESET ROLE;

  SELECT count(*) INTO n FROM clients WHERE id = c_mix AND assigned_agent_id = a2;
  ASSERT n = 1, 'c_mix should now be assigned to a2';
  SELECT count(*) INTO n FROM policies WHERE id IN (p_active, p_pending) AND agent_id = a2;
  ASSERT n = 2, format('active/pending policies should be on a2, got %s', n);
  SELECT count(*) INTO n FROM policies
   WHERE id IN (p_active, p_pending) AND updated_at > now() - interval '1 hour';
  ASSERT n = 2, 'moved policies should have updated_at bumped';
  SELECT count(*) INTO n FROM policies WHERE id IN (p_expired, p_cancelled) AND agent_id = a1;
  ASSERT n = 2, format('expired/cancelled policies should stay on a1, got %s', n);
  SELECT count(*) INTO n FROM policies
   WHERE id IN (p_expired, p_cancelled) AND updated_at < now() - interval '1 hour';
  ASSERT n = 2, 'unmoved policies must keep their updated_at';
  SELECT count(*) INTO n FROM policies WHERE id = p_expired AND commission_received = 3000;
  ASSERT n = 1, 'commission_received must not change';

  -- visibility follows the assignment
  PERFORM set_config('request.jwt.claims', json_build_object('sub', a2, 'role','authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  SELECT count(*) INTO n FROM clients WHERE id = c_mix;
  ASSERT n = 1, 'a2 should see c_mix after reassignment';
  RESET ROLE;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', a1, 'role','authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  SELECT count(*) INTO n FROM clients WHERE id = c_mix;
  ASSERT n = 0, 'a1 should no longer see c_mix';
  SELECT count(*) INTO n FROM policies WHERE client_id = c_mix;
  ASSERT n = 2, format('a1 should still see their 2 historical c_mix policies, got %s', n);
  RESET ROLE;

  -- Owner can reassign too (to o and back to a2)
  PERFORM set_config('request.jwt.claims', json_build_object('sub', o, 'role','authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  r := public.reassign_client(c_mix, o);
  ASSERT (r->>'policies_moved')::int = 2, format('o reassign c_mix to o: expected 2, got %s', r->>'policies_moved');
  r := public.reassign_client(c_mix, a2);
  ASSERT (r->>'policies_moved')::int = 2, format('o reassign c_mix back to a2: expected 2, got %s', r->>'policies_moved');
  RESET ROLE;

  -- ---------------------------------------------------------
  -- change_member_role
  -- ---------------------------------------------------------
  PERFORM set_config('request.jwt.claims', json_build_object('sub', m, 'role','authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  BEGIN
    PERFORM public.change_member_role(a1, 'manager');
    RAISE EXCEPTION 'FAIL: m changed a role';
  EXCEPTION WHEN insufficient_privilege THEN
    GET STACKED DIAGNOSTICS v_text = MESSAGE_TEXT;
    ASSERT v_text = 'Only the owner can do that', format('m change role: got %s', v_text);
  END;
  RESET ROLE;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', a1, 'role','authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  BEGIN
    PERFORM public.change_member_role(a1, 'manager');
    RAISE EXCEPTION 'FAIL: a1 promoted themselves';
  EXCEPTION WHEN insufficient_privilege THEN
    GET STACKED DIAGNOSTICS v_text = MESSAGE_TEXT;
    ASSERT v_text = 'Only the owner can do that', format('a1 change role: got %s', v_text);
  END;
  RESET ROLE;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', o, 'role','authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  PERFORM public.change_member_role(a1, 'manager');
  RESET ROLE;
  SELECT role INTO v_text FROM users WHERE id = a1;
  ASSERT v_text = 'manager', format('a1 promoted: expected manager, got %s', v_text);

  PERFORM set_config('request.jwt.claims', json_build_object('sub', o, 'role','authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  PERFORM public.change_member_role(a1, 'agent');
  PERFORM public.change_member_role(a1, 'agent');   -- same role: no-op
  BEGIN
    PERFORM public.change_member_role(o, 'manager');
    RAISE EXCEPTION 'FAIL: o changed own role';
  EXCEPTION WHEN insufficient_privilege THEN
    GET STACKED DIAGNOSTICS v_text = MESSAGE_TEXT;
    ASSERT v_text = 'The owner cannot be changed or removed', format('o change own role: got %s', v_text);
  END;
  BEGIN
    PERFORM public.change_member_role(a1, 'owner');
    RAISE EXCEPTION 'FAIL: made a second owner';
  EXCEPTION WHEN invalid_parameter_value THEN
    GET STACKED DIAGNOSTICS v_text = MESSAGE_TEXT;
    ASSERT v_text = 'Role must be manager or agent', format('change to owner: got %s', v_text);
  END;
  BEGIN
    PERFORM public.change_member_role(a1, NULL);
    RAISE EXCEPTION 'FAIL: changed role to NULL';
  EXCEPTION WHEN invalid_parameter_value THEN
    GET STACKED DIAGNOSTICS v_text = MESSAGE_TEXT;
    ASSERT v_text = 'Role must be manager or agent', format('change to NULL: got %s', v_text);
  END;
  BEGIN
    PERFORM public.change_member_role(d, 'manager');
    RAISE EXCEPTION 'FAIL: changed a deactivated member''s role';
  EXCEPTION WHEN invalid_parameter_value THEN
    GET STACKED DIAGNOSTICS v_text = MESSAGE_TEXT;
    ASSERT v_text = 'Pick an active member of this agency', format('change deactivated: got %s', v_text);
  END;
  BEGIN
    PERFORM public.change_member_role(o2, 'manager');
    RAISE EXCEPTION 'FAIL: changed another agency''s member';
  EXCEPTION WHEN invalid_parameter_value THEN
    GET STACKED DIAGNOSTICS v_text = MESSAGE_TEXT;
    ASSERT v_text = 'Pick an active member of this agency', format('change other agency: got %s', v_text);
  END;
  RESET ROLE;

  SELECT role INTO v_text FROM users WHERE id = a1;
  ASSERT v_text = 'agent', format('a1 demoted back: expected agent, got %s', v_text);
  SELECT role INTO v_text FROM users WHERE id = o;
  ASSERT v_text = 'owner', 'o must still be owner';
  SELECT role INTO v_text FROM users WHERE id = d;
  ASSERT v_text = 'agent', 'd role must be unchanged';
  SELECT role INTO v_text FROM users WHERE id = o2;
  ASSERT v_text = 'owner', 'o2 role must be unchanged';

  -- ---------------------------------------------------------
  -- remove_member
  -- ---------------------------------------------------------
  PERFORM set_config('request.jwt.claims', json_build_object('sub', m, 'role','authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  BEGIN
    PERFORM public.remove_member(a2, a1);
    RAISE EXCEPTION 'FAIL: m removed a member';
  EXCEPTION WHEN insufficient_privilege THEN
    GET STACKED DIAGNOSTICS v_text = MESSAGE_TEXT;
    ASSERT v_text = 'Only the owner can do that', format('m remove: got %s', v_text);
  END;
  RESET ROLE;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', o, 'role','authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  BEGIN
    PERFORM public.remove_member(o, a1);
    RAISE EXCEPTION 'FAIL: o removed themselves';
  EXCEPTION WHEN insufficient_privilege THEN
    GET STACKED DIAGNOSTICS v_text = MESSAGE_TEXT;
    ASSERT v_text = 'The owner cannot be changed or removed', format('remove owner: got %s', v_text);
  END;
  BEGIN
    PERFORM public.remove_member(a1, a1);
    RAISE EXCEPTION 'FAIL: reassigned a removed member''s clients to themselves';
  EXCEPTION WHEN invalid_parameter_value THEN
    GET STACKED DIAGNOSTICS v_text = MESSAGE_TEXT;
    ASSERT v_text = 'Pick an active member of this agency', format('remove a1 -> a1: got %s', v_text);
  END;
  BEGIN
    PERFORM public.remove_member(a2, d);
    RAISE EXCEPTION 'FAIL: reassigned to a deactivated member';
  EXCEPTION WHEN invalid_parameter_value THEN
    GET STACKED DIAGNOSTICS v_text = MESSAGE_TEXT;
    ASSERT v_text = 'Pick an active member of this agency', format('remove a2 -> d: got %s', v_text);
  END;
  BEGIN
    PERFORM public.remove_member(a2, o2);
    RAISE EXCEPTION 'FAIL: reassigned to another agency''s user';
  EXCEPTION WHEN invalid_parameter_value THEN
    GET STACKED DIAGNOSTICS v_text = MESSAGE_TEXT;
    ASSERT v_text = 'Pick an active member of this agency', format('remove a2 -> o2: got %s', v_text);
  END;
  BEGIN
    PERFORM public.remove_member(a2, NULL);
    RAISE EXCEPTION 'FAIL: reassigned to NULL';
  EXCEPTION WHEN invalid_parameter_value THEN
    GET STACKED DIAGNOSTICS v_text = MESSAGE_TEXT;
    ASSERT v_text = 'Pick an active member of this agency', format('remove a2 -> NULL: got %s', v_text);
  END;
  BEGIN
    PERFORM public.remove_member(o2, a1);
    RAISE EXCEPTION 'FAIL: removed another agency''s member';
  EXCEPTION WHEN invalid_parameter_value THEN
    GET STACKED DIAGNOSTICS v_text = MESSAGE_TEXT;
    ASSERT v_text = 'Pick an active member of this agency', format('remove o2: got %s', v_text);
  END;
  BEGIN
    PERFORM public.remove_member(d, a1);
    RAISE EXCEPTION 'FAIL: removed an already deactivated member';
  EXCEPTION WHEN invalid_parameter_value THEN
    GET STACKED DIAGNOSTICS v_text = MESSAGE_TEXT;
    ASSERT v_text = 'Pick an active member of this agency', format('remove d: got %s', v_text);
  END;
  RESET ROLE;

  SELECT count(*) INTO n FROM users WHERE id IN (o, a1, a2, o2) AND deactivated_at IS NULL;
  ASSERT n = 4, 'failed removes must not deactivate anyone';

  -- success: a2 owns c_mix (2 movable), c_a2_1 (1 active + 1 expired), c_a2_2 (1 pending),
  -- plus 1 active policy on m's client c_m_x (its expired sibling stays)
  PERFORM set_config('request.jwt.claims', json_build_object('sub', o, 'role','authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  r := public.remove_member(a2, a1);
  ASSERT (r->>'clients_moved')::int = 3, format('remove a2: clients_moved expected 3, got %s', r->>'clients_moved');
  ASSERT (r->>'policies_moved')::int = 5, format('remove a2: policies_moved expected 5, got %s', r->>'policies_moved');
  ASSERT (r->>'invites_revoked')::int = 1, format('remove a2: invites_revoked expected 1, got %s', r->>'invites_revoked');
  BEGIN
    PERFORM public.remove_member(a1, a2);
    RAISE EXCEPTION 'FAIL: reassigned to a just-removed member';
  EXCEPTION WHEN invalid_parameter_value THEN
    GET STACKED DIAGNOSTICS v_text = MESSAGE_TEXT;
    ASSERT v_text = 'Pick an active member of this agency', format('remove a1 -> removed a2: got %s', v_text);
  END;
  RESET ROLE;

  SELECT count(*) INTO n FROM users WHERE id = a2 AND deactivated_at IS NOT NULL;
  ASSERT n = 1, 'a2 should be deactivated';
  SELECT count(*) INTO n FROM clients WHERE assigned_agent_id = a2;
  ASSERT n = 0, format('a2 should have no clients left, got %s', n);
  SELECT count(*) INTO n FROM clients WHERE id IN (c_mix, c_a2_1, c_a2_2) AND assigned_agent_id = a1;
  ASSERT n = 3, format('all a2 clients should now be a1''s, got %s', n);
  SELECT count(*) INTO n FROM policies
   WHERE client_id IN (c_mix, c_a2_1, c_a2_2) AND status IN ('active', 'pending') AND agent_id <> a1;
  ASSERT n = 0, 'all active/pending policies of moved clients should be on a1';
  SELECT count(*) INTO n FROM policies WHERE id = p_a2_exp AND agent_id = a2;
  ASSERT n = 1, 'a2''s expired policy should stay with a2';
  SELECT count(*) INTO n FROM clients WHERE id = c_other AND assigned_agent_id = o2;
  ASSERT n = 1, 'other agency client must be untouched';
  SELECT count(*) INTO n FROM policies WHERE id = p_mx_active AND agent_id = a1 AND updated_at > now() - interval '1 hour';
  ASSERT n = 1, 'a2''s active policy on m''s client should move to a1 with updated_at bumped';
  SELECT count(*) INTO n FROM policies WHERE id = p_mx_expired AND agent_id = a2;
  ASSERT n = 1, 'a2''s expired policy on m''s client should stay with a2';
  SELECT count(*) INTO n FROM clients WHERE id = c_m_x AND assigned_agent_id = m;
  ASSERT n = 1, 'm''s client must stay assigned to m';
  SELECT count(*) INTO n FROM policies
   WHERE agency_id = ag AND agent_id = a2 AND status IN ('active', 'pending');
  ASSERT n = 0, format('removed a2 must hold no active/pending policies, got %s', n);

  -- invites: only a2's live invite gets revoked
  SELECT count(*) INTO n FROM agency_invites WHERE id = inv_live AND revoked_at IS NOT NULL;
  ASSERT n = 1, 'a2''s live invite should be revoked';
  SELECT count(*) INTO n FROM agency_invites WHERE id = inv_expired AND revoked_at IS NULL;
  ASSERT n = 1, 'a2''s expired invite should be left alone';
  SELECT count(*) INTO n FROM agency_invites WHERE id = inv_revoked AND revoked_at = old_revoked;
  ASSERT n = 1, 'a2''s already revoked invite should keep its revoked_at';
  SELECT count(*) INTO n FROM agency_invites WHERE id = inv_o AND revoked_at IS NULL;
  ASSERT n = 1, 'o''s invite should be left alone';

  -- removed member sees nothing but their own row
  PERFORM set_config('request.jwt.claims', json_build_object('sub', a2, 'role','authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  SELECT count(*) INTO n FROM clients;  ASSERT n = 0, format('removed a2 clients: expected 0, got %s', n);
  SELECT count(*) INTO n FROM policies; ASSERT n = 0, format('removed a2 policies: expected 0, got %s', n);
  RESET ROLE;

  -- a1 now sees all three clients
  PERFORM set_config('request.jwt.claims', json_build_object('sub', a1, 'role','authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  SELECT count(*) INTO n FROM clients; ASSERT n = 3, format('a1 clients after remove: expected 3, got %s', n);
  RESET ROLE;
END;
$$;

SELECT 'ALL PASSED' AS result;

ROLLBACK;
