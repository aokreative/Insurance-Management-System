import { addDays, addYears, format, parseISO } from 'date-fns';
import type { LostReason, RenewalChannel, RenewalStage, UserRole } from './types';

export const RENEWAL_STAGES: RenewalStage[] = ['to_contact', 'contacted', 'quoted', 'renewed', 'lost'];
export const OPEN_STAGES: RenewalStage[] = ['to_contact', 'contacted', 'quoted'];
export const RENEWAL_CHANNELS: RenewalChannel[] = ['phone', 'whatsapp', 'sms', 'email', 'in_person'];
export const LOST_REASONS: LostReason[] = ['price', 'competitor', 'no_longer_needed', 'no_response', 'other'];

const STAGE_LABELS: Record<RenewalStage, string> = {
  to_contact: 'To contact',
  contacted: 'Contacted',
  quoted: 'Quoted',
  renewed: 'Renewed',
  lost: 'Lost',
};

const CHANNEL_LABELS: Record<RenewalChannel, string> = {
  phone: 'Phone',
  whatsapp: 'WhatsApp',
  sms: 'SMS',
  email: 'Email',
  in_person: 'In person',
};

const LOST_REASON_LABELS: Record<LostReason, string> = {
  price: 'Price',
  competitor: 'Went to another agent/insurer',
  no_longer_needed: 'No longer needs cover',
  no_response: 'No response',
  other: 'Other',
};

export const stageLabel = (s: RenewalStage): string => STAGE_LABELS[s] ?? s;
export const channelLabel = (c: RenewalChannel): string => CHANNEL_LABELS[c] ?? c;
export const lostReasonLabel = (r: LostReason): string => LOST_REASON_LABELS[r] ?? r;

/** New term: starts the day after the old expiry, ends one year later less a day. */
export function defaultRenewalDates(oldExpiry: string): { start: string; expiry: string } {
  const start = addDays(parseISO(oldExpiry), 1);
  // A year after 29 Feb is 1 Mar (date-fns would clamp to 28 Feb), so the term ends 28 Feb.
  const isLeapDay = start.getMonth() === 1 && start.getDate() === 29;
  const nextYear = isLeapDay ? new Date(start.getFullYear() + 1, 2, 1) : addYears(start, 1);
  const expiry = addDays(nextYear, -1);
  return { start: format(start, 'yyyy-MM-dd'), expiry: format(expiry, 'yyyy-MM-dd') };
}

/** Renewed ÷ (renewed + lost) as a percentage with one decimal; null when nothing closed. */
export function renewalRate(renewed: number, lost: number): number | null {
  const total = renewed + lost;
  if (total === 0) return null;
  return Math.round((renewed * 1000) / total) / 10;
}

/** Mirrors the database rule: Owner/Manager always; Agent on own policies while the agency allows it. */
export function canUpdateRenewals(
  role: UserRole | undefined | null,
  agentsManage: boolean,
  isOwnPolicy: boolean,
): boolean {
  if (role === 'owner' || role === 'manager') return true;
  if (role === 'agent') return agentsManage && isOwnPolicy;
  return false;
}
