import { useMemo, useState } from 'react';
import { useLocation } from 'wouter';
import { useAuth } from '@/contexts/AuthContext';
import { useInsurers } from '@/hooks/queries';
import {
  useCreateReceipt,
  useUploadReceiptPdf,
  useInsurerReceivables,
  removeReceiptPdf,
} from '@/hooks/receipts';
import { useToast } from '@/hooks/use-toast';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';
import { LinesGrid } from '@/components/receipts/LinesGrid';
import { MatchTable, type MatchRow } from '@/components/receipts/MatchTable';
import { AllocateOutstanding, allocationCents, type AllocationState } from '@/components/receipts/AllocateOutstanding';
import { matchLines, toCents, fromCents } from '@/lib/reconcile';
import {
  emptyRow,
  rowIsEmpty,
  rowToDraft,
  gridHasErrors,
  formatKes,
  type GridRow,
} from '@/lib/receipt-grid';

const MAX_PDF_BYTES = 10 * 1024 * 1024;
const today = () => new Date().toISOString().split('T')[0];

export default function ReceiptNew() {
  const { agency, isOwnerOrManager } = useAuth();
  const [, navigate] = useLocation();
  const { toast } = useToast();

  const [step, setStep] = useState<1 | 2 | 3>(1);
  const [insurerId, setInsurerId] = useState('');
  const [receivedOn, setReceivedOn] = useState(today());
  const [amountText, setAmountText] = useState('');
  const [bankReference, setBankReference] = useState('');
  const [pdf, setPdf] = useState<File | null>(null);
  const [pdfError, setPdfError] = useState('');
  const [rows, setRows] = useState<GridRow[]>([emptyRow()]);
  const [overrides, setOverrides] = useState<Record<number, string>>({});
  const [allocState, setAllocState] = useState<AllocationState>({});
  const [submitting, setSubmitting] = useState(false);

  const { data: insurers } = useInsurers();
  const { data: receivables, isLoading: receivablesLoading } = useInsurerReceivables(insurerId || undefined);
  const createReceipt = useCreateReceipt();
  const uploadPdf = useUploadReceiptPdf();

  const amountCents = toCents(amountText);
  const detailsValid = !!insurerId && !!receivedOn && amountCents !== null && amountCents > 0;

  const filledRows = useMemo(
    () => rows.map((row, key) => ({ row, key })).filter((x) => !rowIsEmpty(x.row)),
    [rows],
  );
  const hasLines = filledRows.length > 0;
  const policies = receivables?.policies ?? [];
  const commissions = receivables?.commissions ?? [];

  const matches: MatchRow[] = useMemo(() => {
    const drafts = filledRows.map(({ row, key }) => {
      const d = rowToDraft(row);
      const overrideId = overrides[key];
      const chosen = overrideId ? policies.find((p) => p.id === overrideId) : undefined;
      // A manually chosen policy is matched by swapping in its number for matching only.
      return { key, original: d, forMatch: chosen ? { ...d, policyNumber: chosen.policy_number } : d };
    });
    const result = matchLines(
      drafts.map((d) => d.forMatch),
      policies,
    );
    return result.map((r, i) => ({
      key: drafts[i].key,
      line: drafts[i].original,
      policyId: r.policyId,
      status: r.status,
      applyCents: r.applyCents,
    }));
  }, [filledRows, overrides, policies]);

  const appliedCents = hasLines
    ? matches.reduce((s, m) => s + m.applyCents, 0)
    : commissions.reduce((s, c) => s + allocationCents(c, allocState[c.id]), 0);
  const overCents = amountCents !== null ? appliedCents - amountCents : 0;
  const overApplied = overCents > 0;

  if (!isOwnerOrManager) {
    return <div className="text-muted-foreground">Only owners and managers can record receipts.</div>;
  }

  const onPdfChange = (file: File | null) => {
    setPdfError('');
    if (!file) return setPdf(null);
    if (file.type !== 'application/pdf') {
      setPdf(null);
      return setPdfError('Choose a PDF file');
    }
    if (file.size > MAX_PDF_BYTES) {
      setPdf(null);
      return setPdfError('The PDF must be 10 MB or smaller');
    }
    setPdf(file);
  };

  const changeInsurer = (id: string) => {
    setInsurerId(id);
    setOverrides({});
    setAllocState({});
  };

  const pick = (key: number, policyId: string | null) => {
    setOverrides((prev) => {
      const next = { ...prev };
      if (policyId) next[key] = policyId;
      else delete next[key];
      return next;
    });
  };

  const gridBlocked = gridHasErrors(rows);

  const confirm = async () => {
    if (!agency?.id || amountCents === null) return;
    setSubmitting(true);
    let path: string | null = null;
    try {
      if (pdf) path = await uploadPdf.mutateAsync({ agencyId: agency.id, file: pdf });
      const lines = hasLines
        ? matches.map((m) => ({
            policy_number: m.line.policyNumber || null,
            client_name: m.line.clientName || null,
            premium: m.line.premiumCents === null ? null : fromCents(m.line.premiumCents),
            commission: fromCents(m.line.commissionCents ?? 0),
            period: m.line.period,
            policy_id: m.policyId,
          }))
        : [];
      const allocations = hasLines
        ? []
        : commissions
            .map((c) => ({ commission_id: c.id, cents: allocationCents(c, allocState[c.id]) }))
            .filter((a) => a.cents > 0)
            .map((a) => ({ commission_id: a.commission_id, amount: fromCents(a.cents) }));
      let result;
      try {
        result = await createReceipt.mutateAsync({
          insurerId,
          receivedOn,
          amount: fromCents(amountCents),
          bankReference: bankReference.trim() || null,
          filePath: path,
          lines,
          allocations,
        });
      } catch (err) {
        if (path) {
          try { await removeReceiptPdf(path); } catch { /* ignore cleanup failure */ }
        }
        throw err;
      }
      toast({
        title: `Receipt recorded — KES ${formatKes(Math.round(Number(result.applied) * 100))} applied, KES ${formatKes(Math.round(Number(result.unapplied) * 100))} unapplied`,
      });
      navigate(`/receipts/${result.receipt_id}`);
    } catch (err) {
      toast({ title: 'Could not record receipt', description: (err as Error).message, variant: 'destructive' });
      setSubmitting(false);
    }
  };

  const insurerName = insurers?.find((i) => i.id === insurerId)?.name;
  const canConfirm = detailsValid && !overApplied && !(hasLines && gridBlocked) && !submitting;

  return (
    <div className="space-y-6 max-w-4xl">
      <div>
        <h1 className="text-3xl font-bold tracking-tight">Record receipt</h1>
        <p className="text-muted-foreground">Step {step} of 3 — {['Details', 'Statement lines', 'Match & apply'][step - 1]}</p>
      </div>

      {step === 1 && (
        <Card>
          <CardHeader><CardTitle>Details</CardTitle></CardHeader>
          <CardContent className="space-y-4">
            <div className="grid gap-4 sm:grid-cols-2">
              <div className="space-y-2">
                <Label>Insurer</Label>
                <Select value={insurerId} onValueChange={changeInsurer}>
                  <SelectTrigger><SelectValue placeholder="Select insurer" /></SelectTrigger>
                  <SelectContent>
                    {insurers?.filter((i) => i.is_active || i.id === insurerId).map((i) => (
                      <SelectItem key={i.id} value={i.id}>{i.name}</SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              </div>
              <div className="space-y-2">
                <Label htmlFor="received-on">Date received</Label>
                <Input id="received-on" type="date" value={receivedOn} onChange={(e) => setReceivedOn(e.target.value)} />
              </div>
              <div className="space-y-2">
                <Label htmlFor="amount">Amount received (KES)</Label>
                <Input id="amount" inputMode="decimal" value={amountText} onChange={(e) => setAmountText(e.target.value)} />
                {amountText.trim() !== '' && (amountCents === null || amountCents <= 0) && (
                  <div className="text-xs text-destructive">Enter an amount greater than zero</div>
                )}
              </div>
              <div className="space-y-2">
                <Label htmlFor="bank-ref">Bank reference</Label>
                <Input id="bank-ref" value={bankReference} onChange={(e) => setBankReference(e.target.value)} />
              </div>
            </div>
            <div className="space-y-2">
              <Label htmlFor="pdf">Statement PDF (optional, up to 10 MB)</Label>
              <Input id="pdf" type="file" accept="application/pdf" onChange={(e) => onPdfChange(e.target.files?.[0] ?? null)} />
              {pdfError && <div className="text-xs text-destructive">{pdfError}</div>}
            </div>
            <div className="flex justify-end">
              <Button disabled={!detailsValid} onClick={() => setStep(2)}>Next</Button>
            </div>
          </CardContent>
        </Card>
      )}

      {step === 2 && (
        <Card>
          <CardHeader><CardTitle>Statement lines (optional)</CardTitle></CardHeader>
          <CardContent className="space-y-4">
            <LinesGrid rows={rows} onChange={setRows} amountCents={amountCents} />
            <div className="flex justify-between">
              <Button variant="outline" onClick={() => setStep(1)}>Back</Button>
              <Button disabled={gridBlocked} onClick={() => setStep(3)}>
                {hasLines ? 'Next: Match & apply' : 'Skip lines'}
              </Button>
            </div>
          </CardContent>
        </Card>
      )}

      {step === 3 && (
        <Card>
          <CardHeader><CardTitle>Match &amp; apply</CardTitle></CardHeader>
          <CardContent className="space-y-4">
            <div className="text-sm text-muted-foreground">
              {insurerName} — KES {amountCents !== null ? formatKes(amountCents) : '—'} received on {receivedOn}
            </div>
            {receivablesLoading ? (
              <div className="text-sm text-muted-foreground">Loading policies...</div>
            ) : hasLines ? (
              <MatchTable rows={matches} policies={policies} overrides={overrides} onPick={pick} />
            ) : (
              <AllocateOutstanding commissions={commissions} state={allocState} onChange={setAllocState} />
            )}
            <div className="text-sm">
              Applied KES {formatKes(appliedCents)}
              {amountCents !== null && !overApplied && <> — KES {formatKes(amountCents - appliedCents)} will stay unapplied</>}
            </div>
            {overApplied && (
              <div className="text-sm text-destructive">Applied amount is KES {formatKes(overCents)} more than the amount received</div>
            )}
            <div className="flex justify-between">
              <Button variant="outline" disabled={submitting} onClick={() => setStep(2)}>Back</Button>
              <Button disabled={!canConfirm || receivablesLoading} onClick={confirm}>
                {submitting ? 'Recording...' : 'Confirm'}
              </Button>
            </div>
          </CardContent>
        </Card>
      )}
    </div>
  );
}
