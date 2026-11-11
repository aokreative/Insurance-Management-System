-- ============================================================
-- Migration 013: Agent rates, earnings ledger and payouts
--
--   1. agent_rates: default rate per member (product_line_id NULL)
--      plus per-product-line overrides.
--   2. agent_earnings: append-only ledger. 'commission' rows are
--      written by a trigger when money is applied to a commission
--      (commission_allocations INSERT); 'reversal' rows when an
--      allocation is deleted (undo, or cascade from a commission /
--      policy delete); 'adjustment' rows by the Owner. Only
--      payout_id ever changes (payout RPCs).
--   3. agent_payouts: one pay run per agent up to a date.
--   4. RLS: Owner/Manager read the agency; a member reads their
--      own rows. No direct writes for API roles.
--   5. RPCs: set_agent_rates, add_agent_adjustment,
--      preview_agent_payout, create_agent_payout, void_agent_payout;
--      internal _backfill_agent_earnings (not called here: there
--      are no rates yet, so existing allocations earn nothing).
-- ============================================================

-- ------------------------------------------------------------
-- 1. Tables
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS agent_rates (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id       UUID NOT NULL REFERENCES agencies(id) ON DELETE CASCADE,
  user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  product_line_id UUID REFERENCES product_lines(id) ON DELETE CASCADE,
  rate            NUMERIC(5,2) NOT NULL CHECK (rate >= 0 AND rate <= 100),
  updated_by      UUID REFERENCES users(id) ON DELETE SET NULL,
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- One default per member, one override per member and product line
CREATE UNIQUE INDEX IF NOT EXISTS agent_rates_default_key
  ON agent_rates (user_id) WHERE product_line_id IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS agent_rates_override_key
  ON agent_rates (user_id, product_line_id) WHERE product_line_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_agent_rates_agency_id ON agent_rates(agency_id);

CREATE TABLE IF NOT EXISTS agent_payouts (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id   UUID NOT NULL REFERENCES agencies(id) ON DELETE CASCADE,
  agent_id    UUID NOT NULL REFERENCES users(id),
  period_end  DATE NOT NULL,
  paid_on     DATE NOT NULL,
  method      TEXT NOT NULL CHECK (method IN ('mpesa', 'bank', 'cash')),
  reference   TEXT,
  amount      NUMERIC(12,2) NOT NULL CHECK (amount > 0),
  voided_at   TIMESTAMPTZ,
  voided_by   UUID REFERENCES users(id) ON DELETE SET NULL,
  created_by  UUID REFERENCES users(id) ON DELETE SET NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_agent_payouts_agency_agent ON agent_payouts(agency_id, agent_id);

CREATE TABLE IF NOT EXISTS agent_earnings (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id           UUID NOT NULL REFERENCES agencies(id) ON DELETE CASCADE,
  agent_id            UUID NOT NULL REFERENCES users(id),
  kind                TEXT NOT NULL CHECK (kind IN ('commission', 'reversal', 'adjustment')),
  -- not a FK: the allocation may be deleted (that is what a reversal records)
  allocation_id       UUID,
  reverses_earning_id UUID REFERENCES agent_earnings(id),
  policy_id           UUID REFERENCES policies(id) ON DELETE SET NULL,
  commission_id       UUID REFERENCES commission_transactions(id) ON DELETE SET NULL,
  policy_number       TEXT,
  client_name         TEXT,
  base_amount         NUMERIC(12,2),
  rate                NUMERIC(5,2),
  amount              NUMERIC(12,2) NOT NULL,
  earned_on           DATE NOT NULL,
  note                TEXT,
  payout_id           UUID REFERENCES agent_payouts(id),
  created_by          UUID REFERENCES users(id) ON DELETE SET NULL,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT agent_earnings_shape_check CHECK (
    CASE kind
      WHEN 'commission' THEN allocation_id IS NOT NULL AND base_amount IS NOT NULL
                             AND rate IS NOT NULL AND reverses_earning_id IS NULL
      WHEN 'reversal'   THEN allocation_id IS NOT NULL AND base_amount IS NOT NULL
                             AND rate IS NOT NULL AND reverses_earning_id IS NOT NULL
      ELSE allocation_id IS NULL AND base_amount IS NULL AND rate IS NULL
           AND reverses_earning_id IS NULL AND amount <> 0
           AND note IS NOT NULL AND btrim(note) <> ''
    END)
);

CREATE INDEX IF NOT EXISTS idx_agent_earnings_agent_payout ON agent_earnings(agent_id, payout_id);
CREATE INDEX IF NOT EXISTS idx_agent_earnings_allocation_id ON agent_earnings(allocation_id);
CREATE INDEX IF NOT EXISTS idx_agent_earnings_payout_id     ON agent_earnings(payout_id);
CREATE INDEX IF NOT EXISTS idx_agent_earnings_agency_id     ON agent_earnings(agency_id);
-- each commission earning is reversed at most once
CREATE UNIQUE INDEX IF NOT EXISTS agent_earnings_reverses_key
  ON agent_earnings(reverses_earning_id) WHERE reverses_earning_id IS NOT NULL;

-- ------------------------------------------------------------
-- 2. RLS: Owner/Manager read the agency; members read their own
-- ------------------------------------------------------------
ALTER TABLE agent_rates    ENABLE ROW LEVEL SECURITY;
ALTER TABLE agent_earnings ENABLE ROW LEVEL SECURITY;
ALTER TABLE agent_payouts  ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS agent_rates_select ON agent_rates;
CREATE POLICY agent_rates_select ON agent_rates FOR SELECT TO authenticated
  USING (agency_id = public.current_user_agency_id()
         AND (public.is_owner_or_manager() OR user_id = auth.uid()));

DROP POLICY IF EXISTS agent_earnings_select ON agent_earnings;
CREATE POLICY agent_earnings_select ON agent_earnings FOR SELECT TO authenticated
  USING (agency_id = public.current_user_agency_id()
         AND (public.is_owner_or_manager() OR agent_id = auth.uid()));

DROP POLICY IF EXISTS agent_payouts_select ON agent_payouts;
CREATE POLICY agent_payouts_select ON agent_payouts FOR SELECT TO authenticated
  USING (agency_id = public.current_user_agency_id()
         AND (public.is_owner_or_manager() OR agent_id = auth.uid()));

REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON agent_rates    FROM anon, authenticated;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON agent_earnings FROM anon, authenticated;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON agent_payouts  FROM anon, authenticated;

-- ------------------------------------------------------------
-- 3. Rate lookup: product-line override, else default, else NULL
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._agent_rate_for(p_agency_id UUID, p_user_id UUID, p_product_line_id UUID)
RETURNS NUMERIC
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(
    (SELECT rate FROM agent_rates
      WHERE agency_id = p_agency_id AND user_id = p_user_id
        AND product_line_id = p_product_line_id),
    (SELECT rate FROM agent_rates
      WHERE agency_id = p_agency_id AND user_id = p_user_id
        AND product_line_id IS NULL));
$$;

REVOKE EXECUTE ON FUNCTION public._agent_rate_for(UUID, UUID, UUID) FROM PUBLIC, anon, authenticated;

-- ------------------------------------------------------------
-- 4. Triggers on commission_allocations
-- ------------------------------------------------------------
-- 4a. Earning on INSERT: the policy's agent at this moment earns
--     rate x applied amount. Opening-balance receipts never earn;
--     no rate or rate 0 earns nothing.
CREATE OR REPLACE FUNCTION public.allocation_agent_earning()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_opening   BOOLEAN;
  v_received  DATE;
  v_policy    policies;
  v_client    TEXT;
  v_rate      NUMERIC;
BEGIN
  SELECT is_opening_balance, received_on INTO v_opening, v_received
    FROM insurer_receipts WHERE id = NEW.receipt_id;
  IF v_opening IS DISTINCT FROM false THEN
    RETURN NULL;
  END IF;

  SELECT p.* INTO v_policy
    FROM commission_transactions ct
    JOIN policies p ON p.id = ct.policy_id
   WHERE ct.id = NEW.commission_id;
  IF v_policy.id IS NULL OR v_policy.agent_id IS NULL THEN
    RETURN NULL;
  END IF;

  v_rate := public._agent_rate_for(NEW.agency_id, v_policy.agent_id, v_policy.product_line_id);
  IF v_rate IS NULL OR v_rate = 0 THEN
    RETURN NULL;
  END IF;

  SELECT name INTO v_client FROM clients WHERE id = v_policy.client_id;

  INSERT INTO agent_earnings
    (agency_id, agent_id, kind, allocation_id, policy_id, commission_id,
     policy_number, client_name, base_amount, rate, amount, earned_on, created_by)
  VALUES
    (NEW.agency_id, v_policy.agent_id, 'commission', NEW.id, v_policy.id, NEW.commission_id,
     v_policy.policy_number, v_client, NEW.amount, v_rate,
     round(NEW.amount * v_rate / 100, 2), v_received, NEW.created_by);

  RETURN NULL;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.allocation_agent_earning() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_allocation_agent_earning ON commission_allocations;
CREATE TRIGGER trg_allocation_agent_earning
  AFTER INSERT ON commission_allocations
  FOR EACH ROW
  EXECUTE FUNCTION public.allocation_agent_earning();

-- 4b. Reversal on DELETE (undo, or cascade from a commission or
--     policy delete): negate the allocation's unreversed commission
--     earning. Reads only the earning, never the policy (it may be
--     gone mid-cascade); links to rows already deleted are NULL.
CREATE OR REPLACE FUNCTION public.allocation_agent_reversal()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_e agent_earnings;
BEGIN
  SELECT e.* INTO v_e
    FROM agent_earnings e
   WHERE e.allocation_id = OLD.id
     AND e.kind = 'commission'
     AND NOT EXISTS (SELECT 1 FROM agent_earnings r WHERE r.reverses_earning_id = e.id)
   ORDER BY e.created_at
   LIMIT 1
     FOR UPDATE;
  IF v_e.id IS NULL THEN
    RETURN NULL;
  END IF;

  INSERT INTO agent_earnings
    (agency_id, agent_id, kind, allocation_id, reverses_earning_id, policy_id, commission_id,
     policy_number, client_name, base_amount, rate, amount, earned_on, created_by)
  VALUES
    (v_e.agency_id, v_e.agent_id, 'reversal', v_e.allocation_id, v_e.id,
     (SELECT id FROM policies WHERE id = v_e.policy_id),
     (SELECT id FROM commission_transactions WHERE id = v_e.commission_id),
     v_e.policy_number, v_e.client_name, -v_e.base_amount, v_e.rate, -v_e.amount,
     current_date, auth.uid());

  RETURN NULL;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.allocation_agent_reversal() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_allocation_agent_reversal ON commission_allocations;
CREATE TRIGGER trg_allocation_agent_reversal
  AFTER DELETE ON commission_allocations
  FOR EACH ROW
  EXECUTE FUNCTION public.allocation_agent_reversal();

-- ------------------------------------------------------------
-- 5. set_agent_rates (Owner): replaces the member's rates.
--   p_default_rate NULL removes the default;
--   p_overrides: [{product_line_id, rate}, ...]
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_agent_rates(p_user_id UUID, p_default_rate NUMERIC, p_overrides JSONB)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_agency UUID := public.current_user_agency_id();
  v_ov     JSONB;
  v_pl     UUID;
  v_rate   NUMERIC;
BEGIN
  IF v_agency IS NULL OR public.current_user_role() IS DISTINCT FROM 'owner' THEN
    RAISE EXCEPTION 'Only the owner can do that' USING ERRCODE = '42501';
  END IF;

  PERFORM 1 FROM users
   WHERE id = p_user_id AND agency_id = v_agency AND deactivated_at IS NULL
   FOR SHARE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Pick an active member of this agency' USING ERRCODE = '22023';
  END IF;

  p_overrides := COALESCE(p_overrides, '[]'::jsonb);
  IF jsonb_typeof(p_overrides) <> 'array' THEN
    RAISE EXCEPTION 'Pick a product line of this agency' USING ERRCODE = '22023';
  END IF;

  IF p_default_rate IS NOT NULL AND (p_default_rate < 0 OR p_default_rate > 100) THEN
    RAISE EXCEPTION 'Rate must be between 0 and 100' USING ERRCODE = '22023';
  END IF;

  FOR v_ov IN SELECT value FROM jsonb_array_elements(p_overrides)
  LOOP
    v_rate := NULLIF(v_ov->>'rate', '')::numeric;
    IF v_rate IS NULL OR v_rate < 0 OR v_rate > 100 THEN
      RAISE EXCEPTION 'Rate must be between 0 and 100' USING ERRCODE = '22023';
    END IF;
    v_pl := NULLIF(v_ov->>'product_line_id', '')::uuid;
    IF v_pl IS NULL OR NOT EXISTS (SELECT 1 FROM product_lines WHERE id = v_pl AND agency_id = v_agency) THEN
      RAISE EXCEPTION 'Pick a product line of this agency' USING ERRCODE = '22023';
    END IF;
  END LOOP;

  IF (SELECT count(*) <> count(DISTINCT value->>'product_line_id')
        FROM jsonb_array_elements(p_overrides)) THEN
    RAISE EXCEPTION 'Pick each product line once' USING ERRCODE = '22023';
  END IF;

  DELETE FROM agent_rates WHERE user_id = p_user_id;

  IF p_default_rate IS NOT NULL THEN
    INSERT INTO agent_rates (agency_id, user_id, product_line_id, rate, updated_by)
    VALUES (v_agency, p_user_id, NULL, p_default_rate, auth.uid());
  END IF;

  INSERT INTO agent_rates (agency_id, user_id, product_line_id, rate, updated_by)
  SELECT v_agency, p_user_id, (value->>'product_line_id')::uuid, (value->>'rate')::numeric, auth.uid()
    FROM jsonb_array_elements(p_overrides);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.set_agent_rates(UUID, NUMERIC, JSONB) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.set_agent_rates(UUID, NUMERIC, JSONB) TO authenticated;

-- ------------------------------------------------------------
-- 6. add_agent_adjustment (Owner): deactivated members allowed
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.add_agent_adjustment(p_user_id UUID, p_amount NUMERIC, p_note TEXT)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_agency UUID := public.current_user_agency_id();
  v_id     UUID;
BEGIN
  IF v_agency IS NULL OR public.current_user_role() IS DISTINCT FROM 'owner' THEN
    RAISE EXCEPTION 'Only the owner can do that' USING ERRCODE = '42501';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM users WHERE id = p_user_id AND agency_id = v_agency) THEN
    RAISE EXCEPTION 'Pick a member of this agency' USING ERRCODE = '22023';
  END IF;
  IF p_amount IS NULL OR round(p_amount, 2) = 0 THEN
    RAISE EXCEPTION 'Enter an amount' USING ERRCODE = '22023';
  END IF;
  IF p_note IS NULL OR btrim(p_note) = '' THEN
    RAISE EXCEPTION 'Add a note for this adjustment' USING ERRCODE = '22023';
  END IF;

  INSERT INTO agent_earnings (agency_id, agent_id, kind, amount, earned_on, note, created_by)
  VALUES (v_agency, p_user_id, 'adjustment', round(p_amount, 2), current_date, btrim(p_note), auth.uid())
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.add_agent_adjustment(UUID, NUMERIC, TEXT) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.add_agent_adjustment(UUID, NUMERIC, TEXT) TO authenticated;

-- ------------------------------------------------------------
-- 7. preview_agent_payout (Owner/Manager): unpaid earnings with
--    earned_on <= p_period_end -> {lines, total}
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.preview_agent_payout(p_user_id UUID, p_period_end DATE)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_agency UUID := public.current_user_agency_id();
  v_lines  JSONB;
  v_total  NUMERIC;
BEGIN
  IF v_agency IS NULL OR NOT public.is_owner_or_manager() THEN
    RAISE EXCEPTION 'Only owners and managers can do that' USING ERRCODE = '42501';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM users WHERE id = p_user_id AND agency_id = v_agency) THEN
    RAISE EXCEPTION 'Pick a member of this agency' USING ERRCODE = '22023';
  END IF;
  IF p_period_end IS NULL THEN
    RAISE EXCEPTION 'Pick a pay-up-to date' USING ERRCODE = '22023';
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'id', e.id, 'kind', e.kind, 'earned_on', e.earned_on,
           'policy_number', e.policy_number, 'client_name', e.client_name,
           'base_amount', e.base_amount, 'rate', e.rate, 'amount', e.amount,
           'note', e.note)
           ORDER BY e.earned_on, e.created_at, e.id), '[]'::jsonb),
         COALESCE(SUM(e.amount), 0)
    INTO v_lines, v_total
    FROM agent_earnings e
   WHERE e.agency_id = v_agency
     AND e.agent_id = p_user_id
     AND e.payout_id IS NULL
     AND e.earned_on <= p_period_end;

  RETURN jsonb_build_object('lines', v_lines, 'total', round(v_total, 2));
END;
$$;

REVOKE EXECUTE ON FUNCTION public.preview_agent_payout(UUID, DATE) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.preview_agent_payout(UUID, DATE) TO authenticated;

-- ------------------------------------------------------------
-- 8. create_agent_payout (Owner/Manager): locks the agent's unpaid
--    earnings up to the date, pays exactly those. Deactivated
--    members allowed.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_agent_payout(
  p_user_id    UUID,
  p_period_end DATE,
  p_paid_on    DATE,
  p_method     TEXT,
  p_reference  TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_agency UUID := public.current_user_agency_id();
  v_ids    UUID[];
  v_total  NUMERIC;
  v_payout UUID;
  v_lines  JSONB;
BEGIN
  IF v_agency IS NULL OR NOT public.is_owner_or_manager() THEN
    RAISE EXCEPTION 'Only owners and managers can do that' USING ERRCODE = '42501';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM users WHERE id = p_user_id AND agency_id = v_agency) THEN
    RAISE EXCEPTION 'Pick a member of this agency' USING ERRCODE = '22023';
  END IF;
  IF p_period_end IS NULL THEN
    RAISE EXCEPTION 'Pick a pay-up-to date' USING ERRCODE = '22023';
  END IF;
  IF p_paid_on IS NULL THEN
    RAISE EXCEPTION 'Enter the date paid' USING ERRCODE = '22023';
  END IF;
  IF p_method IS NULL OR p_method NOT IN ('mpesa', 'bank', 'cash') THEN
    RAISE EXCEPTION 'Pick a payment method' USING ERRCODE = '22023';
  END IF;

  -- Lock in id order; a concurrent payout's rows drop out on re-check
  -- (payout_id no longer NULL), so nothing is paid twice.
  SELECT array_agg(id), COALESCE(SUM(amount), 0) INTO v_ids, v_total
    FROM (SELECT e.id, e.amount
            FROM agent_earnings e
           WHERE e.agency_id = v_agency
             AND e.agent_id = p_user_id
             AND e.payout_id IS NULL
             AND e.earned_on <= p_period_end
           ORDER BY e.id
             FOR UPDATE) s;

  IF v_total <= 0 THEN
    RAISE EXCEPTION 'Nothing to pay for this agent up to that date' USING ERRCODE = '22023';
  END IF;

  INSERT INTO agent_payouts (agency_id, agent_id, period_end, paid_on, method, reference, amount, created_by)
  VALUES (v_agency, p_user_id, p_period_end, p_paid_on, p_method,
          NULLIF(btrim(p_reference), ''), round(v_total, 2), auth.uid())
  RETURNING id INTO v_payout;

  UPDATE agent_earnings SET payout_id = v_payout WHERE id = ANY (v_ids);

  SELECT jsonb_agg(jsonb_build_object(
           'id', e.id, 'kind', e.kind, 'earned_on', e.earned_on,
           'policy_number', e.policy_number, 'client_name', e.client_name,
           'base_amount', e.base_amount, 'rate', e.rate, 'amount', e.amount,
           'note', e.note)
           ORDER BY e.earned_on, e.created_at, e.id)
    INTO v_lines
    FROM agent_earnings e WHERE e.payout_id = v_payout;

  RETURN jsonb_build_object('payout_id', v_payout, 'amount', round(v_total, 2), 'lines', v_lines);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.create_agent_payout(UUID, DATE, DATE, TEXT, TEXT) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.create_agent_payout(UUID, DATE, DATE, TEXT, TEXT) TO authenticated;

-- ------------------------------------------------------------
-- 9. void_agent_payout (Owner): its earnings become unpaid again
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.void_agent_payout(p_payout_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_agency UUID := public.current_user_agency_id();
  v_p      agent_payouts;
BEGIN
  IF v_agency IS NULL OR public.current_user_role() IS DISTINCT FROM 'owner' THEN
    RAISE EXCEPTION 'Only the owner can do that' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_p FROM agent_payouts
   WHERE id = p_payout_id AND agency_id = v_agency
   FOR UPDATE;
  IF v_p.id IS NULL THEN
    RAISE EXCEPTION 'Payout not found' USING ERRCODE = 'P0002';
  END IF;
  IF v_p.voided_at IS NOT NULL THEN
    RAISE EXCEPTION 'This payout is already voided' USING ERRCODE = '22023';
  END IF;

  UPDATE agent_payouts SET voided_at = now(), voided_by = auth.uid() WHERE id = v_p.id;
  UPDATE agent_earnings SET payout_id = NULL WHERE payout_id = v_p.id;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.void_agent_payout(UUID) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.void_agent_payout(UUID) TO authenticated;

-- ------------------------------------------------------------
-- 10. _backfill_agent_earnings (internal): 'commission' earnings for
--     the agency's existing non-opening-balance allocations that have
--     none, at current rates and the policy's current agent. Idempotent.
--     Not called by this migration.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._backfill_agent_earnings(p_agency_id UUID)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_count INTEGER;
BEGIN
  INSERT INTO agent_earnings
    (agency_id, agent_id, kind, allocation_id, policy_id, commission_id,
     policy_number, client_name, base_amount, rate, amount, earned_on, created_by)
  SELECT a.agency_id, p.agent_id, 'commission', a.id, p.id, a.commission_id,
         p.policy_number, cl.name, a.amount, x.rate,
         round(a.amount * x.rate / 100, 2), r.received_on, a.created_by
    FROM commission_allocations a
    JOIN insurer_receipts r        ON r.id = a.receipt_id
    JOIN commission_transactions ct ON ct.id = a.commission_id
    JOIN policies p                ON p.id = ct.policy_id
    LEFT JOIN clients cl           ON cl.id = p.client_id
    CROSS JOIN LATERAL (SELECT public._agent_rate_for(a.agency_id, p.agent_id, p.product_line_id) AS rate) x
   WHERE a.agency_id = p_agency_id
     AND NOT r.is_opening_balance
     AND x.rate IS NOT NULL AND x.rate > 0
     AND NOT EXISTS (SELECT 1 FROM agent_earnings e
                      WHERE e.allocation_id = a.id AND e.kind = 'commission')
   ORDER BY r.received_on, a.created_at, a.id;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

REVOKE EXECUTE ON FUNCTION public._backfill_agent_earnings(UUID) FROM PUBLIC, anon, authenticated;
