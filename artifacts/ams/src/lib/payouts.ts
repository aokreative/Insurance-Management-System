import { format, startOfMonth } from 'date-fns';
import { toCents } from './reconcile';
import type { PayoutMethod, EarningKind } from './types';

/** Sum of money amounts (numbers or numeric strings) in integer cents. */
export function sumCents(lines: { amount: number | string }[]): number {
  return lines.reduce((acc, l) => acc + (toCents(l.amount) ?? 0), 0);
}

/** "Commission" / "Reversal" / the note for adjustments. */
export function earningLabel(e: { kind: EarningKind; note?: string | null }): string {
  if (e.kind === 'commission') return 'Commission';
  if (e.kind === 'reversal') return 'Reversal';
  return e.note?.trim() || 'Adjustment';
}

const METHOD_LABELS: Record<PayoutMethod, string> = {
  mpesa: 'M-Pesa',
  bank: 'Bank transfer',
  cash: 'Cash',
};

export function methodLabel(m: PayoutMethod): string {
  return METHOD_LABELS[m] ?? m;
}

/** Local calendar dates (not toISOString, which is UTC). */
export function todayLocal(): string {
  return format(new Date(), 'yyyy-MM-dd');
}
export function monthStartLocal(): string {
  return format(startOfMonth(new Date()), 'yyyy-MM-dd');
}
export function yearStartLocal(): string {
  return `${format(new Date(), 'yyyy')}-01-01`;
}

/** 'yyyy-MM-dd' (or ISO timestamp) shown as a local calendar date. */
export function formatDay(d: string | null | undefined): string {
  if (!d) return '-';
  const iso = d.length > 10 ? d : `${d}T00:00:00`;
  return format(new Date(iso), 'dd MMM yyyy');
}

/** "KES 1,234.50" with cents (statements are exact). */
export function kes(n: number | string | null | undefined): string {
  const v = Number(n ?? 0);
  return `KES ${v.toLocaleString('en-KE', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
}
