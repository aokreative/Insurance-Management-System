import { useState } from 'react';
import { Link, useLocation, useParams } from 'wouter';
import { useAuth } from '@/contexts/AuthContext';
import { usePolicies } from '@/hooks/queries';
import {
  useReceipt, useLinkStatementLine, useUndoAllocation, useDeleteReceipt, getReceiptPdfUrl,
  type ReceiptLineWithPolicy,
} from '@/hooks/receipts';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { Badge } from '@/components/ui/badge';
import { Input } from '@/components/ui/input';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import {
  AlertDialog, AlertDialogAction, AlertDialogCancel, AlertDialogContent, AlertDialogDescription,
  AlertDialogFooter, AlertDialogHeader, AlertDialogTitle,
} from '@/components/ui/alert-dialog';
import { useToast } from '@/hooks/use-toast';
import { formatCurrency, formatDate } from '@/lib/utils';
import { ArrowLeft, FileText, Trash2 } from 'lucide-react';

export default function ReceiptDetail() {
  const params = useParams<{ id: string }>();
  const [, navigate] = useLocation();
  const { isOwnerOrManager } = useAuth();
  const { toast } = useToast();

  const { data: receipt, isLoading } = useReceipt(params.id);
  const linkLine = useLinkStatementLine();
  const undo = useUndoAllocation();
  const deleteReceipt = useDeleteReceipt();

  const [linkingLine, setLinkingLine] = useState<ReceiptLineWithPolicy | null>(null);
  const [policySearch, setPolicySearch] = useState('');
  const [deleteOpen, setDeleteOpen] = useState(false);
  const { data: insurerPolicies } = usePolicies(receipt ? { insurerId: receipt.insurer_id } : undefined);

  const showError = (err: Error) => toast({ title: 'Error', description: err.message, variant: 'destructive' });

  if (!isOwnerOrManager) {
    return <div className="text-muted-foreground">Only owners and managers can view receipts.</div>;
  }
  if (isLoading) return <div className="py-8 text-center">Loading...</div>;
  if (!receipt) {
    return (
      <div className="space-y-4">
        <Button variant="ghost" onClick={() => navigate('/receipts')}><ArrowLeft className="w-4 h-4 mr-2" /> Receipts</Button>
        <div className="text-muted-foreground">Receipt not found</div>
      </div>
    );
  }

  const openPdf = async () => {
    if (!receipt.file_path) return;
    try {
      const url = await getReceiptPdfUrl(receipt.file_path);
      window.open(url, '_blank', 'noopener');
    } catch (err) {
      showError(err as Error);
    }
  };

  const appliedByLine = new Map<string, number>();
  for (const a of receipt.allocations) {
    if (a.statement_line_id) appliedByLine.set(a.statement_line_id, (appliedByLine.get(a.statement_line_id) ?? 0) + a.amount);
  }

  const lineStatus = (l: ReceiptLineWithPolicy) => {
    if (!l.policy_id) return { label: 'Unmatched', variant: 'destructive' as const };
    if ((appliedByLine.get(l.id) ?? 0) > 0) return { label: 'Applied', variant: 'success' as const };
    return { label: 'Matched', variant: 'secondary' as const };
  };

  const term = policySearch.trim().toLowerCase();
  const policyOptions = (insurerPolicies ?? []).filter(p =>
    !term || p.policy_number.toLowerCase().includes(term) || (p.client?.name ?? '').toLowerCase().includes(term));

  const handleLink = (policyId: string) => {
    if (!linkingLine) return;
    linkLine.mutate({ lineId: linkingLine.id, policyId }, {
      onSuccess: (res) => {
        toast({ title: `Linked — KES ${Number(res.applied).toLocaleString('en-KE')} applied` });
        setLinkingLine(null);
        setPolicySearch('');
      },
      onError: showError,
    });
  };

  const handleUndo = (id: string) => {
    undo.mutate(id, {
      onSuccess: () => toast({ title: 'Applied amount undone' }),
      onError: showError,
    });
  };

  const handleDelete = () => {
    deleteReceipt.mutate({ id: receipt.id, filePath: receipt.file_path }, {
      onSuccess: () => {
        toast({ title: 'Receipt deleted' });
        navigate('/receipts');
      },
      onError: (err) => { showError(err); setDeleteOpen(false); },
    });
  };

  const canDelete = !receipt.is_opening_balance && receipt.allocations.length === 0;

  return (
    <div className="space-y-6">
      <Button variant="ghost" size="sm" onClick={() => navigate('/receipts')}><ArrowLeft className="w-4 h-4 mr-2" /> Receipts</Button>

      <div className="flex flex-col sm:flex-row sm:items-start justify-between gap-4">
        <div>
          <h1 className="text-3xl font-bold tracking-tight">{receipt.insurer?.name ?? 'Receipt'}</h1>
          <p className="text-muted-foreground">
            Received {formatDate(receipt.received_on)}
            {receipt.bank_reference ? ` - Ref ${receipt.bank_reference}` : ''}
            {receipt.is_opening_balance && <Badge variant="secondary" className="ml-2 text-muted-foreground">Opening balance</Badge>}
          </p>
        </div>
        <div className="flex gap-2">
          {receipt.file_path && (
            <Button variant="outline" onClick={openPdf}><FileText className="w-4 h-4 mr-2" /> View PDF</Button>
          )}
          {!receipt.is_opening_balance && (
            <Button variant="destructive" disabled={!canDelete} onClick={() => setDeleteOpen(true)}>
              <Trash2 className="w-4 h-4 mr-2" /> Delete
            </Button>
          )}
        </div>
      </div>

      <div className="grid grid-cols-1 sm:grid-cols-3 gap-4">
        <Card><CardContent className="p-4"><div className="text-sm text-muted-foreground">Amount</div><div className="text-xl font-bold">{formatCurrency(receipt.amount)}</div></CardContent></Card>
        <Card><CardContent className="p-4"><div className="text-sm text-muted-foreground">Applied</div><div className="text-xl font-bold">{formatCurrency(receipt.applied)}</div></CardContent></Card>
        <Card><CardContent className="p-4"><div className="text-sm text-muted-foreground">Unapplied</div><div className="text-xl font-bold">{formatCurrency(receipt.unapplied)}</div></CardContent></Card>
      </div>

      {receipt.lines.length > 0 && (
        <div className="space-y-3">
          <h2 className="text-lg font-semibold tracking-tight">Statement lines</h2>
          <div className="border rounded-md bg-card overflow-hidden">
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>#</TableHead>
                  <TableHead>Policy number</TableHead>
                  <TableHead>Client</TableHead>
                  <TableHead>Period</TableHead>
                  <TableHead className="text-right">Commission</TableHead>
                  <TableHead>Status</TableHead>
                  <TableHead className="text-right">Action</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {receipt.lines.map(l => {
                  const st = lineStatus(l);
                  return (
                    <TableRow key={l.id}>
                      <TableCell>{l.line_no}</TableCell>
                      <TableCell>{l.policy_number ?? '-'}</TableCell>
                      <TableCell>{l.client_name ?? '-'}</TableCell>
                      <TableCell>{formatDate(l.period)}</TableCell>
                      <TableCell className="text-right">{formatCurrency(l.commission)}</TableCell>
                      <TableCell><Badge variant={st.variant}>{st.label}</Badge></TableCell>
                      <TableCell className="text-right">
                        {!l.policy_id && (
                          <Button size="sm" variant="outline" onClick={() => { setLinkingLine(l); setPolicySearch(l.policy_number ?? ''); }}>
                            Link to policy
                          </Button>
                        )}
                      </TableCell>
                    </TableRow>
                  );
                })}
              </TableBody>
            </Table>
          </div>
        </div>
      )}

      <div className="space-y-3">
        <h2 className="text-lg font-semibold tracking-tight">Applied to commissions</h2>
        <div className="border rounded-md bg-card overflow-hidden">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Policy</TableHead>
                <TableHead>Client</TableHead>
                <TableHead>Expected</TableHead>
                <TableHead className="text-right">Applied</TableHead>
                <TableHead className="text-right">Action</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {receipt.allocations.length === 0 ? (
                <TableRow><TableCell colSpan={5} className="text-center py-8 text-muted-foreground">Nothing applied yet.</TableCell></TableRow>
              ) : receipt.allocations.map(a => (
                <TableRow key={a.id}>
                  <TableCell>
                    {a.commission?.policy ? (
                      <Link href="/commissions" className="font-medium text-primary underline">{a.commission.policy.policy_number}</Link>
                    ) : '-'}
                  </TableCell>
                  <TableCell>{a.commission?.policy?.client?.name ?? '-'}</TableCell>
                  <TableCell>{a.commission ? formatCurrency(a.commission.amount) : '-'}</TableCell>
                  <TableCell className="text-right font-medium">{formatCurrency(a.amount)}</TableCell>
                  <TableCell className="text-right">
                    <Button size="sm" variant="outline" disabled={undo.isPending} onClick={() => handleUndo(a.id)}>Undo</Button>
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </div>
      </div>

      <Dialog open={!!linkingLine} onOpenChange={(open) => { if (!open) { setLinkingLine(null); setPolicySearch(''); } }}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Link to policy</DialogTitle>
            <DialogDescription>
              Policies with {receipt.insurer?.name ?? 'this insurer'} only. Line: {linkingLine?.policy_number ?? '-'} / {linkingLine?.client_name ?? '-'}.
            </DialogDescription>
          </DialogHeader>
          <Input placeholder="Search policy number or client..." value={policySearch} onChange={(e) => setPolicySearch(e.target.value)} />
          <div className="max-h-72 overflow-y-auto border rounded-md divide-y">
            {policyOptions.length === 0 ? (
              <div className="p-4 text-sm text-muted-foreground text-center">No matching policies.</div>
            ) : policyOptions.slice(0, 50).map(p => (
              <button
                key={p.id}
                type="button"
                className="w-full text-left px-3 py-2 hover:bg-muted disabled:opacity-50"
                disabled={linkLine.isPending}
                onClick={() => handleLink(p.id)}
              >
                <div className="font-medium text-sm">{p.policy_number}</div>
                <div className="text-xs text-muted-foreground">{p.client?.name ?? '-'}</div>
              </button>
            ))}
          </div>
        </DialogContent>
      </Dialog>

      <AlertDialog open={deleteOpen} onOpenChange={setDeleteOpen}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>Delete this receipt?</AlertDialogTitle>
            <AlertDialogDescription>
              This removes the receipt, its statement lines and the stored PDF. This cannot be undone.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Cancel</AlertDialogCancel>
            <AlertDialogAction onClick={handleDelete} disabled={deleteReceipt.isPending}>Delete</AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </div>
  );
}
