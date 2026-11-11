import { useState } from 'react';
import { Link, useLocation } from 'wouter';
import { useAuth } from '@/contexts/AuthContext';
import { useAgencyUsers } from '@/hooks/queries';
import {
  useOwedToAgents, usePayouts, usePreviewPayout, useCreatePayout, useVoidPayout, useAddAdjustment,
} from '@/hooks/payouts';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Textarea } from '@/components/ui/textarea';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import {
  AlertDialog, AlertDialogAction, AlertDialogCancel, AlertDialogContent, AlertDialogDescription,
  AlertDialogFooter, AlertDialogHeader, AlertDialogTitle,
} from '@/components/ui/alert-dialog';
import { useToast } from '@/hooks/use-toast';
import { earningLabel, formatDay, kes, methodLabel, todayLocal } from '@/lib/payouts';
import { fromCents, toCents } from '@/lib/reconcile';
import type { PayoutMethod } from '@/lib/types';
import { Plus } from 'lucide-react';

const NOTHING_TO_PAY = 'Nothing to pay for this agent up to that date';
const AMOUNT_CHANGED = 'The amount owed changed — review the payout again';

function useMemberOptions() {
  const { data: users } = useAgencyUsers();
  return (users ?? []).map((u) => ({
    id: u.id,
    label: u.deactivated_at ? `${u.full_name} (removed)` : u.full_name,
  }));
}

function NewPayoutDialog({ open, onOpenChange, initialAgentId }: { open: boolean; onOpenChange: (o: boolean) => void; initialAgentId?: string }) {
  const { toast } = useToast();
  const [, navigate] = useLocation();
  const members = useMemberOptions();
  const createPayout = useCreatePayout();
  const [agentId, setAgentId] = useState(initialAgentId ?? '');
  const [periodEnd, setPeriodEnd] = useState(todayLocal());
  const [paidOn, setPaidOn] = useState(todayLocal());
  const [method, setMethod] = useState<PayoutMethod | ''>('');
  const [reference, setReference] = useState('');

  const { data: preview, isFetching, error: previewError, refetch: refetchPreview } = usePreviewPayout(agentId || undefined, periodEnd || undefined);
  const total = preview ? Number(preview.total) : 0;
  const nothing = !!preview && total <= 0;

  const reset = (o: boolean) => {
    if (!o) {
      setAgentId(initialAgentId ?? '');
      setPeriodEnd(todayLocal());
      setPaidOn(todayLocal());
      setMethod('');
      setReference('');
    }
    onOpenChange(o);
  };

  const confirm = () => {
    if (!preview) return;
    createPayout.mutate(
      { agentId, periodEnd, paidOn, method, reference, expectedTotal: total },
      {
        onSuccess: (res) => {
          toast({ title: `Payout recorded — ${kes(res.amount)}` });
          reset(false);
          navigate(`/payouts/${res.payout_id}`);
        },
        onError: (err: any) => {
          toast({ title: 'Could not record payout', description: err.message, variant: 'destructive' });
          // Stale preview: show the new amount and keep the dialog open for review
          if (err?.message === AMOUNT_CHANGED) refetchPreview();
        },
      },
    );
  };

  return (
    <Dialog open={open} onOpenChange={reset}>
      <DialogContent className="max-w-3xl max-h-[90vh] overflow-y-auto">
        <DialogHeader>
          <DialogTitle>New payout</DialogTitle>
          <DialogDescription>Pay an agent everything they are owed up to a date.</DialogDescription>
        </DialogHeader>

        <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
          <div className="space-y-2">
            <Label>Agent</Label>
            <Select value={agentId} onValueChange={setAgentId}>
              <SelectTrigger><SelectValue placeholder="Select an agent" /></SelectTrigger>
              <SelectContent>
                {members.map((m) => <SelectItem key={m.id} value={m.id}>{m.label}</SelectItem>)}
              </SelectContent>
            </Select>
          </div>
          <div className="space-y-2">
            <Label htmlFor="period-end">Pay up to</Label>
            <Input id="period-end" type="date" value={periodEnd} onChange={(e) => setPeriodEnd(e.target.value)} />
          </div>
        </div>

        {agentId && periodEnd && (
          <div className="space-y-2">
            {previewError ? (
              <div className="text-sm text-destructive">{(previewError as Error).message}</div>
            ) : isFetching && !preview ? (
              <div className="text-sm text-muted-foreground">Loading...</div>
            ) : preview ? (
              <>
                <div className="border rounded-md overflow-x-auto">
                  <Table>
                    <TableHeader>
                      <TableRow>
                        <TableHead>Earned on</TableHead>
                        <TableHead>Policy</TableHead>
                        <TableHead>Client</TableHead>
                        <TableHead className="text-right">Base</TableHead>
                        <TableHead className="text-right">Rate</TableHead>
                        <TableHead className="text-right">Earned</TableHead>
                      </TableRow>
                    </TableHeader>
                    <TableBody>
                      {preview.lines.length === 0 ? (
                        <TableRow><TableCell colSpan={6} className="text-center py-6 text-muted-foreground">Nothing owed up to that date.</TableCell></TableRow>
                      ) : preview.lines.map((l) => (
                        <TableRow key={l.id}>
                          <TableCell>{formatDay(l.earned_on)}</TableCell>
                          {l.kind === 'adjustment' ? (
                            <TableCell colSpan={4}>{earningLabel(l)}</TableCell>
                          ) : (
                            <>
                              <TableCell>
                                {l.policy_number ?? '-'}
                                {l.kind === 'reversal' && <Badge variant="secondary" className="ml-2">Reversal</Badge>}
                              </TableCell>
                              <TableCell>{l.client_name ?? '-'}</TableCell>
                              <TableCell className="text-right">{kes(l.base_amount)}</TableCell>
                              <TableCell className="text-right">{l.rate != null ? `${Number(l.rate)}%` : '-'}</TableCell>
                            </>
                          )}
                          <TableCell className="text-right font-medium">{kes(l.amount)}</TableCell>
                        </TableRow>
                      ))}
                    </TableBody>
                  </Table>
                </div>
                <div className="flex justify-between font-semibold px-1">
                  <span>Total</span>
                  <span>{kes(total)}</span>
                </div>
              </>
            ) : null}
          </div>
        )}

        {preview && !nothing && (
          <div className="grid grid-cols-1 sm:grid-cols-3 gap-4">
            <div className="space-y-2">
              <Label htmlFor="paid-on">Paid on</Label>
              <Input id="paid-on" type="date" value={paidOn} onChange={(e) => setPaidOn(e.target.value)} />
            </div>
            <div className="space-y-2">
              <Label>Method</Label>
              <Select value={method} onValueChange={(v) => setMethod(v as PayoutMethod)}>
                <SelectTrigger><SelectValue placeholder="Select method" /></SelectTrigger>
                <SelectContent>
                  <SelectItem value="mpesa">{methodLabel('mpesa')}</SelectItem>
                  <SelectItem value="bank">{methodLabel('bank')}</SelectItem>
                  <SelectItem value="cash">{methodLabel('cash')}</SelectItem>
                </SelectContent>
              </Select>
            </div>
            <div className="space-y-2">
              <Label htmlFor="reference">Reference</Label>
              <Input id="reference" value={reference} onChange={(e) => setReference(e.target.value)} placeholder="e.g. M-Pesa code" />
            </div>
          </div>
        )}

        <DialogFooter className="items-center gap-2">
          {nothing && <span className="text-sm text-muted-foreground sm:mr-auto">{NOTHING_TO_PAY}</span>}
          <Button variant="outline" onClick={() => reset(false)}>Cancel</Button>
          <Button onClick={confirm} disabled={!agentId || !preview || nothing || !method || !paidOn || isFetching || createPayout.isPending}>
            {createPayout.isPending ? 'Recording...' : 'Confirm payout'}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

function AddAdjustmentDialog({ open, onOpenChange }: { open: boolean; onOpenChange: (o: boolean) => void }) {
  const { toast } = useToast();
  const members = useMemberOptions();
  const addAdjustment = useAddAdjustment();
  const [agentId, setAgentId] = useState('');
  const [amount, setAmount] = useState('');
  const [note, setNote] = useState('');

  const reset = (o: boolean) => {
    if (!o) { setAgentId(''); setAmount(''); setNote(''); }
    onOpenChange(o);
  };

  const save = () => {
    const cents = toCents(amount);
    addAdjustment.mutate(
      { agentId, amount: cents === null ? null : fromCents(cents), note },
      {
        onSuccess: () => { toast({ title: 'Adjustment added' }); reset(false); },
        onError: (err: any) => toast({ title: 'Could not add adjustment', description: err.message, variant: 'destructive' }),
      },
    );
  };

  return (
    <Dialog open={open} onOpenChange={reset}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Add adjustment</DialogTitle>
          <DialogDescription>A bonus or correction that is added to (or, if negative, deducted from) the agent's next payout.</DialogDescription>
        </DialogHeader>
        <div className="space-y-4">
          <div className="space-y-2">
            <Label>Agent</Label>
            <Select value={agentId} onValueChange={setAgentId}>
              <SelectTrigger><SelectValue placeholder="Select an agent" /></SelectTrigger>
              <SelectContent>
                {members.map((m) => <SelectItem key={m.id} value={m.id}>{m.label}</SelectItem>)}
              </SelectContent>
            </Select>
          </div>
          <div className="space-y-2">
            <Label htmlFor="adj-amount">Amount (KES, negative to deduct)</Label>
            <Input id="adj-amount" inputMode="decimal" value={amount} onChange={(e) => setAmount(e.target.value)} placeholder="e.g. 2500 or -500" />
          </div>
          <div className="space-y-2">
            <Label htmlFor="adj-note">Note</Label>
            <Textarea id="adj-note" value={note} onChange={(e) => setNote(e.target.value)} placeholder="Why this adjustment?" />
          </div>
        </div>
        <DialogFooter>
          <Button variant="outline" onClick={() => reset(false)}>Cancel</Button>
          <Button onClick={save} disabled={!agentId || addAdjustment.isPending}>
            {addAdjustment.isPending ? 'Saving...' : 'Add adjustment'}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

export default function Payouts() {
  const { isOwner, isOwnerOrManager } = useAuth();
  const { toast } = useToast();
  const members = useMemberOptions();
  const [agentFilter, setAgentFilter] = useState('all');
  const [newOpen, setNewOpen] = useState(false);
  const [newFor, setNewFor] = useState<string | undefined>();
  const [adjOpen, setAdjOpen] = useState(false);
  const [voiding, setVoiding] = useState<string | null>(null);
  const voidPayout = useVoidPayout();

  const { data: owed, isLoading: owedLoading } = useOwedToAgents();
  const { data: payouts, isLoading } = usePayouts({ agentId: agentFilter === 'all' ? undefined : agentFilter });

  if (!isOwnerOrManager) {
    return <div className="text-muted-foreground">Only owners and managers can view payouts.</div>;
  }

  const openNew = (agentId?: string) => { setNewFor(agentId); setNewOpen(true); };

  const confirmVoid = () => {
    if (!voiding) return;
    voidPayout.mutate(voiding, {
      onSuccess: () => { toast({ title: 'Payout voided' }); setVoiding(null); },
      onError: (err: any) => { toast({ title: 'Could not void payout', description: err.message, variant: 'destructive' }); setVoiding(null); },
    });
  };

  return (
    <div className="space-y-6">
      <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-4">
        <div>
          <h1 className="text-3xl font-bold tracking-tight">Payouts</h1>
          <p className="text-muted-foreground">What each agent is owed and what has been paid.</p>
        </div>
        <div className="flex gap-2">
          {isOwner && <Button variant="outline" onClick={() => setAdjOpen(true)}>Add adjustment</Button>}
          <Button onClick={() => openNew()}><Plus className="w-4 h-4 mr-2" /> New payout</Button>
        </div>
      </div>

      <Card>
        <CardHeader className="pb-2"><CardTitle className="text-lg">Owed to agents</CardTitle></CardHeader>
        <CardContent>
          <div className="border rounded-md overflow-x-auto">
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Agent</TableHead>
                  <TableHead className="text-right">Unpaid</TableHead>
                  <TableHead>Last paid</TableHead>
                  <TableHead className="text-right"></TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {owedLoading ? (
                  <TableRow><TableCell colSpan={4} className="text-center py-6">Loading...</TableCell></TableRow>
                ) : !owed || owed.length === 0 ? (
                  <TableRow><TableCell colSpan={4} className="text-center py-6 text-muted-foreground">No agent earnings yet. Set rates under Settings, Team.</TableCell></TableRow>
                ) : owed.map((o) => (
                  <TableRow key={o.agentId}>
                    <TableCell className="font-medium">{o.name}</TableCell>
                    <TableCell className="text-right">{kes(o.unpaid)}</TableCell>
                    <TableCell>{formatDay(o.lastPaidOn)}</TableCell>
                    <TableCell className="text-right">
                      <Button variant="outline" size="sm" onClick={() => openNew(o.agentId)}>Pay</Button>
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </div>
        </CardContent>
      </Card>

      <div className="space-y-3">
        <div className="flex items-center justify-between gap-4">
          <h2 className="text-lg font-semibold tracking-tight">Payouts</h2>
          <Select value={agentFilter} onValueChange={setAgentFilter}>
            <SelectTrigger className="w-[220px] bg-card"><SelectValue placeholder="Agent" /></SelectTrigger>
            <SelectContent>
              <SelectItem value="all">All agents</SelectItem>
              {members.map((m) => <SelectItem key={m.id} value={m.id}>{m.label}</SelectItem>)}
            </SelectContent>
          </Select>
        </div>
        <div className="border rounded-md bg-card overflow-x-auto">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Paid on</TableHead>
                <TableHead>Agent</TableHead>
                <TableHead>Method</TableHead>
                <TableHead>Reference</TableHead>
                <TableHead className="text-right">Amount</TableHead>
                <TableHead>Status</TableHead>
                {isOwner && <TableHead className="text-right"></TableHead>}
              </TableRow>
            </TableHeader>
            <TableBody>
              {isLoading ? (
                <TableRow><TableCell colSpan={isOwner ? 7 : 6} className="text-center py-8">Loading...</TableCell></TableRow>
              ) : !payouts || payouts.length === 0 ? (
                <TableRow><TableCell colSpan={isOwner ? 7 : 6} className="text-center py-8 text-muted-foreground">No payouts yet.</TableCell></TableRow>
              ) : payouts.map((p) => (
                <TableRow key={p.id}>
                  <TableCell>
                    <Link href={`/payouts/${p.id}`} className="font-medium text-primary underline">{formatDay(p.paid_on)}</Link>
                  </TableCell>
                  <TableCell>{p.agent?.full_name ?? '-'}</TableCell>
                  <TableCell>{methodLabel(p.method)}</TableCell>
                  <TableCell>{p.reference ?? '-'}</TableCell>
                  <TableCell className="text-right font-medium">{kes(p.amount)}</TableCell>
                  <TableCell>{p.voided_at ? <Badge variant="destructive">Voided</Badge> : <Badge variant="success">Paid</Badge>}</TableCell>
                  {isOwner && (
                    <TableCell className="text-right">
                      {!p.voided_at && <Button variant="outline" size="sm" onClick={() => setVoiding(p.id)}>Void</Button>}
                    </TableCell>
                  )}
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </div>
      </div>

      <NewPayoutDialog key={newFor ?? 'none'} open={newOpen} onOpenChange={setNewOpen} initialAgentId={newFor} />
      {isOwner && <AddAdjustmentDialog open={adjOpen} onOpenChange={setAdjOpen} />}

      <AlertDialog open={!!voiding} onOpenChange={(o) => { if (!o) setVoiding(null); }}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>Void this payout?</AlertDialogTitle>
            <AlertDialogDescription>
              The earnings it covered become unpaid again and will be included in the agent's next payout.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Cancel</AlertDialogCancel>
            <AlertDialogAction onClick={confirmVoid} disabled={voidPayout.isPending}>Void payout</AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </div>
  );
}
