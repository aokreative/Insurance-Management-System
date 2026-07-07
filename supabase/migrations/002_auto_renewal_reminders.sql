-- ============================================================
-- Migration 002: Auto-schedule renewal reminders on policy INSERT
-- Run this in Supabase SQL Editor after 001_initial_schema.sql
-- ============================================================

-- Function: auto-create pending reminders at 90, 60, 30 days before expiry
CREATE OR REPLACE FUNCTION auto_create_renewal_reminders()
RETURNS TRIGGER AS $$
DECLARE
  days_before INTEGER;
  reminder_days INTEGER[] := ARRAY[90, 60, 30];
  target_date DATE;
BEGIN
  FOREACH days_before IN ARRAY reminder_days
  LOOP
    target_date := NEW.expiry_date - days_before;
    -- Only schedule if the reminder date is still in the future
    IF target_date > CURRENT_DATE THEN
      INSERT INTO renewal_reminders (
        policy_id, agency_id, reminder_date, channel, sent
      ) VALUES (
        NEW.id, NEW.agency_id, target_date, 'email', false
      )
      ON CONFLICT DO NOTHING;
    END IF;
  END LOOP;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Trigger: fires after each new policy row is inserted
DROP TRIGGER IF EXISTS trg_auto_renewal_reminders ON policies;

CREATE TRIGGER trg_auto_renewal_reminders
  AFTER INSERT ON policies
  FOR EACH ROW
  EXECUTE FUNCTION auto_create_renewal_reminders();

-- ============================================================
-- Function: mark overdue commissions (call periodically or via cron)
-- Sets status='overdue' for pending commissions whose expected_date has passed.
-- ============================================================
CREATE OR REPLACE FUNCTION mark_overdue_commissions()
RETURNS INTEGER AS $$
DECLARE
  updated_count INTEGER;
BEGIN
  UPDATE commission_transactions
  SET status = 'overdue'
  WHERE status = 'pending'
    AND expected_date < CURRENT_DATE;
  GET DIAGNOSTICS updated_count = ROW_COUNT;
  RETURN updated_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
