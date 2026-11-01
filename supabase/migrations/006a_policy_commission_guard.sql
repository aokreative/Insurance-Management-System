-- ============================================================
-- Migration 006a: Guard policies.commission_received
--
-- Commissions are read-only for Agents, but RLS cannot restrict
-- columns: an Agent may insert/update their own policies, which
-- would otherwise let them set commission_received (the per-policy
-- received tally the dashboard sums) to any value.
--
-- For callers who are not Owner/Manager:
--   INSERT -> commission_received is forced to 0 (the app already
--             sends 0, so agents' policy creation keeps working)
--   UPDATE -> changing commission_received is rejected (42501)
--
-- Calls with no JWT (auth.uid() IS NULL: SQL editor, service_role,
-- cron) are trusted and pass through; anon cannot write policies
-- because RLS has no anon policy.
-- ============================================================

CREATE OR REPLACE FUNCTION public.guard_policy_commission_received()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_owner_or_manager() THEN
    IF TG_OP = 'INSERT' THEN
      NEW.commission_received := 0;
    ELSIF NEW.commission_received IS DISTINCT FROM OLD.commission_received THEN
      RAISE EXCEPTION 'Only owners and managers can record commission received'
        USING ERRCODE = '42501';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.guard_policy_commission_received() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_guard_policy_commission_received ON policies;
CREATE TRIGGER trg_guard_policy_commission_received
  BEFORE INSERT OR UPDATE ON policies
  FOR EACH ROW
  EXECUTE FUNCTION public.guard_policy_commission_received();
