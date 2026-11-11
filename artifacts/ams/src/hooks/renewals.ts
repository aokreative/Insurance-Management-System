import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { supabase } from '@/lib/supabase';
import { useAuth } from '@/contexts/AuthContext';
import type { LostReason, Policy, RenewalActivity, RenewalChannel, RenewalRow, RenewalStage } from '@/lib/types';

const PIPELINE_COLUMNS =
  'policy_id, agency_id, policy_number, expiry_date, start_date, premium_amount, policy_status, client_id, client_name, client_phone, client_email, insurer_id, insurer_name, product_line_id, product_line_name, agent_id, agent_name, days_to_expiry, renewal_id, stage, quoted_insurer_id, quoted_insurer_name, quoted_premium, lost_reason, renewed_policy_id, renewed_premium, closed_at, last_activity_at';

export type RenewalWindow = 'overdue' | '30' | '60' | '90' | 'all';

/** Open renewals (To contact / Contacted / Quoted), soonest expiry first. RLS limits Agents to their own. */
export function useOpenRenewals(agentId?: string) {
  const { agency, session } = useAuth();
  return useQuery({
    queryKey: ['renewals', agency?.id, 'open', agentId ?? 'all'],
    queryFn: async () => {
      let q = supabase
        .from('renewal_pipeline')
        .select(PIPELINE_COLUMNS)
        .eq('agency_id', agency?.id)
        .in('stage', ['to_contact', 'contacted', 'quoted'])
        .order('expiry_date', { ascending: true });
      if (agentId) q = q.eq('agent_id', agentId);
      const { data, error } = await q;
      if (error) throw error;
      return (data ?? []) as RenewalRow[];
    },
    enabled: !!session && !!agency?.id,
  });
}

/** Renewed and lost renewals closed between two local dates (inclusive), latest first. */
export function useClosedRenewals(from: string, to: string, agentId?: string) {
  const { agency, session } = useAuth();
  return useQuery({
    queryKey: ['renewals', agency?.id, 'closed', from, to, agentId ?? 'all'],
    queryFn: async () => {
      // closed_at is a timestamp; compare against the local day boundaries
      const start = new Date(`${from}T00:00:00`).toISOString();
      const end = new Date(`${to}T23:59:59.999`).toISOString();
      let q = supabase
        .from('renewal_pipeline')
        .select(PIPELINE_COLUMNS)
        .eq('agency_id', agency?.id)
        .in('stage', ['renewed', 'lost'])
        .gte('closed_at', start)
        .lte('closed_at', end)
        .order('closed_at', { ascending: false });
      if (agentId) q = q.eq('agent_id', agentId);
      const { data, error } = await q;
      if (error) throw error;
      return (data ?? []) as RenewalRow[];
    },
    enabled: !!session && !!agency?.id && !!from && !!to,
  });
}

export interface PolicyRenewalInfo {
  /** Stage of the policy's own renewal, when it is in the pipeline. */
  stage: Record<string, RenewalStage>;
  /** old policy id → the new-term policy id */
  renewedAs: Record<string, string>;
  /** new-term policy id → the old policy id */
  renewedFrom: Record<string, string>;
}

/** Renewal stage and links for a set of policies (for badges on policy and client pages). */
export function useRenewalForPolicies(policyIds: string[]) {
  const { agency, session } = useAuth();
  const ids = [...new Set(policyIds)].sort();
  return useQuery({
    queryKey: ['renewals', agency?.id, 'for-policies', ids],
    queryFn: async (): Promise<PolicyRenewalInfo> => {
      const info: PolicyRenewalInfo = { stage: {}, renewedAs: {}, renewedFrom: {} };
      // Chunk to keep the URL short
      for (let i = 0; i < ids.length; i += 100) {
        const chunk = ids.slice(i, i + 100);
        const [own, from] = await Promise.all([
          supabase.from('renewal_pipeline').select('policy_id, stage, renewed_policy_id').in('policy_id', chunk),
          supabase.from('policy_renewals').select('policy_id, renewed_policy_id').in('renewed_policy_id', chunk),
        ]);
        if (own.error) throw own.error;
        if (from.error) throw from.error;
        for (const r of own.data ?? []) {
          info.stage[r.policy_id] = r.stage as RenewalStage;
          if (r.renewed_policy_id) info.renewedAs[r.policy_id] = r.renewed_policy_id;
        }
        for (const r of from.data ?? []) {
          if (r.renewed_policy_id) info.renewedFrom[r.renewed_policy_id] = r.policy_id;
        }
      }
      return info;
    },
    enabled: !!session && !!agency?.id && ids.length > 0,
  });
}

/** History of one renewal, newest first. */
export function useRenewalActivities(renewalId: string | null | undefined) {
  const { session } = useAuth();
  return useQuery({
    queryKey: ['renewal-activities', renewalId],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('renewal_activities')
        .select('*, insurer:insurers(name), author:users(full_name)')
        .eq('renewal_id', renewalId!)
        .order('created_at', { ascending: false });
      if (error) throw error;
      return (data ?? []) as RenewalActivity[];
    },
    enabled: !!session && !!renewalId,
  });
}

/** The full policy row a renewal starts from (commission settings for the Renew form). */
export function usePolicyForRenewal(policyId: string | null | undefined) {
  const { session } = useAuth();
  return useQuery({
    queryKey: ['policy', policyId],
    queryFn: async () => {
      const { data, error } = await supabase.from('policies').select('*').eq('id', policyId!).single();
      if (error) throw error;
      return data as Policy;
    },
    enabled: !!session && !!policyId,
  });
}

function useRenewalMutation<TVars, TResult = unknown>(fn: (vars: TVars) => Promise<TResult>) {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: fn,
    onSuccess: () => {
      for (const key of ['renewals', 'renewal-activities', 'policies', 'policy', 'commissions', 'dashboard', 'overdue-renewals']) {
        queryClient.invalidateQueries({ queryKey: [key] });
      }
    },
  });
}

export function useLogContact() {
  return useRenewalMutation(
    async (v: { policyId: string; channel: RenewalChannel; occurredOn: string; note: string }) => {
      const { error } = await supabase.rpc('log_renewal_contact', {
        p_policy_id: v.policyId,
        p_channel: v.channel,
        p_occurred_on: v.occurredOn,
        p_note: v.note,
      });
      if (error) throw error;
    },
  );
}

export function useRecordQuote() {
  return useRenewalMutation(async (v: { policyId: string; insurerId: string; premium: number; note: string }) => {
    const { error } = await supabase.rpc('record_renewal_quote', {
      p_policy_id: v.policyId,
      p_insurer_id: v.insurerId,
      p_premium: v.premium,
      p_note: v.note,
    });
    if (error) throw error;
  });
}

export function useMarkLost() {
  return useRenewalMutation(async (v: { policyId: string; reason: LostReason; note: string }) => {
    const { error } = await supabase.rpc('mark_renewal_lost', {
      p_policy_id: v.policyId,
      p_reason: v.reason,
      p_note: v.note,
    });
    if (error) throw error;
  });
}

export function useReopenRenewal() {
  return useRenewalMutation(async (policyId: string) => {
    const { error } = await supabase.rpc('reopen_renewal', { p_policy_id: policyId });
    if (error) throw error;
  });
}

export interface RenewPolicyInput {
  policy_number: string;
  insurer_id: string;
  product_line_id: string;
  premium_amount: number;
  commission_rate: number;
  commission_basis: 'annual' | 'per_premium';
  premium_frequency: string | null;
  instalment_premium: number | null;
  renewal_commission_rate: number | null;
  start_date: string;
  expiry_date: string;
  notes?: string | null;
}

/** Creates the new-term policy; resolves to its id. */
export function useRenewPolicy() {
  return useRenewalMutation(async (v: { policyId: string; next: RenewPolicyInput }) => {
    const { data, error } = await supabase.rpc('renew_policy', { p_policy_id: v.policyId, p_new: v.next });
    if (error) throw error;
    return data as string;
  });
}

/** Owner only. Reloads the agency so the new value reaches every page. */
export function useSetAgentsManageRenewals() {
  const { refreshProfile } = useAuth();
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async (enabled: boolean) => {
      const { error } = await supabase.rpc('set_agents_manage_renewals', { p_enabled: enabled });
      if (error) throw error;
    },
    onSuccess: async () => {
      await refreshProfile();
      queryClient.invalidateQueries({ queryKey: ['agency'] });
    },
  });
}
