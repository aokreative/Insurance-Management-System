import { describe, expect, it } from 'vitest';
import {
  canUpdateRenewals,
  channelLabel,
  defaultRenewalDates,
  lostReasonLabel,
  renewalRate,
  stageLabel,
} from './renewals';

describe('defaultRenewalDates', () => {
  it('starts the day after expiry and runs one year less a day', () => {
    expect(defaultRenewalDates('2026-12-31')).toEqual({ start: '2027-01-01', expiry: '2027-12-31' });
  });
  it('starts on 29 Feb in a leap year', () => {
    expect(defaultRenewalDates('2028-02-28')).toEqual({ start: '2028-02-29', expiry: '2029-02-28' });
  });
  it('ends on 29 Feb when the year after a 1 March start is a leap year', () => {
    expect(defaultRenewalDates('2027-02-28')).toEqual({ start: '2027-03-01', expiry: '2028-02-29' });
  });
  it('mid-year', () => {
    expect(defaultRenewalDates('2026-11-30')).toEqual({ start: '2026-12-01', expiry: '2027-11-30' });
  });
});

describe('renewalRate', () => {
  it('renewed share as a percentage', () => {
    expect(renewalRate(3, 1)).toBe(75);
  });
  it('null when nothing closed', () => {
    expect(renewalRate(0, 0)).toBeNull();
  });
  it('zero when all lost', () => {
    expect(renewalRate(0, 2)).toBe(0);
  });
  it('rounds to one decimal', () => {
    expect(renewalRate(1, 2)).toBe(33.3);
  });
});

describe('labels', () => {
  it('stages', () => {
    expect(['to_contact', 'contacted', 'quoted', 'renewed', 'lost'].map((s) => stageLabel(s as never))).toEqual([
      'To contact',
      'Contacted',
      'Quoted',
      'Renewed',
      'Lost',
    ]);
  });
  it('channels', () => {
    expect(['phone', 'whatsapp', 'sms', 'email', 'in_person'].map((c) => channelLabel(c as never))).toEqual([
      'Phone',
      'WhatsApp',
      'SMS',
      'Email',
      'In person',
    ]);
  });
  it('lost reasons', () => {
    expect(
      ['price', 'competitor', 'no_longer_needed', 'no_response', 'other'].map((r) => lostReasonLabel(r as never)),
    ).toEqual(['Price', 'Went to another agent/insurer', 'No longer needs cover', 'No response', 'Other']);
  });
});

describe('canUpdateRenewals', () => {
  it('owner and manager always', () => {
    expect(canUpdateRenewals('owner', false, false)).toBe(true);
    expect(canUpdateRenewals('manager', false, false)).toBe(true);
  });
  it('agent only on own policy with the setting on', () => {
    expect(canUpdateRenewals('agent', true, true)).toBe(true);
    expect(canUpdateRenewals('agent', false, true)).toBe(false);
    expect(canUpdateRenewals('agent', true, false)).toBe(false);
  });
  it('nobody without a role', () => {
    expect(canUpdateRenewals(undefined, true, true)).toBe(false);
  });
});
