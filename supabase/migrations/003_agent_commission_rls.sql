-- ============================================================
-- Migration 003: Agent-scoped commission_transactions RLS
-- Replace the blanket agency-wide policy with role-aware ones.
-- Run this in your Supabase SQL Editor.
-- ============================================================

-- Drop existing catch-all policy
DROP POLICY IF EXISTS "commission_tx_all" ON commission_transactions;

-- Owners & admins see every transaction in their agency
CREATE POLICY "commission_tx_owner_admin"
  ON commission_transactions FOR ALL
  USING (
    agency_id = public.current_user_agency_id()
    AND public.current_user_role() IN ('owner', 'admin')
  );

-- Agents see only transactions on policies they own
CREATE POLICY "commission_tx_agent"
  ON commission_transactions FOR ALL
  USING (
    agency_id = public.current_user_agency_id()
    AND public.current_user_role() = 'agent'
    AND policy_id IN (
      SELECT id FROM policies
      WHERE agency_id = public.current_user_agency_id()
        AND agent_id = auth.uid()
    )
  );
