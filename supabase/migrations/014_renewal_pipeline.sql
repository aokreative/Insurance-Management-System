-- ============================================================
-- Migration 014: Renewal pipeline
--
--   1. agencies.agents_manage_renewals (Owner toggles)
--   2. Policy numbers may repeat across terms: unique only among
--      active/pending policies
--   3. policy_renewals (one row per policy term) and
--      renewal_activities (append-only history), RLS read-only
--   4. renewal_pipeline view (security_invoker)
--   5. RPCs: log_renewal_contact, record_renewal_quote,
--      mark_renewal_lost, reopen_renewal, renew_policy,
--      set_agents_manage_renewals
--   6. Reset trigger: deleting a renewal's new policy reopens it
--   7. Retire placeholder reminders (copy manual logs, delete unsent,
--      drop the auto-schedule trigger)
--   8. generate_monthly_report: renewals_renewed / _lost / rate;
--      renewals_due_30d excludes closed renewals
-- ============================================================

-- ------------------------------------------------------------
-- 1. Agency setting
-- ------------------------------------------------------------
ALTER TABLE agencies
  ADD COLUMN IF NOT EXISTS agents_manage_renewals BOOLEAN NOT NULL DEFAULT true;

-- ------------------------------------------------------------
-- 2. Policy numbers
-- ------------------------------------------------------------
ALTER TABLE policies DROP CONSTRAINT IF EXISTS policies_agency_id_policy_number_key;
CREATE UNIQUE INDEX IF NOT EXISTS policies_active_number_uniq
  ON policies (agency_id, policy_number) WHERE status IN ('active', 'pending');
CREATE INDEX IF NOT EXISTS idx_policies_agency_number ON policies (agency_id, policy_number);

-- ------------------------------------------------------------
-- 3. Tables
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS policy_renewals (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id         UUID NOT NULL REFERENCES agencies(id) ON DELETE CASCADE,
  policy_id         UUID NOT NULL UNIQUE REFERENCES policies(id) ON DELETE CASCADE,
  stage             TEXT NOT NULL DEFAULT 'to_contact'
    CHECK (stage IN ('to_contact', 'contacted', 'quoted', 'renewed', 'lost')),
  previous_stage    TEXT
    CHECK (previous_stage IN ('to_contact', 'contacted', 'quoted')),
  quoted_insurer_id UUID REFERENCES insurers(id) ON DELETE SET NULL,
  quoted_premium    NUMERIC(12,2),
  lost_reason       TEXT
    CHECK (lost_reason IN ('price', 'competitor', 'no_longer_needed', 'no_response', 'other')),
  -- not a FK: the reset trigger must still find the renewal after the
  -- new policy row is gone (FK actions would clear it first)
  renewed_policy_id UUID,
  closed_at         TIMESTAMPTZ,
  closed_by         UUID REFERENCES users(id),
  expired_by_loss   BOOLEAN NOT NULL DEFAULT false,
  last_activity_at  TIMESTAMPTZ,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_policy_renewals_agency_stage ON policy_renewals (agency_id, stage);
CREATE INDEX IF NOT EXISTS idx_policy_renewals_renewed ON policy_renewals (renewed_policy_id);

CREATE TABLE IF NOT EXISTS renewal_activities (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id     UUID NOT NULL REFERENCES agencies(id) ON DELETE CASCADE,
  renewal_id    UUID NOT NULL REFERENCES policy_renewals(id) ON DELETE CASCADE,
  kind          TEXT NOT NULL
    CHECK (kind IN ('contact', 'quote', 'renewed', 'lost', 'reopened', 'reset')),
  occurred_on   DATE NOT NULL,
  channel       TEXT CHECK (channel IN ('phone', 'whatsapp', 'sms', 'email', 'in_person')),
  insurer_id    UUID REFERENCES insurers(id) ON DELETE SET NULL,
  premium       NUMERIC(12,2),
  lost_reason   TEXT,
  new_policy_id UUID,   -- not a FK, same reason as renewed_policy_id
  note          TEXT,
  created_by    UUID REFERENCES users(id),
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_renewal_activities_renewal ON renewal_activities (renewal_id);

ALTER TABLE policy_renewals    ENABLE ROW LEVEL SECURITY;
ALTER TABLE renewal_activities ENABLE ROW LEVEL SECURITY;

CREATE POLICY policy_renewals_manage_select ON policy_renewals FOR SELECT TO authenticated
  USING (agency_id = public.current_user_agency_id() AND public.is_owner_or_manager());
CREATE POLICY policy_renewals_agent_select ON policy_renewals FOR SELECT TO authenticated
  USING (agency_id = public.current_user_agency_id()
         AND policy_id IN (SELECT id FROM policies WHERE agent_id = auth.uid()));
CREATE POLICY renewal_activities_select ON renewal_activities FOR SELECT TO authenticated
  USING (agency_id = public.current_user_agency_id()
         AND renewal_id IN (SELECT id FROM policy_renewals));

REVOKE ALL ON policy_renewals, renewal_activities FROM anon, authenticated;
GRANT SELECT ON policy_renewals, renewal_activities TO authenticated;

-- ------------------------------------------------------------
-- 4. Pipeline view
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW renewal_pipeline WITH (security_invoker = true) AS
SELECT
  p.id                AS policy_id,
  p.agency_id,
  p.policy_number,
  p.expiry_date,
  p.start_date,
  p.premium_amount,
  p.status            AS policy_status,
  p.client_id,
  c.name              AS client_name,
  c.phone             AS client_phone,
  c.email             AS client_email,
  p.insurer_id,
  i.name              AS insurer_name,
  p.product_line_id,
  pl.name             AS product_line_name,
  p.agent_id,
  u.full_name         AS agent_name,
  (p.expiry_date - (now() AT TIME ZONE 'Africa/Nairobi')::date)::int AS days_to_expiry,
  r.id                AS renewal_id,
  COALESCE(r.stage, 'to_contact') AS stage,
  r.quoted_insurer_id,
  qi.name             AS quoted_insurer_name,
  r.quoted_premium,
  r.lost_reason,
  r.renewed_policy_id,
  r.closed_at,
  r.last_activity_at
FROM policies p
LEFT JOIN policy_renewals r ON r.policy_id = p.id
LEFT JOIN clients c        ON c.id = p.client_id
LEFT JOIN insurers i       ON i.id = p.insurer_id
LEFT JOIN product_lines pl ON pl.id = p.product_line_id
LEFT JOIN users u          ON u.id = p.agent_id
LEFT JOIN insurers qi      ON qi.id = r.quoted_insurer_id
WHERE (p.status = 'active'
       AND p.expiry_date <= (now() AT TIME ZONE 'Africa/Nairobi')::date + 90
       AND COALESCE(r.stage, 'to_contact') NOT IN ('renewed', 'lost'))
   OR r.stage IN ('renewed', 'lost');

REVOKE ALL ON renewal_pipeline FROM anon, authenticated;
GRANT SELECT ON renewal_pipeline TO authenticated;

-- ------------------------------------------------------------
-- 5. RPCs
-- ------------------------------------------------------------

-- Internal: permission + window check, then lock (creating if needed)
-- the policy's renewal row. Returns the locked renewal.
CREATE OR REPLACE FUNCTION public._renewal_for_update(p_policy_id UUID)
RETURNS policy_renewals
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_agency UUID := public.current_user_agency_id();
  v_today  DATE := (now() AT TIME ZONE 'Africa/Nairobi')::date;
  v_pol    policies;
  v_ren    policy_renewals;
BEGIN
  SELECT * INTO v_pol FROM policies WHERE id = p_policy_id AND agency_id = v_agency FOR UPDATE;
  IF v_pol.id IS NULL OR v_agency IS NULL THEN
    RAISE EXCEPTION 'Policy not found' USING ERRCODE = 'P0002';
  END IF;

  IF NOT public.is_owner_or_manager() THEN
    IF NOT (SELECT agents_manage_renewals FROM agencies WHERE id = v_agency) THEN
      RAISE EXCEPTION 'Renewal updates by agents are turned off for this agency' USING ERRCODE = '42501';
    END IF;
    IF v_pol.agent_id IS DISTINCT FROM auth.uid() THEN
      RAISE EXCEPTION 'You can only update renewals for your own policies' USING ERRCODE = '42501';
    END IF;
  END IF;

  SELECT * INTO v_ren FROM policy_renewals WHERE policy_id = p_policy_id FOR UPDATE;
  IF v_ren.id IS NULL THEN
    IF v_pol.status <> 'active' OR v_pol.expiry_date > v_today + 90 THEN
      RAISE EXCEPTION 'This policy is not due for renewal';
    END IF;
    INSERT INTO policy_renewals (agency_id, policy_id)
    VALUES (v_agency, p_policy_id)
    RETURNING * INTO v_ren;
  END IF;
  RETURN v_ren;
END;
$$;

CREATE OR REPLACE FUNCTION public._renewal_assert_open(p_ren policy_renewals)
RETURNS VOID
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF p_ren.stage IN ('renewed', 'lost') THEN
    RAISE EXCEPTION 'This renewal is already closed';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.log_renewal_contact(
  p_policy_id UUID, p_channel TEXT, p_occurred_on DATE, p_note TEXT
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_ren policy_renewals;
  v_id  UUID;
BEGIN
  v_ren := public._renewal_for_update(p_policy_id);
  PERFORM public._renewal_assert_open(v_ren);
  IF p_channel IS NULL OR p_channel NOT IN ('phone', 'whatsapp', 'sms', 'email', 'in_person') THEN
    RAISE EXCEPTION 'Pick a channel';
  END IF;
  IF p_occurred_on IS NULL THEN
    RAISE EXCEPTION 'Enter the date';
  END IF;

  INSERT INTO renewal_activities (agency_id, renewal_id, kind, occurred_on, channel, note, created_by)
  VALUES (v_ren.agency_id, v_ren.id, 'contact', p_occurred_on, p_channel, NULLIF(btrim(p_note), ''), auth.uid())
  RETURNING id INTO v_id;

  UPDATE policy_renewals
     SET stage = CASE WHEN stage = 'to_contact' THEN 'contacted' ELSE stage END,
         last_activity_at = now(), updated_at = now()
   WHERE id = v_ren.id;
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.record_renewal_quote(
  p_policy_id UUID, p_insurer_id UUID, p_premium NUMERIC, p_note TEXT
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_ren policy_renewals;
  v_id  UUID;
BEGIN
  v_ren := public._renewal_for_update(p_policy_id);
  PERFORM public._renewal_assert_open(v_ren);
  IF p_insurer_id IS NULL OR NOT EXISTS
       (SELECT 1 FROM insurers WHERE id = p_insurer_id AND agency_id = v_ren.agency_id) THEN
    RAISE EXCEPTION 'Pick an insurer of this agency';
  END IF;
  IF p_premium IS NULL OR p_premium <= 0 THEN
    RAISE EXCEPTION 'Enter a premium';
  END IF;

  INSERT INTO renewal_activities (agency_id, renewal_id, kind, occurred_on, insurer_id, premium, note, created_by)
  VALUES (v_ren.agency_id, v_ren.id, 'quote', (now() AT TIME ZONE 'Africa/Nairobi')::date,
          p_insurer_id, round(p_premium, 2), NULLIF(btrim(p_note), ''), auth.uid())
  RETURNING id INTO v_id;

  UPDATE policy_renewals
     SET stage = 'quoted', quoted_insurer_id = p_insurer_id, quoted_premium = round(p_premium, 2),
         last_activity_at = now(), updated_at = now()
   WHERE id = v_ren.id;
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.mark_renewal_lost(p_policy_id UUID, p_reason TEXT, p_note TEXT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_ren     policy_renewals;
  v_today   DATE := (now() AT TIME ZONE 'Africa/Nairobi')::date;
  v_expire  BOOLEAN;
BEGIN
  v_ren := public._renewal_for_update(p_policy_id);
  PERFORM public._renewal_assert_open(v_ren);
  IF p_reason IS NULL OR p_reason NOT IN ('price', 'competitor', 'no_longer_needed', 'no_response', 'other') THEN
    RAISE EXCEPTION 'Pick a reason';
  END IF;

  SELECT status = 'active' AND expiry_date < v_today INTO v_expire FROM policies WHERE id = p_policy_id;
  IF v_expire THEN
    UPDATE policies SET status = 'expired', updated_at = now() WHERE id = p_policy_id;
  END IF;

  UPDATE policy_renewals
     SET previous_stage = stage, stage = 'lost', lost_reason = p_reason,
         closed_at = now(), closed_by = auth.uid(), expired_by_loss = COALESCE(v_expire, false),
         last_activity_at = now(), updated_at = now()
   WHERE id = v_ren.id;

  INSERT INTO renewal_activities (agency_id, renewal_id, kind, occurred_on, lost_reason, note, created_by)
  VALUES (v_ren.agency_id, v_ren.id, 'lost', v_today, p_reason, NULLIF(btrim(p_note), ''), auth.uid());
END;
$$;

CREATE OR REPLACE FUNCTION public.reopen_renewal(p_policy_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_ren policy_renewals;
BEGIN
  IF NOT COALESCE(public.is_owner_or_manager(), false) THEN
    RAISE EXCEPTION 'Only owners and managers can do that' USING ERRCODE = '42501';
  END IF;
  v_ren := public._renewal_for_update(p_policy_id);
  IF v_ren.stage <> 'lost' THEN
    RAISE EXCEPTION 'Only a lost renewal can be reopened';
  END IF;

  IF v_ren.expired_by_loss THEN
    BEGIN
      UPDATE policies SET status = 'active', updated_at = now() WHERE id = p_policy_id;
    EXCEPTION WHEN unique_violation THEN
      RAISE EXCEPTION 'That policy number is already used by an active policy';
    END;
  END IF;

  UPDATE policy_renewals
     SET stage = COALESCE(previous_stage, 'to_contact'), previous_stage = NULL,
         lost_reason = NULL, closed_at = NULL, closed_by = NULL, expired_by_loss = false,
         last_activity_at = now(), updated_at = now()
   WHERE id = v_ren.id;

  INSERT INTO renewal_activities (agency_id, renewal_id, kind, occurred_on, created_by)
  VALUES (v_ren.agency_id, v_ren.id, 'reopened', (now() AT TIME ZONE 'Africa/Nairobi')::date, auth.uid());
END;
$$;

CREATE OR REPLACE FUNCTION public.renew_policy(p_policy_id UUID, p_new JSONB)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_ren    policy_renewals;
  v_old    policies;
  v_new_id UUID;
  v_number TEXT    := NULLIF(btrim(p_new->>'policy_number'), '');
  v_ins    UUID    := NULLIF(p_new->>'insurer_id', '')::uuid;
  v_pl     UUID    := NULLIF(p_new->>'product_line_id', '')::uuid;
  v_start  DATE    := NULLIF(p_new->>'start_date', '')::date;
  v_expiry DATE    := NULLIF(p_new->>'expiry_date', '')::date;
  v_prem   NUMERIC := NULLIF(p_new->>'premium_amount', '')::numeric;
BEGIN
  v_ren := public._renewal_for_update(p_policy_id);
  PERFORM public._renewal_assert_open(v_ren);
  SELECT * INTO v_old FROM policies WHERE id = p_policy_id;

  IF v_number IS NULL THEN
    RAISE EXCEPTION 'Enter the policy number';
  END IF;
  IF v_ins IS NULL OR NOT EXISTS (SELECT 1 FROM insurers WHERE id = v_ins AND agency_id = v_old.agency_id) THEN
    RAISE EXCEPTION 'Pick an insurer of this agency';
  END IF;
  IF v_pl IS NULL OR NOT EXISTS (SELECT 1 FROM product_lines WHERE id = v_pl AND agency_id = v_old.agency_id) THEN
    RAISE EXCEPTION 'Pick a product line of this agency';
  END IF;
  IF v_prem IS NULL OR v_prem <= 0 THEN
    RAISE EXCEPTION 'Enter a premium';
  END IF;
  IF v_start IS NULL OR v_expiry IS NULL OR v_expiry <= v_start THEN
    RAISE EXCEPTION 'Expiry must be after the start date';
  END IF;

  -- the old term ends first, so the new one may reuse its number
  UPDATE policies SET status = 'expired', updated_at = now() WHERE id = p_policy_id;

  BEGIN
    INSERT INTO policies (
      agency_id, client_id, agent_id, insurer_id, product_line_id, policy_number,
      premium_amount, commission_rate, commission_basis, premium_frequency,
      instalment_premium, renewal_commission_rate, start_date, expiry_date,
      status, notes, commission_received
    ) VALUES (
      v_old.agency_id, v_old.client_id, v_old.agent_id, v_ins, v_pl, v_number,
      round(v_prem, 2),
      COALESCE(NULLIF(p_new->>'commission_rate', '')::numeric, v_old.commission_rate),
      COALESCE(NULLIF(p_new->>'commission_basis', ''), v_old.commission_basis),
      CASE WHEN p_new ? 'premium_frequency' THEN NULLIF(p_new->>'premium_frequency', '') ELSE v_old.premium_frequency END,
      CASE WHEN p_new ? 'instalment_premium' THEN NULLIF(p_new->>'instalment_premium', '')::numeric ELSE v_old.instalment_premium END,
      CASE WHEN p_new ? 'renewal_commission_rate' THEN NULLIF(p_new->>'renewal_commission_rate', '')::numeric ELSE v_old.renewal_commission_rate END,
      v_start, v_expiry, 'active', NULLIF(btrim(p_new->>'notes'), ''), 0
    )
    RETURNING id INTO v_new_id;
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'That policy number is already used by an active policy';
  END;

  UPDATE policy_renewals
     SET previous_stage = stage, stage = 'renewed', renewed_policy_id = v_new_id,
         closed_at = now(), closed_by = auth.uid(),
         last_activity_at = now(), updated_at = now()
   WHERE id = v_ren.id;

  INSERT INTO renewal_activities (agency_id, renewal_id, kind, occurred_on, insurer_id, premium, new_policy_id, created_by)
  VALUES (v_ren.agency_id, v_ren.id, 'renewed', (now() AT TIME ZONE 'Africa/Nairobi')::date,
          v_ins, round(v_prem, 2), v_new_id, auth.uid());
  RETURN v_new_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.set_agents_manage_renewals(p_enabled BOOLEAN)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF public.current_user_role() IS DISTINCT FROM 'owner' THEN
    RAISE EXCEPTION 'Only the owner can do that' USING ERRCODE = '42501';
  END IF;
  UPDATE agencies SET agents_manage_renewals = COALESCE(p_enabled, true)
   WHERE id = public.current_user_agency_id();
END;
$$;

-- ------------------------------------------------------------
-- 6. Reset trigger: the new policy of a renewal was deleted
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.policy_renewal_reset()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_ren policy_renewals;
BEGIN
  SELECT * INTO v_ren FROM policy_renewals
   WHERE renewed_policy_id = OLD.id AND stage = 'renewed'
   FOR UPDATE;
  IF v_ren.id IS NULL THEN
    RETURN NULL;
  END IF;

  UPDATE policy_renewals
     SET stage = COALESCE(previous_stage, 'to_contact'), previous_stage = NULL,
         renewed_policy_id = NULL, closed_at = NULL, closed_by = NULL,
         last_activity_at = now(), updated_at = now()
   WHERE id = v_ren.id;

  UPDATE policies SET status = 'active', updated_at = now()
   WHERE id = v_ren.policy_id AND status = 'expired';

  INSERT INTO renewal_activities (agency_id, renewal_id, kind, occurred_on, new_policy_id, created_by)
  VALUES (v_ren.agency_id, v_ren.id, 'reset', (now() AT TIME ZONE 'Africa/Nairobi')::date, OLD.id, auth.uid());
  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_policy_renewal_reset ON policies;
CREATE TRIGGER trg_policy_renewal_reset
  AFTER DELETE ON policies
  FOR EACH ROW EXECUTE FUNCTION public.policy_renewal_reset();

-- ------------------------------------------------------------
-- 7. Retire placeholder reminders
-- ------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_auto_renewal_reminders ON policies;
DROP FUNCTION IF EXISTS public.auto_create_renewal_reminders();

-- Copies manually logged reminders (sent = true) into the history as
-- contacts, then deletes every reminder row: sent ones are now in
-- renewal_activities, unsent ones were placeholders nobody sent.
CREATE OR REPLACE FUNCTION public._migrate_renewal_reminders()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_rem    renewal_reminders;
  v_ren_id UUID;
  v_count  INTEGER := 0;
BEGIN
  FOR v_rem IN SELECT * FROM renewal_reminders WHERE sent ORDER BY reminder_date, created_at LOOP
    INSERT INTO policy_renewals (agency_id, policy_id, stage, last_activity_at)
    SELECT p.agency_id, p.id, 'contacted', COALESCE(v_rem.sent_at, v_rem.created_at)
      FROM policies p WHERE p.id = v_rem.policy_id
    ON CONFLICT (policy_id) DO UPDATE
      SET stage = CASE WHEN policy_renewals.stage = 'to_contact' THEN 'contacted' ELSE policy_renewals.stage END,
          last_activity_at = GREATEST(policy_renewals.last_activity_at, EXCLUDED.last_activity_at)
    RETURNING id INTO v_ren_id;

    INSERT INTO renewal_activities (agency_id, renewal_id, kind, occurred_on, channel, note, created_at)
    VALUES (v_rem.agency_id, v_ren_id, 'contact', v_rem.reminder_date, v_rem.channel, v_rem.notes,
            COALESCE(v_rem.sent_at, v_rem.created_at, now()));
    v_count := v_count + 1;
  END LOOP;

  DELETE FROM renewal_reminders;
  RETURN v_count;
END;
$$;

SELECT public._migrate_renewal_reminders();

-- ------------------------------------------------------------
-- 8. generate_monthly_report (full source from now on; supersedes 012)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.generate_monthly_report(
  p_month INTEGER DEFAULT NULL,
  p_year  INTEGER DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public
AS $$
DECLARE
  v_agency_id  UUID := public.current_user_agency_id();
  v_role       TEXT := public.current_user_role();
  v_prev       DATE := (date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::DATE;
  v_month      INTEGER := COALESCE(p_month, EXTRACT(MONTH FROM v_prev)::INTEGER);
  v_year       INTEGER := COALESCE(p_year,  EXTRACT(YEAR  FROM v_prev)::INTEGER);
  v_start      DATE;
  v_end        DATE;
  v_written    INTEGER;
  v_premium    NUMERIC;
  v_expected   NUMERIC;
  v_received   NUMERIC;
  v_renewed    INTEGER;
  v_lost       INTEGER;
  v_metadata   JSONB;
  v_report     reports;
BEGIN
  IF v_agency_id IS NULL THEN
    RAISE EXCEPTION 'No profile found' USING ERRCODE = '42501';
  END IF;
  IF v_role NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'Only owners and managers can generate reports' USING ERRCODE = '42501';
  END IF;
  IF v_month NOT BETWEEN 1 AND 12 OR v_year < 2020 THEN
    RAISE EXCEPTION 'Invalid report period' USING ERRCODE = '22023';
  END IF;

  v_start := make_date(v_year, v_month, 1);
  v_end   := (v_start + INTERVAL '1 month' - INTERVAL '1 day')::DATE;

  SELECT COUNT(*), COALESCE(SUM(premium_amount), 0), COALESCE(SUM(commission_expected), 0)
    INTO v_written, v_premium, v_expected
    FROM policies
   WHERE agency_id = v_agency_id
     AND start_date BETWEEN v_start AND v_end;

  SELECT COALESCE(SUM(a.amount), 0)
    INTO v_received
    FROM commission_allocations a
    JOIN insurer_receipts r ON r.id = a.receipt_id
   WHERE a.agency_id = v_agency_id
     AND r.agency_id = v_agency_id
     AND r.received_on BETWEEN v_start AND v_end;

  SELECT COUNT(*) FILTER (WHERE stage = 'renewed'), COUNT(*) FILTER (WHERE stage = 'lost')
    INTO v_renewed, v_lost
    FROM policy_renewals
   WHERE agency_id = v_agency_id
     AND stage IN ('renewed', 'lost')
     AND (closed_at AT TIME ZONE 'Africa/Nairobi')::date BETWEEN v_start AND v_end;

  v_metadata := jsonb_build_object(
    'month',                   v_month,
    'year',                    v_year,
    'total_policies_written',  v_written,
    'total_premium_kes',       v_premium,
    'commission_expected_kes', v_expected,
    'commission_received_kes', v_received,
    'collection_rate_pct',     CASE WHEN v_expected > 0
                                    THEN ROUND(v_received / v_expected * 100, 1)
                                    ELSE 0 END,
    'new_clients',             (SELECT COUNT(*) FROM clients
                                 WHERE agency_id = v_agency_id
                                   AND created_at >= v_start AND created_at < v_end + 1),
    'renewals_due_30d',        (SELECT COUNT(*) FROM policies p
                                 WHERE p.agency_id = v_agency_id AND p.status = 'active'
                                   AND p.expiry_date BETWEEN CURRENT_DATE AND CURRENT_DATE + 30
                                   AND NOT EXISTS (SELECT 1 FROM policy_renewals r
                                                    WHERE r.policy_id = p.id
                                                      AND r.stage IN ('renewed', 'lost'))),
    'renewals_renewed',        v_renewed,
    'renewals_lost',           v_lost,
    'renewal_rate',            CASE WHEN v_renewed + v_lost > 0
                                    THEN ROUND(v_renewed * 100.0 / (v_renewed + v_lost), 1)
                                    ELSE NULL END,
    'portfolio_active',        (SELECT COUNT(*) FROM policies WHERE agency_id = v_agency_id AND status = 'active'),
    'portfolio_expired',       (SELECT COUNT(*) FROM policies WHERE agency_id = v_agency_id AND status = 'expired'),
    'portfolio_cancelled',     (SELECT COUNT(*) FROM policies WHERE agency_id = v_agency_id AND status = 'cancelled'),
    'generated_at',            NOW()
  );

  INSERT INTO reports (agency_id, month, year, metadata, generated_at)
  VALUES (v_agency_id, v_month, v_year, v_metadata, NOW())
  RETURNING * INTO v_report;

  RETURN jsonb_build_object('report', to_jsonb(v_report), 'metadata', v_metadata);
END;
$$;

-- ------------------------------------------------------------
-- Grants
-- ------------------------------------------------------------
REVOKE EXECUTE ON FUNCTION public._renewal_for_update(UUID)            FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public._renewal_assert_open(policy_renewals) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.policy_renewal_reset()               FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public._migrate_renewal_reminders()         FROM PUBLIC, anon, authenticated;

REVOKE EXECUTE ON FUNCTION public.log_renewal_contact(UUID, TEXT, DATE, TEXT)      FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.record_renewal_quote(UUID, UUID, NUMERIC, TEXT)  FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.mark_renewal_lost(UUID, TEXT, TEXT)              FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.reopen_renewal(UUID)                             FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.renew_policy(UUID, JSONB)                        FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.set_agents_manage_renewals(BOOLEAN)              FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.log_renewal_contact(UUID, TEXT, DATE, TEXT)      TO authenticated;
GRANT  EXECUTE ON FUNCTION public.record_renewal_quote(UUID, UUID, NUMERIC, TEXT)  TO authenticated;
GRANT  EXECUTE ON FUNCTION public.mark_renewal_lost(UUID, TEXT, TEXT)              TO authenticated;
GRANT  EXECUTE ON FUNCTION public.reopen_renewal(UUID)                             TO authenticated;
GRANT  EXECUTE ON FUNCTION public.renew_policy(UUID, JSONB)                        TO authenticated;
GRANT  EXECUTE ON FUNCTION public.set_agents_manage_renewals(BOOLEAN)              TO authenticated;
REVOKE EXECUTE ON FUNCTION public.generate_monthly_report(INTEGER, INTEGER) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.generate_monthly_report(INTEGER, INTEGER) TO authenticated;
