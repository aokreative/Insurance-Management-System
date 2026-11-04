import { describe, expect, it } from 'vitest';
import { isRealCalendarDate, rowErrors, rowToDraft, normalisePeriodText, emptyRow } from './receipt-grid';

describe('isRealCalendarDate', () => {
  it('accepts real dates incl. leap day', () => {
    expect(isRealCalendarDate('2024-02-29')).toBe(true);
    expect(isRealCalendarDate('2025-12-31')).toBe(true);
  });
  it('rejects impossible dates', () => {
    expect(isRealCalendarDate('2025-02-29')).toBe(false);
    expect(isRealCalendarDate('2025-13-01')).toBe(false);
    expect(isRealCalendarDate('2025-04-31')).toBe(false);
    expect(isRealCalendarDate('2025-00-10')).toBe(false);
    expect(isRealCalendarDate('nope')).toBe(false);
  });
});

describe('rowErrors', () => {
  const base = { ...emptyRow(), policyNumber: 'P1', commission: '100' };
  it('blank row has no errors', () => expect(rowErrors(emptyRow())).toEqual({ amount: false, date: false }));
  it('flags unparseable or missing commission', () => {
    expect(rowErrors({ ...base, commission: 'abc' }).amount).toBe(true);
    expect(rowErrors({ ...base, commission: '' }).amount).toBe(true);
    expect(rowErrors(base).amount).toBe(false);
  });
  it('allows negative commission (reversal) but flags bad dates', () => {
    expect(rowErrors({ ...base, commission: '-50' }).amount).toBe(false);
    expect(rowErrors({ ...base, period: '2025-02-30' }).date).toBe(true);
    expect(rowErrors({ ...base, period: '31/04/2025' }).date).toBe(true);
    expect(rowErrors({ ...base, period: 'garbage' }).date).toBe(true);
    expect(rowErrors({ ...base, period: '2025-02-28' }).date).toBe(false);
    expect(rowErrors({ ...base, period: '3/2025' }).date).toBe(false);
  });
});

describe('rowToDraft / normalisePeriodText', () => {
  it('converts cells', () => {
    const d = rowToDraft({ policyNumber: ' P1 ', clientName: 'A', premium: '1,000', commission: '12.5', period: '5/3/2025' });
    expect(d).toEqual({ policyNumber: 'P1', clientName: 'A', premiumCents: 100000, commissionCents: 1250, period: '2025-03-05' });
    expect(normalisePeriodText('x')).toBeNull();
  });
});
