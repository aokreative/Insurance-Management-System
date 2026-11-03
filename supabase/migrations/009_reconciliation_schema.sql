-- ============================================================
-- Migration 009: Reconciliation schema
--
-- Insurer receipts, statement lines and commission allocations;
-- commission status derived from amount_received; expected
-- commission created by trigger for annual-basis policies.
--
--   1. Policy commission-basis columns; commission columns;
--      status values (pending | part_paid | received).
--   2. Tables insurer_receipts / statement_lines /
--      commission_allocations, indexes, RLS (owner/manager SELECT
--      only; writes go through SECURITY DEFINER RPCs added later).
--   3. Triggers: derived status + amount_received guard,
--      policy tally recompute on commission change/delete,
--      allocation recompute, expected commission on policy insert.
--      (3b and the 3c change were applied live as migration
--      009a_recompute_on_commission_change; this file is the
--      full source.)
--
-- RPCs, the receipts storage bucket and the opening-balance
-- backfill come in later migrations.
-- ============================================================

-- ------------------------------------------------------------
-- 1a. Policies: commission basis
-- ------------------------------------------------------------
ALTER TABLE policies
  ADD COLUMN IF NOT EXISTS commission_basis        TEXT NOT NULL DEFAULT 'annual',
  ADD COLUMN IF NOT EXISTS premium_frequency       TEXT,
  ADD COLUMN IF NOT EXISTS instalment_premium      NUMERIC(12,2),
  ADD COLUMN IF NOT EXISTS renewal_commission_rate NUMERIC(5,2);

ALTER TABLE policies DROP CONSTRAINT IF EXISTS policies_commission_basis_check;
ALTER TABLE policies ADD CONSTRAINT policies_commission_basis_check
  CHECK (commission_basis IN ('annual', 'per_premium'));

ALTER TABLE policies DROP CONSTRAINT IF EXISTS policies_premium_frequency_check;
ALTER TABLE policies ADD CONSTRAINT policies_premium_frequency_check
  CHECK (premium_frequency IN ('monthly', 'quarterly', 'half_yearly', 'yearly'));

ALTER TABLE policies DROP CONSTRAINT IF EXISTS policies_per_premium_fields_check;
ALTER TABLE policies ADD CONSTRAINT policies_per_premium_fields_check
  CHECK (commission_basis <> 'per_premium'
         OR (premium_frequency IS NOT NULL AND instalment_premium IS NOT NULL));

-- ------------------------------------------------------------
-- 1b. Commission transactions: received tally, period, source
-- ------------------------------------------------------------
ALTER TABLE commission_transactions
  ADD COLUMN IF NOT EXISTS amount_received NUMERIC(12,2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS period          DATE,
  ADD COLUMN IF NOT EXISTS source          TEXT NOT NULL DEFAULT 'expected';

ALTER TABLE commission_transactions DROP CONSTRAINT IF EXISTS commission_transactions_source_check;
ALTER TABLE commission_transactions ADD CONSTRAINT commission_transactions_source_check
  CHECK (source IN ('expected', 'statement'));

ALTER TABLE commission_transactions DROP CONSTRAINT IF EXISTS commission_transactions_amount_received_check;
ALTER TABLE commission_transactions ADD CONSTRAINT commission_transactions_amount_received_check
  CHECK (amount_received >= 0);

-- ------------------------------------------------------------
-- 1c. Status values. Overdue is no longer stored (it is
--     pending/part_paid with expected_date in the past).
--     Existing received rows keep 'received': their
--     amount_received is set to amount so the derived status
--     agrees. Runs before the status trigger exists.
-- ------------------------------------------------------------
ALTER TABLE commission_transactions DROP CONSTRAINT IF EXISTS commission_transactions_status_check;
UPDATE commission_transactions SET status = 'pending' WHERE status = 'overdue';
UPDATE commission_transactions SET amount_received = amount WHERE status = 'received';
ALTER TABLE commission_transactions ADD CONSTRAINT commission_transactions_status_check
  CHECK (status IN ('pending', 'part_paid', 'received'));

-- Targets for same-agency composite foreign keys
ALTER TABLE insurers DROP CONSTRAINT IF EXISTS insurers_id_agency_id_key;
ALTER TABLE insurers ADD CONSTRAINT insurers_id_agency_id_key UNIQUE (id, agency_id);
ALTER TABLE policies DROP CONSTRAINT IF EXISTS policies_id_agency_id_key;
ALTER TABLE policies ADD CONSTRAINT policies_id_agency_id_key UNIQUE (id, agency_id);
ALTER TABLE commission_transactions DROP CONSTRAINT IF EXISTS commission_transactions_id_agency_id_key;
ALTER TABLE commission_transactions ADD CONSTRAINT commission_transactions_id_agency_id_key UNIQUE (id, agency_id);

-- ------------------------------------------------------------
-- 2a. Tables
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS insurer_receipts (
  id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id          UUID NOT NULL REFERENCES agencies(id) ON DELETE CASCADE,
  insurer_id         UUID NOT NULL,
  received_on        DATE NOT NULL,
  amount             NUMERIC(12,2) NOT NULL CHECK (amount > 0),
  bank_reference     TEXT,
  file_path          TEXT,
  notes              TEXT,
  is_opening_balance BOOLEAN NOT NULL DEFAULT false,
  created_by         UUID REFERENCES users(id) ON DELETE SET NULL DEFAULT auth.uid(),
  created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (id, agency_id),
  -- insurer in the same agency
  FOREIGN KEY (insurer_id, agency_id) REFERENCES insurers(id, agency_id)
);

CREATE TABLE IF NOT EXISTS statement_lines (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id      UUID NOT NULL REFERENCES agencies(id) ON DELETE CASCADE,
  receipt_id     UUID NOT NULL,
  line_no        INTEGER NOT NULL,
  policy_number  TEXT,
  client_name    TEXT,
  premium        NUMERIC(12,2),
  commission     NUMERIC(12,2) NOT NULL,
  period         DATE,
  policy_id      UUID,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (receipt_id, line_no),
  FOREIGN KEY (receipt_id, agency_id) REFERENCES insurer_receipts(id, agency_id) ON DELETE CASCADE,
  -- matched policy in the same agency; unmatched again if the policy is deleted
  FOREIGN KEY (policy_id, agency_id) REFERENCES policies(id, agency_id) ON DELETE SET NULL (policy_id)
);

CREATE TABLE IF NOT EXISTS commission_allocations (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id         UUID NOT NULL REFERENCES agencies(id) ON DELETE CASCADE,
  receipt_id        UUID NOT NULL,
  commission_id     UUID NOT NULL,
  statement_line_id UUID REFERENCES statement_lines(id) ON DELETE SET NULL,
  amount            NUMERIC(12,2) NOT NULL CHECK (amount > 0),
  created_by        UUID REFERENCES users(id) ON DELETE SET NULL DEFAULT auth.uid(),
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  -- receipt deletion is blocked while allocations exist
  FOREIGN KEY (receipt_id, agency_id) REFERENCES insurer_receipts(id, agency_id),
  -- deleting a commission (or its policy) returns the money to the receipt as unapplied
  FOREIGN KEY (commission_id, agency_id) REFERENCES commission_transactions(id, agency_id) ON DELETE CASCADE
);

-- ------------------------------------------------------------
-- 2b. Indexes
-- ------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_commission_allocations_commission_id ON commission_allocations(commission_id);
CREATE INDEX IF NOT EXISTS idx_commission_allocations_receipt_id    ON commission_allocations(receipt_id);
CREATE INDEX IF NOT EXISTS idx_statement_lines_receipt_id           ON statement_lines(receipt_id);
CREATE INDEX IF NOT EXISTS idx_policies_agent_id                    ON policies(agent_id);

-- ------------------------------------------------------------
-- 2c. RLS: owner/manager read; no direct writes for anyone
-- ------------------------------------------------------------
ALTER TABLE insurer_receipts       ENABLE ROW LEVEL SECURITY;
ALTER TABLE statement_lines        ENABLE ROW LEVEL SECURITY;
ALTER TABLE commission_allocations ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS insurer_receipts_select ON insurer_receipts;
CREATE POLICY insurer_receipts_select ON insurer_receipts FOR SELECT TO authenticated
  USING (agency_id = public.current_user_agency_id() AND public.is_owner_or_manager());

DROP POLICY IF EXISTS statement_lines_select ON statement_lines;
CREATE POLICY statement_lines_select ON statement_lines FOR SELECT TO authenticated
  USING (agency_id = public.current_user_agency_id() AND public.is_owner_or_manager());

DROP POLICY IF EXISTS commission_allocations_select ON commission_allocations;
CREATE POLICY commission_allocations_select ON commission_allocations FOR SELECT TO authenticated
  USING (agency_id = public.current_user_agency_id() AND public.is_owner_or_manager());

REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON insurer_receipts       FROM anon, authenticated;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON statement_lines        FROM anon, authenticated;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON commission_allocations FROM anon, authenticated;

-- ------------------------------------------------------------
-- 3a. Commission status: derived from amount_received vs amount.
--     JWT callers cannot change amount_received; trusted callers
--     (no JWT) and the allocation recompute trigger (which sets
--     the transaction-local flag app.allocating = 'on') can.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.commission_derive_status()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NOT NULL
     AND COALESCE(current_setting('app.allocating', true), '') <> 'on'
     AND ((TG_OP = 'INSERT' AND NEW.amount_received <> 0)
          OR (TG_OP = 'UPDATE' AND NEW.amount_received IS DISTINCT FROM OLD.amount_received)) THEN
    RAISE EXCEPTION 'Commission received is recorded through receipts'
      USING ERRCODE = '42501';
  END IF;

  NEW.status := CASE
    WHEN NEW.amount_received <= 0          THEN 'pending'
    WHEN NEW.amount_received <  NEW.amount THEN 'part_paid'
    ELSE 'received'
  END;
  RETURN NEW;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.commission_derive_status() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_commission_status ON commission_transactions;
CREATE TRIGGER trg_commission_status
  BEFORE INSERT OR UPDATE ON commission_transactions
  FOR EACH ROW
  EXECUTE FUNCTION public.commission_derive_status();

-- ------------------------------------------------------------
-- 3b. Policy tally: policies.commission_received = sum of its
--     commissions' amount_received. One helper, called whenever a
--     commission row's amount_received or policy_id changes or the
--     row is deleted (incl. cascades from policy/commission deletes).
--     The policy update goes through the 006a guard: callers are
--     owner/manager (RLS on commission_transactions) or no-JWT.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.recompute_policy_commission_received(p_policy_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_sum       NUMERIC;
  v_prev_flag TEXT;
BEGIN
  IF p_policy_id IS NULL THEN
    RETURN;
  END IF;

  SELECT COALESCE(SUM(amount_received), 0) INTO v_sum
    FROM commission_transactions WHERE policy_id = p_policy_id;

  v_prev_flag := COALESCE(current_setting('app.allocating', true), '');
  PERFORM set_config('app.allocating', 'on', true);

  -- A policy deleted in this statement (cascade) simply matches no row
  UPDATE policies
     SET commission_received = v_sum
   WHERE id = p_policy_id
     AND commission_received IS DISTINCT FROM v_sum;

  PERFORM set_config('app.allocating', v_prev_flag, true);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.recompute_policy_commission_received(UUID) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.commission_policy_recompute()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    PERFORM public.recompute_policy_commission_received(OLD.policy_id);
    RETURN NULL;
  END IF;

  IF NEW.policy_id IS DISTINCT FROM OLD.policy_id THEN
    PERFORM public.recompute_policy_commission_received(OLD.policy_id);
    PERFORM public.recompute_policy_commission_received(NEW.policy_id);
  ELSIF NEW.amount_received IS DISTINCT FROM OLD.amount_received THEN
    PERFORM public.recompute_policy_commission_received(NEW.policy_id);
  END IF;
  RETURN NULL;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.commission_policy_recompute() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_commission_policy_recompute ON commission_transactions;
CREATE TRIGGER trg_commission_policy_recompute
  AFTER DELETE OR UPDATE OF policy_id, amount_received ON commission_transactions
  FOR EACH ROW
  EXECUTE FUNCTION public.commission_policy_recompute();

-- ------------------------------------------------------------
-- 3c. Allocation recompute: re-checks the allocation rules on
--     insert, then recomputes the commission's amount_received
--     (which in turn recomputes the policy via 3b).
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.commission_allocation_recompute()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row         commission_allocations;
  v_policy_id   UUID;
  v_comm_amount NUMERIC;
  v_rcpt_amount NUMERIC;
  v_rcpt_ins    UUID;
  v_pol_ins     UUID;
  v_prev_flag   TEXT;
BEGIN
  IF TG_OP = 'INSERT' THEN v_row := NEW; ELSE v_row := OLD; END IF;

  SELECT ct.policy_id, ct.amount, p.insurer_id
    INTO v_policy_id, v_comm_amount, v_pol_ins
    FROM commission_transactions ct
    JOIN policies p ON p.id = ct.policy_id
   WHERE ct.id = v_row.commission_id;

  IF TG_OP = 'INSERT' THEN
    -- Row locks serialise concurrent allocations on the same receipt /
    -- commission, so the sums below see each other's rows.
    SELECT amount, insurer_id INTO v_rcpt_amount, v_rcpt_ins
      FROM insurer_receipts WHERE id = NEW.receipt_id FOR UPDATE;
    PERFORM 1 FROM commission_transactions WHERE id = NEW.commission_id FOR UPDATE;

    IF v_pol_ins IS DISTINCT FROM v_rcpt_ins THEN
      RAISE EXCEPTION 'That policy is not with this insurer';
    END IF;
    IF (SELECT COALESCE(SUM(amount), 0) FROM commission_allocations
         WHERE receipt_id = NEW.receipt_id) > v_rcpt_amount THEN
      RAISE EXCEPTION 'Applied amount exceeds the receipt amount';
    END IF;
    IF (SELECT COALESCE(SUM(amount), 0) FROM commission_allocations
         WHERE commission_id = NEW.commission_id) > v_comm_amount THEN
      RAISE EXCEPTION 'That commission is already fully received';
    END IF;
  END IF;

  -- Commission (or its policy) already gone, e.g. cascade delete
  IF v_policy_id IS NULL THEN
    RETURN NULL;
  END IF;

  v_prev_flag := COALESCE(current_setting('app.allocating', true), '');
  PERFORM set_config('app.allocating', 'on', true);

  -- The policy tally is recomputed by trg_commission_policy_recompute
  -- (UPDATE OF amount_received), so it is not repeated here.
  UPDATE commission_transactions
     SET amount_received = (SELECT COALESCE(SUM(amount), 0) FROM commission_allocations
                             WHERE commission_id = v_row.commission_id)
   WHERE id = v_row.commission_id;

  PERFORM set_config('app.allocating', v_prev_flag, true);
  RETURN NULL;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.commission_allocation_recompute() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_allocation_recompute ON commission_allocations;
CREATE TRIGGER trg_allocation_recompute
  AFTER INSERT OR DELETE ON commission_allocations
  FOR EACH ROW
  EXECUTE FUNCTION public.commission_allocation_recompute();

-- ------------------------------------------------------------
-- 3d. Expected commission on policy insert (annual basis only).
--     SECURITY DEFINER so agents' new policies still get one.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_expected_commission()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO commission_transactions
    (policy_id, agency_id, amount, expected_date, source, notes)
  VALUES
    (NEW.id, NEW.agency_id, NEW.premium_amount * NEW.commission_rate / 100,
     NEW.start_date + 30, 'expected', 'Expected commission');
  RETURN NULL;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.create_expected_commission() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_policy_expected_commission ON policies;
CREATE TRIGGER trg_policy_expected_commission
  AFTER INSERT ON policies
  FOR EACH ROW
  WHEN (NEW.commission_basis = 'annual')
  EXECUTE FUNCTION public.create_expected_commission();
