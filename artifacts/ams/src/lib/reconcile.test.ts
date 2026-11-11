import { describe, expect, it } from 'vitest';
import {
  toCents,
  normalisePolicyNumber,
  parsePastedLines,
  matchLines,
  totalCents,
  type DraftLine,
} from './reconcile';

const line = (policyNumber: string, commissionCents: number | null): DraftLine => ({
  policyNumber,
  clientName: 'X',
  premiumCents: null,
  commissionCents,
  period: null,
});

describe('toCents', () => {
  it('parses KES with commas', () => expect(toCents('KES 12,345.00')).toBe(1234500));
  it('parses parentheses as negative', () => expect(toCents('(1,250.00)')).toBe(-125000));
  it('parses leading minus', () => expect(toCents('-10.50')).toBe(-1050));
  it('returns null for invalid', () => expect(toCents('abc')).toBeNull());
});

describe('normalisePolicyNumber', () => {
  it('lowercases and strips punctuation', () =>
    expect(normalisePolicyNumber('BRI/MP-2025/01111')).toBe('brimp202501111'));
});

describe('parsePastedLines', () => {
  it('splits tabs into 5 fields even with comma amounts', () => {
    const [l] = parsePastedLines('BRI/1\tJohn Doe\t10,000.00\t1,500.00\t2026-10-05');
    expect(l).toEqual({
      policyNumber: 'BRI/1',
      clientName: 'John Doe',
      premiumCents: 1000000,
      commissionCents: 150000,
      period: '2026-10-05',
    });
  });
  it('splits on 2+ spaces and skips blank lines', () => {
    const r = parsePastedLines('BRI/1  John Doe  10,000.00  1,500.00  05/10/2026\n\n');
    expect(r).toHaveLength(1);
    expect(r[0].clientName).toBe('John Doe');
    expect(r[0].period).toBe('2026-10-05');
  });
  it('splits comma-separated 5-field lines', () => {
    const [l] = parsePastedLines('BRI/1,John Doe,10000,1500,2026-10-05');
    expect(l.commissionCents).toBe(150000);
  });
  it('maps MM/YYYY to first of month', () => {
    const [l] = parsePastedLines('P1\tA\t1\t1\t10/2026');
    expect(l.period).toBe('2026-10-01');
  });
  it('invalid period is null', () => {
    const [l] = parsePastedLines('P1\tA\t1\t1\tsoon');
    expect(l.period).toBeNull();
  });
});

describe('matchLines', () => {
  const policies = [
    { id: 'a', policy_number: 'BRI/A', commission_basis: 'annual' as const, outstandingCents: 10000 },
    { id: 'p', policy_number: 'BRI/P', commission_basis: 'per_premium' as const, outstandingCents: 0 },
  ];
  it('matched when equal', () => {
    const [r] = matchLines([line('bri/a', 10000)], policies);
    expect(r).toMatchObject({ policyId: 'a', status: 'matched', applyCents: 10000 });
  });
  it('short when less', () => {
    const [r] = matchLines([line('BRI/A', 4000)], policies);
    expect(r).toMatchObject({ status: 'short', applyCents: 4000 });
  });
  it('over when more', () => {
    const [r] = matchLines([line('BRI/A', 15000)], policies);
    expect(r).toMatchObject({ status: 'over', applyCents: 10000 });
  });
  it('unmatched', () => {
    const [r] = matchLines([line('NOPE', 100)], policies);
    expect(r).toMatchObject({ policyId: null, status: 'unmatched', applyCents: 0 });
  });
  it('reversal for negative, also unmatched', () => {
    const r = matchLines([line('BRI/A', -500), line('NOPE', -500)], policies);
    expect(r.map((x) => x.status)).toEqual(['reversal', 'reversal']);
    expect(r.map((x) => x.applyCents)).toEqual([0, 0]);
  });
  it('per_premium is new_commission', () => {
    const [r] = matchLines([line('BRI/P', 700)], policies);
    expect(r).toMatchObject({ policyId: 'p', status: 'new_commission', applyCents: 700 });
  });
  it('same number on two terms: the older term with outstanding wins', () => {
    const terms = [
      { id: 'new', policy_number: 'BRI/R', commission_basis: 'annual' as const, outstandingCents: 9000, start_date: '2026-06-01' },
      { id: 'old', policy_number: 'BRI/R', commission_basis: 'annual' as const, outstandingCents: 3000, start_date: '2025-06-01' },
    ];
    const r = matchLines([line('BRI/R', 3000), line('BRI/R', 9000)], terms);
    expect(r.map((x) => x.policyId)).toEqual(['old', 'new']);
    expect(r.map((x) => x.status)).toEqual(['matched', 'matched']);
  });
  it('same number: a small leftover on the old term does not swallow the new term payment', () => {
    const terms = [
      { id: 'old', policy_number: 'BRI/R', commission_basis: 'annual' as const, outstandingCents: 1000, start_date: '2025-06-01' },
      { id: 'new', policy_number: 'BRI/R', commission_basis: 'annual' as const, outstandingCents: 500000, start_date: '2026-06-01' },
    ];
    const r = matchLines([line('BRI/R', 500000), line('BRI/R', 1000)], terms);
    expect(r.map((x) => x.policyId)).toEqual(['new', 'old']);
    expect(r.map((x) => x.status)).toEqual(['matched', 'matched']);
  });
  it('same number, nothing outstanding: the latest term wins', () => {
    const terms = [
      { id: 'old', policy_number: 'BRI/R', commission_basis: 'annual' as const, outstandingCents: 0, start_date: '2025-06-01' },
      { id: 'new', policy_number: 'BRI/R', commission_basis: 'annual' as const, outstandingCents: 0, start_date: '2026-06-01' },
    ];
    const [r] = matchLines([line('BRI/R', 500)], terms);
    expect(r).toMatchObject({ policyId: 'new', status: 'over', applyCents: 0 });
  });
  it('consumes outstanding sequentially', () => {
    const r = matchLines([line('BRI/A', 6000), line('BRI/A', 6000), line('BRI/A', 1)], policies);
    expect(r.map((x) => x.status)).toEqual(['short', 'over', 'over']);
    expect(r.map((x) => x.applyCents)).toEqual([6000, 4000, 0]);
  });
  it('second line short with remaining', () => {
    const r = matchLines([line('BRI/A', 6000), line('BRI/A', 3000)], policies);
    expect(r[1]).toMatchObject({ status: 'short', applyCents: 3000 });
  });
});

describe('totalCents', () => {
  it('sums commissions ignoring null', () =>
    expect(totalCents([line('a', 100), line('b', null), line('c', -30)])).toBe(70));
});
