// Pure helpers for parsing pasted commission statements and matching to policies.
// Money is integer cents.

export function toCents(input: string | number): number | null {
  if (typeof input === 'number') {
    return Number.isFinite(input) ? Math.round(input * 100) : null;
  }
  let s = input.trim();
  if (!s) return null;
  let neg = false;
  if (/^\(.*\)$/.test(s)) {
    neg = true;
    s = s.slice(1, -1);
  }
  s = s.replace(/kes|ksh/gi, '').replace(/[\s,]/g, '');
  if (s.startsWith('-')) {
    neg = !neg ? true : neg;
    s = s.slice(1);
  }
  if (!/^\d+(\.\d+)?$/.test(s) && !/^\.\d+$/.test(s)) return null;
  const cents = Math.round(parseFloat(s) * 100);
  if (!Number.isFinite(cents)) return null;
  return neg ? -cents : cents;
}

export function fromCents(c: number): number {
  return c / 100;
}

export function normalisePolicyNumber(s: string): string {
  return s.toLowerCase().replace(/[^a-z0-9]/g, '');
}

export type DraftLine = {
  policyNumber: string;
  clientName: string;
  premiumCents: number | null;
  commissionCents: number | null;
  period: string | null;
};

function parsePeriod(raw: string | undefined): string | null {
  const s = (raw ?? '').trim();
  let m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(s);
  if (m) return s;
  m = /^(\d{1,2})\/(\d{1,2})\/(\d{4})$/.exec(s);
  if (m) return `${m[3]}-${m[2].padStart(2, '0')}-${m[1].padStart(2, '0')}`;
  m = /^(\d{1,2})\/(\d{4})$/.exec(s);
  if (m) return `${m[2]}-${m[1].padStart(2, '0')}-01`;
  return null;
}

function splitLine(raw: string): string[] {
  if (raw.includes('\t')) return raw.split('\t').map((f) => f.trim());
  const spaced = raw.trim().split(/ {2,}/);
  if (spaced.length > 1) return spaced.map((f) => f.trim());
  const commas = raw.split(',');
  if (commas.length === 5) return commas.map((f) => f.trim());
  return spaced;
}

export function parsePastedLines(text: string): DraftLine[] {
  return text
    .split(/\r?\n/)
    .filter((l) => l.trim() !== '')
    .map((raw) => {
      const f = splitLine(raw);
      return {
        policyNumber: f[0] ?? '',
        clientName: f[1] ?? '',
        premiumCents: f[2] ? toCents(f[2]) : null,
        commissionCents: f[3] ? toCents(f[3]) : null,
        period: parsePeriod(f[4]),
      };
    });
}

export type MatchStatus =
  | 'matched'
  | 'short'
  | 'over'
  | 'unmatched'
  | 'new_commission'
  | 'reversal';

export function matchLines(
  lines: DraftLine[],
  policies: {
    id: string;
    policy_number: string;
    commission_basis: 'annual' | 'per_premium';
    outstandingCents: number;
    /** Renewed terms may share a policy number; the term start decides which one a line matches. */
    start_date?: string;
  }[],
): { line: DraftLine; policyId: string | null; status: MatchStatus; applyCents: number }[] {
  // Terms per number, oldest first
  const byNumber = new Map<string, (typeof policies)[number][]>();
  const remaining = new Map<string, number>();
  for (const p of policies) {
    const key = normalisePolicyNumber(p.policy_number);
    const list = byNumber.get(key) ?? [];
    list.push(p);
    byNumber.set(key, list);
    remaining.set(p.id, p.outstandingCents);
  }
  for (const list of byNumber.values()) {
    list.sort((a, b) => (a.start_date ?? '').localeCompare(b.start_date ?? ''));
  }
  // The oldest term with commission still outstanding, else the latest term.
  const pick = (number: string) => {
    const list = byNumber.get(normalisePolicyNumber(number));
    if (!list || list.length === 0) return undefined;
    return list.find((p) => (remaining.get(p.id) ?? 0) > 0) ?? list[list.length - 1];
  };
  return lines.map((l) => {
    const p = pick(l.policyNumber);
    const policyId = p ? p.id : null;
    const c = l.commissionCents ?? 0;
    if (c <= 0) return { line: l, policyId, status: 'reversal', applyCents: 0 };
    if (!p) return { line: l, policyId: null, status: 'unmatched', applyCents: 0 };
    if (p.commission_basis === 'per_premium') {
      return { line: l, policyId, status: 'new_commission', applyCents: c };
    }
    const rem = remaining.get(p.id) ?? 0;
    const apply = Math.min(c, rem);
    remaining.set(p.id, rem - apply);
    const status: MatchStatus = c === rem ? 'matched' : c < rem ? 'short' : 'over';
    return { line: l, policyId, status, applyCents: apply };
  });
}

export function totalCents(lines: DraftLine[]): number {
  return lines.reduce((sum, l) => sum + (l.commissionCents ?? 0), 0);
}
