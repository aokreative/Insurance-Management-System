import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { supabase } from '@/lib/supabase';
import { useAuth } from '@/contexts/AuthContext';
import type { InsurerReceipt, StatementLine, CommissionAllocation, CommissionStatus } from '@/lib/types';

const MAX_PDF_BYTES = 10 * 1024 * 1024;

export interface ReceiptListItem extends InsurerReceipt {
  insurer: { id: string; name: string } | null;
  applied: number;
  unapplied: number;
}

export interface ReceiptLineWithPolicy extends StatementLine {
  policy: { id: string; policy_number: string } | null;
}

export interface ReceiptAllocationDetail extends CommissionAllocation {
  commission: {
    id: string;
    amount: number;
    amount_received: number;
    expected_date: string | null;
    period: string | null;
    status: CommissionStatus;
    policy: { id: string; policy_number: string; client: { id: string; name: string } | null } | null;
  } | null;
}

export interface ReceiptDetail extends InsurerReceipt {
  insurer: { id: string; name: string } | null;
  lines: ReceiptLineWithPolicy[];
  allocations: ReceiptAllocationDetail[];
  applied: number;
  unapplied: number;
}

export interface InsurerMoney {
  insurerId: string;
  outstanding: number;
  overdue: number;
  unapplied: number;
}

export interface CreateReceiptInput {
  insurerId: string;
  receivedOn: string;
  amount: number;
  bankReference?: string | null;
  filePath?: string | null;
  lines?: Array<{
    policy_number: string | null;
    client_name: string | null;
    premium: number | null;
    commission: number;
    period: string | null;
    policy_id: string | null;
  }>;
  allocations?: Array<{ commission_id: string; amount: number }>;
}

const num = (v: unknown) => Number(v) || 0;

function invalidateReceiptQueries(qc: ReturnType<typeof useQueryClient>) {
  for (const key of ['receipts', 'receipt', 'commissions', 'policies', 'dashboard-metrics', 'insurer-money']) {
    qc.invalidateQueries({ queryKey: [key] });
  }
}

function monthRange(month: string): { from: string; to: string } {
  const [y, m] = month.split('-').map(Number);
  const next = m === 12 ? { y: y + 1, m: 1 } : { y, m: m + 1 };
  const pad = (n: number) => String(n).padStart(2, '0');
  return { from: `${y}-${pad(m)}-01`, to: `${next.y}-${pad(next.m)}-01` };
}

export function useReceipts(filters?: { insurerId?: string; month?: string }) {
  const { agency, session, isOwnerOrManager } = useAuth();
  return useQuery({
    queryKey: ['receipts', agency?.id, filters],
    queryFn: async () => {
      let query = supabase
        .from('insurer_receipts')
        .select('*, insurer:insurers(id, name), allocations:commission_allocations(amount)')
        .eq('agency_id', agency?.id);
      if (filters?.insurerId && filters.insurerId !== 'all') query = query.eq('insurer_id', filters.insurerId);
      if (filters?.month) {
        const { from, to } = monthRange(filters.month);
        query = query.gte('received_on', from).lt('received_on', to);
      }
      const { data, error } = await query
        .order('received_on', { ascending: false })
        .order('created_at', { ascending: false });
      if (error) throw error;
      return (data ?? []).map((r: any) => {
        const applied = (r.allocations ?? []).reduce((s: number, a: any) => s + num(a.amount), 0);
        const { allocations: _a, ...rest } = r;
        return { ...rest, amount: num(r.amount), applied, unapplied: num(r.amount) - applied } as ReceiptListItem;
      });
    },
    enabled: !!session && !!agency?.id && isOwnerOrManager,
  });
}

export function useReceipt(id: string | undefined) {
  const { agency, session, isOwnerOrManager } = useAuth();
  return useQuery({
    queryKey: ['receipt', id],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('insurer_receipts')
        .select(`
          *,
          insurer:insurers(id, name),
          lines:statement_lines(*, policy:policies(id, policy_number)),
          allocations:commission_allocations(
            *,
            commission:commission_transactions(
              id, amount, amount_received, expected_date, period, status,
              policy:policies(id, policy_number, client:clients(id, name))
            )
          )
        `)
        .eq('id', id)
        .eq('agency_id', agency?.id)
        .maybeSingle();
      if (error) throw error;
      if (!data) return null;
      const r: any = data;
      const allocations = (r.allocations ?? []) as ReceiptAllocationDetail[];
      const applied = allocations.reduce((s, a) => s + num(a.amount), 0);
      const lines = ((r.lines ?? []) as ReceiptLineWithPolicy[]).slice().sort((a, b) => a.line_no - b.line_no);
      return { ...r, amount: num(r.amount), lines, allocations, applied, unapplied: num(r.amount) - applied } as ReceiptDetail;
    },
    enabled: !!session && !!agency?.id && !!id && isOwnerOrManager,
  });
}

export function useCreateReceipt() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (input: CreateReceiptInput) => {
      const { data, error } = await supabase.rpc('create_insurer_receipt', {
        p_insurer_id: input.insurerId,
        p_received_on: input.receivedOn,
        p_amount: input.amount,
        p_bank_reference: input.bankReference || null,
        p_file_path: input.filePath || null,
        p_lines: input.lines ?? [],
        p_allocations: input.allocations ?? [],
      });
      if (error) throw new Error(error.message);
      return data as { receipt_id: string; applied: number; unapplied: number };
    },
    onSuccess: () => invalidateReceiptQueries(qc),
  });
}

export function useLinkStatementLine() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async ({ lineId, policyId }: { lineId: string; policyId: string }) => {
      const { data, error } = await supabase.rpc('link_statement_line', {
        p_line_id: lineId,
        p_policy_id: policyId,
      });
      if (error) throw new Error(error.message);
      return data as { applied: number };
    },
    onSuccess: () => invalidateReceiptQueries(qc),
  });
}

export function useUndoAllocation() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (allocationId: string) => {
      const { error } = await supabase.rpc('undo_commission_allocation', { p_allocation_id: allocationId });
      if (error) throw new Error(error.message);
      return allocationId;
    },
    onSuccess: () => invalidateReceiptQueries(qc),
  });
}

export function useApplyReceiptAllocations() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async ({ receiptId, allocations }: { receiptId: string; allocations: { commissionId: string; amount: number }[] }) => {
      const { data, error } = await supabase.rpc('apply_receipt_allocations', {
        p_receipt_id: receiptId,
        p_allocations: allocations.map((a) => ({ commission_id: a.commissionId, amount: a.amount })),
      });
      if (error) throw new Error(error.message);
      return data as { applied: number; unapplied: number };
    },
    onSuccess: () => invalidateReceiptQueries(qc),
  });
}

export async function removeReceiptPdf(path: string): Promise<void> {
  const { error } = await supabase.storage.from('receipts').remove([path]);
  if (error) throw new Error(error.message);
}

export function useDeleteReceipt() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async ({ id, filePath }: { id: string; filePath?: string | null }) => {
      const { error } = await supabase.rpc('delete_insurer_receipt', { p_receipt_id: id });
      if (error) throw new Error(error.message);
      if (filePath) {
        // The receipt is already gone; a leftover file is not worth failing the delete for.
        try { await removeReceiptPdf(filePath); } catch { /* ignore */ }
      }
      return id;
    },
    onSuccess: () => invalidateReceiptQueries(qc),
  });
}

export function useUploadReceiptPdf() {
  return useMutation({
    mutationFn: async ({ agencyId, file }: { agencyId: string; file: File }) => {
      if (file.type !== 'application/pdf') throw new Error('Choose a PDF file');
      if (file.size > MAX_PDF_BYTES) throw new Error('The PDF must be 10 MB or smaller');
      const path = `${agencyId}/${crypto.randomUUID()}.pdf`;
      const { error } = await supabase.storage
        .from('receipts')
        .upload(path, file, { contentType: 'application/pdf', upsert: false });
      if (error) throw new Error(error.message);
      return path;
    },
  });
}

/** Signed URL (1 hour) for viewing a stored receipt PDF. */
export async function getReceiptPdfUrl(path: string): Promise<string> {
  const { data, error } = await supabase.storage.from('receipts').createSignedUrl(path, 3600);
  if (error || !data) throw new Error(error?.message ?? 'Could not open the PDF');
  return data.signedUrl;
}

/** Per insurer: money still to collect, the overdue part, and received money not yet applied. */
export function useInsurerMoneySummary() {
  const { agency, session, isOwnerOrManager } = useAuth();
  return useQuery({
    queryKey: ['insurer-money', agency?.id],
    queryFn: async () => {
      const today = new Date().toISOString().split('T')[0];
      const [commRes, recRes] = await Promise.all([
        supabase
          .from('commission_transactions')
          .select('amount, amount_received, expected_date, status, policy:policies(insurer_id)')
          .eq('agency_id', agency?.id)
          .in('status', ['pending', 'part_paid']),
        supabase
          .from('insurer_receipts')
          .select('insurer_id, amount, allocations:commission_allocations(amount)')
          .eq('agency_id', agency?.id),
      ]);
      if (commRes.error) throw commRes.error;
      if (recRes.error) throw recRes.error;

      const map = new Map<string, InsurerMoney>();
      const get = (id: string) => {
        let m = map.get(id);
        if (!m) { m = { insurerId: id, outstanding: 0, overdue: 0, unapplied: 0 }; map.set(id, m); }
        return m;
      };
      for (const c of (commRes.data ?? []) as any[]) {
        const insurerId = c.policy?.insurer_id;
        if (!insurerId) continue;
        const remaining = Math.max(num(c.amount) - num(c.amount_received), 0);
        const m = get(insurerId);
        m.outstanding += remaining;
        if (c.expected_date && c.expected_date < today) m.overdue += remaining;
      }
      for (const r of (recRes.data ?? []) as any[]) {
        const applied = (r.allocations ?? []).reduce((s: number, a: any) => s + num(a.amount), 0);
        get(r.insurer_id).unapplied += num(r.amount) - applied;
      }
      return Array.from(map.values());
    },
    enabled: !!session && !!agency?.id && isOwnerOrManager,
  });
}

export interface ReceivablePolicy {
  id: string;
  policy_number: string;
  commission_basis: 'annual' | 'per_premium';
  clientName: string;
  outstandingCents: number;
  start_date: string;
}

export interface ReceivableCommission {
  id: string;
  policyNumber: string;
  clientName: string;
  period: string | null;
  expectedDate: string | null;
  remainingCents: number;
}

/** An insurer's policies (with outstanding commission in cents) and its commissions still to collect. */
export function useInsurerReceivables(insurerId: string | undefined) {
  const { agency, session, isOwnerOrManager } = useAuth();
  return useQuery({
    queryKey: ['insurer-receivables', agency?.id, insurerId],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('policies')
        .select(
          'id, policy_number, commission_basis, start_date, client:clients(name), commissions:commission_transactions(id, amount, amount_received, expected_date, period)',
        )
        .eq('agency_id', agency?.id)
        .eq('insurer_id', insurerId)
        .order('policy_number');
      if (error) throw error;
      const policies: ReceivablePolicy[] = [];
      const commissions: ReceivableCommission[] = [];
      for (const p of (data ?? []) as any[]) {
        let outstanding = 0;
        for (const c of p.commissions ?? []) {
          const remaining = Math.max(Math.round(num(c.amount) * 100) - Math.round(num(c.amount_received) * 100), 0);
          outstanding += remaining;
          if (remaining > 0) {
            commissions.push({
              id: c.id,
              policyNumber: p.policy_number,
              clientName: p.client?.name ?? '',
              period: c.period ?? null,
              expectedDate: c.expected_date ?? null,
              remainingCents: remaining,
            });
          }
        }
        policies.push({
          id: p.id,
          policy_number: p.policy_number,
          commission_basis: p.commission_basis,
          start_date: p.start_date,
          clientName: p.client?.name ?? '',
          outstandingCents: p.commission_basis === 'per_premium' ? 0 : outstanding,
        });
      }
      commissions.sort((a, b) => (a.expectedDate ?? '').localeCompare(b.expectedDate ?? ''));
      return { policies, commissions };
    },
    enabled: !!session && !!agency?.id && !!insurerId && isOwnerOrManager,
  });
}
