// Pure helpers for the receipt lines grid. Cell values are strings; money is integer cents.
import { toCents, fromCents, type DraftLine } from './reconcile';

export type GridRow = {
  policyNumber: string;
  clientName: string;
  premium: string;
  commission: string;
  period: string;
};

export const emptyRow = (): GridRow => ({ policyNumber: '', clientName: '', premium: '', commission: '', period: '' });

export function rowIsEmpty(r: GridRow): boolean {
  return !r.policyNumber.trim() && !r.clientName.trim() && !r.premium.trim() && !r.commission.trim() && !r.period.trim();
}

/** True only for a real calendar date written YYYY-MM-DD (month 1-12, day valid for the month). */
export function isRealCalendarDate(iso: string): boolean {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(iso);
  if (!m) return false;
  const y = Number(m[1]);
  const mo = Number(m[2]);
  const d = Number(m[3]);
  if (mo < 1 || mo > 12 || d < 1) return false;
  const dim = new Date(Date.UTC(y, mo, 0)).getUTCDate();
  return d <= dim;
}

/** Normalise a typed period (YYYY-MM-DD, D/M/YYYY or M/YYYY) to ISO. Returns null if it has no recognised shape. */
export function normalisePeriodText(raw: string): string | null {
  const s = raw.trim();
  let m = /^(\d{4})-(\d{1,2})-(\d{1,2})$/.exec(s);
  if (m) return `${m[1]}-${m[2].padStart(2, '0')}-${m[3].padStart(2, '0')}`;
  m = /^(\d{1,2})\/(\d{1,2})\/(\d{4})$/.exec(s);
  if (m) return `${m[3]}-${m[2].padStart(2, '0')}-${m[1].padStart(2, '0')}`;
  m = /^(\d{1,2})\/(\d{4})$/.exec(s);
  if (m) return `${m[2]}-${m[1].padStart(2, '0')}-01`;
  return null;
}

export function rowErrors(r: GridRow): { amount: boolean; date: boolean } {
  if (rowIsEmpty(r)) return { amount: false, date: false };
  const amount = toCents(r.commission) === null;
  let date = false;
  if (r.period.trim()) {
    const iso = normalisePeriodText(r.period);
    date = iso === null || !isRealCalendarDate(iso);
  }
  return { amount, date };
}

export function rowToDraft(r: GridRow): DraftLine {
  const iso = r.period.trim() ? normalisePeriodText(r.period) : null;
  return {
    policyNumber: r.policyNumber.trim(),
    clientName: r.clientName.trim(),
    premiumCents: r.premium.trim() ? toCents(r.premium) : null,
    commissionCents: r.commission.trim() ? toCents(r.commission) : null,
    period: iso,
  };
}

export function draftToRow(l: DraftLine): GridRow {
  return {
    policyNumber: l.policyNumber,
    clientName: l.clientName,
    premium: l.premiumCents === null ? '' : String(fromCents(l.premiumCents)),
    commission: l.commissionCents === null ? '' : String(fromCents(l.commissionCents)),
    period: l.period ?? '',
  };
}

export function gridHasErrors(rows: GridRow[]): boolean {
  return rows.some((r) => {
    const e = rowErrors(r);
    return e.amount || e.date;
  });
}

/** Amount for messages, e.g. 1,234.5 (no currency prefix). */
export function formatKes(cents: number): string {
  return (cents / 100).toLocaleString('en-KE', { minimumFractionDigits: 0, maximumFractionDigits: 2 });
}
