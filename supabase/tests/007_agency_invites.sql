-- ============================================================
-- Test 007: agency invites (create / preview / accept / revoke).
--
-- Run the whole file in one go (Supabase SQL editor / execute_sql).
-- Everything happens inside one transaction that is ALWAYS rolled
-- back: on success the final SELECT returns 'ALL PASSED'; on any
-- failed ASSERT the batch aborts and nothing is committed.
--
-- Same impersonation pattern as test 006. Expected errors are
-- caught by SQLSTATE (raise_exception = P0001, insufficient_privilege
-- = 42501) and the message text is asserted, because the UI shows it.
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
  nu   UUID := gen_random_uuid();   -- new@test.local, no users row
  nu3  UUID := gen_random_uuid();   -- new3@test.local, no users row
  oth  UUID := gen_random_uuid();   -- other@test.local, no users row
  r    JSONB;
  inv_mgr   JSONB;
  inv_agent JSONB;
  inv_new   JSONB;
  inv_new2  JSONB;
  inv_new3  JSONB;
  inv_m     JSONB;
  inv_a2    JSONB;
  v_text TEXT;
  v_hash TEXT;
  n      INTEGER;
BEGIN
  -- ---------------------------------------------------------
  -- Fixture (as superuser)
  -- ---------------------------------------------------------
  INSERT INTO auth.users (id, email, aud, role, instance_id) VALUES
    (o,   'o-007@test.local',  'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000'),
    (m,   'm-007@test.local',  'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000'),
    (a1,  'a1-007@test.local', 'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000'),
    (a2,  'a2-007@test.local', 'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000'),
    (d,   'd-007@test.local',  'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000'),
    (o2,  'o2-007@test.local', 'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000'),
    (nu,  'new@test.local',    'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000'),
    (nu3, 'New3@Test.local',   'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000'),
    (oth, 'other@test.local',  'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000');

  INSERT INTO agencies (id, name) VALUES (ag, 'Test Agency 007'), (ag2, 'Other Agency 007');

  INSERT INTO users (id, agency_id, role, full_name, email, deactivated_at) VALUES
    (o,  ag,  'owner',   'Owner 007',   'o-007@test.local',  NULL),
    (m,  ag,  'manager', 'Manager 007', 'm-007@test.local',  NULL),
    (a1, ag,  'agent',   'Agent1 007',  'a1-007@test.local', NULL),
    (a2, ag,  'agent',   'Agent2 007',  'a2-007@test.local', NULL),
    (d,  ag,  'agent',   'Gone 007',    'd-007@test.local',  now()),
    (o2, ag2, 'owner',   'Owner2 007',  'o2-007@test.local', NULL);

  -- ---------------------------------------------------------
  -- create_invite: who may invite which role
  -- ---------------------------------------------------------
  PERFORM set_config('request.jwt.claims', json_build_object('sub', o, 'role','authenticated')::text, true);
  SET LOCAL ROLE authenticated;

  inv_mgr   := public.create_invite('mgr@test.local', 'manager');
  inv_agent := public.create_invite('agent@test.local', 'agent');
  ASSERT length(inv_mgr->>'code') = 64,   format('o manager invite: code length %s', length(inv_mgr->>'code'));
  ASSERT length(inv_agent->>'code') = 64, format('o agent invite: code length %s', length(inv_agent->>'code'));
  ASSERT inv_mgr->>'code' ~ '^[0-9a-f]{64}$', 'o manager invite: code should be lowercase hex';
  ASSERT inv_mgr->>'invite_id' IS NOT NULL, 'o manager invite: invite_id missing';
  ASSERT (inv_mgr->>'expires_at')::timestamptz > now() + interval '6 days',
    'o manager invite: expires_at should be ~7 days out';

  BEGIN
    PERFORM public.create_invite('owner2@test.local', 'owner');
    RAISE EXCEPTION 'FAIL: o invited an owner';
  EXCEPTION WHEN insufficient_privilege THEN
    GET STACKED DIAGNOSTICS v_text = MESSAGE_TEXT;
    ASSERT v_text = 'You are not allowed to invite that role', format('o invite owner: got %s', v_text);
  END;

  BEGIN
    PERFORM public.create_invite('no-at-sign', 'agent');
    RAISE EXCEPTION 'FAIL: invite with invalid email accepted';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS v_text = MESSAGE_TEXT;
    ASSERT v_text = 'Enter a valid email address', format('invalid email: got %s', v_text);
  END;

  -- existing member (any case / spacing)
  BEGIN
    PERFORM public.create_invite('  A1-007@Test.Local ', 'agent');
    RAISE EXCEPTION 'FAIL: o invited an existing member';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS v_text = MESSAGE_TEXT;
    ASSERT v_text = 'That person is already a member of this agency', format('invite member: got %s', v_text);
  END;

  -- deactivated member counts as a member
  BEGIN
    PERFORM public.create_invite('d-007@test.local', 'agent');
    RAISE EXCEPTION 'FAIL: o invited a deactivated member';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS v_text = MESSAGE_TEXT;
    ASSERT v_text = 'That person is already a member of this agency', format('invite deactivated member: got %s', v_text);
  END;

  -- duplicate live invite
  BEGIN
    PERFORM public.create_invite('Agent@test.local', 'manager');
    RAISE EXCEPTION 'FAIL: duplicate pending invite created';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS v_text = MESSAGE_TEXT;
    ASSERT v_text = 'There is already a pending invite for this email', format('duplicate invite: got %s', v_text);
  END;

  -- invite for new@test.local stored normalised
  inv_new  := public.create_invite(' New@Test.local ', 'agent');
  inv_new2 := public.create_invite('new2@test.local', 'agent');
  inv_new3 := public.create_invite('new3@test.local', 'manager');

  -- owner/manager can read the agency's invites, but never token_hash
  SELECT count(*) INTO n FROM agency_invites;
  ASSERT n = 5, format('o invites visible: expected 5, got %s', n);
  SELECT email INTO v_text FROM agency_invites WHERE id = (inv_new->>'invite_id')::uuid;
  ASSERT v_text = 'new@test.local', format('stored email: expected new@test.local, got %s', v_text);
  BEGIN
    SELECT token_hash INTO v_text FROM agency_invites LIMIT 1;
    RAISE EXCEPTION 'FAIL: o read token_hash';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  RESET ROLE;

  -- stored hash is sha256(code), never the code
  SELECT token_hash INTO v_hash FROM agency_invites WHERE id = (inv_mgr->>'invite_id')::uuid;
  ASSERT v_hash <> inv_mgr->>'code', 'token_hash must not equal the code';
  ASSERT v_hash = encode(extensions.digest(inv_mgr->>'code', 'sha256'), 'hex'), 'token_hash must be sha256(code)';

  -- Manager: agent yes, manager no
  PERFORM set_config('request.jwt.claims', json_build_object('sub', m, 'role','authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  BEGIN
    PERFORM public.create_invite('mgr2@test.local', 'manager');
    RAISE EXCEPTION 'FAIL: m invited a manager';
  EXCEPTION WHEN insufficient_privilege THEN
    GET STACKED DIAGNOSTICS v_text = MESSAGE_TEXT;
    ASSERT v_text = 'You are not allowed to invite that role', format('m invite manager: got %s', v_text);
  END;
  inv_m := public.create_invite('m-agent@test.local', 'agent');
  ASSERT length(inv_m->>'code') = 64, 'm agent invite: code length';
  SELECT count(*) INTO n FROM agency_invites;
  ASSERT n = 6, format('m invites visible: expected 6, got %s', n);
  RESET ROLE;

  -- Agent: nothing
  PERFORM set_config('request.jwt.claims', json_build_object('sub', a1, 'role','authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  BEGIN
    PERFORM public.create_invite('x@test.local', 'agent');
    RAISE EXCEPTION 'FAIL: a1 invited someone';
  EXCEPTION WHEN insufficient_privilege THEN
    GET STACKED DIAGNOSTICS v_text = MESSAGE_TEXT;
    ASSERT v_text = 'You are not allowed to invite that role', format('a1 invite: got %s', v_text);
  END;
  SELECT count(*) INTO n FROM agency_invites;
  ASSERT n = 0, format('a1 invites visible: expected 0, got %s', n);
  BEGIN
    INSERT INTO agency_invites (agency_id, email, role, token_hash, invited_by, expires_at)
    VALUES (ag, 'sneaky@test.local', 'agent', repeat('0', 64), a1, now() + interval '7 days');
    RAISE EXCEPTION 'FAIL: a1 inserted an invite directly';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  RESET ROLE;

  -- Deactivated member: cannot invite
  PERFORM set_config('request.jwt.claims', json_build_object('sub', d, 'role','authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  BEGIN
    PERFORM public.create_invite('y@test.local', 'agent');
    RAISE EXCEPTION 'FAIL: deactivated member invited someone';
  EXCEPTION WHEN insufficient_privilege THEN
    GET STACKED DIAGNOSTICS v_text = MESSAGE_TEXT;
    ASSERT v_text = 'You are not allowed to invite that role', format('deactivated invite: got %s', v_text);
  END;
  RESET ROLE;

  -- ---------------------------------------------------------
  -- revoke_invite
  -- ---------------------------------------------------------
  PERFORM set_config('request.jwt.claims', json_build_object('sub', m, 'role','authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  PERFORM public.revoke_invite((inv_m->>'invite_id')::uuid);
  BEGIN
    PERFORM public.revoke_invite((inv_mgr->>'invite_id')::uuid);
    RAISE EXCEPTION 'FAIL: m revoked a manager invite';
  EXCEPTION WHEN insufficient_privilege THEN
    GET STACKED DIAGNOSTICS v_text = MESSAGE_TEXT;
    ASSERT v_text = 'You are not allowed to revoke that invite', format('m revoke manager invite: got %s', v_text);
  END;
  BEGIN
    PERFORM public.revoke_invite((inv_m->>'invite_id')::uuid);
    RAISE EXCEPTION 'FAIL: revoked the same invite twice';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS v_text = MESSAGE_TEXT;
    ASSERT v_text = 'Invalid or expired invite', format('double revoke: got %s', v_text);
  END;
  RESET ROLE;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', a1, 'role','authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  BEGIN
    PERFORM public.revoke_invite((inv_agent->>'invite_id')::uuid);
    RAISE EXCEPTION 'FAIL: a1 revoked an invite';
  EXCEPTION WHEN insufficient_privilege THEN
    GET STACKED DIAGNOSTICS v_text = MESSAGE_TEXT;
    ASSERT v_text = 'You are not allowed to revoke that invite', format('a1 revoke: got %s', v_text);
  END;
  RESET ROLE;

  -- Owner of another agency: cannot see or revoke ag's invites
  PERFORM set_config('request.jwt.claims', json_build_object('sub', o2, 'role','authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  SELECT count(*) INTO n FROM agency_invites;
  ASSERT n = 0, format('o2 invites visible: expected 0, got %s', n);
  BEGIN
    PERFORM public.revoke_invite((inv_agent->>'invite_id')::uuid);
    RAISE EXCEPTION 'FAIL: o2 revoked another agency''s invite';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS v_text = MESSAGE_TEXT;
    ASSERT v_text = 'Invalid or expired invite', format('o2 revoke: got %s', v_text);
  END;
  -- o2 invites a2 (a member of ag, not of ag2) for the "already in an agency" test
  inv_a2 := public.create_invite('a2-007@test.local', 'agent');
  RESET ROLE;

  SELECT count(*) INTO n FROM agency_invites WHERE id = (inv_agent->>'invite_id')::uuid AND revoked_at IS NULL;
  ASSERT n = 1, 'failed revokes must not change the invite';

  -- ---------------------------------------------------------
  -- get_invite_preview (anon)
  -- ---------------------------------------------------------
  PERFORM set_config('request.jwt.claims', json_build_object('role','anon')::text, true);
  SET LOCAL ROLE anon;

  r := public.get_invite_preview(inv_new->>'code');
  ASSERT r->>'agency_name' = 'Test Agency 007', format('preview agency_name: got %s', r->>'agency_name');
  ASSERT r->>'role' = 'agent', format('preview role: got %s', r->>'role');
  ASSERT r->>'email' = 'new@test.local', format('preview email: got %s', r->>'email');

  -- upper-case code is accepted (lower() first)
  r := public.get_invite_preview(upper(inv_new->>'code'));
  ASSERT r->>'email' = 'new@test.local', 'preview of upper-cased code should work';

  BEGIN
    PERFORM public.get_invite_preview('garbage');
    RAISE EXCEPTION 'FAIL: preview of garbage';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS v_text = MESSAGE_TEXT;
    ASSERT v_text = 'Invalid or expired invite', format('preview garbage: got %s', v_text);
  END;
  BEGIN
    PERFORM public.get_invite_preview('');
    RAISE EXCEPTION 'FAIL: preview of empty code';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS v_text = MESSAGE_TEXT;
    ASSERT v_text = 'Invalid or expired invite', format('preview empty: got %s', v_text);
  END;
  BEGIN
    PERFORM public.get_invite_preview(NULL);
    RAISE EXCEPTION 'FAIL: preview of NULL code';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS v_text = MESSAGE_TEXT;
    ASSERT v_text = 'Invalid or expired invite', format('preview NULL: got %s', v_text);
  END;
  BEGIN
    PERFORM public.get_invite_preview(repeat('a', 64));
    RAISE EXCEPTION 'FAIL: preview of unknown code';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS v_text = MESSAGE_TEXT;
    ASSERT v_text = 'Invalid or expired invite', format('preview unknown: got %s', v_text);
  END;
  BEGIN
    PERFORM public.get_invite_preview(inv_m->>'code');
    RAISE EXCEPTION 'FAIL: preview of revoked code';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS v_text = MESSAGE_TEXT;
    ASSERT v_text = 'Invalid or expired invite', format('preview revoked: got %s', v_text);
  END;

  -- anon cannot use the other RPCs or read the table
  BEGIN
    PERFORM public.accept_invite(inv_new->>'code', 'Anon Person');
    RAISE EXCEPTION 'FAIL: anon called accept_invite';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM public.create_invite('z@test.local', 'agent');
    RAISE EXCEPTION 'FAIL: anon called create_invite';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    SELECT count(*) INTO n FROM agency_invites;
    RAISE EXCEPTION 'FAIL: anon read agency_invites';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  RESET ROLE;

  -- ---------------------------------------------------------
  -- accept_invite
  -- ---------------------------------------------------------
  -- wrong email
  PERFORM set_config('request.jwt.claims', json_build_object('sub', oth, 'role','authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  BEGIN
    PERFORM public.accept_invite(inv_new2->>'code', 'Other Person');
    RAISE EXCEPTION 'FAIL: other@ accepted new2@ invite';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS v_text = MESSAGE_TEXT;
    ASSERT v_text = 'This invite is for a different email address', format('wrong email: got %s', v_text);
  END;
  RESET ROLE;

  -- already in an agency (a2 is in ag; o2's invite is for ag2)
  PERFORM set_config('request.jwt.claims', json_build_object('sub', a2, 'role','authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  BEGIN
    PERFORM public.accept_invite(inv_a2->>'code', 'Agent2 007');
    RAISE EXCEPTION 'FAIL: a2 joined a second agency';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS v_text = MESSAGE_TEXT;
    ASSERT v_text = 'This account already belongs to an agency', format('already member: got %s', v_text);
  END;
  RESET ROLE;

  -- success: new@test.local accepts the invite created for ' New@Test.local '
  PERFORM set_config('request.jwt.claims', json_build_object('sub', nu, 'role','authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  BEGIN
    PERFORM public.accept_invite(inv_new->>'code', ' x ');
    RAISE EXCEPTION 'FAIL: accepted with a 1-char name';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS v_text = MESSAGE_TEXT;
    ASSERT v_text = 'Enter your full name', format('short name: got %s', v_text);
  END;
  BEGIN
    PERFORM public.accept_invite('garbage', 'New Person');
    RAISE EXCEPTION 'FAIL: accepted a garbage code';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS v_text = MESSAGE_TEXT;
    ASSERT v_text = 'Invalid or expired invite', format('accept garbage: got %s', v_text);
  END;

  r := public.accept_invite(inv_new->>'code', '  New Person  ');
  ASSERT (r->>'agency_id')::uuid = ag, format('accept agency_id: got %s', r->>'agency_id');
  ASSERT r->>'role' = 'agent', format('accept role: got %s', r->>'role');
  ASSERT public.current_user_agency_id() = ag, 'new member: current_user_agency_id() should be ag';
  ASSERT public.current_user_role() = 'agent', 'new member: current_user_role() should be agent';

  BEGIN
    PERFORM public.accept_invite(inv_new->>'code', 'New Person');
    RAISE EXCEPTION 'FAIL: accepted the same code twice';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS v_text = MESSAGE_TEXT;
    ASSERT v_text = 'Invalid or expired invite', format('reuse: got %s', v_text);
  END;
  RESET ROLE;

  SELECT count(*) INTO n FROM users
   WHERE id = nu AND agency_id = ag AND role = 'agent' AND full_name = 'New Person'
     AND email = 'new@test.local' AND deactivated_at IS NULL;
  ASSERT n = 1, 'accepted user row: wrong or missing';
  SELECT count(*) INTO n FROM agency_invites
   WHERE id = (inv_new->>'invite_id')::uuid AND accepted_at IS NOT NULL AND accepted_by = nu;
  ASSERT n = 1, 'accepted invite: accepted_at/accepted_by not set';

  -- accepted code no longer previews
  PERFORM set_config('request.jwt.claims', json_build_object('role','anon')::text, true);
  SET LOCAL ROLE anon;
  BEGIN
    PERFORM public.get_invite_preview(inv_new->>'code');
    RAISE EXCEPTION 'FAIL: preview of accepted code';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS v_text = MESSAGE_TEXT;
    ASSERT v_text = 'Invalid or expired invite', format('preview accepted: got %s', v_text);
  END;
  RESET ROLE;

  -- revoking an accepted invite
  PERFORM set_config('request.jwt.claims', json_build_object('sub', o, 'role','authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  BEGIN
    PERFORM public.revoke_invite((inv_new->>'invite_id')::uuid);
    RAISE EXCEPTION 'FAIL: revoked an accepted invite';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS v_text = MESSAGE_TEXT;
    ASSERT v_text = 'Invalid or expired invite', format('revoke accepted: got %s', v_text);
  END;
  -- owner can revoke a manager invite
  PERFORM public.revoke_invite((inv_mgr->>'invite_id')::uuid);
  RESET ROLE;
  SELECT count(*) INTO n FROM agency_invites WHERE id = (inv_mgr->>'invite_id')::uuid AND revoked_at IS NOT NULL;
  ASSERT n = 1, 'owner revoke: revoked_at not set';

  -- expired invite (new3@ invite forced into the past)
  UPDATE agency_invites SET expires_at = now() - interval '1 minute'
   WHERE id = (inv_new3->>'invite_id')::uuid;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', nu3, 'role','authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  BEGIN
    PERFORM public.accept_invite(inv_new3->>'code', 'New Three');
    RAISE EXCEPTION 'FAIL: accepted an expired invite';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS v_text = MESSAGE_TEXT;
    ASSERT v_text = 'Invalid or expired invite', format('expired: got %s', v_text);
  END;
  RESET ROLE;

  -- an expired invite does not block re-inviting; the auth email
  -- 'New3@Test.local' matches the stored 'new3@test.local'
  PERFORM set_config('request.jwt.claims', json_build_object('sub', o, 'role','authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  inv_new3 := public.create_invite('new3@test.local', 'manager');
  RESET ROLE;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', nu3, 'role','authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  r := public.accept_invite(inv_new3->>'code', 'New Three');
  ASSERT r->>'role' = 'manager', format('re-invite accept role: got %s', r->>'role');
  RESET ROLE;
END;
$$;

SELECT 'ALL PASSED' AS result;

ROLLBACK;
