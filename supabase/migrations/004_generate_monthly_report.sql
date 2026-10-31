-- ============================================================
-- Migration 004: generate_monthly_report RPC
-- Replaces the Express POST /api/reports/generate route so the
-- frontend can run as a static site (Vercel) with no API server.
-- SECURITY INVOKER: runs under the caller's RLS, so it only ever
-- sees the caller's agency.
-- ============================================================

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
  IF v_role NOT IN ('owner', 'admin') THEN
    RAISE EXCEPTION 'Only owners and admins can generate reports' USING ERRCODE = '42501';
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

REVOKE EXECUTE ON FUNCTION public.generate_monthly_report FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.generate_monthly_report TO authenticated;
