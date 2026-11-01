-- ============================================================
-- Migration 006: Team & access control
--
-- Roles become owner | manager | agent (admin -> manager).
-- Members can be deactivated: the RLS helpers return NULL for a
-- deactivated user, so every agency-scoped policy denies them.
-- Clients get an assigned agent; Agents see and edit only their
-- assigned clients, their own policies, and (read-only) the
-- commissions and reminders on those policies. Owner/Manager see
-- the whole agency. Only the Owner edits agency settings.
-- Team membership changes (insert/role/deactivate) go through
-- SECURITY DEFINER RPCs added in later migrations, so `users`
-- has no direct write policies.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Roles: admin -> manager
-- ------------------------------------------------------------
ALTER TABLE users DROP CONSTRAINT IF EXISTS users_role_check;
UPDATE users SET role = 'manager' WHERE role = 'admin';
ALTER TABLE users ADD CONSTRAINT users_role_check
  CHECK (role IN ('owner', 'manager', 'agent'));

-- ------------------------------------------------------------
-- 2. Deactivation + RLS helpers
-- ------------------------------------------------------------
ALTER TABLE users ADD COLUMN IF NOT EXISTS deactivated_at TIMESTAMPTZ;

-- CREATE OR REPLACE keeps the existing EXECUTE grants: policies
-- evaluate these for every role, and for anon they return NULL.
CREATE OR REPLACE FUNCTION public.current_user_agency_id()
RETURNS UUID
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT agency_id FROM users WHERE id = auth.uid() AND deactivated_at IS NULL;
$$;

CREATE OR REPLACE FUNCTION public.current_user_role()
RETURNS TEXT
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT role FROM users WHERE id = auth.uid() AND deactivated_at IS NULL;
$$;

CREATE OR REPLACE FUNCTION public.is_owner_or_manager()
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(public.current_user_role() IN ('owner', 'manager'), false);
$$;

REVOKE EXECUTE ON FUNCTION public.is_owner_or_manager() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.is_owner_or_manager() TO authenticated;

-- ------------------------------------------------------------
-- 3. Client assignment
-- ------------------------------------------------------------
ALTER TABLE clients ADD COLUMN IF NOT EXISTS assigned_agent_id UUID REFERENCES users(id);

-- Existing clients go to their agency's owner
UPDATE clients c
   SET assigned_agent_id = (
     SELECT u.id FROM users u
      WHERE u.agency_id = c.agency_id AND u.role = 'owner'
      ORDER BY u.created_at
      LIMIT 1)
 WHERE c.assigned_agent_id IS NULL;

ALTER TABLE clients ALTER COLUMN assigned_agent_id SET NOT NULL;
ALTER TABLE clients ALTER COLUMN assigned_agent_id SET DEFAULT auth.uid();
CREATE INDEX IF NOT EXISTS idx_clients_assigned_agent_id ON clients(assigned_agent_id);

-- ------------------------------------------------------------
-- 4. RLS: drop every existing policy and recreate per the matrix
-- ------------------------------------------------------------
DO $$
DECLARE
  r RECORD;
BEGIN
  FOR r IN
    SELECT tablename, policyname FROM pg_policies
     WHERE schemaname = 'public'
       AND tablename IN ('agencies', 'users', 'clients', 'policies',
                         'commission_transactions', 'renewal_reminders',
                         'reports', 'insurers', 'product_lines')
  LOOP
    EXECUTE format('DROP POLICY %I ON public.%I', r.policyname, r.tablename);
  END LOOP;
END;
$$;

-- agencies: members read; only the Owner edits settings/branding
CREATE POLICY agencies_select ON agencies FOR SELECT TO authenticated
  USING (id = public.current_user_agency_id());
CREATE POLICY agencies_update_owner ON agencies FOR UPDATE TO authenticated
  USING      (id = public.current_user_agency_id() AND public.current_user_role() = 'owner')
  WITH CHECK (id = public.current_user_agency_id() AND public.current_user_role() = 'owner');

-- users: own row always (a deactivated user can still read it, so the
-- app can show "access removed"); Owner/Manager see the whole team.
-- No direct writes: membership changes go through RPCs.
CREATE POLICY users_select ON users FOR SELECT TO authenticated
  USING (id = auth.uid()
         OR (public.is_owner_or_manager() AND agency_id = public.current_user_agency_id()));

-- clients
CREATE POLICY clients_manage ON clients FOR ALL TO authenticated
  USING (agency_id = public.current_user_agency_id() AND public.is_owner_or_manager())
  WITH CHECK (agency_id = public.current_user_agency_id() AND public.is_owner_or_manager()
              AND assigned_agent_id IN (SELECT id FROM users WHERE agency_id = public.current_user_agency_id()));
CREATE POLICY clients_agent_select ON clients FOR SELECT TO authenticated
  USING (agency_id = public.current_user_agency_id() AND assigned_agent_id = auth.uid());
CREATE POLICY clients_agent_insert ON clients FOR INSERT TO authenticated
  WITH CHECK (agency_id = public.current_user_agency_id() AND assigned_agent_id = auth.uid());
CREATE POLICY clients_agent_update ON clients FOR UPDATE TO authenticated
  USING      (agency_id = public.current_user_agency_id() AND assigned_agent_id = auth.uid())
  WITH CHECK (agency_id = public.current_user_agency_id() AND assigned_agent_id = auth.uid());

-- policies: agents keep seeing their own policies (history) even after the
-- client is reassigned away, but can only write rows that are theirs AND on
-- a client assigned to them.
CREATE POLICY policies_manage ON policies FOR ALL TO authenticated
  USING      (agency_id = public.current_user_agency_id() AND public.is_owner_or_manager())
  WITH CHECK (agency_id = public.current_user_agency_id() AND public.is_owner_or_manager());
CREATE POLICY policies_agent_select ON policies FOR SELECT TO authenticated
  USING (agency_id = public.current_user_agency_id() AND agent_id = auth.uid());
CREATE POLICY policies_agent_insert ON policies FOR INSERT TO authenticated
  WITH CHECK (agency_id = public.current_user_agency_id()
              AND agent_id = auth.uid()
              AND client_id IN (SELECT id FROM clients WHERE assigned_agent_id = auth.uid()));
CREATE POLICY policies_agent_update ON policies FOR UPDATE TO authenticated
  USING      (agency_id = public.current_user_agency_id()
              AND agent_id = auth.uid()
              AND client_id IN (SELECT id FROM clients WHERE assigned_agent_id = auth.uid()))
  WITH CHECK (agency_id = public.current_user_agency_id()
              AND agent_id = auth.uid()
              AND client_id IN (SELECT id FROM clients WHERE assigned_agent_id = auth.uid()));

-- commission_transactions: Owner/Manager full (mark received); agents read own
CREATE POLICY commission_tx_manage ON commission_transactions FOR ALL TO authenticated
  USING      (agency_id = public.current_user_agency_id() AND public.is_owner_or_manager())
  WITH CHECK (agency_id = public.current_user_agency_id() AND public.is_owner_or_manager());
CREATE POLICY commission_tx_agent_select ON commission_transactions FOR SELECT TO authenticated
  USING (agency_id = public.current_user_agency_id()
         AND policy_id IN (SELECT id FROM policies WHERE agent_id = auth.uid()));

-- renewal_reminders: same shape (the policy-insert trigger is SECURITY
-- DEFINER, so agents' new policies still get reminders)
CREATE POLICY renewal_reminders_manage ON renewal_reminders FOR ALL TO authenticated
  USING      (agency_id = public.current_user_agency_id() AND public.is_owner_or_manager())
  WITH CHECK (agency_id = public.current_user_agency_id() AND public.is_owner_or_manager());
CREATE POLICY renewal_reminders_agent_select ON renewal_reminders FOR SELECT TO authenticated
  USING (agency_id = public.current_user_agency_id()
         AND policy_id IN (SELECT id FROM policies WHERE agent_id = auth.uid()));

-- reports: Owner/Manager only
CREATE POLICY reports_manage ON reports FOR ALL TO authenticated
  USING      (agency_id = public.current_user_agency_id() AND public.is_owner_or_manager())
  WITH CHECK (agency_id = public.current_user_agency_id() AND public.is_owner_or_manager());

-- insurers / product_lines: everyone reads, Owner/Manager edit
CREATE POLICY insurers_select ON insurers FOR SELECT TO authenticated
  USING (agency_id = public.current_user_agency_id());
CREATE POLICY insurers_manage ON insurers FOR ALL TO authenticated
  USING      (agency_id = public.current_user_agency_id() AND public.is_owner_or_manager())
  WITH CHECK (agency_id = public.current_user_agency_id() AND public.is_owner_or_manager());

CREATE POLICY product_lines_select ON product_lines FOR SELECT TO authenticated
  USING (agency_id = public.current_user_agency_id());
CREATE POLICY product_lines_manage ON product_lines FOR ALL TO authenticated
  USING      (agency_id = public.current_user_agency_id() AND public.is_owner_or_manager())
  WITH CHECK (agency_id = public.current_user_agency_id() AND public.is_owner_or_manager());

-- ------------------------------------------------------------
-- 5. generate_monthly_report: owner/admin -> owner/manager
--    (CREATE OR REPLACE keeps the grants from migration 004)
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

  SELECT COALESCE(SUM(amount), 0)
    INTO v_received
    FROM commission_transactions
   WHERE agency_id = v_agency_id
     AND status = 'received'
     AND created_at >= v_start
     AND created_at <  v_end + 1;

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
    'renewals_due_30d',        (SELECT COUNT(*) FROM policies
                                 WHERE agency_id = v_agency_id AND status = 'active'
                                   AND expiry_date BETWEEN CURRENT_DATE AND CURRENT_DATE + 30),
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
