// Pure helpers for the receipt lines grid. Cell values are strings; money is integer cents.
import { toCents, type DraftLine } from './reconcile';

export type GridRow = {
  id: string;
  policyNumber: string;
  clientName: string;
  premium: string;
  commission: string;
  period: string;
};

export const newRowId = (): string =>
  typeof crypto !== 'undefined' && 'randomUUID' in crypto ? crypto.randomUUID() : `r${Date.now()}${Math.random()}`;

export const emptyRow = (): GridRow => ({ id: newRowId(), policyNumber: '', clientName: '', premium: '', commission: '', period: '' });

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

export function rowErrors(r: GridRow): { amount: boolean; premium: boolean; date: boolean } {
  if (rowIsEmpty(r)) return { amount: false, premium: false, date: false };
  const amount = toCents(r.commission) === null;
  const premium = r.premium.trim() !== '' && toCents(r.premium) === null;
  let date = false;
  if (r.period.trim()) {
    const iso = normalisePeriodText(r.period);
    date = iso === null || !isRealCalendarDate(iso);
  }
  return { amount, premium, date };
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

/** True when pasted text looks like statement rows (more than one cell or row) rather than a single value. */
export function isMultiCellPaste(text: string): boolean {
  const t = text.replace(/[\r\n]+$/, '');
  return /[\t\r\n]/.test(t) || t.split(',').length === 5;
}

/** Raw pasted rows: cell text is kept as typed so unparsed values are flagged by validation. */
export function parsePastedRows(text: string): GridRow[] {
  return text
    .replace(/[\r\n]+$/, '')
    .split(/\r?\n/)
    .filter((l) => l.trim() !== '')
    .map((raw) => {
      let f: string[];
      if (raw.includes('\t')) f = raw.split('\t');
      else if (raw.trim().split(/ {2,}/).length > 1) f = raw.trim().split(/ {2,}/);
      else if (raw.split(',').length === 5) f = raw.split(',');
      else f = [raw];
      const c = (i: number) => (f[i] ?? '').trim();
      return { id: newRowId(), policyNumber: c(0), clientName: c(1), premium: c(2), commission: c(3), period: c(4) };
    });
}

export function gridHasErrors(rows: GridRow[]): boolean {
  return rows.some((r) => {
    const e = rowErrors(r);
    return e.amount || e.premium || e.date;
  });
}

/** Amount for messages, e.g. 1,234.5 (no currency prefix). */
export function formatKes(cents: number): string {
  return (cents / 100).toLocaleString('en-KE', { minimumFractionDigits: 0, maximumFractionDigits: 2 });
}
