import { describe, expect, it } from 'vitest';
import { projectedMonthlyCommission, isPastFirstYear } from './projection';

describe('projectedMonthlyCommission', () => {
  const now = new Date(2026, 5, 15);
  const p = (o: object) => ({
    instalment_premium: 1000,
    premium_frequency: 'monthly' as const,
    commission_rate: 10,
    renewal_commission_rate: null,
    start_date: '2026-01-01',
    ...o,
  });
  it('monthly, quarterly, half-yearly, yearly', () => {
    expect(projectedMonthlyCommission([p({})], now)).toBeCloseTo(100);
    expect(projectedMonthlyCommission([p({ premium_frequency: 'quarterly' })], now)).toBeCloseTo(100 / 3);
    expect(projectedMonthlyCommission([p({ premium_frequency: 'half_yearly' })], now)).toBeCloseTo(100 / 6);
    expect(projectedMonthlyCommission([p({ premium_frequency: 'yearly' })], now)).toBeCloseTo(100 / 12);
  });
  it('uses renewal rate only after 12 months', () => {
    const old = p({ start_date: '2025-01-01', renewal_commission_rate: 2 });
    expect(projectedMonthlyCommission([old], now)).toBeCloseTo(20);
    expect(isPastFirstYear('2025-06-15', now)).toBe(false);
    expect(isPastFirstYear('2025-05-15', now)).toBe(true);
    expect(projectedMonthlyCommission([p({ renewal_commission_rate: 2 })], now)).toBeCloseTo(100);
    expect(projectedMonthlyCommission([p({ start_date: '2025-01-01' })], now)).toBeCloseTo(100);
  });
});
