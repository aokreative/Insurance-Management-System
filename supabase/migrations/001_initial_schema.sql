-- ============================================================
-- AMS (Agency Management System) — Initial Schema
-- Run this in your Supabase SQL Editor
-- ============================================================

-- Enable UUID generation
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ============================================================
-- TABLES
-- ============================================================

-- agencies
CREATE TABLE IF NOT EXISTS agencies (
  id            UUID DEFAULT uuid_generate_v4() PRIMARY KEY,
  name          TEXT NOT NULL,
  logo_url      TEXT,
  primary_color TEXT DEFAULT '#2563EB',
  email         TEXT,
  phone         TEXT,
  address       TEXT,
  subscription_tier TEXT DEFAULT 'starter'
    CHECK (subscription_tier IN ('starter', 'pro', 'enterprise')),
  created_at    TIMESTAMPTZ DEFAULT NOW()
);

-- users (extends auth.users — one row per auth user)
CREATE TABLE IF NOT EXISTS users (
  id         UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  agency_id  UUID NOT NULL REFERENCES agencies(id) ON DELETE CASCADE,
  role       TEXT NOT NULL CHECK (role IN ('owner', 'admin', 'agent')),
  full_name  TEXT NOT NULL,
  phone      TEXT,
  email      TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- insurers (per-agency, freely editable)
CREATE TABLE IF NOT EXISTS insurers (
  id            UUID DEFAULT uuid_generate_v4() PRIMARY KEY,
  agency_id     UUID NOT NULL REFERENCES agencies(id) ON DELETE CASCADE,
  name          TEXT NOT NULL,
  contact_email TEXT,
  contact_phone TEXT,
  website       TEXT,
  is_active     BOOLEAN DEFAULT TRUE,
  created_at    TIMESTAMPTZ DEFAULT NOW()
);

-- product_lines (per-agency, seeded with Kenyan defaults)
CREATE TABLE IF NOT EXISTS product_lines (
  id          UUID DEFAULT uuid_generate_v4() PRIMARY KEY,
  agency_id   UUID NOT NULL REFERENCES agencies(id) ON DELETE CASCADE,
  name        TEXT NOT NULL,
  description TEXT,
  is_active   BOOLEAN DEFAULT TRUE,
  created_at  TIMESTAMPTZ DEFAULT NOW()
);

-- clients
CREATE TABLE IF NOT EXISTS clients (
  id               UUID DEFAULT uuid_generate_v4() PRIMARY KEY,
  agency_id        UUID NOT NULL REFERENCES agencies(id) ON DELETE CASCADE,
  type             TEXT NOT NULL CHECK (type IN ('individual', 'corporate')),
  name             TEXT NOT NULL,
  phone            TEXT,
  email            TEXT,
  kra_pin          TEXT,
  id_or_reg_number TEXT,
  address          TEXT,
  created_at       TIMESTAMPTZ DEFAULT NOW()
);

-- policies
CREATE TABLE IF NOT EXISTS policies (
  id                  UUID DEFAULT uuid_generate_v4() PRIMARY KEY,
  agency_id           UUID NOT NULL REFERENCES agencies(id) ON DELETE CASCADE,
  client_id           UUID NOT NULL REFERENCES clients(id) ON DELETE RESTRICT,
  insurer_id          UUID NOT NULL REFERENCES insurers(id) ON DELETE RESTRICT,
  product_line_id     UUID NOT NULL REFERENCES product_lines(id) ON DELETE RESTRICT,
  agent_id            UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  policy_number       TEXT NOT NULL,
  premium_amount      DECIMAL(12,2) NOT NULL,
  commission_rate     DECIMAL(5,2) NOT NULL,
  commission_expected DECIMAL(12,2) GENERATED ALWAYS AS (premium_amount * commission_rate / 100) STORED,
  commission_received DECIMAL(12,2) DEFAULT 0,
  start_date          DATE NOT NULL,
  expiry_date         DATE NOT NULL,
  status              TEXT NOT NULL DEFAULT 'active'
    CHECK (status IN ('active', 'expired', 'cancelled', 'pending')),
  notes               TEXT,
  created_at          TIMESTAMPTZ DEFAULT NOW(),
  updated_at          TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE (agency_id, policy_number)
);

-- commission_transactions (reconciliation layer)
CREATE TABLE IF NOT EXISTS commission_transactions (
  id            UUID DEFAULT uuid_generate_v4() PRIMARY KEY,
  policy_id     UUID NOT NULL REFERENCES policies(id) ON DELETE CASCADE,
  agency_id     UUID NOT NULL REFERENCES agencies(id) ON DELETE CASCADE,
  amount        DECIMAL(12,2) NOT NULL,
  expected_date DATE,
  received_date DATE,
  status        TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'received', 'overdue')),
  notes         TEXT,
  created_at    TIMESTAMPTZ DEFAULT NOW()
);

-- renewal_reminders
CREATE TABLE IF NOT EXISTS renewal_reminders (
  id            UUID DEFAULT uuid_generate_v4() PRIMARY KEY,
  policy_id     UUID NOT NULL REFERENCES policies(id) ON DELETE CASCADE,
  agency_id     UUID NOT NULL REFERENCES agencies(id) ON DELETE CASCADE,
  reminder_date DATE NOT NULL,
  channel       TEXT NOT NULL CHECK (channel IN ('whatsapp', 'email', 'sms')),
  sent          BOOLEAN DEFAULT FALSE,
  sent_at       TIMESTAMPTZ,
  notes         TEXT,
  created_at    TIMESTAMPTZ DEFAULT NOW()
);

-- reports (historical PDF archive)
CREATE TABLE IF NOT EXISTS reports (
  id           UUID DEFAULT uuid_generate_v4() PRIMARY KEY,
  agency_id    UUID NOT NULL REFERENCES agencies(id) ON DELETE CASCADE,
  month        INTEGER NOT NULL CHECK (month BETWEEN 1 AND 12),
  year         INTEGER NOT NULL,
  generated_at TIMESTAMPTZ DEFAULT NOW(),
  file_url     TEXT,
  metadata     JSONB
);

-- ============================================================
-- INDEXES
-- ============================================================

CREATE INDEX IF NOT EXISTS idx_users_agency_id                   ON users(agency_id);
CREATE INDEX IF NOT EXISTS idx_insurers_agency_id                ON insurers(agency_id);
CREATE INDEX IF NOT EXISTS idx_product_lines_agency_id           ON product_lines(agency_id);
CREATE INDEX IF NOT EXISTS idx_clients_agency_id                 ON clients(agency_id);
CREATE INDEX IF NOT EXISTS idx_policies_agency_id                ON policies(agency_id);
CREATE INDEX IF NOT EXISTS idx_policies_expiry_date              ON policies(expiry_date);
CREATE INDEX IF NOT EXISTS idx_policies_status                   ON policies(status);
CREATE INDEX IF NOT EXISTS idx_policies_client_id                ON policies(client_id);
CREATE INDEX IF NOT EXISTS idx_policies_agent_id                 ON policies(agent_id);
CREATE INDEX IF NOT EXISTS idx_commission_tx_agency_id           ON commission_transactions(agency_id);
CREATE INDEX IF NOT EXISTS idx_commission_tx_policy_id           ON commission_transactions(policy_id);
CREATE INDEX IF NOT EXISTS idx_commission_tx_status              ON commission_transactions(status);
CREATE INDEX IF NOT EXISTS idx_renewal_reminders_agency_id       ON renewal_reminders(agency_id);
CREATE INDEX IF NOT EXISTS idx_renewal_reminders_reminder_date   ON renewal_reminders(reminder_date);

-- ============================================================
-- ROW LEVEL SECURITY
-- ============================================================

ALTER TABLE agencies             ENABLE ROW LEVEL SECURITY;
ALTER TABLE users                ENABLE ROW LEVEL SECURITY;
ALTER TABLE insurers             ENABLE ROW LEVEL SECURITY;
ALTER TABLE product_lines        ENABLE ROW LEVEL SECURITY;
ALTER TABLE clients              ENABLE ROW LEVEL SECURITY;
ALTER TABLE policies             ENABLE ROW LEVEL SECURITY;
ALTER TABLE commission_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE renewal_reminders    ENABLE ROW LEVEL SECURITY;
ALTER TABLE reports              ENABLE ROW LEVEL SECURITY;

-- ============================================================
-- HELPER FUNCTIONS (SECURITY DEFINER — run as postgres user)
-- ============================================================

-- Get current user's agency_id
CREATE OR REPLACE FUNCTION public.current_user_agency_id()
RETURNS UUID
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $$
  SELECT agency_id FROM users WHERE id = auth.uid();
$$;

-- Get current user's role
CREATE OR REPLACE FUNCTION public.current_user_role()
RETURNS TEXT
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $$
  SELECT role FROM users WHERE id = auth.uid();
$$;

-- ============================================================
-- RLS POLICIES
-- ============================================================

-- agencies: see & edit only own agency
DROP POLICY IF EXISTS "agencies_select"  ON agencies;
DROP POLICY IF EXISTS "agencies_update"  ON agencies;
CREATE POLICY "agencies_select" ON agencies FOR SELECT USING (id = public.current_user_agency_id());
CREATE POLICY "agencies_update" ON agencies FOR UPDATE
  USING (id = public.current_user_agency_id() AND public.current_user_role() IN ('owner', 'admin'));

-- users: all operations scoped to same agency
DROP POLICY IF EXISTS "users_select" ON users;
DROP POLICY IF EXISTS "users_insert" ON users;
DROP POLICY IF EXISTS "users_update" ON users;
DROP POLICY IF EXISTS "users_delete" ON users;
CREATE POLICY "users_select" ON users FOR SELECT USING (agency_id = public.current_user_agency_id());
CREATE POLICY "users_insert" ON users FOR INSERT
  WITH CHECK (agency_id = public.current_user_agency_id() AND public.current_user_role() IN ('owner', 'admin'));
CREATE POLICY "users_update" ON users FOR UPDATE
  USING (agency_id = public.current_user_agency_id() AND public.current_user_role() IN ('owner', 'admin'));
CREATE POLICY "users_delete" ON users FOR DELETE
  USING (agency_id = public.current_user_agency_id() AND public.current_user_role() = 'owner');

-- insurers: all ops scoped to agency
DROP POLICY IF EXISTS "insurers_all" ON insurers;
CREATE POLICY "insurers_all" ON insurers FOR ALL USING (agency_id = public.current_user_agency_id());

-- product_lines: all ops scoped to agency
DROP POLICY IF EXISTS "product_lines_all" ON product_lines;
CREATE POLICY "product_lines_all" ON product_lines FOR ALL USING (agency_id = public.current_user_agency_id());

-- clients: all ops scoped to agency
DROP POLICY IF EXISTS "clients_all" ON clients;
CREATE POLICY "clients_all" ON clients FOR ALL USING (agency_id = public.current_user_agency_id());

-- policies: owners/admins see all; agents see only their own
DROP POLICY IF EXISTS "policies_select_owner_admin" ON policies;
DROP POLICY IF EXISTS "policies_select_agent"       ON policies;
DROP POLICY IF EXISTS "policies_insert"             ON policies;
DROP POLICY IF EXISTS "policies_update"             ON policies;
DROP POLICY IF EXISTS "policies_delete"             ON policies;
CREATE POLICY "policies_select_owner_admin" ON policies FOR SELECT
  USING (agency_id = public.current_user_agency_id() AND public.current_user_role() IN ('owner', 'admin'));
CREATE POLICY "policies_select_agent" ON policies FOR SELECT
  USING (agency_id = public.current_user_agency_id() AND public.current_user_role() = 'agent' AND agent_id = auth.uid());
CREATE POLICY "policies_insert" ON policies FOR INSERT
  WITH CHECK (agency_id = public.current_user_agency_id());
CREATE POLICY "policies_update" ON policies FOR UPDATE
  USING (agency_id = public.current_user_agency_id()
    AND (public.current_user_role() IN ('owner', 'admin') OR agent_id = auth.uid()));
CREATE POLICY "policies_delete" ON policies FOR DELETE
  USING (agency_id = public.current_user_agency_id() AND public.current_user_role() IN ('owner', 'admin'));

-- commission_transactions: scoped to agency
DROP POLICY IF EXISTS "commission_tx_all" ON commission_transactions;
CREATE POLICY "commission_tx_all" ON commission_transactions FOR ALL USING (agency_id = public.current_user_agency_id());

-- renewal_reminders: scoped to agency
DROP POLICY IF EXISTS "renewal_reminders_all" ON renewal_reminders;
CREATE POLICY "renewal_reminders_all" ON renewal_reminders FOR ALL USING (agency_id = public.current_user_agency_id());

-- reports: scoped to agency
DROP POLICY IF EXISTS "reports_all" ON reports;
CREATE POLICY "reports_all" ON reports FOR ALL USING (agency_id = public.current_user_agency_id());

-- ============================================================
-- SEED FUNCTION (call from API after creating a new agency)
-- ============================================================

CREATE OR REPLACE FUNCTION public.seed_default_product_lines(p_agency_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  INSERT INTO product_lines (agency_id, name) VALUES
    (p_agency_id, 'Motor Private'),
    (p_agency_id, 'Motor Commercial'),
    (p_agency_id, 'Medical'),
    (p_agency_id, 'Life'),
    (p_agency_id, 'WIBA'),
    (p_agency_id, 'Fire & Burglary'),
    (p_agency_id, 'Marine'),
    (p_agency_id, 'Travel'),
    (p_agency_id, 'Professional Indemnity'),
    (p_agency_id, 'Personal Accident')
  ON CONFLICT DO NOTHING;
END;
$$;

-- ============================================================
-- AGENCY SIGNUP FUNCTION
-- Call this after a user signs up via Supabase Auth.
-- Creates agency + owner user + seeds product lines atomically.
-- Must be called with service-role key (bypasses RLS).
-- ============================================================

CREATE OR REPLACE FUNCTION public.create_agency_with_owner(
  p_auth_user_id UUID,
  p_agency_name  TEXT,
  p_owner_name   TEXT,
  p_owner_email  TEXT,
  p_owner_phone  TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_agency_id UUID;
BEGIN
  -- Create agency
  INSERT INTO agencies (name, email)
  VALUES (p_agency_name, p_owner_email)
  RETURNING id INTO v_agency_id;

  -- Create owner user row
  INSERT INTO users (id, agency_id, role, full_name, phone, email)
  VALUES (p_auth_user_id, v_agency_id, 'owner', p_owner_name, p_owner_phone, p_owner_email);

  -- Seed default product lines
  PERFORM public.seed_default_product_lines(v_agency_id);

  RETURN jsonb_build_object('agency_id', v_agency_id);
END;
$$;

-- Allow authenticated users to call this RPC from the browser (SECURITY DEFINER handles privilege escalation)
GRANT EXECUTE ON FUNCTION public.create_agency_with_owner TO authenticated;
