import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { supabase } from '@/lib/supabase';
import type { 
  Client, 
  Policy, 
  PolicyWithRelations, 
  Insurer, 
  ProductLine, 
  CommissionTransaction,
  AgencyUser,
  Agency
} from '@/lib/types';
import { useAuth } from '@/contexts/AuthContext';

// ============================================================================
// CLIENTS
// ============================================================================

export function useClients() {
  const { agency, session } = useAuth();
  return useQuery({
    queryKey: ['clients', agency?.id],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('clients')
        .select('*')
        .eq('agency_id', agency?.id)
        .order('name');
      if (error) throw error;
      return data as Client[];
    },
    enabled: !!session && !!agency?.id,
  });
}

export function useClient(id: string) {
  const { session } = useAuth();
  return useQuery({
    queryKey: ['client', id],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('clients')
        .select('*')
        .eq('id', id)
        .single();
      if (error) throw error;
      return data as Client;
    },
    enabled: !!session && !!id,
  });
}

export function useCreateClient() {
  const queryClient = useQueryClient();
  const { agency } = useAuth();
  
  return useMutation({
    mutationFn: async (client: Omit<Client, 'id' | 'agency_id' | 'created_at'>) => {
      if (!agency?.id) throw new Error('No agency');
      const { data, error } = await supabase
        .from('clients')
        .insert({ ...client, agency_id: agency.id })
        .select()
        .single();
      if (error) throw error;
      return data as Client;
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['clients'] });
    },
  });
}

export function useUpdateClient() {
  const queryClient = useQueryClient();
  
  return useMutation({
    mutationFn: async ({ id, ...client }: Partial<Client> & { id: string }) => {
      const { data, error } = await supabase
        .from('clients')
        .update(client)
        .eq('id', id)
        .select()
        .single();
      if (error) throw error;
      return data as Client;
    },
    onSuccess: (data) => {
      queryClient.invalidateQueries({ queryKey: ['clients'] });
      queryClient.invalidateQueries({ queryKey: ['client', data.id] });
    },
  });
}

export function useDeleteClient() {
  const queryClient = useQueryClient();
  const { agency } = useAuth();

  return useMutation({
    mutationFn: async (id: string) => {
      const { error } = await supabase
        .from('clients')
        .delete()
        .eq('id', id)
        .eq('agency_id', agency?.id);
      if (error) throw error;
      return id;
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['clients'] });
    },
  });
}

// ============================================================================
// INSURERS
// ============================================================================

export function useInsurers() {
  const { agency, session } = useAuth();
  return useQuery({
    queryKey: ['insurers', agency?.id],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('insurers')
        .select('*')
        .eq('agency_id', agency?.id)
        .order('name');
      if (error) throw error;
      return data as Insurer[];
    },
    enabled: !!session && !!agency?.id,
  });
}

export function useCreateInsurer() {
  const queryClient = useQueryClient();
  const { agency } = useAuth();
  
  return useMutation({
    mutationFn: async (insurer: Omit<Insurer, 'id' | 'agency_id' | 'created_at'>) => {
      if (!agency?.id) throw new Error('No agency');
      const { data, error } = await supabase
        .from('insurers')
        .insert({ ...insurer, agency_id: agency.id })
        .select()
        .single();
      if (error) throw error;
      return data as Insurer;
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['insurers'] });
    },
  });
}

export function useUpdateInsurer() {
  const queryClient = useQueryClient();
  
  return useMutation({
    mutationFn: async ({ id, ...insurer }: Partial<Insurer> & { id: string }) => {
      const { data, error } = await supabase
        .from('insurers')
        .update(insurer)
        .eq('id', id)
        .select()
        .single();
      if (error) throw error;
      return data as Insurer;
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['insurers'] });
    },
  });
}

export function useDeleteInsurer() {
  const queryClient = useQueryClient();
  const { agency } = useAuth();

  return useMutation({
    mutationFn: async (id: string) => {
      const { error } = await supabase
        .from('insurers')
        .delete()
        .eq('id', id)
        .eq('agency_id', agency?.id);
      if (error) throw error;
      return id;
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['insurers'] });
    },
  });
}

// ============================================================================
// PRODUCT LINES
// ============================================================================

export function useProductLines() {
  const { agency, session } = useAuth();
  return useQuery({
    queryKey: ['product-lines', agency?.id],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('product_lines')
        .select('*')
        .eq('agency_id', agency?.id)
        .order('name');
      if (error) throw error;
      return data as ProductLine[];
    },
    enabled: !!session && !!agency?.id,
  });
}

export function useCreateProductLine() {
  const queryClient = useQueryClient();
  const { agency } = useAuth();
  
  return useMutation({
    mutationFn: async (productLine: Omit<ProductLine, 'id' | 'agency_id' | 'created_at'>) => {
      if (!agency?.id) throw new Error('No agency');
      const { data, error } = await supabase
        .from('product_lines')
        .insert({ ...productLine, agency_id: agency.id })
        .select()
        .single();
      if (error) throw error;
      return data as ProductLine;
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['product-lines'] });
    },
  });
}

export function useUpdateProductLine() {
  const queryClient = useQueryClient();
  
  return useMutation({
    mutationFn: async ({ id, ...productLine }: Partial<ProductLine> & { id: string }) => {
      const { data, error } = await supabase
        .from('product_lines')
        .update(productLine)
        .eq('id', id)
        .select()
        .single();
      if (error) throw error;
      return data as ProductLine;
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['product-lines'] });
    },
  });
}

export function useDeleteProductLine() {
  const queryClient = useQueryClient();
  const { agency } = useAuth();

  return useMutation({
    mutationFn: async (id: string) => {
      const { error } = await supabase
        .from('product_lines')
        .delete()
        .eq('id', id)
        .eq('agency_id', agency?.id);
      if (error) throw error;
      return id;
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['product-lines'] });
    },
  });
}

// ============================================================================
// POLICIES
// ============================================================================

export function usePolicies(filters?: { clientId?: string; status?: string; insurerId?: string }) {
  const { agency, session } = useAuth();
  return useQuery({
    queryKey: ['policies', agency?.id, filters],
    queryFn: async () => {
      let query = supabase
        .from('policies')
        .select(`
          *,
          client:clients(id, name, type, phone, email),
          insurer:insurers(id, name),
          product_line:product_lines(id, name),
          agent:users(id, full_name)
        `)
        .eq('agency_id', agency?.id);
        
      if (filters?.clientId) query = query.eq('client_id', filters.clientId);
      if (filters?.status && filters.status !== 'all') query = query.eq('status', filters.status);
      if (filters?.insurerId && filters.insurerId !== 'all') query = query.eq('insurer_id', filters.insurerId);
      
      const { data, error } = await query.order('created_at', { ascending: false });
      if (error) throw error;
      return data as unknown as PolicyWithRelations[];
    },
    enabled: !!session && !!agency?.id,
  });
}

export function useCreatePolicy() {
  const queryClient = useQueryClient();
  const { agency } = useAuth();
  
  return useMutation({
    mutationFn: async (policy: Omit<Policy, 'id' | 'agency_id' | 'created_at' | 'updated_at' | 'commission_expected' | 'commission_received'>) => {
      if (!agency?.id) throw new Error('No agency');
      
      const expected = (policy.premium_amount * policy.commission_rate) / 100;
      
      const { data, error } = await supabase
        .from('policies')
        .insert({ 
          ...policy, 
          agency_id: agency.id,
          commission_expected: expected,
          commission_received: 0
        })
        .select()
        .single();
        
      if (error) throw error;
      
      // Auto-create initial commission transaction for expected amount
      await supabase.from('commission_transactions').insert({
        agency_id: agency.id,
        policy_id: data.id,
        amount: expected,
        expected_date: data.start_date, // Or derived based on standard rules
        status: 'pending',
        notes: 'Initial expected commission'
      });
      
      return data as Policy;
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['policies'] });
      queryClient.invalidateQueries({ queryKey: ['commissions'] });
    },
  });
}

export function useUpdatePolicy() {
  const queryClient = useQueryClient();
  
  return useMutation({
    mutationFn: async ({ id, ...policy }: Partial<Policy> & { id: string }) => {
      // Recompute expected if premium or rate changes
      let expected;
      if (policy.premium_amount !== undefined && policy.commission_rate !== undefined) {
        expected = (policy.premium_amount * policy.commission_rate) / 100;
      }
      
      const { data, error } = await supabase
        .from('policies')
        .update({
          ...policy,
          ...(expected !== undefined ? { commission_expected: expected } : {}),
          updated_at: new Date().toISOString()
        })
        .eq('id', id)
        .select()
        .single();
      if (error) throw error;
      return data as Policy;
    },
    onSuccess: (data) => {
      queryClient.invalidateQueries({ queryKey: ['policies'] });
      queryClient.invalidateQueries({ queryKey: ['policy', data.id] });
    },
  });
}

export function useDeletePolicy() {
  const queryClient = useQueryClient();
  const { agency } = useAuth();

  return useMutation({
    mutationFn: async (id: string) => {
      if (!agency?.id) throw new Error('No agency');
      const { error } = await supabase
        .from('policies')
        .delete()
        .eq('id', id)
        .eq('agency_id', agency.id);
      if (error) throw error;
      return id;
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['policies'] });
      queryClient.invalidateQueries({ queryKey: ['commissions'] });
    },
  });
}

// ============================================================================
// COMMISSIONS
// ============================================================================

export function useCommissions(filters?: { status?: string }) {
  const { agency, session } = useAuth();
  return useQuery({
    queryKey: ['commissions', agency?.id, filters],
    queryFn: async () => {
      let query = supabase
        .from('commission_transactions')
        .select(`
          *,
          policy:policies(id, policy_number, client:clients(id, name), insurer:insurers(id, name))
        `)
        .eq('agency_id', agency?.id);
        
      if (filters?.status && filters.status !== 'all') {
        if (filters.status === 'overdue') {
          // Overdue logic: pending and expected_date < today
          const today = new Date().toISOString().split('T')[0];
          query = query.eq('status', 'pending').lt('expected_date', today);
        } else {
          query = query.eq('status', filters.status);
        }
      }
      
      const { data, error } = await query.order('expected_date', { ascending: false });
      if (error) throw error;
      return data;
    },
    enabled: !!session && !!agency?.id,
  });
}

export function useUpdateCommission() {
  const queryClient = useQueryClient();
  
  return useMutation({
    mutationFn: async ({ id, ...transaction }: Partial<CommissionTransaction> & { id: string }) => {
      const { data, error } = await supabase
        .from('commission_transactions')
        .update(transaction)
        .eq('id', id)
        .select()
        .single();
      if (error) throw error;
      
      // If marked received, update the policy's commission_received tally
      if (transaction.status === 'received' && transaction.amount && data.policy_id) {
        // Fetch current policy
        const { data: policy } = await supabase.from('policies').select('commission_received').eq('id', data.policy_id).single();
        if (policy) {
          await supabase.from('policies')
            .update({ commission_received: (policy.commission_received || 0) + transaction.amount })
            .eq('id', data.policy_id);
        }
      }
      
      return data as CommissionTransaction;
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['commissions'] });
      queryClient.invalidateQueries({ queryKey: ['policies'] });
    },
  });
}

export function useDeleteCommission() {
  const queryClient = useQueryClient();
  const { agency } = useAuth();

  return useMutation({
    mutationFn: async (id: string) => {
      const { error } = await supabase
        .from('commission_transactions')
        .delete()
        .eq('id', id)
        .eq('agency_id', agency?.id);
      if (error) throw error;
      return id;
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['commissions'] });
    },
  });
}

export function useCreateCommission() {
  const queryClient = useQueryClient();
  const { agency } = useAuth();
  
  return useMutation({
    mutationFn: async (transaction: Omit<CommissionTransaction, 'id' | 'agency_id' | 'created_at'>) => {
      if (!agency?.id) throw new Error('No agency');
      const { data, error } = await supabase
        .from('commission_transactions')
        .insert({ ...transaction, agency_id: agency.id })
        .select()
        .single();
      if (error) throw error;
      
      // If received immediately
      if (transaction.status === 'received' && transaction.amount && transaction.policy_id) {
        const { data: policy } = await supabase.from('policies').select('commission_received').eq('id', transaction.policy_id).single();
        if (policy) {
          await supabase.from('policies')
            .update({ commission_received: (policy.commission_received || 0) + transaction.amount })
            .eq('id', transaction.policy_id);
        }
      }
      
      return data as CommissionTransaction;
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['commissions'] });
      queryClient.invalidateQueries({ queryKey: ['policies'] });
    },
  });
}

// ============================================================================
// RENEWAL REMINDERS
// ============================================================================

export function useRenewalReminders(policyId?: string) {
  const { agency, session } = useAuth();
  return useQuery({
    queryKey: ['renewal-reminders', agency?.id, policyId],
    queryFn: async () => {
      let query = supabase
        .from('renewal_reminders')
        .select('*')
        .eq('agency_id', agency?.id)
        .order('reminder_date', { ascending: false });
      if (policyId) query = query.eq('policy_id', policyId);
      const { data, error } = await query;
      if (error) throw error;
      return data;
    },
    enabled: !!session && !!agency?.id,
  });
}

export function useCreateRenewalReminder() {
  const queryClient = useQueryClient();
  const { agency } = useAuth();

  return useMutation({
    mutationFn: async (reminder: {
      policy_id: string;
      reminder_date: string;
      channel: 'whatsapp' | 'email' | 'sms';
      sent?: boolean;
      notes?: string | null;
    }) => {
      if (!agency?.id) throw new Error('No agency');
      const { data, error } = await supabase
        .from('renewal_reminders')
        .insert({
          ...reminder,
          agency_id: agency.id,
          sent: reminder.sent ?? true,
          sent_at: reminder.sent !== false ? new Date().toISOString() : null,
        })
        .select()
        .single();
      if (error) throw error;
      return data;
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['renewal-reminders'] });
    },
  });
}

// ============================================================================
// RENEWALS — extra queries for Phase 3
// ============================================================================

/** Returns reminder rows grouped by policy_id. Pass the list of visible policy IDs. */
export function useRenewalReminderCounts(policyIds: string[]) {
  const { agency, session } = useAuth();
  return useQuery({
    queryKey: ['renewal-reminder-counts', agency?.id, policyIds.join(',')],
    queryFn: async () => {
      if (!policyIds.length) return {} as Record<string, Array<{ id: string; reminder_date: string; channel: string; notes: string | null; sent_at: string | null }>>;
      const { data, error } = await supabase
        .from('renewal_reminders')
        .select('id, policy_id, reminder_date, channel, notes, sent_at')
        .eq('agency_id', agency?.id)
        .in('policy_id', policyIds)
        .order('reminder_date', { ascending: false });
      if (error) throw error;
      // Group by policy_id
      return (data ?? []).reduce((acc, r) => {
        if (!acc[r.policy_id]) acc[r.policy_id] = [];
        acc[r.policy_id].push(r);
        return acc;
      }, {} as Record<string, typeof data>);
    },
    enabled: !!session && !!agency?.id && policyIds.length > 0,
  });
}

/** Active policies already past their expiry date — renewal failures. */
export function useOverdueRenewals() {
  const { agency, session } = useAuth();
  return useQuery({
    queryKey: ['overdue-renewals', agency?.id],
    queryFn: async () => {
      const today = new Date().toISOString().split('T')[0];
      const { data, error } = await supabase
        .from('policies')
        .select(`
          id, policy_number, expiry_date, premium_amount,
          client:clients(name, phone, email),
          insurer:insurers(name),
          product_line:product_lines(name),
          agent:users(full_name)
        `)
        .eq('agency_id', agency?.id)
        .eq('status', 'active')
        .lt('expiry_date', today)
        .order('expiry_date', { ascending: true });
      if (error) throw error;
      return ((data ?? []) as any[]).map((p: any) => ({
        ...p,
        days_overdue: Math.floor((Date.now() - new Date(p.expiry_date).getTime()) / 86_400_000),
      }));
    },
    enabled: !!session && !!agency?.id,
  });
}

// ============================================================================
// COMMISSIONS — bulk action for Phase 3
// ============================================================================

/** Mark multiple pending/overdue commissions as received in one operation. */
export function useBulkMarkCommissionsReceived() {
  const queryClient = useQueryClient();
  const { agency } = useAuth();
  return useMutation({
    mutationFn: async (ids: string[]) => {
      if (!ids.length) throw new Error('No ids');
      if (!agency?.id) throw new Error('No agency');
      const today = new Date().toISOString().split('T')[0];
      const { error } = await supabase
        .from('commission_transactions')
        .update({ status: 'received', received_date: today })
        .in('id', ids)
        .eq('agency_id', agency.id)
        .in('status', ['pending', 'overdue']);
      if (error) throw error;
      return ids;
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['commissions'] });
      queryClient.invalidateQueries({ queryKey: ['policies'] });
    },
  });
}

// ============================================================================
// USERS (AGENTS)
// ============================================================================

export function useAgencyUsers() {
  const { agency, session } = useAuth();
  return useQuery({
    queryKey: ['users', agency?.id],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('users')
        .select('*')
        .eq('agency_id', agency?.id)
        .order('full_name');
      if (error) throw error;
      return data as AgencyUser[];
    },
    enabled: !!session && !!agency?.id,
  });
}

export function useUpdateAgency() {
  const queryClient = useQueryClient();
  
  return useMutation({
    mutationFn: async ({ id, ...agency }: Partial<Agency> & { id: string }) => {
      const { data, error } = await supabase
        .from('agencies')
        .update(agency)
        .eq('id', id)
        .select()
        .single();
      if (error) throw error;
      return data as Agency;
    },
    onSuccess: () => {
      // Force reload or auth context update ideally, but invalidate is fine if we fetch it
    },
  });
}
