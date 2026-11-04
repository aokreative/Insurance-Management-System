// Projected monthly commission for per-premium (life) policies.
export type ProjectionPolicy = {
  instalment_premium: number | null;
  premium_frequency: 'monthly' | 'quarterly' | 'half_yearly' | 'yearly' | null;
  commission_rate: number;
  renewal_commission_rate: number | null;
  start_date: string;
};

const PAYMENTS_PER_MONTH = { monthly: 1, quarterly: 1 / 3, half_yearly: 1 / 6, yearly: 1 / 12 } as const;

/** True when `now` is more than 12 whole months after `start` (YYYY-MM-DD). */
export function isPastFirstYear(start: string, now: Date): boolean {
  const [sy, sm, sd] = start.slice(0, 10).split('-').map(Number);
  const months = (now.getFullYear() - sy) * 12 + (now.getMonth() + 1 - sm) - (now.getDate() < sd ? 1 : 0);
  return months > 12;
}

export function projectedMonthlyCommission(policies: ProjectionPolicy[], now: Date = new Date()): number {
  let total = 0;
  for (const p of policies) {
    if (!p.premium_frequency || p.instalment_premium == null) continue;
    const rate =
      p.renewal_commission_rate != null && isPastFirstYear(p.start_date, now)
        ? p.renewal_commission_rate
        : p.commission_rate;
    total += ((Number(p.instalment_premium) * Number(rate)) / 100) * PAYMENTS_PER_MONTH[p.premium_frequency];
  }
  return total;
}
