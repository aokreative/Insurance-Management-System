import { describe, expect, it } from 'vitest';
import { autoCommissionBasis } from './policy-form';

describe('autoCommissionBasis', () => {
  it('Life defaults to per premium, other lines to annual', () => {
    expect(autoCommissionBasis('Life', false)).toBe('per_premium');
    expect(autoCommissionBasis('Medical', false)).toBe('annual');
  });
  it('leaves a basis the user (or a pre-filled renewal) already chose', () => {
    expect(autoCommissionBasis('Medical', true)).toBeNull();
    expect(autoCommissionBasis('Life', true)).toBeNull();
  });
  it('no product line yet: nothing to set', () => {
    expect(autoCommissionBasis(undefined, false)).toBeNull();
  });
});
