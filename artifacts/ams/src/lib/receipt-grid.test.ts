import { describe, expect, it } from 'vitest';
import { isRealCalendarDate, rowErrors, rowToDraft, normalisePeriodText, emptyRow, parsePastedRows, isMultiCellPaste } from './receipt-grid';

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
  it('blank row has no errors', () => expect(rowErrors(emptyRow())).toEqual({ amount: false, premium: false, date: false }));
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
    const d = rowToDraft({ id: 'x', policyNumber: ' P1 ', clientName: 'A', premium: '1,000', commission: '12.5', period: '5/3/2025' });
    expect(d).toEqual({ policyNumber: 'P1', clientName: 'A', premiumCents: 100000, commissionCents: 1250, period: '2025-03-05' });
    expect(normalisePeriodText('x')).toBeNull();
  });
});

describe('pasted rows', () => {
  it('keeps unparsed raw text so validation flags it', () => {
    const [r] = parsePastedRows('P1\tAnn\t12x\t100\t31/02/2025\n');
    expect(r.premium).toBe('12x');
    expect(r.period).toBe('31/02/2025');
    expect(rowErrors(r)).toEqual({ amount: false, premium: true, date: true });
    const [b] = parsePastedRows('P1\tAnn\t100\tabc\t');
    expect(rowErrors(b).amount).toBe(true);
  });
  it('gives each pasted row a unique id and ignores trailing newline', () => {
    const rows = parsePastedRows('P1\tA\t1\t2\t\nP2\tB\t1\t2\t\n');
    expect(rows).toHaveLength(2);
    expect(rows[0].id).not.toBe(rows[1].id);
  });
  it('single Excel cell with trailing newline is not a multi-row paste', () => {
    expect(isMultiCellPaste('1234\n')).toBe(false);
    expect(isMultiCellPaste('a\tb')).toBe(true);
    expect(isMultiCellPaste('a\nb')).toBe(true);
  });
});
