-- ============================================================
-- Migration 010: Reconciliation RPCs
--
--   create_insurer_receipt  - receipt + statement lines + allocations
--   link_statement_line     - match an unmatched line and apply it
--   undo_commission_allocation
--   delete_insurer_receipt
--   _apply_line             - internal: apply one line (not callable
--                             by API roles)
--
-- All SECURITY DEFINER with search_path pinned, owner/manager only.
-- Every write path locks the receipt row FOR UPDATE first, then the
-- commission rows it touches in ascending id order, so concurrent
-- calls on the same receipt / commission serialise without
-- deadlocking. The allocation trigger from 009 re-checks the caps
-- and the insurer match as a backstop (same messages).
--
-- Also drops mark_overdue_commissions(): overdue is derived now.
--
-- (The per-premium period default in _apply_line - period falls back
-- to received_on - was applied live as migration
-- 010a_apply_line_period_default, and the budget check in
-- link_statement_line as 010b_link_requires_budget; this file is the
-- full source.)
-- ============================================================

DROP FUNCTION IF EXISTS public.mark_overdue_commissions();

-- ------------------------------------------------------------
-- _apply_line: applies a stored, matched line from the receipt's
-- money, at most p_budget. Returns the amount applied.
--   annual      -> the policy's commissions with money outstanding,
--                  oldest expected_date first, up to the line's
--                  commission.
--   per_premium -> a new source='statement' commission for the line
--                  (amount = line commission; period and expected_date =
--                  the line's period, else the receipt's received_on),
--                  allocated up to the budget.
-- Zero / negative lines and unmatched lines apply nothing.
-- The caller has validated the policy (agency + insurer) and holds
-- the receipt lock and the commission locks.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._apply_line(p_line_id UUID, p_budget NUMERIC)
RETURNS NUMERIC
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_line    statement_lines;
  v_rcpt    insurer_receipts;
  v_basis   TEXT;
  v_left    NUMERIC;
  v_applied NUMERIC := 0;
  v_take    NUMERIC;
  v_comm_id UUID;
  c         RECORD;
BEGIN
  SELECT * INTO v_line FROM statement_lines WHERE id = p_line_id;
  IF v_line.id IS NULL OR v_line.policy_id IS NULL OR v_line.commission <= 0 THEN
    RETURN 0;
  END IF;

  v_left := LEAST(v_line.commission, COALESCE(p_budget, 0));
  IF v_left <= 0 THEN
    RETURN 0;
  END IF;

  SELECT * INTO v_rcpt FROM insurer_receipts WHERE id = v_line.receipt_id;
  SELECT commission_basis INTO v_basis FROM policies WHERE id = v_line.policy_id;

  IF v_basis = 'per_premium' THEN
    INSERT INTO commission_transactions
      (policy_id, agency_id, amount, period, expected_date, source, notes)
    VALUES
      (v_line.policy_id, v_line.agency_id, v_line.commission,
       COALESCE(v_line.period, v_rcpt.received_on),
       COALESCE(v_line.period, v_rcpt.received_on), 'statement', 'From statement')
    RETURNING id INTO v_comm_id;

    INSERT INTO commission_allocations
      (agency_id, receipt_id, commission_id, statement_line_id, amount)
    VALUES (v_line.agency_id, v_line.receipt_id, v_comm_id, v_line.id, v_left);
    RETURN v_left;
  END IF;

  -- annual
  FOR c IN
    SELECT id, amount - amount_received AS remaining
      FROM commission_transactions
     WHERE policy_id = v_line.policy_id
       AND amount - amount_received > 0
     ORDER BY expected_date NULLS LAST, id
  LOOP
    EXIT WHEN v_left <= 0;
    v_take := LEAST(c.remaining, v_left);
    INSERT INTO commission_allocations
      (agency_id, receipt_id, commission_id, statement_line_id, amount)
    VALUES (v_line.agency_id, v_line.receipt_id, c.id, v_line.id, v_take);
    v_left    := v_left - v_take;
    v_applied := v_applied + v_take;
  END LOOP;

  RETURN v_applied;
END;
$$;

REVOKE EXECUTE ON FUNCTION public._apply_line(UUID, NUMERIC) FROM PUBLIC, anon, authenticated;

-- ------------------------------------------------------------
-- create_insurer_receipt
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_insurer_receipt(
  p_insurer_id     UUID,
  p_received_on    DATE,
  p_amount         NUMERIC,
  p_bank_reference TEXT,
  p_file_path      TEXT,
  p_lines          JSONB,
  p_allocations    JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_agency    UUID := public.current_user_agency_id();
  v_receipt   UUID;
  v_applied   NUMERIC := 0;
  v_line      JSONB;
  v_line_no   BIGINT;
  v_line_id   UUID;
  v_policy_id UUID;
  v_comm      NUMERIC;
  v_basis     TEXT;
  v_demand    NUMERIC;
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

  PERFORM 1 FROM insurers WHERE id = p_insurer_id AND agency_id = v_agency;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Insurer not found' USING ERRCODE = 'P0002';
  END IF;

  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'Enter the amount received';
  END IF;
  IF p_received_on IS NULL THEN
    RAISE EXCEPTION 'Enter the date received';
  END IF;

  p_lines       := COALESCE(p_lines, '[]'::jsonb);
  p_allocations := COALESCE(p_allocations, '[]'::jsonb);

  INSERT INTO insurer_receipts (agency_id, insurer_id, received_on, amount, bank_reference, file_path)
  VALUES (v_agency, p_insurer_id, p_received_on, p_amount, p_bank_reference, p_file_path)
  RETURNING id INTO v_receipt;

  -- Lock order: receipt, then every commission this call may touch
  -- (annual lines' policies and explicit allocations), ascending id.
  PERFORM 1 FROM insurer_receipts WHERE id = v_receipt FOR UPDATE;
  PERFORM 1
     FROM commission_transactions
    WHERE agency_id = v_agency
      AND (policy_id IN (SELECT NULLIF(l->>'policy_id', '')::uuid
                           FROM jsonb_array_elements(p_lines) l)
           OR id IN (SELECT NULLIF(a->>'commission_id', '')::uuid
                       FROM jsonb_array_elements(p_allocations) a))
    ORDER BY id
    FOR UPDATE;

  -- Statement lines, in order
  FOR v_line, v_line_no IN
    SELECT value, ordinality FROM jsonb_array_elements(p_lines) WITH ORDINALITY
  LOOP
    v_policy_id := NULLIF(v_line->>'policy_id', '')::uuid;
    v_comm      := NULLIF(v_line->>'commission', '')::numeric;

    IF v_comm IS NULL THEN
      RAISE EXCEPTION 'Enter the commission for each line';
    END IF;

    IF v_policy_id IS NOT NULL THEN
      SELECT commission_basis INTO v_basis
        FROM policies
       WHERE id = v_policy_id AND agency_id = v_agency AND insurer_id = p_insurer_id;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'That policy is not with this insurer';
      END IF;
    END IF;

    INSERT INTO statement_lines
      (agency_id, receipt_id, line_no, policy_number, client_name, premium, commission, period, policy_id)
    VALUES
      (v_agency, v_receipt, v_line_no, v_line->>'policy_number', v_line->>'client_name',
       NULLIF(v_line->>'premium', '')::numeric, v_comm,
       NULLIF(v_line->>'period', '')::date, v_policy_id)
    RETURNING id INTO v_line_id;

    IF v_policy_id IS NOT NULL AND v_comm > 0 THEN
      -- What the line would apply without a budget; more than the
      -- money left on the receipt is an error here (the user confirmed
      -- these amounts), not a silent cap.
      IF v_basis = 'per_premium' THEN
        v_demand := v_comm;
      ELSE
        SELECT LEAST(v_comm, COALESCE(SUM(amount - amount_received), 0)) INTO v_demand
          FROM commission_transactions
         WHERE policy_id = v_policy_id AND amount - amount_received > 0;
      END IF;

      IF v_applied + v_demand > p_amount THEN
        RAISE EXCEPTION 'Applied amount exceeds the receipt amount';
      END IF;

      v_applied := v_applied + public._apply_line(v_line_id, p_amount - v_applied);
    END IF;
  END LOOP;

  -- Explicit allocations
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

    IF NOT FOUND OR v_pol_ins IS DISTINCT FROM p_insurer_id THEN
      RAISE EXCEPTION 'That policy is not with this insurer';
    END IF;
    IF v_amt > v_ct_amount - v_ct_recv THEN
      RAISE EXCEPTION 'That commission is already fully received';
    END IF;
    IF v_applied + v_amt > p_amount THEN
      RAISE EXCEPTION 'Applied amount exceeds the receipt amount';
    END IF;

    INSERT INTO commission_allocations (agency_id, receipt_id, commission_id, amount)
    VALUES (v_agency, v_receipt, v_comm_id, v_amt);
    v_applied := v_applied + v_amt;
  END LOOP;

  SELECT COALESCE(SUM(amount), 0) INTO v_applied
    FROM commission_allocations WHERE receipt_id = v_receipt;

  RETURN jsonb_build_object(
    'receipt_id', v_receipt,
    'applied',    round(v_applied, 2),
    'unapplied',  round(p_amount - v_applied, 2)
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.create_insurer_receipt(UUID, DATE, NUMERIC, TEXT, TEXT, JSONB, JSONB) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.create_insurer_receipt(UUID, DATE, NUMERIC, TEXT, TEXT, JSONB, JSONB) TO authenticated;

-- ------------------------------------------------------------
-- link_statement_line: match an unmatched line and apply it from the
-- receipt's unapplied money (annual lines capped by it; per-premium
-- lines need the full commission).
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.link_statement_line(p_line_id UUID, p_policy_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_agency  UUID := public.current_user_agency_id();
  v_rcpt    insurer_receipts;
  v_line    statement_lines;
  v_basis   TEXT;
  v_budget  NUMERIC;
  v_applied NUMERIC;
BEGIN
  IF NOT public.is_owner_or_manager() THEN
    RAISE EXCEPTION 'Only owners and managers can do that' USING ERRCODE = '42501';
  END IF;

  -- Lock the receipt first, then re-read the line under that lock
  SELECT r.* INTO v_rcpt
    FROM insurer_receipts r
   WHERE r.agency_id = v_agency
     AND r.id = (SELECT receipt_id FROM statement_lines WHERE id = p_line_id)
     FOR UPDATE;
  IF v_rcpt.id IS NULL THEN
    RAISE EXCEPTION 'Receipt not found' USING ERRCODE = 'P0002';
  END IF;

  SELECT * INTO v_line FROM statement_lines WHERE id = p_line_id;
  IF v_line.policy_id IS NOT NULL THEN
    RAISE EXCEPTION 'That line is already matched';
  END IF;

  SELECT commission_basis INTO v_basis FROM policies
   WHERE id = p_policy_id AND agency_id = v_agency AND insurer_id = v_rcpt.insurer_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'That policy is not with this insurer';
  END IF;

  PERFORM 1 FROM commission_transactions WHERE policy_id = p_policy_id ORDER BY id FOR UPDATE;

  SELECT v_rcpt.amount - COALESCE(SUM(amount), 0) INTO v_budget
    FROM commission_allocations WHERE receipt_id = v_rcpt.id;

  -- A line that would apply something needs money on the receipt, or
  -- it would end up matched with nothing applied (and could not be
  -- re-linked). Per-premium lines are applied in full, as in create.
  -- Lines that apply nothing (commission <= 0, or an annual policy
  -- with nothing outstanding) may still be linked.
  IF v_line.commission > 0 THEN
    IF v_basis = 'per_premium' THEN
      IF v_budget < v_line.commission THEN
        RAISE EXCEPTION 'Applied amount exceeds the receipt amount';
      END IF;
    ELSIF v_budget <= 0
          AND EXISTS (SELECT 1 FROM commission_transactions
                       WHERE policy_id = p_policy_id AND amount - amount_received > 0) THEN
      RAISE EXCEPTION 'Applied amount exceeds the receipt amount';
    END IF;
  END IF;

  UPDATE statement_lines SET policy_id = p_policy_id WHERE id = p_line_id;

  v_applied := public._apply_line(p_line_id, v_budget);

  RETURN jsonb_build_object('applied', round(v_applied, 2));
END;
$$;

REVOKE EXECUTE ON FUNCTION public.link_statement_line(UUID, UUID) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.link_statement_line(UUID, UUID) TO authenticated;

-- ------------------------------------------------------------
-- undo_commission_allocation: delete the allocation; a statement-
-- sourced commission left with no allocations is deleted too.
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
END;
$$;

REVOKE EXECUTE ON FUNCTION public.undo_commission_allocation(UUID) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.undo_commission_allocation(UUID) TO authenticated;

-- ------------------------------------------------------------
-- delete_insurer_receipt: only with nothing applied; lines cascade.
-- Opening-balance receipts are never deleted here.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.delete_insurer_receipt(p_receipt_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_agency UUID := public.current_user_agency_id();
  v_rcpt   insurer_receipts;
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

  IF v_rcpt.is_opening_balance THEN
    RAISE EXCEPTION 'Opening balance receipts cannot be deleted';
  END IF;

  IF EXISTS (SELECT 1 FROM commission_allocations WHERE receipt_id = p_receipt_id) THEN
    RAISE EXCEPTION 'Undo the applied amounts before deleting this receipt';
  END IF;

  DELETE FROM insurer_receipts WHERE id = p_receipt_id;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.delete_insurer_receipt(UUID) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.delete_insurer_receipt(UUID) TO authenticated;
