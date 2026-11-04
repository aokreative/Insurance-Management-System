-- ============================================================
-- Migration 011: Receipts storage bucket and opening balances
--
--   1. Private storage bucket 'receipts' (10 MB, PDF only) and
--      storage.objects policies: owner/manager of the agency named
--      by the first path segment ({agency_id}/{receipt_id}.pdf) may
--      upload, read and delete. No UPDATE policy.
--   2. _backfill_opening_balances(p_agency_id): for each
--      agency x insurer with 'received' commissions that have no
--      allocations yet, one is_opening_balance receipt for their
--      total, allocated to each commission in full. Skips pairs
--      that already have an opening-balance receipt (idempotent).
--      Existing received rows already have amount_received = amount
--      (migration 009), so the recompute leaves every tally as is.
--   3. Run the backfill once for all agencies.
-- ============================================================

-- ------------------------------------------------------------
-- 1a. Bucket
-- ------------------------------------------------------------
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('receipts', 'receipts', false, 10485760, '{application/pdf}')
ON CONFLICT (id) DO UPDATE
  SET name               = EXCLUDED.name,
      public             = EXCLUDED.public,
      file_size_limit    = EXCLUDED.file_size_limit,
      allowed_mime_types = EXCLUDED.allowed_mime_types;

-- ------------------------------------------------------------
-- 1b. Storage policies (owner/manager, own agency folder)
-- ------------------------------------------------------------
DROP POLICY IF EXISTS receipts_owner_manager_insert ON storage.objects;
CREATE POLICY receipts_owner_manager_insert ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'receipts'
              AND (storage.foldername(name))[1] = public.current_user_agency_id()::text
              AND public.is_owner_or_manager());

DROP POLICY IF EXISTS receipts_owner_manager_select ON storage.objects;
CREATE POLICY receipts_owner_manager_select ON storage.objects
  FOR SELECT TO authenticated
  USING (bucket_id = 'receipts'
         AND (storage.foldername(name))[1] = public.current_user_agency_id()::text
         AND public.is_owner_or_manager());

DROP POLICY IF EXISTS receipts_owner_manager_delete ON storage.objects;
CREATE POLICY receipts_owner_manager_delete ON storage.objects
  FOR DELETE TO authenticated
  USING (bucket_id = 'receipts'
         AND (storage.foldername(name))[1] = public.current_user_agency_id()::text
         AND public.is_owner_or_manager());

-- ------------------------------------------------------------
-- 2. Opening balances
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._backfill_opening_balances(p_agency_id UUID DEFAULT NULL)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  g          RECORD;
  v_owner    UUID;
  v_receipt  UUID;
  v_count    INTEGER := 0;
BEGIN
  FOR g IN
    SELECT ct.agency_id,
           p.insurer_id,
           SUM(ct.amount)                               AS total,
           COALESCE(MAX(ct.received_date), current_date) AS received_on
      FROM commission_transactions ct
      JOIN policies p ON p.id = ct.policy_id
     WHERE ct.status = 'received'
       AND (p_agency_id IS NULL OR ct.agency_id = p_agency_id)
       AND NOT EXISTS (SELECT 1 FROM commission_allocations a WHERE a.commission_id = ct.id)
       AND NOT EXISTS (SELECT 1 FROM insurer_receipts r
                        WHERE r.agency_id = ct.agency_id
                          AND r.insurer_id = p.insurer_id
                          AND r.is_opening_balance)
     GROUP BY ct.agency_id, p.insurer_id
     ORDER BY ct.agency_id, p.insurer_id
  LOOP
    SELECT u.id INTO v_owner
      FROM users u
     WHERE u.agency_id = g.agency_id AND u.role = 'owner'
     ORDER BY u.deactivated_at NULLS FIRST, u.created_at
     LIMIT 1;

    INSERT INTO insurer_receipts
      (agency_id, insurer_id, received_on, amount, bank_reference, file_path,
       notes, is_opening_balance, created_by)
    VALUES
      (g.agency_id, g.insurer_id, g.received_on, g.total, NULL, NULL,
       'Opening balance (before receipts were tracked)', true, v_owner)
    RETURNING id INTO v_receipt;

    -- The allocation trigger sets amount_received = amount (unchanged)
    INSERT INTO commission_allocations (agency_id, receipt_id, commission_id, amount, created_by)
    SELECT ct.agency_id, v_receipt, ct.id, ct.amount, v_owner
      FROM commission_transactions ct
      JOIN policies p ON p.id = ct.policy_id
     WHERE ct.status = 'received'
       AND ct.agency_id = g.agency_id
       AND p.insurer_id = g.insurer_id
       AND NOT EXISTS (SELECT 1 FROM commission_allocations a WHERE a.commission_id = ct.id)
     ORDER BY ct.expected_date, ct.id;

    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$$;

REVOKE EXECUTE ON FUNCTION public._backfill_opening_balances(UUID) FROM PUBLIC, anon, authenticated;

-- ------------------------------------------------------------
-- 3. Run once for every agency
-- ------------------------------------------------------------
SELECT public._backfill_opening_balances();
