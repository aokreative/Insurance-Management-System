import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { supabase } from '@/lib/supabase';
import type { UserRole, AgencyInvite } from '@/lib/types';
import { useAuth } from '@/contexts/AuthContext';

export interface AgencyMember {
  id: string;
  full_name: string;
  role: UserRole;
}

/**
 * Active members of the agency (deactivated ones excluded). RLS means an
 * Agent only ever gets their own row back.
 */
export function useAgencyMembers() {
  const { agency, session } = useAuth();
  return useQuery({
    queryKey: ['members', agency?.id],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('users')
        .select('id, full_name, role')
        .eq('agency_id', agency?.id)
        .is('deactivated_at', null)
        .order('full_name');
      if (error) throw error;
      return data as AgencyMember[];
    },
    enabled: !!session && !!agency?.id,
  });
}

export function useReassignClient() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: async ({ clientId, newAgentId }: { clientId: string; newAgentId: string }) => {
      const { data, error } = await supabase.rpc('reassign_client', {
        p_client_id: clientId,
        p_new_agent_id: newAgentId,
      });
      if (error) throw error;
      return data as { policies_moved: number };
    },
    onSuccess: () => invalidateOwnershipData(queryClient),
  });
}

export interface InviteResult {
  invite_id: string;
  code: string;
  expires_at: string;
}

export function inviteLink(code: string): string {
  return `${window.location.origin}/join?code=${code}`;
}

const INVITE_COLUMNS =
  'id, agency_id, email, role, invited_by, created_at, expires_at, accepted_at, accepted_by, revoked_at';

/** Invites that are still usable: not accepted, not revoked, not expired. */
export function usePendingInvites() {
  const { agency, session, isOwnerOrManager } = useAuth();
  return useQuery({
    queryKey: ['invites', agency?.id],
    queryFn: async () => {
      // token_hash is not granted, so named columns only (select('*') fails).
      const { data, error } = await supabase
        .from('agency_invites')
        .select(INVITE_COLUMNS)
        .eq('agency_id', agency?.id)
        .is('accepted_at', null)
        .is('revoked_at', null)
        .order('created_at', { ascending: false });
      if (error) throw error;
      const now = Date.now();
      return (data as AgencyInvite[]).filter((i) => new Date(i.expires_at).getTime() > now);
    },
    enabled: !!session && !!agency?.id && isOwnerOrManager,
  });
}

/** Number of clients assigned to each agent id (Owner/Manager can read all). */
export function useClientCountsByAgent() {
  const { agency, session, isOwnerOrManager } = useAuth();
  return useQuery({
    queryKey: ['clients', 'counts-by-agent', agency?.id],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('clients')
        .select('assigned_agent_id')
        .eq('agency_id', agency?.id);
      if (error) throw error;
      const counts: Record<string, number> = {};
      for (const row of data as { assigned_agent_id: string | null }[]) {
        if (row.assigned_agent_id) counts[row.assigned_agent_id] = (counts[row.assigned_agent_id] ?? 0) + 1;
      }
      return counts;
    },
    enabled: !!session && !!agency?.id && isOwnerOrManager,
  });
}

export function useCreateInvite() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async ({ email, role }: { email: string; role: 'manager' | 'agent' }) => {
      const { data, error } = await supabase.rpc('create_invite', { p_email: email, p_role: role });
      if (error) throw error;
      return (Array.isArray(data) ? data[0] : data) as InviteResult;
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['invites'] });
    },
  });
}

export function useRevokeInvite() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async (inviteId: string) => {
      const { error } = await supabase.rpc('revoke_invite', { p_invite_id: inviteId });
      if (error) throw error;
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['invites'] });
    },
  });
}

/**
 * Ownership changes (reassign / role change / removal) move clients, policies and
 * commissions between agents, so every aggregate derived from them is stale too.
 */
const OWNERSHIP_KEYS = [
  'clients', 'client', 'policies', 'commissions',
  'dashboard-metrics', 'renewals', 'renewals-count', 'overdue-renewals',
  'renewal-reminders', 'renewal-reminder-counts', 'reports',
];

function invalidateOwnershipData(queryClient: ReturnType<typeof useQueryClient>) {
  for (const key of OWNERSHIP_KEYS) {
    queryClient.invalidateQueries({ queryKey: [key] });
  }
  // Dashboard charts: ['chart-monthly-premium', ...], ['chart-policy-status', ...], etc.
  queryClient.invalidateQueries({
    predicate: (q) => typeof q.queryKey[0] === 'string' && q.queryKey[0].startsWith('chart-'),
  });
}

function invalidateTeamData(queryClient: ReturnType<typeof useQueryClient>) {
  for (const key of ['users', 'members', 'invites']) {
    queryClient.invalidateQueries({ queryKey: [key] });
  }
  invalidateOwnershipData(queryClient);
}

export function useChangeMemberRole() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async ({ userId, role }: { userId: string; role: 'manager' | 'agent' }) => {
      const { error } = await supabase.rpc('change_member_role', { p_user_id: userId, p_role: role });
      if (error) throw error;
    },
    onSuccess: () => invalidateTeamData(queryClient),
  });
}

export interface RemoveMemberResult {
  clients_moved: number;
  policies_moved: number;
  invites_revoked: number;
}

export function useRemoveMember() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async ({ userId, reassignTo }: { userId: string; reassignTo: string }) => {
      const { data, error } = await supabase.rpc('remove_member', {
        p_user_id: userId,
        p_reassign_to: reassignTo,
      });
      if (error) throw error;
      return (Array.isArray(data) ? data[0] : data) as RemoveMemberResult;
    },
    onSuccess: () => invalidateTeamData(queryClient),
  });
}
