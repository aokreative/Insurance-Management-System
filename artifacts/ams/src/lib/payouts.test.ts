import { describe, it, expect } from 'vitest';
import { sumCents, earningLabel, methodLabel } from './payouts';

describe('sumCents', () => {
  it('sums mixed strings and numbers', () => {
    expect(sumCents([{ amount: '10.50' }, { amount: 2 }, { amount: '0.25' }])).toBe(1275);
  });
  it('handles negatives', () => {
    expect(sumCents([{ amount: '100.00' }, { amount: -30.5 }, { amount: '-0.5' }])).toBe(6900);
  });
  it('avoids float drift', () => {
    expect(sumCents([{ amount: '0.10' }, { amount: '0.20' }])).toBe(30);
  });
  it('is zero for no lines', () => {
    expect(sumCents([])).toBe(0);
  });
});

describe('earningLabel', () => {
  it('labels kinds', () => {
    expect(earningLabel({ kind: 'commission', note: null })).toBe('Commission');
    expect(earningLabel({ kind: 'reversal', note: null })).toBe('Reversal');
  });
  it('uses the note for adjustments', () => {
    expect(earningLabel({ kind: 'adjustment', note: 'Bonus Q3' })).toBe('Bonus Q3');
    expect(earningLabel({ kind: 'adjustment', note: null })).toBe('Adjustment');
  });
});

describe('methodLabel', () => {
  it('maps methods', () => {
    expect(methodLabel('mpesa')).toBe('M-Pesa');
    expect(methodLabel('bank')).toBe('Bank transfer');
    expect(methodLabel('cash')).toBe('Cash');
  });
});
