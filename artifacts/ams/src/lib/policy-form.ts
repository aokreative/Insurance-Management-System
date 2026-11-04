import * as z from 'zod';

// Shared commission-type fields for the policy forms.
export const commissionFields = {
  commission_basis: z.enum(['annual', 'per_premium']),
  premium_frequency: z.enum(['monthly', 'quarterly', 'half_yearly', 'yearly']).optional().or(z.literal('')),
  instalment_premium: z.string().optional(),
  renewal_commission_rate: z.string().optional(),
};

type CommissionValues = {
  commission_basis: 'annual' | 'per_premium';
  premium_frequency?: string;
  instalment_premium?: string;
  renewal_commission_rate?: string;
};

export function refineCommission(v: CommissionValues, ctx: z.RefinementCtx) {
  if (v.commission_basis !== 'per_premium') return;
  if (!v.premium_frequency) {
    ctx.addIssue({ code: 'custom', path: ['premium_frequency'], message: 'Required for per premium' });
  }
  const amt = Number(v.instalment_premium);
  if (!v.instalment_premium?.trim() || !Number.isFinite(amt) || amt <= 0) {
    ctx.addIssue({ code: 'custom', path: ['instalment_premium'], message: 'Enter the amount per payment' });
  }
  const r = v.renewal_commission_rate?.trim();
  if (r && (!Number.isFinite(Number(r)) || Number(r) < 0 || Number(r) > 100)) {
    ctx.addIssue({ code: 'custom', path: ['renewal_commission_rate'], message: 'Must be between 0 and 100' });
  }
}

/** Splits the form values into the four DB columns plus the remaining policy fields. */
export function withCommissionColumns<T extends CommissionValues>(values: T) {
  const { commission_basis, premium_frequency, instalment_premium, renewal_commission_rate, ...rest } = values;
  const perPremium = commission_basis === 'per_premium';
  return {
    ...rest,
    commission_basis,
    premium_frequency: perPremium ? ((premium_frequency || null) as 'monthly' | 'quarterly' | 'half_yearly' | 'yearly' | null) : null,
    instalment_premium: perPremium ? Number(instalment_premium) : null,
    renewal_commission_rate: perPremium && renewal_commission_rate?.trim() ? Number(renewal_commission_rate) : null,
  };
}

export const commissionDefaults = {
  commission_basis: 'annual' as 'annual' | 'per_premium',
  premium_frequency: '' as '' | 'monthly' | 'quarterly' | 'half_yearly' | 'yearly',
  instalment_premium: '',
  renewal_commission_rate: '',
};
