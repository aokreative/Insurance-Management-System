-- ============================================================
-- Migration 012: Reconciliation follow-ups
--
--   1. generate_monthly_report: commission received = money applied
--      from receipts dated in the report month (Σ commission_allocations
--      .amount by insurer_receipts.received_on), so part payments and
--      payments for older commissions count in the month the money
--      arrived. collection_rate_pct uses the same figure. Everything
--      else is unchanged from 006 (signature, SECURITY INVOKER, grants
--      from 004 kept by CREATE OR REPLACE).
--   2. undo_commission_allocation: when the undone allocation was the
--      last one for its statement line, the line is unmatched again
--      (policy_id = NULL) so it can be re-linked. This file is the full
--      source for this function from now on (supersedes 010).
--   3. apply_receipt_allocations: apply a receipt's unapplied money to
--      commissions of the receipt's insurer.
-- ============================================================

-- ------------------------------------------------------------
-- 1. generate_monthly_report
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

  -- Money received this month: everything applied from receipts dated
  -- in the month, whichever commission (or year) it paid.
  SELECT COALESCE(SUM(a.amount), 0)
    INTO v_received
    FROM commission_allocations a
    JOIN insurer_receipts r ON r.id = a.receipt_id
   WHERE a.agency_id = v_agency_id
     AND r.agency_id = v_agency_id
     AND r.received_on BETWEEN v_start AND v_end;

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

REVOKE EXECUTE ON FUNCTION public.generate_monthly_report(INTEGER, INTEGER) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.generate_monthly_report(INTEGER, INTEGER) TO authenticated;

-- ------------------------------------------------------------
-- 2. undo_commission_allocation: delete the allocation; a statement-
-- sourced commission left with no allocations is deleted too; a
-- statement line left with no allocations is unmatched again.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.undo_commission_allocation(p_allocation_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_agency  UUID := public.current_user_agency_id();
  v_rcpt_id UUID;
  v_alloc   commission_allocations;
BEGIN
  IF NOT public.is_owner_or_manager() THEN
    RAISE EXCEPTION 'Only owners and managers can do that' USING ERRCODE = '42501';
  END IF;

  SELECT r.id INTO v_rcpt_id
    FROM insurer_receipts r
   WHERE r.agency_id = v_agency
     AND r.id = (SELECT receipt_id FROM commission_allocations WHERE id = p_allocation_id)
     FOR UPDATE;
  IF v_rcpt_id IS NULL THEN
    RAISE EXCEPTION 'Receipt not found' USING ERRCODE = 'P0002';
  END IF;

  SELECT * INTO v_alloc FROM commission_allocations WHERE id = p_allocation_id;
  IF v_alloc.id IS NULL THEN
    -- removed concurrently while we waited for the receipt lock
    RAISE EXCEPTION 'Receipt not found' USING ERRCODE = 'P0002';
  END IF;

  PERFORM 1 FROM commission_transactions WHERE id = v_alloc.commission_id FOR UPDATE;

  DELETE FROM commission_allocations WHERE id = p_allocation_id;

  DELETE FROM commission_transactions ct
   WHERE ct.id = v_alloc.commission_id
     AND ct.source = 'statement'
     AND NOT EXISTS (SELECT 1 FROM commission_allocations a WHERE a.commission_id = ct.id);

  -- The line's money is unapplied again: unmatch it so it can be re-linked
  IF v_alloc.statement_line_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM commission_allocations a
                      WHERE a.statement_line_id = v_alloc.statement_line_id) THEN
    UPDATE statement_lines SET policy_id = NULL WHERE id = v_alloc.statement_line_id;
  END IF;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.undo_commission_allocation(UUID) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.undo_commission_allocation(UUID) TO authenticated;

-- ------------------------------------------------------------
-- 3. apply_receipt_allocations: apply unapplied receipt money.
--   p_allocations: [{commission_id, amount}, ...]
--   Returns {applied: applied by this call, unapplied: left on the
--   receipt afterwards}. Same checks and messages as the allocations
--   path of create_insurer_receipt; the cap is the receipt's unapplied
--   money. Locks: receipt FOR UPDATE, then commissions ascending id.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.apply_receipt_allocations(p_receipt_id UUID, p_allocations JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_agency    UUID := public.current_user_agency_id();
  v_rcpt      insurer_receipts;
  v_budget    NUMERIC;
  v_applied   NUMERIC := 0;
  v_alloc     JSONB;
  v_comm_id   UUID;
  v_amt       NUMERIC;
  v_ct_amount NUMERIC;
  v_ct_recv   NUMERIC;
  v_pol_ins   UUID;
BEGIN
  IF NOT public.is_owner_or_manager() THEN
    RAISE EXCEPTION 'Only owners and managers can do that' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_rcpt
    FROM insurer_receipts
   WHERE id = p_receipt_id AND agency_id = v_agency
     FOR UPDATE;
  IF v_rcpt.id IS NULL THEN
    RAISE EXCEPTION 'Receipt not found' USING ERRCODE = 'P0002';
  END IF;

  p_allocations := COALESCE(p_allocations, '[]'::jsonb);
  IF jsonb_typeof(p_allocations) <> 'array' OR jsonb_array_length(p_allocations) = 0 THEN
    RAISE EXCEPTION 'Enter an amount to apply';
  END IF;

  PERFORM 1
     FROM commission_transactions
    WHERE agency_id = v_agency
      AND id IN (SELECT NULLIF(a->>'commission_id', '')::uuid
                   FROM jsonb_array_elements(p_allocations) a)
    ORDER BY id
    FOR UPDATE;

  SELECT v_rcpt.amount - COALESCE(SUM(amount), 0) INTO v_budget
    FROM commission_allocations WHERE receipt_id = v_rcpt.id;

  FOR v_alloc IN SELECT value FROM jsonb_array_elements(p_allocations)
  LOOP
    v_comm_id := NULLIF(v_alloc->>'commission_id', '')::uuid;
    v_amt     := NULLIF(v_alloc->>'amount', '')::numeric;

    IF v_amt IS NULL OR v_amt <= 0 THEN
      RAISE EXCEPTION 'Enter an amount to apply';
    END IF;

    SELECT ct.amount, ct.amount_received, p.insurer_id
      INTO v_ct_amount, v_ct_recv, v_pol_ins
      FROM commission_transactions ct
      JOIN policies p ON p.id = ct.policy_id
     WHERE ct.id = v_comm_id AND ct.agency_id = v_agency;

    IF NOT FOUND OR v_pol_ins IS DISTINCT FROM v_rcpt.insurer_id THEN
      RAISE EXCEPTION 'That policy is not with this insurer';
    END IF;
    IF v_amt > v_ct_amount - v_ct_recv THEN
      RAISE EXCEPTION 'That commission is already fully received';
    END IF;
    IF v_applied + v_amt > v_budget THEN
      RAISE EXCEPTION 'Applied amount exceeds the receipt amount';
    END IF;

    INSERT INTO commission_allocations (agency_id, receipt_id, commission_id, amount)
    VALUES (v_agency, v_rcpt.id, v_comm_id, v_amt);
    v_applied := v_applied + v_amt;
  END LOOP;

  RETURN jsonb_build_object(
    'applied',   round(v_applied, 2),
    'unapplied', round(v_budget - v_applied, 2)
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.apply_receipt_allocations(UUID, JSONB) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.apply_receipt_allocations(UUID, JSONB) TO authenticated;
