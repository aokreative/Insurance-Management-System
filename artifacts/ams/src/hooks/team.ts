import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { supabase } from '@/lib/supabase';
import type { UserRole } from '@/lib/types';
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
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['clients'] });
      queryClient.invalidateQueries({ queryKey: ['client'] });
      queryClient.invalidateQueries({ queryKey: ['policies'] });
      queryClient.invalidateQueries({ queryKey: ['commissions'] });
    },
  });
}
