import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { supabase } from '@/lib/supabase';
import { useAuth } from '@/contexts/AuthContext';
import { sumCents } from '@/lib/payouts';
import { fromCents } from '@/lib/reconcile';
import type { AgentRate, AgentEarning, AgentPayout, EarningKind, PayoutMethod } from '@/lib/types';

const EARNING_COLUMNS =
  'id, agency_id, agent_id, kind, policy_id, commission_id, policy_number, client_name, base_amount, rate, amount, earned_on, note, payout_id, created_at';

export interface PayoutWithAgent extends AgentPayout {
  agent: { id: string; full_name: string } | null;
}

export interface PayoutLine {
  id: string;
  kind: EarningKind;
  earned_on: string;
  policy_number: string | null;
  client_name: string | null;
  base_amount: number | null;
  rate: number | null;
  amount: number;
  note: string | null;
}

export interface PayoutPreview {
  lines: PayoutLine[];
  total: number;
}

export interface OwedToAgent {
  agentId: string;
  name: string;
  unpaid: number;
  lastPaidOn: string | null;
}

/** Whether the user has any earnings of their own (head-only count). */
export function useHasOwnEarnings(userId: string | undefined) {
  const { agency, session } = useAuth();
  return useQuery({
    queryKey: ['agent-earnings', agency?.id, 'has-own', userId],
    queryFn: async () => {
      const { count, error } = await supabase
        .from('agent_earnings')
        .select('id', { count: 'exact', head: true })
        .eq('agency_id', agency?.id)
        .eq('agent_id', userId);
      if (error) throw error;
      return (count ?? 0) > 0;
    },
    enabled: !!session && !!agency?.id && !!userId,
  });
}

/** The agency's rates (Owner/Manager) or just the caller's own (Agent), optionally for one member. */
export function useAgentRates(userId?: string) {
  const { agency, session } = useAuth();
  return useQuery({
    queryKey: ['agent-rates', agency?.id, userId ?? 'all'],
    queryFn: async () => {
      let q = supabase.from('agent_rates').select('*').eq('agency_id', agency?.id);
      if (userId) q = q.eq('user_id', userId);
      const { data, error } = await q;
      if (error) throw error;
      return data as AgentRate[];
    },
    enabled: !!session && !!agency?.id,
  });
}

function invalidatePayoutData(queryClient: ReturnType<typeof useQueryClient>) {
  for (const key of ['agent-earnings', 'payouts', 'payout', 'owed-to-agents', 'agent-rates', 'payout-preview']) {
    queryClient.invalidateQueries({ queryKey: [key] });
  }
}

export interface RateOverride {
  product_line_id: string;
  rate: number;
}

export function useSetAgentRates() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async (v: { userId: string; defaultRate: number | null; overrides: RateOverride[] }) => {
      const { error } = await supabase.rpc('set_agent_rates', {
        p_user_id: v.userId,
        p_default_rate: v.defaultRate,
        p_overrides: v.overrides,
      });
      if (error) throw error;
    },
    onSuccess: () => invalidatePayoutData(queryClient),
  });
}

export function useAgentEarnings(opts: { agentId?: string; unpaidOnly?: boolean } = {}) {
  const { agency, session } = useAuth();
  return useQuery({
    queryKey: ['agent-earnings', agency?.id, opts.agentId ?? 'all', !!opts.unpaidOnly],
    queryFn: async () => {
      let q = supabase
        .from('agent_earnings')
        .select(EARNING_COLUMNS)
        .eq('agency_id', agency?.id)
        .order('earned_on', { ascending: false })
        .order('created_at', { ascending: false });
      if (opts.agentId) q = q.eq('agent_id', opts.agentId);
      if (opts.unpaidOnly) q = q.is('payout_id', null);
      const { data, error } = await q;
      if (error) throw error;
      return data as AgentEarning[];
    },
    enabled: !!session && !!agency?.id,
  });
}

/** Unpaid earnings per agent plus the last non-voided payout date (Owner/Manager). */
export function useOwedToAgents() {
  const { agency, session, isOwnerOrManager } = useAuth();
  return useQuery({
    queryKey: ['owed-to-agents', agency?.id],
    queryFn: async () => {
      const [earn, pays, users] = await Promise.all([
        supabase.from('agent_earnings').select('agent_id, amount').eq('agency_id', agency?.id).is('payout_id', null),
        supabase.from('agent_payouts').select('agent_id, paid_on').eq('agency_id', agency?.id).is('voided_at', null),
        supabase.from('users').select('id, full_name').eq('agency_id', agency?.id),
      ]);
      if (earn.error) throw earn.error;
      if (pays.error) throw pays.error;
      if (users.error) throw users.error;

      const unpaid = new Map<string, { amount: number }[]>();
      for (const e of earn.data as { agent_id: string; amount: number }[]) {
        const arr = unpaid.get(e.agent_id) ?? [];
        arr.push({ amount: e.amount });
        unpaid.set(e.agent_id, arr);
      }
      const last = new Map<string, string>();
      for (const p of pays.data as { agent_id: string; paid_on: string }[]) {
        const cur = last.get(p.agent_id);
        if (!cur || p.paid_on > cur) last.set(p.agent_id, p.paid_on);
      }
      const names = new Map((users.data as { id: string; full_name: string }[]).map((u) => [u.id, u.full_name]));

      const ids = new Set<string>([...unpaid.keys(), ...last.keys()]);
      const rows: OwedToAgent[] = [...ids].map((agentId) => ({
        agentId,
        name: names.get(agentId) ?? 'Unknown',
        unpaid: fromCents(sumCents(unpaid.get(agentId) ?? [])),
        lastPaidOn: last.get(agentId) ?? null,
      }));
      return rows.sort((a, b) => a.name.localeCompare(b.name));
    },
    enabled: !!session && !!agency?.id && isOwnerOrManager,
  });
}

const PAYOUT_COLUMNS = '*, agent:users!agent_id(id, full_name)';

export function usePayouts(opts: { agentId?: string } = {}) {
  const { agency, session } = useAuth();
  return useQuery({
    queryKey: ['payouts', agency?.id, opts.agentId ?? 'all'],
    queryFn: async () => {
      let q = supabase
        .from('agent_payouts')
        .select(PAYOUT_COLUMNS)
        .eq('agency_id', agency?.id)
        .order('paid_on', { ascending: false })
        .order('created_at', { ascending: false });
      if (opts.agentId) q = q.eq('agent_id', opts.agentId);
      const { data, error } = await q;
      if (error) throw error;
      return data as unknown as PayoutWithAgent[];
    },
    enabled: !!session && !!agency?.id,
  });
}

export interface PayoutDetail {
  payout: PayoutWithAgent;
  earnings: AgentEarning[];
}

/** Payout plus its earnings; null when no such row is visible to the caller. */
export function usePayout(id: string | undefined) {
  const { agency, session } = useAuth();
  return useQuery({
    queryKey: ['payout', agency?.id, id],
    queryFn: async (): Promise<PayoutDetail | null> => {
      const { data: payout, error } = await supabase
        .from('agent_payouts')
        .select(PAYOUT_COLUMNS)
        .eq('id', id)
        .maybeSingle();
      if (error) throw error;
      if (!payout) return null;
      const { data: earnings, error: eErr } = await supabase
        .from('agent_earnings')
        .select(EARNING_COLUMNS)
        .eq('payout_id', id)
        .order('earned_on')
        .order('created_at');
      if (eErr) throw eErr;
      return { payout: payout as unknown as PayoutWithAgent, earnings: earnings as AgentEarning[] };
    },
    enabled: !!session && !!agency?.id && !!id,
  });
}

export function usePreviewPayout(agentId: string | undefined, periodEnd: string | undefined) {
  const { agency, session } = useAuth();
  return useQuery({
    queryKey: ['payout-preview', agency?.id, agentId, periodEnd],
    queryFn: async () => {
      const { data, error } = await supabase.rpc('preview_agent_payout', {
        p_user_id: agentId,
        p_period_end: periodEnd,
      });
      if (error) throw error;
      return data as PayoutPreview;
    },
    enabled: !!session && !!agency?.id && !!agentId && !!periodEnd,
    gcTime: 0,
  });
}

export function useCreatePayout() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async (v: {
      agentId: string;
      periodEnd: string;
      paidOn: string;
      method: PayoutMethod | '';
      reference: string;
      /** The previewed total the user confirmed; the server refuses if what is owed changed. */
      expectedTotal: number;
    }) => {
      const { data, error } = await supabase.rpc('create_agent_payout', {
        p_user_id: v.agentId,
        p_period_end: v.periodEnd || null,
        p_paid_on: v.paidOn || null,
        p_method: v.method || null,
        p_reference: v.reference.trim() || null,
        p_expected_total: v.expectedTotal,
      });
      if (error) throw error;
      return data as { payout_id: string; amount: number; lines: PayoutLine[] };
    },
    onSuccess: () => invalidatePayoutData(queryClient),
  });
}

export function useVoidPayout() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async (payoutId: string) => {
      const { error } = await supabase.rpc('void_agent_payout', { p_payout_id: payoutId });
      if (error) throw error;
    },
    onSuccess: () => invalidatePayoutData(queryClient),
  });
}

export function useAddAdjustment() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async (v: { agentId: string; amount: number | null; note: string }) => {
      const { data, error } = await supabase.rpc('add_agent_adjustment', {
        p_user_id: v.agentId,
        p_amount: v.amount,
        p_note: v.note,
      });
      if (error) throw error;
      return data as string;
    },
    onSuccess: () => invalidatePayoutData(queryClient),
  });
}
